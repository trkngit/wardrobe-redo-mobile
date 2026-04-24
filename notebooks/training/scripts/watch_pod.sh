#!/bin/bash
# Layer-1 training monitor — single-line rolling status, tmux-friendly.
#
# Usage:
#   bash notebooks/training/scripts/watch_pod.sh
#
# Env overrides:
#   POD_KEY       — ssh private key   (default ~/.ssh/id_ed25519_runpod)
#   POD_IP        — pod IP             (default 213.192.2.77)
#   POD_PORT      — pod ssh port       (default 40172)
#   TRAIN_PID     — train.py pid       (default 11882)
#   WATCHDOG_PID  — watchdog pid       (default 12540)
#   INTERVAL      — seconds between polls (default 30)
#
# Exits 0 on clean completion (DONE.txt STATUS=OK), 2 on anomaly, 1 on error.

set -u

POD_KEY="${POD_KEY:-$HOME/.ssh/id_ed25519_runpod}"
POD_IP="${POD_IP:-213.192.2.77}"
POD_PORT="${POD_PORT:-40172}"
TRAIN_PID="${TRAIN_PID:-11882}"
WATCHDOG_PID="${WATCHDOG_PID:-12540}"
INTERVAL="${INTERVAL:-30}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
GREY=$'\033[0;90m'
NC=$'\033[0m'
BELL=$'\007'

