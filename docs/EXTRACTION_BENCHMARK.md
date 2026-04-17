# Extraction Benchmark

Tracks the quality and speed of `ClothingExtractionService` over time.
Two independent measurements feed this doc:

1. **Committed IoU fixtures** (`WardrobeReDoTests/Fixtures/Extraction/`) —
   30 owner-supplied photos + hand-traced masks, covering clean backgrounds,
   cluttered backgrounds, and on-person captures. Runs on device as
   `SegmentationIoUTests` + `ExtractionPerformanceTests`. Every PR is
   expected to keep these green.
2. **Dev-only DeepFashion2 benchmark** — ~300 images from the DeepFashion2
   validation split, stored outside the repo at `~/wardrobe-benchmark/`.
   Run locally when touching the extraction pipeline; reports diffed with
   `scripts/compare_benchmarks.py` and pasted into the PR description.

## How to run each

### Committed fixtures (always — runs in CI on device)

```bash
xcodebuild test -scheme WardrobeReDo \
  -destination 'platform=iOS,name=<your device>' \
  -only-testing WardrobeReDoTests/SegmentationIoUTests \
  -only-testing WardrobeReDoTests/ExtractionPerformanceTests
```

On the simulator the tests short-circuit with a skip message — Vision and
SAM2 both need a Neural Engine.

### DeepFashion2 benchmark (dev-only)

```bash
# One-time: apply for access, download validation split, unzip at
#   ~/wardrobe-benchmark/DeepFashion2/validation/{image,annos}/
python3 scripts/build_benchmark.py   # writes ~/wardrobe-benchmark/benchmark_manifest.json
swift run --package-path scripts/benchmark-tool -c release benchmark-tool
# → ~/wardrobe-benchmark/reports/YYYYMMDD-HHMMSS-<commit>.json
```

```bash
# Regression check between two reports
python3 scripts/compare_benchmarks.py \
  ~/wardrobe-benchmark/reports/<baseline>.json \
  ~/wardrobe-benchmark/reports/<candidate>.json
```

The benchmark tool is Vision-only on purpose. SAM2 needs iOS Neural Engine
inference, so its performance signal comes from `ExtractionPerformanceTests`
on device — not from this macOS CLI.

## Targets

### IoU floors (committed fixtures)

| Scenario     | Phase 1 floor | Phase 3 target |
|--------------|---------------|----------------|
| `clean_bg_*` | ≥ 0.82        | ≥ 0.82         |
| `cluttered_*`| ≥ 0.65        | ≥ 0.85         |
| `on_person_*`| ≥ 0.45        | ≥ 0.80 (with tap) |

The per-fixture `expected_iou_min` in `manifest.json` is each image's
individual floor — set by running the current pipeline once and subtracting
a 5% safety margin. Scenario aggregates above are the plan's success bar.

### Latency / memory (device-only perf tests)

| Path       | p95 wall clock | Peak memory |
|------------|----------------|-------------|
| Vision     | < 0.8 s        | < 120 MB    |
| SAM2 (warm)| < 1.5 s        | < 220 MB    |

Xcode's metric report auto-compares against the device's prior baseline
and flags regressions. Accept the new baseline explicitly when a perf win
is real.

## Results log

Append one row per commit that changed the extraction pipeline. Numbers
come from the latest device run + the benchmark-tool report.

| Date | Commit | Phase | Clean bg IoU | Cluttered IoU | On-person IoU | Vision p95 | SAM2 p95 |
|------|--------|-------|--------------|---------------|---------------|------------|----------|
| —    | —      | 1     | (fill in)    | (fill in)     | (fill in)     | (fill in)  | n/a      |
| —    | —      | 3     | (fill in)    | (fill in)     | (fill in)     | (fill in)  | (fill in)|

(Baseline numbers filled in once the owner traces the 30 ground-truth masks
and runs the rig end-to-end on device. Before that, the rig emits skip
messages rather than failing.)

## When to refresh this doc

- A PR changes `ClothingExtractionService.swift`, `VisionForegroundExtractor.swift`,
  or `SAM2Extractor.swift`.
- A PR changes the SAM2 model (swap architecture or retrain).
- A PR changes fixture manifests or adds new scenarios.
- Every six months: re-draw the DeepFashion2 subset with a new seed to
  catch pipeline overfitting to the current set.
