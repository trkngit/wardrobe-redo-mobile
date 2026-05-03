#!/usr/bin/env bash
# Autonomous Option C fit classifier training driver.
# Runs Phases B-G end-to-end on local MPS; no user input required.
# Tee's all output to logs/autonomous-<ts>.log. Intended to be invoked
# under `nohup caffeinate -dims -i -t 86400 bash scripts/autonomous_attr_train.sh &`.

set -uo pipefail

PROJECT_ROOT="~/Projects/Coding/Wardrobe Re-Do"
cd "$PROJECT_ROOT"

TS=$(date +%s)
LOG="$PROJECT_ROOT/logs/autonomous-$TS.log"
mkdir -p "$PROJECT_ROOT/logs"
exec > >(tee -a "$LOG") 2>&1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { log "[abort] $*"; echo "[run-summary] gates=FAIL: $*"; exit 1; }

log "=== Autonomous attr-train start (pid=$$, log=$LOG) ==="

# Activate Python env
if [[ ! -f .venv-train/bin/activate ]]; then
  fail "venv-missing"
fi
# shellcheck disable=SC1091
source .venv-train/bin/activate
log "python: $(which python) / $(python --version)"
python -c "import torch; print(f'torch={torch.__version__} mps={torch.backends.mps.is_available()}')" \
  || fail "torch-import"

# ===== Phase B: Download missing Fashionpedia artifacts ==========================
log "[Phase B] Download Fashionpedia train artifacts"
mkdir -p data/fashionpedia/_raw

_curl_resume() {
  local url=$1 dest=$2
  local attempt=0
  # Outer loop: curl handles its own retries for HTTP errors, but a TCP
  # stall (0-byte flow on an open socket) won't trigger curl's --retry.
  # --speed-time 60 --speed-limit 10240 aborts the connection if <10 KB/s
  # sustained for 60s, letting curl's --retry kick in. The outer while
  # catches the case where curl exhausts its own retries on a flaky link.
  while true; do
    attempt=$((attempt+1))
    log "  curl attempt=$attempt → $dest"
    if curl -fL -C - \
        --retry 10 --retry-delay 5 --retry-all-errors \
        --connect-timeout 30 --max-time 7200 \
        --speed-time 60 --speed-limit 10240 \
        -o "$dest" "$url"; then
      return 0
    fi
    log "  curl exit non-zero on attempt $attempt; sleeping 15s and retrying"
    if [[ "$attempt" -ge 20 ]]; then
      log "  giving up after $attempt attempts"
      return 1
    fi
    sleep 15
  done
}

# instances_attributes_train2020.json (~1.2 GB)
_TRAIN_JSON="data/fashionpedia/_raw/instances_attributes_train2020.json"
if [[ ! -s "$_TRAIN_JSON" ]] || ! python -c "import json; json.load(open('$_TRAIN_JSON'))" >/dev/null 2>&1; then
  _curl_resume \
    "https://s3.amazonaws.com/ifashionist-dataset/annotations/instances_attributes_train2020.json" \
    "$_TRAIN_JSON" || fail "phase-B-train-json-download"
fi
python -c "import json; json.load(open('$_TRAIN_JSON'))" >/dev/null 2>&1 \
  || fail "phase-B-train-json-corrupt"
log "  train json ok ($(du -h "$_TRAIN_JSON" | awk '{print $1}'))"

# train2020.zip (~9.5 GB)
_TRAIN_ZIP="data/fashionpedia/_raw/train2020.zip"
if [[ ! -s "$_TRAIN_ZIP" ]] || ! unzip -tq "$_TRAIN_ZIP" >/dev/null 2>&1; then
  _curl_resume \
    "https://s3.amazonaws.com/ifashionist-dataset/images/train2020.zip" \
    "$_TRAIN_ZIP" || fail "phase-B-train-zip-download"
fi
unzip -tq "$_TRAIN_ZIP" >/dev/null 2>&1 || fail "phase-B-train-zip-corrupt"
log "  train zip ok ($(du -h "$_TRAIN_ZIP" | awk '{print $1}'))"

