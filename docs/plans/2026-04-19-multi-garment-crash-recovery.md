# Wardrobe Re-Do — Multi-Garment Save-Loop Crash Recovery

**Plan slug:** `2026-04-19-multi-garment-crash-recovery`
**Status:** PROPOSED
**Parent plan:** [2026-04-18-multi-garment-detection](./2026-04-18-multi-garment-detection.md) (punch-list item v1.1)
**Estimated effort:** ~0.5–1 day

## Context

The multi-garment feature (shipping today) splits a single photo into N mask proposals and walks the user through N sequential "enter details + save" sheets. The in-flight queue lives entirely in `AddItemViewModel` memory:

- [WardrobeReDo/ViewModels/AddItemViewModel.swift](WardrobeReDo/ViewModels/AddItemViewModel.swift) — `pendingProposalQueue: [MaskProposal]`, held as a plain `@Observable` property.

**Failure mode.** User snaps a 3-garment photo, picks all three, saves garment 1, backgrounds the app to answer a text, iOS jetsams the process. On relaunch the queue is gone; 1 garment is saved, 2 are silently lost, and the user has to re-shoot + re-pick.

This is fine for the v1 ship (the multi-pick UX is net-positive even with the bug) but becomes a real complaint once enough users use it. This plan scaffolds the v1.1 fix.

## Recommended approach

Persist the queue to **SwiftData** (already in the stack) as a first-class `@Model`, not in-memory. The model lives only as long as the save loop runs; on the terminal save (or explicit cancel) it's wiped.

### Model sketch

```swift
@Model
final class PendingProposalBatch {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var sourcePhotoRef: String          // asset identifier — NOT the full UIImage
    var proposals: [StoredProposal]     // ordered
    var currentIndex: Int               // resume pointer
}

@Model
final class StoredProposal {
    var ordinal: Int
    var bboxData: Data                  // CGRect encoded
    var maskPngPath: String             // on-disk, not BLOB in DB
    var predictedCategoryRaw: String?
    var classLabel: String
}
```

**Key design choices:**
- Mask PNGs live in the app's Caches directory referenced by path, not as SwiftData `Data` — large BLOBs regress the store.
- Source photo is referenced by `PHAsset.localIdentifier` so the restored flow can re-fetch the original without duplicating bytes.
- A single live batch at a time — on scan start, delete any orphan batch > 24h old.

### Files to modify

| Path | What changes |
| --- | --- |
| `WardrobeReDo/Models/PendingProposalBatch.swift` | NEW `@Model` type |
| `WardrobeReDo/Models/StoredProposal.swift` | NEW `@Model` type |
| `WardrobeReDo/Repositories/PendingProposalRepository.swift` | NEW — CRUD over SwiftData `ModelContext` |
| `WardrobeReDo/ViewModels/AddItemViewModel.swift` | swap in-memory queue for repo-backed queue; resume-on-launch hook |
| `WardrobeReDo/App/ContentView.swift` (or AppState) | on launch, check for orphan batch → offer "Resume 2 of 3?" banner |
| `WardrobeReDoTests/Services/AddItemCrashRecoveryTests.swift` | NEW — scenarios: kill mid-queue, relaunch, assert resume |

### Reuse

- `ClothingExtractionService.maskToPNG` pattern — copy for the on-disk mask persistence.
- `MockMultiGarmentExtractor` — existing fixture works as-is for the new tests.
- The `.serialized` + `FeatureFlagTestIsolation` pattern in `ImageServiceProposalsTests` — reuse for repo tests that touch the shared SwiftData container.

## Verification

```bash
# New test suite must pass
xcodebuild test \
  -scheme WardrobeReDo \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WardrobeReDoTests/AddItemCrashRecoveryTests

# Manual: sim smoke
#   1. Take a 3-garment photo
#   2. Save garment 1
#   3. On garment 2 sheet: `xcrun simctl terminate booted com.wardroberedo`
#   4. Re-launch app
#   5. Expect: resume banner → garment 2 sheet reopens with saved state
#   6. Save garment 2, save garment 3 — all three land in the wardrobe
```

## Open questions

1. **Cross-device sync.** If the user saves garment 1 on iPhone and crashes before garment 2, should resume also work on iPad? Likely **no** for v1.1 — local-only. Supabase sync is out of scope.
2. **Mask quality.** Mask PNGs are ~200 KB each. A queue of 5 = 1 MB on disk, cleared on completion — acceptable.
3. **Privacy.** Is the user's source photo guaranteed to still exist in Photos on resume? If the user deleted the photo between crash and relaunch, fall back to showing only the cropped mask (no full photo preview).

## Sequence (to be filled in when plan is promoted from PROPOSED → IN PROGRESS)

- [ ] Add `PendingProposalBatch` + `StoredProposal` models + migration
- [ ] Add `PendingProposalRepository` with CRUD + orphan-cleanup
- [ ] Swap `AddItemViewModel.pendingProposalQueue` to repo-backed
- [ ] Resume banner in ContentView on launch
- [ ] Tests: `AddItemCrashRecoveryTests`
- [ ] Manual sim smoke per Verification section
- [ ] Commit sequence: 3 commits (models, repo+VM swap, UI + tests)

---

## User Request (Verbatim)

Auto-generated from the v1.1 punch list in [2026-04-18-multi-garment-detection.md:938](2026-04-18-multi-garment-detection.md:938):

> **v1.1:** Persist `pendingProposalQueue` to SwiftData for crash recovery mid-batch

Authored 2026-04-19 during the wait window between pod training completion and wrap-up.
