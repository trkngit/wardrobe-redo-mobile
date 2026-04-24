# feat: ship v1 resilience + ML + dogfood plumbing (phases 0-8)

> **Scope:** 90 commits / 245 files / ~41.8k insertions vs. `origin/main`.
> The branch covers the attribute-classifier training arc (pre-resume),
> the multi-garment detection pipeline, and the 9-phase Tier-A autonomous
> execution plan documented in `docs/AUTONOMOUS_IMPLEMENTATION_PLAN.md`.
>
> **Strategy:** squash-merge to `main` so the history is one coherent
> landing point. The per-phase detail below is how to review it; the
> single commit on `main` will be the end state.

## Summary

- Ship multi-garment detection + attribute classifier on-device.
- Land the Tier-A resilience layer (retry, local cache, upload queue, idempotency).
- Add Sentry crash reporting + opt-in ML inference telemetry.
- Ship an Edit Item form, a Supabase seed script, and a 3-test integration target.
- Make the Developer menu dogfood-ready (telemetry toggle, Sentry smoke, diagnostics ShareLink).
- Full test matrix 598/598 green (595 unit + 3 integration).

## Reviewer's roadmap

Pick any phase heading and pull the commit(s) under it for a focused review. All status lives in `docs/AUTONOMOUS_IMPLEMENTATION_STATUS.md`.

### Pre-autonomous (multi-garment + attribute training)

- Multi-garment detection (`RFDETRSegFashion.mlpackage`): shipped 461/461 iOS tests green, feature-flagged (default on).
- Attribute classifier attempts 1-2: seed-1337 winner, 6-bit palettized, 1.3 MB, feature-flagged (default off — calibration regression, see `docs/plans/2026-04-19-auto-attribute-detection/`).
- Training infra: `scripts/autonomous_attr_train.sh` production-grade with retry + gate abort + auto-commit.

### Autonomous session (phases 0-8)

| Phase | Commit | Scope |
|-------|--------|-------|
| 0 — repo hygiene | `7bcd061` | extend .gitignore, track autonomous_attr_train.sh |
| 1 — Sentry | `fc1ae14` | DSN-gated init in `WardrobeReDoApp.init()`; privacy-first defaults; SPM 8.x. No-op when DSN missing. |
| 2 — Resilience foundation | `ff370e7` | `RetryPolicy` (.default/.interactive/.background) + `LocalCache` actor (7-day TTL, JSON backing); cache-first reads in Wardrobe + Outfit repos |
| 3 — Upload queue + idempotency | `8a6cd7e` | `UploadQueue` actor (handler-injected, persisted); `idempotencyKey: UUID?` on `NewWardrobeItem`/`NewOutfit`; migration `00010_idempotency_keys.sql`; `isDuplicateKeyError` catches Postgres 23505 |
| 4 — ML telemetry | `f3964bf` | Migration `00011_ml_inference_telemetry.sql` + `MLTelemetryService` actor; `FeatureFlags.isMLTelemetryEnabled` (opt-in); wired into `MLDiagnosticsStore.record()` + `AttributeClassifierService` |
| 5 — Edit Item form | `3d4fbab` | `WardrobeRepository.updateItem`; `ItemFormView` shared scaffold; `EditItemViewModel` + `EditItemView` with column-precise diff (nil = "don't touch"); `.wardrobeDidChange` grid refresh |
| 6 — Supabase seed script | `eb33147` | `scripts/seed_supabase.py` — stdlib-only, 50 archetypes + 200 rules, `--dry-run` + `--only` flags, FK pre-flight validation |
| 7 — Integration tests | `02d5bca` | `WardrobeReDoIntegrationTests` target sharing `WardrobeReDoTests/Helpers`; 3 golden paths (add→refetch, edit→save→refetch, multi-garment batch→shared source_photo_id) |
| 8 — Dogfood plumbing | `53ce16d` | ML Telemetry toggle + "Report issue" ShareLink + "Fire Sentry smoke event" button in `DeveloperMenuView`; `SentryService.captureSmokeEvent`; 7-day Daily Journal section in `DOGFOOD_RESULTS.md` |

### Database migrations applied in this branch

- `00007_wardrobe_items_masked.sql` — pre-autonomous (masked image path)
- `00008_source_photo_grouping.sql` — pre-autonomous (multi-garment grouping)
- `00009_detected_attributes.sql` — pre-autonomous (ML provenance JSONB)
- `00010_idempotency_keys.sql` — Phase 3 (idempotency_key + partial unique index)
- `00011_ml_inference_telemetry.sql` — Phase 4 (telemetry table + RLS)

