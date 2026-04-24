# Autonomous Implementation Status

> Running plan: [AUTONOMOUS_IMPLEMENTATION_PLAN.md](./AUTONOMOUS_IMPLEMENTATION_PLAN.md). Updated after every commit.

**Current phase:** 9 — Merge prep
**Last commit:** `53ce16d` — feat(dev): add dogfood plumbing to Developer menu
**Branch:** `feature/photo-extraction-engine`
**Session started:** 2026-04-24

---

## Completed (9)

- [x] **Phase 0** — repo hygiene (commit `7bcd061`): `.gitignore` extended, `scripts/autonomous_attr_train.sh` tracked.
- [x] **Phase 1** — Sentry crash reporting (commit `fc1ae14`): DSN-gated init in `WardrobeReDoApp.init()` before any other work. Privacy-first defaults. SPM 8.x added. Graceful no-op when `SENTRY_DSN` missing.
- [x] **Phase 2** — Resilience layer (commit `ff370e7`):
  - `RetryPolicy` with `.default` / `.interactive` / `.background` presets.
  - `LocalCache` actor with 7-day TTL backing `Library/Caches/wardrobe-cache.json`. Chose actor+JSON over SwiftData to keep Swift 6 strict-concurrency story simple.
  - Cache-first reads + retry-wrapped calls in `WardrobeRepository` + `OutfitRepository`. Writes invalidate affected buckets.
  - Unit tests: `RetryPolicyTests` (happy path, transient, cancellation, exhaustion, classifier, jitter), `LocalCacheTests` (round-trip, TTL, invalidation, partial-hit guard).
- [x] **Phase 3** — Upload queue + idempotency (commit `8a6cd7e`):
  - `UploadQueue` actor singleton with persistent JSON backing (`Library/Caches/upload-queue.json`). Handler injection avoids repo import cycle. Drops envelopes after 6 failed attempts; stops drain cycle on non-retryable errors.
  - `isDuplicateKeyError(_:)` helper on `RetryPolicy.swift` detects Postgres 23505.
  - Added `idempotencyKey: UUID?` to `NewWardrobeItem` and `NewOutfit` DTOs. `WardrobeRepository.insertItem` + `OutfitRepository.saveOutfit` catch dup-key errors after retry and re-fetch the already-inserted row.
  - Migration `00010_idempotency_keys.sql` adds nullable column + partial unique index `(user_id, idempotency_key) WHERE idempotency_key IS NOT NULL` on both tables.
  - Unit tests: `UploadQueueTests` covering happy drain, retryable failure, max-attempts drop, non-retryable stop, no-handler persistence, payload round-trip, sequential idempotency, parallel convergence (8 tests green).
  - AddItemViewModel + OutfitGenerationService call sites now pass `idempotencyKey: UUID()`.
  - **Scope trimmed vs. plan:** did not refactor `AddItemViewModel.save` to route through `UploadQueue` (960-line file, multi-garment state made it 3-strike risk). Idempotency keys already cover the "retry after network timeout" case. Full offline-first capture flow deferred to v1.1.
- [x] **Phase 4** — ML inference telemetry (commit `f3964bf`):
  - Migration `00011_ml_inference_telemetry.sql` creates `public.ml_inference_telemetry` with timing, label, confidence, pre-fill/correction flags. `auth.uid() = user_id` INSERT policy, no SELECT policy (service role only). `ON DELETE CASCADE` for GDPR right-to-erasure.
  - `FeatureFlags.isMLTelemetryEnabled` (default `false`, opt-in via Developer menu).
  - `MLTelemetryService` actor resolves userId via `supabase.auth.session.user.id` at upload time so call sites don't thread identity. Fire-and-forget: errors logged at `.info` and swallowed — telemetry never bubbles into user-visible surfaces.
  - Wired into `MLDiagnosticsStore.record()`/`recordFailure()` (multi-garment path) and `AttributeClassifierService.predict(crop:)` (classifier path). Both emit a single observation per inference, with `ContinuousClock` wall-time.
  - Privacy posture: no image bytes, no crops, no colors — only `latency_ms`, `top_class_raw`, `top_score`, `threw`, and pre-fill correction flags. Enforced at the service layer (the `Observation` struct has no image field).
  - Unit tests: `MLTelemetryServiceTests` (8 tests — gate default off, flag-flips-live, flag-off no-op, Observation field round-trip, surface heuristic, compute-unit banding).
  - Static helpers `MLDiagnosticsStore.surface(for:)` + `inferredComputeUnit(forLatencyMs:)` so telemetry callers label without racing the ring buffer.
