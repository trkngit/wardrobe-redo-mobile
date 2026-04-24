#!/bin/bash
# One-shot pod training health check. Emits a JSON blob on stdout and exits
# 0=green / 2=anomaly / 3=completed (DONE.txt present) / 1=infra error.
#
# Invoked by:
#   - Layer-2 scheduled task (wakes Claude when exit != 0)
#   - ad-hoc diagnostics from the CLI
#
# Env overrides:
#   POD_KEY POD_IP POD_PORT TRAIN_PID WATCHDOG_PID (see watch_pod.sh)

set -u

POD_KEY="${POD_KEY:-$HOME/.ssh/id_ed25519_runpod}"
POD_IP="${POD_IP:-213.192.2.77}"
POD_PORT="${POD_PORT:-40172}"
TRAIN_PID="${TRAIN_PID:-11882}"
WATCHDOG_PID="${WATCHDOG_PID:-12540}"

SSH=(ssh -i "$POD_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=10 -o ServerAliveInterval=15 -p "$POD_PORT" "root@$POD_IP")

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
    HARD_ANOM=$(tail -300 "$LOG" 2>/dev/null \
        | grep -iE "(NaN|out of memory|CUDA out of memory|CUDA error|Traceback|RuntimeError|AssertionError)" \
        | tail -3 | tr "\n" "|" || true)
    LATEST_AP=$(tail -200 "$LOG" 2>/dev/null \
        | grep -oE "(bbox_AP_50|segm_AP_50|AP@0\.5|bbox_AP50|segm_AP50|Average Precision.*IoU=0\.50 .*=)[: =]+[0-9]+\.[0-9]+" \
        | tail -1 | grep -oE "[0-9]+\.[0-9]+" || echo "0")
    DONE_CONTENT=$(cat /workspace/training/DONE.txt 2>/dev/null || echo "")
    EPOCH_HINT=$(tail -100 "$LOG" 2>/dev/null \
        | grep -oE "[Ee]poch: *\[?[0-9]+/?[0-9]*\]?|Epoch [0-9]+/[0-9]+" | tail -1 || true)
    printf "PID_OK=%s\nWD_OK=%s\nGPU=%s\nLAST_LOG_TS=%s\nCKPT_TS=%s\nNOW=%s\nLATEST_AP=%s\n" \
        "$PID_OK" "$WD_OK" "$GPU" "$LAST_LOG_TS" "$CKPT_TS" "$NOW" "$LATEST_AP"
    printf "LAST_LOG_LINE=%s\n" "$LAST_LOG_LINE"
    printf "HARD_ANOM=%s\n" "$HARD_ANOM"
    printf "DONE_CONTENT=%s\n" "$DONE_CONTENT"
    printf "EPOCH_HINT=%s\n" "$EPOCH_HINT"
'

raw=$("${SSH[@]}" "$remote_script" 2>/dev/null)
ssh_exit=$?

if [[ $ssh_exit -ne 0 ]]; then
    printf '{"status":"error","reason":"ssh_failed","ssh_exit":%d}\n' "$ssh_exit"
    exit 1
fi

get() { grep "^$1=" <<<"$raw" | head -1 | cut -d= -f2- | tr -d '\r'; }

PID_OK=$(get PID_OK)
WD_OK=$(get WD_OK)
GPU=$(get GPU)
LAST_LOG_TS=$(get LAST_LOG_TS)
CKPT_TS=$(get CKPT_TS)
NOW=$(get NOW)
LATEST_AP=$(get LATEST_AP)
LAST_LOG_LINE=$(get LAST_LOG_LINE)
HARD_ANOM=$(get HARD_ANOM)
DONE_CONTENT=$(get DONE_CONTENT)
EPOCH_HINT=$(get EPOCH_HINT)

log_stall=$(( NOW - LAST_LOG_TS ))
ckpt_age=$(( NOW - CKPT_TS ))

anomalies=()
[[ "$PID_OK" == "0" && -z "$DONE_CONTENT" ]] && anomalies+=("TRAIN_EXITED_NO_DONE")
[[ -n "$HARD_ANOM" ]] && anomalies+=("HARD_KEYWORD")
[[ "$PID_OK" == "1" && "$log_stall" -gt 300 ]] && anomalies+=("LOG_STALLED_${log_stall}s")

status="green"
exit_code=0
if [[ -n "$DONE_CONTENT" ]]; then
    if grep -q "STATUS=OK" <<<"$DONE_CONTENT"; then
        status="done_ok"
    else
        status="done_fail"
    fi
    exit_code=3
elif [[ ${#anomalies[@]} -gt 0 ]]; then
    status="anomaly"
    exit_code=2
fi

# JSON escape helper (basic — handles \, ", newlines, and control chars)
jesc() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

printf '{'
printf '"status":%s,' "$(jesc "$status")"
printf '"timestamp":%s,' "$(jesc "$(date -Iseconds)")"
printf '"train_pid_alive":%s,' "$PID_OK"
printf '"watchdog_pid_alive":%s,' "$WD_OK"
printf '"gpu":%s,' "$(jesc "$GPU")"
printf '"epoch_hint":%s,' "$(jesc "$EPOCH_HINT")"
printf '"latest_ap":%s,' "$(jesc "$LATEST_AP")"
printf '"log_stall_seconds":%s,' "$log_stall"
printf '"ckpt_age_seconds":%s,' "$ckpt_age"
printf '"last_log_line":%s,' "$(jesc "$LAST_LOG_LINE")"
printf '"hard_anom":%s,' "$(jesc "$HARD_ANOM")"
printf '"done":%s,' "$(jesc "$DONE_CONTENT")"
printf '"anomalies":['
first=1
for a in "${anomalies[@]:-}"; do
    [[ -z "$a" ]] && continue
    [[ $first -eq 1 ]] || printf ','
    printf '%s' "$(jesc "$a")"
    first=0
done
printf ']'
printf '}\n'

exit "$exit_code"