**Not yet pushed.** User runs `supabase db push` when ready — see deferred items below.

## CI status

CI is green on [run 24902269220](https://github.com/trkngit/wardrobe-redo-mobile/actions/runs/24902269220) (5m31s end-to-end).

GitHub-hosted `macos-15` minutes are blocked at the account-billing level on this repo right now, so the workflow runs on a self-hosted macOS/ARM64 runner on the maintainer's Mac instead. To revert to hosted: flip `runs-on` back to `macos-15`, restore the `Select Xcode` / `-downloadPlatform iOS` steps (see git history for `.github/workflows/ios-tests.yml`), and drop the explicit `Resolve Git LFS` step. The Git-LFS fix is worth keeping in either world — `actions/checkout`'s built-in `lfs: true` didn't re-resolve pointer files on a persistent self-hosted `_work` directory, so an explicit `git lfs pull` plus a Manifest.json `{`-vs-`v` sanity check now guards against that cryptic failure mode.

## Test plan

- [x] Local: `xcodebuild test -scheme WardrobeReDo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` → 598/598 green
- [x] CI: `.github/workflows/ios-tests.yml` → green on run 24902269220 (self-hosted macOS/ARM64)
- [ ] Manual: Open Profile → Developer → toggle ML Telemetry → add a new item → verify `ml_inference_telemetry` row appears (needs migrations pushed + user opted in)
- [ ] Manual: Profile → Developer → "Fire Sentry smoke event" → verify event in Sentry dashboard within 60 s (needs SENTRY_DSN in Secrets.plist first)
- [ ] Manual: Profile → Developer → "Report issue (share diagnostics)" → verify bundle includes build info, flag state, last 10 inferences
- [ ] Manual: Wardrobe → item detail → Edit → change texture → Save → verify grid reflects change
- [ ] Manual: offline-flow smoke — airplane mode → open Wardrobe → cache renders → exit airplane mode → retry fires → state reconciles

## Deferred to v1.1 (not in this PR)

These require external credentials, compute, or Apple Developer Portal access and cannot be landed autonomously. Each is documented with a precise resume path in `docs/AUTONOMOUS_IMPLEMENTATION_STATUS.md`:

- `supabase db push` for migrations 00010, 00011 (user must run)
- `SENTRY_DSN` provisioning in `Secrets.plist` (create Sentry project first)
- Attempt-3 classifier retrain (`--focal-gamma 1 --label-smoothing 0.0` — needs RunPod key + ~$0.20 + 45 min)
- Full Supabase seed execution (`scripts/seed_supabase.py` with `SUPABASE_SERVICE_ROLE_KEY`)
- TestFlight distribution (Apple Developer Portal setup)
- Live-Supabase integration tests (needs a dedicated test branch)
- `UploadQueue` integration into `AddItemViewModel.save` (queue ships tested but save path still synchronous — idempotency keys cover the retry-after-timeout case in the meantime)
- `AddItemView.detailsStep` → `ItemFormView` consolidation (Edit side ships on `ItemFormView`; Add side keeps its own detail form until the auto-detect badge UX stabilizes)

## Known scope trims

Three decisions made during autonomous execution to stay on the time budget:

1. **Phase 3**: did not refactor `AddItemViewModel.save` to route through `UploadQueue`. Idempotency keys cover the duplicate-insert failure mode; full offline-first capture is v1.1.
2. **Phase 5**: did not extract `AddItemView.detailsStep` into `ItemFormView` (3-strike risk on a 960-line multi-garment file). `EditItemView` ships on the new shared form; consolidation follows when Add-side auto-detect badges are stable.
3. **Phase 8**: diagnostics bundle includes the last 10 ML inferences but not a parallel `os.log` ring buffer (new scope with its own capture/filter story). MLDiagnostics slice covers the model-side failure modes we're likely to hit first in dogfood.

## Safety posture

- No secrets in the diff (verified — Sentry DSN + Supabase service role key both read at runtime from `Secrets.plist`).
- All migrations are forward-only (no destructive operations).
- Sentry telemetry: `sendDefaultPii = false`, network breadcrumbs disabled, no image bytes anywhere in the pipeline.
- ML telemetry: privacy-first by construction (Observation struct has no image field); opt-in via Developer menu; `auth.uid() = user_id` RLS on INSERT, no SELECT policy at all (service role only).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