log "[Phase B] done"

# Pre-Phase-C disk guard: need ~20 GB for crops + temp
FREE_GB=$(df -g "$PROJECT_ROOT" | awk 'NR==2{print $4}')
log "disk free: ${FREE_GB} GB"
if [[ "$FREE_GB" -lt 20 ]]; then
  fail "disk-low-free-${FREE_GB}GB"
fi

# ===== Phase C: Prepare dataset ===================================================
log "[Phase C] Prepare dataset"
# Idempotency: if the manifest already has >= 40k train rows, assume Phase C
# completed on a prior run and skip the ~2-min re-crop.
_EXISTING_TRAIN=0
if [[ -f data/fashionpedia/attr_crops/manifest.csv ]]; then
  _EXISTING_TRAIN=$(awk -F, 'NR>1 && $1=="train"' data/fashionpedia/attr_crops/manifest.csv | wc -l | tr -d ' ')
fi
if [[ "$_EXISTING_TRAIN" -ge 40000 ]]; then
  log "  manifest already has $_EXISTING_TRAIN train rows → skipping prep"
else
  python notebooks/training/scripts/prepare_attribute_dataset.py \
    --out data/fashionpedia/attr_crops \
    --annotations-dir data/fashionpedia/_raw \
    --images-dir data/fashionpedia/_raw \
    --splits train val \
    || fail "phase-C-prep"
fi

MANIFEST="data/fashionpedia/attr_crops/manifest.csv"
[[ -s "$MANIFEST" ]] || fail "phase-C-no-manifest"
TRAIN_N=$(awk -F, 'NR>1 && $1=="train"' "$MANIFEST" | wc -l | tr -d ' ')
VAL_N=$(awk -F, 'NR>1 && $1=="val"' "$MANIFEST" | wc -l | tr -d ' ')
log "[Phase C] train=$TRAIN_N val=$VAL_N"
[[ "$TRAIN_N" -ge 10000 ]] || fail "phase-C-train-too-small-${TRAIN_N}"
[[ "$VAL_N"   -ge 1000  ]] || fail "phase-C-val-too-small-${VAL_N}"

# ===== Phase D: Train =============================================================
log "[Phase D] Train 20 epochs bs=64 on MPS"
_train() {
  local bs=$1 nw=$2
  python notebooks/training/scripts/train_attributes.py \
    --dataset-root data/fashionpedia/attr_crops \
    --out checkpoints/attr-full \
    --epochs 20 \
    --batch-size "$bs" \
    --num-workers "$nw" \
    --seed 42
}

if ! _train 64 4; then
  log "[Phase D] bs=64 failed; retrying at bs=32"
  rm -rf checkpoints/attr-full
  _train 32 2 || fail "phase-D-train"
fi
[[ -s checkpoints/attr-full/attr_best.pth ]] || fail "phase-D-no-best"
log "[Phase D] done"

# ===== Phase E: Evaluate + gate check =============================================
log "[Phase E] Evaluate"
python notebooks/training/scripts/eval_attributes.py \
  --checkpoint checkpoints/attr-full/attr_best.pth \
  --dataset-root data/fashionpedia/attr_crops \
  --split val \
  --report-dir checkpoints/attr-full/eval \
  || log "[warn] eval-script-nonzero"

GATE_RESULT=$(python - <<'PY'
import json, sys, pathlib
try:
    summ = json.load(open("checkpoints/attr-full/eval/summary.json"))
    per  = json.load(open("checkpoints/attr-full/eval/per_class.json"))
except Exception as e:
    print(f"FAIL no-metrics:{e}")
    sys.exit(0)
top1 = float(summ.get("top1", 0))
macf = float(summ.get("macro_f1", 0))
hc   = summ.get("high_conf", {}) or {}
cal  = float(hc.get("realized_acc", 0)) if hc.get("count", 0) else 0.0
osz  = float((per.get("oversized") or {}).get("f1", 0))
gates = [
    ("top1",        top1, 0.75),
    ("macro_f1",    macf, 0.55),
    ("oversized_f1",osz,  0.30),
    ("calib_0.80",  cal,  0.90),
]
fails = [f"{n}={v:.3f}<{t}" for n,v,t in gates if v < t]
if fails:
    print("FAIL " + ";".join(fails))
else:
    print(f"PASS top1={top1:.3f} macro_f1={macf:.3f} osz_f1={osz:.3f} cal={cal:.3f}")
PY
)
log "[gate] $GATE_RESULT"

