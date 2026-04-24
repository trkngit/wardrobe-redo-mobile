#!/bin/bash
# Local wrap-up after pod training + auto-export completes.
#
# This script does the automatable half of the Phase-3 integration:
#   1. Verify pod DONE marker is STATUS=OK
#   2. rsync checkpoint + .mlpackage artifacts back to Mac
#   3. Replace the current (rank-6-broken) mlpackage in-tree
#   4. Remove the RFDETRSegFashion exclude from project.yml
#   5. xcodegen generate
#   6. xcodebuild build + test (simulator)
#
# The user-gated half (flipping FeatureFlags.isMultiGarmentEnabled default,
# committing, stopping the pod) is intentionally left for manual review.
#
# Usage:
#   bash notebooks/training/scripts/wrap_up_local.sh
#
# Env overrides:
#   POD_KEY   — ssh private key         (default ~/.ssh/id_ed25519_runpod)
#   POD_IP    — pod public IP           (default 213.192.2.77)
#   POD_PORT  — pod ssh port            (default 40172)
#   POD_ID    — runpod pod id           (default odewf19w58pdqy)
#   SIM_NAME  — iOS simulator           (default "iPhone 17 Pro")

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

POD_KEY="${POD_KEY:-$HOME/.ssh/id_ed25519_runpod}"
POD_IP="${POD_IP:-213.192.2.77}"
POD_PORT="${POD_PORT:-40172}"
POD_ID="${POD_ID:-odewf19w58pdqy}"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"

SSH="ssh -i $POD_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $POD_PORT root@$POD_IP"
RSYNC_SSH="ssh -i $POD_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $POD_PORT"

echo "=== [1/6] check pod DONE marker ==="
MARKER="$($SSH 'cat /workspace/training/DONE.txt 2>/dev/null || echo MISSING')"
echo "$MARKER"
if ! grep -q 'STATUS=OK' <<<"$MARKER"; then
    echo "FATAL: pod reports failure or not finished — inspect watchdog.log"
    exit 1
fi

echo
echo "=== [2/6] rsync checkpoint + mlpackages to Mac ==="
mkdir -p "$REPO_ROOT/notebooks/training/checkpoints-p2/coreml"
rsync -avh --progress \
    -e "$RSYNC_SSH" \
    "root@$POD_IP:/workspace/training/checkpoints-p2/checkpoint_best_ema.pth" \
    "$REPO_ROOT/notebooks/training/checkpoints-p2/" || \
rsync -avh --progress \
    -e "$RSYNC_SSH" \
    "root@$POD_IP:/workspace/training/checkpoints-p2/" \
    "$REPO_ROOT/notebooks/training/checkpoints-p2/"

rsync -avh --progress \
    -e "$RSYNC_SSH" \
    "root@$POD_IP:/workspace/training/checkpoints-p2/coreml/" \
    "$REPO_ROOT/notebooks/training/checkpoints-p2/coreml/"

echo
echo "=== [3/6] drop new mlpackage into iOS bundle path ==="
DEST_DIR="$REPO_ROOT/WardrobeReDo/Models/CoreML"
NEW_PKG="$REPO_ROOT/notebooks/training/checkpoints-p2/coreml/RFDETRSegFashion.mlpackage"
if [[ ! -d "$NEW_PKG" ]]; then
    echo "FATAL: $NEW_PKG not found after rsync"
    exit 2
fi
rm -rf "$DEST_DIR/RFDETRSegFashion.mlpackage" "$DEST_DIR/RFDETRSegFashion_fp16.mlpackage"
cp -R "$NEW_PKG" "$DEST_DIR/RFDETRSegFashion.mlpackage"
# keep fp16 around too for debugging / Core ML Performance Reports
if [[ -d "$REPO_ROOT/notebooks/training/checkpoints-p2/coreml/RFDETRSegFashion_fp16.mlpackage" ]]; then
    cp -R "$REPO_ROOT/notebooks/training/checkpoints-p2/coreml/RFDETRSegFashion_fp16.mlpackage" \
          "$DEST_DIR/RFDETRSegFashion_fp16.mlpackage"
fi
du -sh "$DEST_DIR"/*.mlpackage

echo
echo "=== [4/6] local coremlc compile dry-run ==="
TMP_COMPILE="$(mktemp -d)"
xcrun coremlc compile "$DEST_DIR/RFDETRSegFashion.mlpackage" "$TMP_COMPILE"
echo "coremlc accepted the rank-5 graph"
rm -rf "$TMP_COMPILE"

echo
echo "=== [5/6] remove exclude from project.yml + xcodegen ==="
python3 - <<'PY'
"""Line-based removal of the RFDETRSegFashion exclude block.

A regex approach on YAML is fragile — the previous implementation over-matched
the trailing whitespace and glued the preceding `- path: WardrobeReDo` line
onto the next `resources:` key. This walks line by line and removes only the
self-contained `excludes:` block that covers the RFDETRSegFashion pattern.
"""
import pathlib, re

p = pathlib.Path("project.yml")
lines = p.read_text().splitlines(keepends=True)

# Find the excludes: block whose body mentions RFDETRSegFashion.
start = None
for i, line in enumerate(lines):
    if re.match(r"^\s+excludes:\s*$", line):
        # Look at the next ~8 lines: if any is a RFDETRSegFashion list entry
        # and no non-comment/non-list line appears before it, this is our block.
        indent = len(line) - len(line.lstrip())
        body = []
        j = i + 1
        while j < len(lines):
            nxt = lines[j]
            nxt_indent = len(nxt) - len(nxt.lstrip())
            if nxt.strip() == "" or nxt_indent <= indent:
                break
            body.append((j, nxt))
            j += 1
        if any("RFDETRSegFashion" in b for _, b in body):
            start = i
            end = j  # exclusive
            break

if start is None:
    print("NOTE: RFDETRSegFashion excludes block not found — assuming already removed")
else:
    print(f"removing lines {start}..{end - 1} from project.yml:")
    for idx, ln in enumerate(lines[start:end], start=start):
        print(f"  {idx:3d}| {ln.rstrip()}")
    new_lines = lines[:start] + lines[end:]
    p.write_text("".join(new_lines))
    print(f"wrote project.yml ({len(new_lines)} lines)")
PY
xcodegen generate

echo
echo "=== [6/6] xcodebuild build + test ==="
xcodebuild \
    -scheme WardrobeReDo \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,name=$SIM_NAME" \
    -quiet \
    build test 2>&1 | tail -30

echo
echo "SUCCESS — build + tests green with new mlpackage."
echo
echo "Next (manual):"
echo "  1) flip FeatureFlags.isMultiGarmentEnabled default to true (edit Config/FeatureFlags.swift)"
echo "  2) re-run xcodebuild test"
echo "  3) commit changes"
echo "  4) curl -s -X POST https://api.runpod.io/graphql ... podStop $POD_ID"