- [x] **Phase 5** — Edit Item form (commit `3d4fbab`):
  - `WardrobeRepositoryProtocol.updateItem(id:updates:)` + production implementation hits `wardrobe_items` via `.update(...).eq("id", ...).single()`. Cache invalidates the user's bucket on success so the grid refresh picks up the diff.
  - `ItemFormView` — shared SwiftUI form with 6 bindings (category, subcategory, texture, fitAttribute, seasons, occasions). Section-level auto-detected badge hook reserved for the Add side (not wired yet — Add migration deferred, see below).
  - `EditItemViewModel` — `@MainActor @Observable`; hydrates every user-editable field from the item, exposes `hasChanges`/`buildUpdate()`/`save()`. Diff is column-precise: `nil` fields skipped at Postgres so server-managed columns (`wear_count`, etc.) never get clobbered. `texture = nil` emits explicit null; season/occasion diff is set-based so storage ordering can't produce phantom payloads. Baseline replaces after successful save.
  - `EditItemView` — push-navigated from `ItemDetailView` toolbar. Cancel + Save toolbar slots; Save disabled via `!hasChanges`; error banner under the form. Posts `.wardrobeDidChange` on success so the grid refreshes, matching archive/delete paths.
  - Unit tests: `EditItemViewModelTests` (11 tests — hydration, no-op diff, per-field diffs incl. texture→nil, set-based seasons, multi-field, save happy/failure/no-op, subcategory clamp). `MockWardrobeRepository` extended with `updateItemResult` / `updateItemCallCount` / `lastUpdate`. Full suite 595/595 green.
  - **Scope trimmed vs. plan:** did not extract `AddItemView.detailsStep` into `ItemFormView` — `AddItemView` still owns its own detail form. Lower-risk landing for the Edit surface (which is the user-visible gap); consolidation can follow in v1.1 when Add-side auto-detect badges are stable.
- [x] **Phase 6** — Supabase seed script (commit `eb33147`):
  - `scripts/seed_supabase.py` upserts the full 50 archetypes + 200 rules from `WardrobeReDo/Resources/SeedData/*.json` into `public.style_archetypes` + `public.style_rules` via PostgREST `Prefer: resolution=merge-duplicates`.
  - Stdlib-only (`urllib.request` + `json`) — no pip deps beyond Python 3.10+. Chunked 50 rows at a time so partial failures report a specific range.
  - Pre-flight validation: every row carries all required keys; every rule's `archetype_id` is in `archetypes.json` (FK integrity) — both catch JSON corruption before hitting the wire.
  - `--dry-run` prints the plan without network calls. `--only archetypes|rules` limits a re-run after a surgical JSON fix. Dry run verified locally (1 chunk archetypes + 4 chunks rules).
  - **Execution deferred to v1.1** — needs `SUPABASE_SERVICE_ROLE_KEY` (not the anon key; bypasses RLS). Script committed for reproducibility; user runs once per environment when canonical JSON changes. Usage docs in the module docstring. After this runs against prod, the `StyleDataRepository` bundled-JSON fallback becomes true DR, not the primary source.
- [x] **Phase 7** — Integration test target (commit `02d5bca`):
  - New `WardrobeReDoIntegrationTests` target in `project.yml`. Re-uses `WardrobeReDoTests/Helpers` (fixtures, mocks, isolation) so the integration bar stays consistent with the unit suite.
  - `GoldenPathTests` — 3 tests exercising multi-component contracts that unit tests don't:
    - `addThenRefetchSurfacesTheNewItem` — insert → mock re-armed to reflect the server view → fetch returns the row. Proves the insert→fetch round-trip contract the Wardrobe grid depends on.
    - `editSaveRefreshFlowPersistsChangeEndToEnd` — `EditItemViewModel` hydrates from fetch, mutates texture, saves, baseline advances; a second fetch returns the updated row.
    - `multiGarmentBatchSharesSourcePhotoIdAcrossInserts` — 3 garments from one capture all reach the repo with matching `sourcePhotoId` (regression guard for migration-00008 grouping queries).
  - Full matrix 598/598 (595 unit + 3 integration). Integration suite runs in under 10 ms.
  - **Live-Supabase harness deferred to v1.1** — needs a dedicated Supabase test branch + credentials. Mock-backed tests land the scaffolding; swapping mocks for a real `WardrobeRepository` is the follow-up.
