# Test Plans

Three-plan split for the WardrobeReDo test suite, landed in the build-7 hardening sweep (Phase D2).

## Plans

### `All.xctestplan` (default)

The default plan when `xcodebuild test` runs without `-testPlan`. Runs every test target — same behaviour as pre-build-7. Wall time on iPhone 17 Pro simulator: **~80 s** (888 tests across both targets).

### `Fast.xctestplan`

The dev inner loop. Skips three slow suites that require either real-model inference or large-image stress fixtures:

- `MultiGarmentProposalServiceRealModelTests` — loads the bundled `RFDETRSegFashion.mlmodelc` and runs end-to-end inference (~26 s)
- `LargeImageProcessingTests` — drives the full pipeline on a 3840×2160 EXIF-rotated source (~24 s)
- `EXIFOrientationInvarianceTests` — runs four extractions back-to-back across orientation hints (~29 s)

Everything else runs in random execution order. Wall time on iPhone 17 Pro simulator: **~46 s** (872 tests).

### `Integration.xctestplan`

The CI gate. Selects the three slow suites above plus the `WardrobeReDoIntegrationTests` target (which exercises Supabase / network paths). Wall time: **~110 s** (17 tests).

## Usage

### From the command line

```bash
# Default — runs every test target (same as before build 7)
xcodebuild test \
  -scheme WardrobeReDo \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Fast inner loop
xcodebuild test \
  -scheme WardrobeReDo \
  -testPlan Fast \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Integration / CI
xcodebuild test \
  -scheme WardrobeReDo \
  -testPlan Integration \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### From Xcode

`Cmd+U` runs the default plan (`All`). To switch: `Product → Test Plan → Fast` or `Integration`, then `Cmd+U`.

## Parallelization (D3)

`xcodebuild test` accepts `-parallel-testing-enabled YES -parallel-testing-worker-count N` to spawn N simulator clones and shard the suite across them. This works with either test plan:

```bash
xcodebuild test \
  -scheme WardrobeReDo \
  -testPlan Fast \
  -parallel-testing-enabled YES \
  -parallel-testing-worker-count 4 \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

**Caveat (D1, deferred).** 25 of our test suites are `@Suite(.serialized)` because they flip global feature flags (`FeatureFlags.shared.*`), use the singleton `MLDiagnosticsStore`, or share the `UploadQueue` Realm. `.serialized` only serializes within ONE suite — across suites Swift Testing happily runs them in parallel, which races on global state. The `Fast` plan deliberately keeps `testExecutionOrdering: random` only at the suite level; intra-suite tests still run serially where the suite is marked.

A proper fix (D1) would extract per-test isolation harnesses (`FeatureFlagTestIsolation`, `UploadQueueTestIsolation`, `MLDiagnosticsTestIsolation` already exist as patterns) into every flag-flipping test, drop the serialized markers, and let the parallel test runner spread them across simulator clones. That's a separate concerted effort — tracked as a follow-up.

## Adding a test to a plan

`Fast` uses `skippedTests` (allowlist by default). To skip a new slow suite, add its test class name to the `skippedTests` array in `Fast.xctestplan`.

`Integration` uses `selectedTests` (denylist by default). To add a new integration suite, add its test class name to the `selectedTests` array in `Integration.xctestplan`.

Both plans live in JSON form here — Xcode reads them directly, no rebuild required.