SSH=(ssh -i "$POD_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=10 -o ServerAliveInterval=15 -p "$POD_PORT" "root@$POD_IP")

ANOMALY_LOG="/tmp/watch_pod_anomalies.log"
LAST_ANOMALY_HASH_FILE="/tmp/watch_pod_last_anomaly_hash"
AP_HISTORY_FILE="/tmp/watch_pod_ap_history"

: > "$ANOMALY_LOG"
: > "$AP_HISTORY_FILE"
echo "" > "$LAST_ANOMALY_HASH_FILE"

anomaly_print() {
    local kind="$1" msg="$2"
    local line="$(date -Iseconds) ${kind}: ${msg}"
    echo "$line" >> "$ANOMALY_LOG"
    printf "\n${RED}%s${BELL}${NC}\n" "$line"
}

# Soft AP-regression check: appends epoch AP numbers (if present in log) to
# AP_HISTORY_FILE. If the latest two entries both regress vs. the epoch best,
# fires an anomaly.
check_ap_regression() {
    local latest_ap="$1"
    if [[ -z "$latest_ap" || "$latest_ap" == "0" ]]; then return; fi
    echo "$latest_ap" >> "$AP_HISTORY_FILE"
    awk -v cur="$latest_ap" '
        { history[NR] = $1 }
        END {
            if (NR < 3) exit 0
            best = 0
            for (i = 1; i < NR; i++) if (history[i] > best) best = history[i]
            prev = history[NR - 1]
            drop_cur = best > 0 ? (best - history[NR]) / best : 0
            drop_prev = best > 0 ? (best - prev) / best : 0
            if (drop_cur > 0.10 && drop_prev > 0.10) {
                printf("SOFT_REGRESSION cur=%.3f prev=%.3f best=%.3f\n", history[NR], prev, best)
                exit 2
            }
        }
    ' "$AP_HISTORY_FILE" >/tmp/watch_pod_ap_check.out
    if [[ -s /tmp/watch_pod_ap_check.out ]]; then
        anomaly_print "AP_REGRESSION" "$(cat /tmp/watch_pod_ap_check.out)"
    fi
}

echo "${CYAN}[watch_pod] starting — interval=${INTERVAL}s train=${TRAIN_PID} wd=${WATCHDOG_PID} pod=${POD_IP}:${POD_PORT}${NC}"

while true; do
    # Collect everything in one SSH round-trip for speed.
    remote_script='
        PID_OK=0; WD_OK=0
        kill -0 '"$TRAIN_PID"' 2>/dev/null && PID_OK=1
        kill -0 '"$WATCHDOG_PID"' 2>/dev/null && WD_OK=1
        GPU=$(nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d " ")
        LOG=/workspace/training/logs/train_p2.log
        LAST_LOG_LINE=$(tail -1 "$LOG" 2>/dev/null)
        LAST_LOG_TS=$(stat -c %Y "$LOG" 2>/dev/null || echo 0)
        CKPT_TS=$(stat -c %Y /workspace/training/checkpoints-p2/checkpoint_best_ema.pth 2>/dev/null || echo 0)
        NOW=$(date +%s)
        # Hard anomaly scan — grep last 200 lines for trouble keywords.
        HARD_ANOM=$(tail -200 "$LOG" 2>/dev/null \
            | grep -iE "(NaN|out of memory|OOM|CUDA error|CUDA out of memory|Traceback|RuntimeError|AssertionError)" \
            | tail -3 || true)
        # Soft AP extraction — grep last 50 lines for any AP@0.5 number.
        LATEST_AP=$(tail -50 "$LOG" 2>/dev/null \
            | grep -oE "(bbox_AP_50|segm_AP_50|AP@0\.5|bbox_AP50|segm_AP50)[: =]+[0-9]+\.[0-9]+" \
            | tail -1 | grep -oE "[0-9]+\.[0-9]+" || echo "0")
        DONE_CONTENT=$(cat /workspace/training/DONE.txt 2>/dev/null || echo "")
        echo "PID_OK=$PID_OK"
        echo "WD_OK=$WD_OK"
        echo "GPU=$GPU"
        echo "LAST_LOG_LINE=$LAST_LOG_LINE"
        echo "LAST_LOG_TS=$LAST_LOG_TS"
        echo "CKPT_TS=$CKPT_TS"
        echo "NOW=$NOW"
        echo "HARD_ANOM=$HARD_ANOM"
        echo "LATEST_AP=$LATEST_AP"
        echo "DONE_CONTENT=$DONE_CONTENT"
    '
    raw=$("${SSH[@]}" "$remote_script" 2>&1)
    ssh_exit=$?

    if [[ $ssh_exit -ne 0 ]]; then
        printf "\r[%s] ${YELLOW}SSH error (exit %d) — retry in %ds${NC}\n" \
            "$(date +%H:%M:%S)" "$ssh_exit" "$INTERVAL"
        sleep "$INTERVAL"
        continue
    fi

    PID_OK=$(grep "^PID_OK=" <<<"$raw" | cut -d= -f2-)
    WD_OK=$(grep "^WD_OK=" <<<"$raw" | cut -d= -f2-)
    GPU=$(grep "^GPU=" <<<"$raw" | cut -d= -f2- | tr -d '\r')
    LAST_LOG_LINE=$(grep "^LAST_LOG_LINE=" <<<"$raw" | cut -d= -f2- | tr -d '\r')
    LAST_LOG_TS=$(grep "^LAST_LOG_TS=" <<<"$raw" | cut -d= -f2-)
    CKPT_TS=$(grep "^CKPT_TS=" <<<"$raw" | cut -d= -f2-)
    NOW=$(grep "^NOW=" <<<"$raw" | cut -d= -f2-)
    HARD_ANOM=$(grep "^HARD_ANOM=" <<<"$raw" | cut -d= -f2-)
    LATEST_AP=$(grep "^LATEST_AP=" <<<"$raw" | cut -d= -f2-)
    DONE_CONTENT=$(grep "^DONE_CONTENT=" <<<"$raw" | cut -d= -f2-)

    # Derived metrics
    log_stall=$(( NOW - LAST_LOG_TS ))
    ckpt_age=$(( NOW - CKPT_TS ))

    # ---- Anomaly gating ----
    # A) Training PID died unexpectedly (and no DONE file yet) — soft signal
    if [[ "$PID_OK" == "0" && -z "$DONE_CONTENT" ]]; then
        anomaly_print "TRAIN_EXITED_NO_DONE" "train PID $TRAIN_PID not alive, DONE.txt absent"
    fi
    # B) Hard-anomaly keyword (only if different from last alert)
    if [[ -n "$HARD_ANOM" ]]; then
        h=$(md5 -q -s "$HARD_ANOM" 2>/dev/null || md5sum <<<"$HARD_ANOM" | cut -d' ' -f1)
        last_h=$(cat "$LAST_ANOMALY_HASH_FILE" 2>/dev/null)
        if [[ "$h" != "$last_h" ]]; then
            anomaly_print "HARD_KEYWORD" "$HARD_ANOM"
            echo "$h" > "$LAST_ANOMALY_HASH_FILE"
        fi
    fi
    # C) Log stalled (> 5 min with training still alleged to be running)
    if [[ "$PID_OK" == "1" && "$log_stall" -gt 300 ]]; then
        anomaly_print "LOG_STALLED" "train.log untouched for ${log_stall}s while train PID alive"
    fi
    # D) DONE marker appeared — wake event
    if [[ -n "$DONE_CONTENT" ]]; then
        status_kind="DONE_OK"
        grep -q "STATUS=OK" <<<"$DONE_CONTENT" || status_kind="DONE_FAIL"
        printf "\n${GREEN}[%s] DONE.txt present: %s${NC}${BELL}\n" "$(date +%H:%M:%S)" "$DONE_CONTENT"
        echo "$(date -Iseconds) ${status_kind}: ${DONE_CONTENT}" >> "$ANOMALY_LOG"
        if [[ "$status_kind" == "DONE_OK" ]]; then
            exit 0
        else
            exit 2
        fi
    fi
    # E) Soft regression
    check_ap_regression "$LATEST_AP"

    # ---- Status line ----
    if [[ "$PID_OK" == "1" && "$WD_OK" == "1" ]]; then
        status="${GREEN}UP${NC}"
    elif [[ "$PID_OK" == "0" && "$WD_OK" == "1" ]]; then
        status="${YELLOW}TRAIN_DONE_WATCHDOG_RUNNING${NC}"
    else
        status="${RED}DEGRADED${NC}"
    fi
    printf "\r${GREY}[%s]${NC} %s GPU=%-18s AP=%-5s ckpt_age=%-4ds log_stall=%-4ds %.80s   \r" \
        "$(date +%H:%M:%S)" "$status" "$GPU" "$LATEST_AP" "$ckpt_age" "$log_stall" "$LAST_LOG_LINE"

    sleep "$INTERVAL"
done