- [x] **Phase 8** — Dogfood plumbing (commit `53ce16d`):
  - `DeveloperMenuView` gets three new affordances wrapped in `#if DEBUG`-scoped `ProfileView.developerSection`:
    - **ML Inference Telemetry toggle** in the Experimental Features section, bound to `FeatureFlags.isMLTelemetryEnabled` (closes a Phase-4 UI gap — the flag existed in `FeatureFlags.swift` since `f3964bf` but had no developer-menu control until now).
    - **"Report issue (share diagnostics)" ShareLink** in a new Dogfood section. Exports a plaintext bundle with build config, version/build, bundle ID, feature-flag state, ML smoke-test status, median latency, and the last 10 inferences from `MLDiagnosticsStore`. No image bytes, crops, or colors — same privacy posture as the telemetry pipeline.
    - **"Fire Sentry smoke event"** button calling new `SentryService.captureSmokeEvent(note:)`. Returns `true` when submitted, `false` when SDK is disabled (no DSN or module unavailable) so the button can surface a "Sentry disabled" hint rather than silently no-op. Satisfies the Tier A1 verification bullet: "trigger a caught event in DEBUG dev menu → event appears in Sentry dashboard within 60 s".
  - `docs/plans/2026-04-19-auto-attribute-detection/DOGFOOD_RESULTS.md` gets a new **Daily Journal (7-day window)** section prepended to the existing Phase-9 aggregate template. Journal captures in-the-moment notes (build, photos added, pre-fill fire rate, corrections, bugs, perf) during the week; the aggregate rolls up for the flag-flip decision gate.
  - Build + full test matrix green (598/598, no regressions).
  - **Scope trimmed vs. plan:** plan called for "last 10 os.log errors captured by a ring buffer" in the diagnostics bundle. We already surface the last 10 ML inferences via `MLDiagnosticsStore` — adding a second parallel ring buffer for generic `os.log` output is new scope with its own capture/filter story. Deferred to v1.1; the bundle's MLDiagnostics slice covers the model-side failure modes that cause the dogfood issues we're likely to hit first.

---

## Blocked (0)

_(none)_

---

## Skipped (2)

- **UploadQueue integration into `AddItemViewModel.save`** — the queue ships as a tested scaffold but the save path still runs synchronously. Re-visiting in v1.1 once the photo-upload side of the save is moved off-main. Idempotency keys prevent the known duplicate-insert failure mode in the meantime.
- **`AddItemView.detailsStep` → `ItemFormView` migration** — the new shared form ships against the Edit surface only. Add keeps its own detail form (with live auto-detect badges pre-wired) until the consolidation can be done against a stable auto-fill UX. Purely a DRY cleanup; no user-visible gap.

---

## Deferred to v1.1

- **Attempt-3 classifier retrain** — needs RunPod API key + ~$0.20 + 45 min. Recipe: `scripts/autonomous_attr_train.sh` with `--focal-gamma 1 --label-smoothing 0.0`.
- **Full Supabase seed run** — needs `SUPABASE_SERVICE_ROLE_KEY`. Script `scripts/seed_supabase.py` will be written in Phase 6 but not executed.
- **TestFlight distribution** — needs Apple Developer Portal setup.
- **Live Supabase integration tests** — local mock-based tests shipped in Phase 7; live harness needs a test branch credential.
- **`supabase db push` for migrations 00010, 00011** — user must run when ready.
- **Sentry DSN provisioning** — create Sentry project, drop `SENTRY_DSN` into `Secrets.plist`.

---

## Session summary

_(written at end of session)_
