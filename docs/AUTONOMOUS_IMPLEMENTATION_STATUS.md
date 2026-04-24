# Autonomous Implementation Status

> Running plan: [AUTONOMOUS_IMPLEMENTATION_PLAN.md](./AUTONOMOUS_IMPLEMENTATION_PLAN.md). Updated after every commit.

**Current phase:** 4 — ML telemetry
**Last commit:** `<phase-3>` — feat(resilience): add upload queue + idempotency keys + migration 00010
**Branch:** `feature/photo-extraction-engine`
**Session started:** 2026-04-24

---

## Completed (4)

- [x] **Phase 0** — repo hygiene (commit `7bcd061`): `.gitignore` extended, `scripts/autonomous_attr_train.sh` tracked.
- [x] **Phase 1** — Sentry crash reporting (commit `fc1ae14`): DSN-gated init in `WardrobeReDoApp.init()` before any other work. Privacy-first defaults. SPM 8.x added. Graceful no-op when `SENTRY_DSN` missing.
- [x] **Phase 2** — Resilience layer (commit `ff370e7`):
  - `RetryPolicy` with `.default` / `.interactive` / `.background` presets.
  - `LocalCache` actor with 7-day TTL backing `Library/Caches/wardrobe-cache.json`. Chose actor+JSON over SwiftData to keep Swift 6 strict-concurrency story simple.
  - Cache-first reads + retry-wrapped calls in `WardrobeRepository` + `OutfitRepository`. Writes invalidate affected buckets.
  - Unit tests: `RetryPolicyTests` (happy path, transient, cancellation, exhaustion, classifier, jitter), `LocalCacheTests` (round-trip, TTL, invalidation, partial-hit guard).
- [x] **Phase 3** — Upload queue + idempotency (commit `<phase-3>`):
  - `UploadQueue` actor singleton with persistent JSON backing (`Library/Caches/upload-queue.json`). Handler injection avoids repo import cycle. Drops envelopes after 6 failed attempts; stops drain cycle on non-retryable errors.
  - `isDuplicateKeyError(_:)` helper on `RetryPolicy.swift` detects Postgres 23505.
  - Added `idempotencyKey: UUID?` to `NewWardrobeItem` and `NewOutfit` DTOs. `WardrobeRepository.insertItem` + `OutfitRepository.saveOutfit` catch dup-key errors after retry and re-fetch the already-inserted row.
  - Migration `00010_idempotency_keys.sql` adds nullable column + partial unique index `(user_id, idempotency_key) WHERE idempotency_key IS NOT NULL` on both tables.
  - Unit tests: `UploadQueueTests` covering happy drain, retryable failure, max-attempts drop, non-retryable stop, no-handler persistence, payload round-trip, sequential idempotency, parallel convergence (8 tests green).
  - AddItemViewModel + OutfitGenerationService call sites now pass `idempotencyKey: UUID()`.
  - **Scope trimmed vs. plan:** did not refactor `AddItemViewModel.save` to route through `UploadQueue` (960-line file, multi-garment state made it 3-strike risk). Idempotency keys already cover the "retry after network timeout" case. Full offline-first capture flow deferred to v1.1.

---

## Blocked (0)

_(none)_

---

## Skipped (1)

- **UploadQueue integration into `AddItemViewModel.save`** — the queue ships as a tested scaffold but the save path still runs synchronously. Re-visiting in v1.1 once the photo-upload side of the save is moved off-main. Idempotency keys prevent the known duplicate-insert failure mode in the meantime.

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