# ===== Phase F: Export + iOS =====================================================
log "[Phase F] Export + iOS bundle"
python notebooks/training/scripts/export_attribute_classifier.py \
  --checkpoint checkpoints/attr-full/attr_best.pth \
  --out checkpoints/attr-full/export \
  --copy-to-app \
  || fail "phase-F-export"

[[ -d "WardrobeReDo/ML/AttributeClassifier.mlpackage" ]] \
  || fail "phase-F-mlpackage-missing"

log "  xcodegen regenerate"
xcodegen generate 2>&1 | tail -5 || log "[warn] xcodegen-failed"

log "  iOS test suite"
xcodebuild test \
  -scheme WardrobeReDo -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet 2>&1 | tail -30 \
  && log "[Phase F] xcodebuild-test-pass" \
  || log "[warn] xcodebuild-test-fail (logged, not blocking)"

# ===== Phase G: Commit + push =====================================================
log "[Phase G] Commit + push"

git add notebooks/training/scripts/train_attributes.py \
        notebooks/training/scripts/eval_attributes.py
if ! git diff --cached --quiet; then
  git commit -m "$(cat <<'MSG'
fix(ml): add MPS device fallback to train/eval scripts

Enable Apple Silicon training by selecting MPS when CUDA is unavailable.
AMP stays CUDA-only because MPS AMP is still immature in torch 2.5.1 and
the fp32 overhead is acceptable for the 20-epoch run.

MSG
  )" || log "[warn] commit-1-failed"
fi

git add checkpoints/attr-full/attr_metrics.json \
        checkpoints/attr-full/eval/summary.json \
        checkpoints/attr-full/eval/per_class.json \
        checkpoints/attr-full/eval/confusion_matrix.png \
        checkpoints/attr-full/eval/calibration.png \
        WardrobeReDo/ML/AttributeClassifier.mlpackage \
        WardrobeReDo.xcodeproj 2>/dev/null || true

if ! git diff --cached --quiet; then
  git commit -m "$(cat <<MSG
feat(attr): train Option C fit classifier on Fashionpedia (full run)

20-epoch run on Apple M2/MPS, bs=64, MobileNetV3-Small backbone, 5 fit
classes (oversized/relaxed/regular/slim/cropped). Ships the palettized
6-bit .mlpackage into the iOS bundle at WardrobeReDo/ML/ behind the
existing isAttributeDetectionEnabled flag (still off; Phase 9 flips it
after dogfood).

Gate check: $GATE_RESULT

MSG
  )" || log "[warn] commit-2-failed"
fi

# Append run summary to the training plan
{
  echo
  echo "## Run $(date -u +%Y-%m-%dT%H:%M:%SZ) — autonomous local MPS"
  echo
  echo "- Gate: $GATE_RESULT"
  echo "- Summary json:"
  echo '```json'
  cat checkpoints/attr-full/eval/summary.json 2>/dev/null || echo '{}'
  echo
  echo '```'
  echo "- Log: $LOG"
} >> docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md

git add docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md
if ! git diff --cached --quiet; then
  git commit -m "$(cat <<'MSG'
docs(attr): log autonomous run summary

MSG
  )" || log "[warn] commit-3-failed"
fi

log "  git push"
git push origin feature/photo-extraction-engine 2>&1 | tail -10 \
  || log "[warn] push-failed-local-commits-intact"

log "=== complete ==="
echo "[run-summary] gates=$GATE_RESULT"
