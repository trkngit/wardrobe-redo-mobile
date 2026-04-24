# Autonomous Implementation Plan — Wardrobe Re-Do v1

> Generated 2026-04-24. Companion to [SESSION_HANDOFF_BRIEF.md](./SESSION_HANDOFF_BRIEF.md) and the approved plan at `~/.claude/plans/read-docs-session-handoff-brief-md-for-t-velvet-flamingo.md`.
>
> **Operating mode:** autonomous, bypass-permissions. No user interruption. Save-and-skip on blockers rather than waiting for answers.

---

## Mission

Implement Tier A (Resilience + ML Completion + Backend Hardening) from the approved plan without user interruption. Land everything that can be landed without external credentials or external compute. Save everything else into a clean "resume here" hand-off.

---

## Operating principles

1. **Default all open questions** to the recommendations in the approved plan (see "Defaults" below). Never block on a missing answer.
2. **Save-and-skip** on any blocker. Never loop on the same error. Three-strike rule: after 3 failed attempts on the same unit of work, commit what's done, log the blocker with full reproduction context to [AUTONOMOUS_IMPLEMENTATION_STATUS.md](./AUTONOMOUS_IMPLEMENTATION_STATUS.md), and move to the next phase.
3. **Commit frequently.** After every completed logical unit (not every file). Conventional commits. Never amend.
4. **Trust the existing patterns.** Reuse `StyleDataRepository`'s fallback pattern, `AppState`'s `withTimeout(seconds:)`, Kingfisher for images, MockWardrobeRepository + TestFixtures for tests.
5. **No destructive git** (force push, reset --hard, branch delete). No secrets ever committed.
6. **Build verification after each phase.** Run `xcodebuild build` (not full test suite) as a fast smoke. Run full tests only at phase boundaries.
7. **No new top-level dependencies without justification.** Sentry is the only new SPM dep allowed; anything else gets flagged to the status doc.
8. **Scope discipline.** Every change must map to a gap in [SESSION_HANDOFF_BRIEF.md §15](./SESSION_HANDOFF_BRIEF.md) or the approved plan's G1–G12. If it doesn't, defer it with a `mcp__ccd_session__spawn_task` flag.

---

## Defaults for open questions

| # | Question | Default | Rationale |
|---|---|---|---|
| 1 | Crash reporting vendor | **Sentry** | No Google dependency, Swift 6 concurrency-safe, SPM distribution |
| 2 | Dogfood scope | **Local dev-build** | TestFlight requires Apple Developer Portal setup — out of autonomous scope |
| 3 | Merge strategy | **Single squash PR** | Lowest friction, clearest reviewer story |
| 4 | Attempt-3 retrain timing | **Defer** | Requires RunPod API key + 45 min of external compute + $0.20; save recipe |
| 5 | Oversized F1 hard gate | **Downgrade to v1.1 nice-to-have** | Dataset-bound (16 val samples); blocking v1 on it is bad ROI |
| 6 | Commit `autonomous_attr_train.sh` | **Commit** | Production-grade, reproducible, currently untracked |

---

## Phase plan

Each phase has: scope, files touched, blocker taxonomy, exit criteria. Work top-down, phase by phase. Skip a phase if hard-blocked; never stop.

### Phase 0 — Setup (≤ 10 min)
- Initialize [AUTONOMOUS_IMPLEMENTATION_STATUS.md](./AUTONOMOUS_IMPLEMENTATION_STATUS.md).
- Verify `xcodebuild build` green at head. If not green, fix *only* what regressed in current uncommitted state (should just be project.pbxproj); otherwise revert and document.
- Confirm branch is `feature/photo-extraction-engine`.

### Phase 1 — Ground work (≤ 30 min, low risk)
**Scope:** Commit-hygiene + tiny no-risk wins that don't need architecture decisions.

1. Update `.gitignore` to cover `data/`, `logs/`, `checkpoints/attr-smoke/`, `checkpoints/attr-full/export/`, `.claude/worktrees/`, `WardrobeReDo.xcodeproj/project.xcworkspace/xcuserdata/`.
2. Commit `scripts/autonomous_attr_train.sh` as-is.
3. Configure Kingfisher disk cache in `WardrobeReDoApp.init` (256 MB, 7-day TTL).
4. Add `Sentry` via SPM (`getsentry/sentry-cocoa` 8.x). Initialize in `WardrobeReDoApp.init` **only if a DSN exists in Secrets.plist** (no DSN → log and skip, never crash).

**Exit criteria:** `xcodebuild build` green. 4 commits.

**Blockers:** Sentry SPM fetch network failure → skip step 4, log, continue.

### Phase 2 — Retry + Persistence foundation (≤ 60 min)
**Scope:** Infrastructure for A1.

1. Create `WardrobeReDo/Services/Network/RetryPolicy.swift` with `withRetry<T>(maxAttempts: Int = 3, backoff: RetryBackoff, _ op: () async throws -> T)`. Include unit tests.
2. Create `WardrobeReDo/Services/Persistence/LocalCache.swift` with SwiftData `@Model` shadows for `WardrobeItem`, `Outfit`, `OutfitSlot`, `Profile`. Keep field-for-field with server models (not a reduced DTO — simplifies sync).
3. Initialize SwiftData container in `WardrobeReDoApp` and inject into `AppState`.
4. Add cache-first read path to `WardrobeRepository.fetchItems(...)` and `OutfitRepository.fetchOutfits(for:date:)`. Pattern: return cache immediately → fire Supabase call → update cache → emit update if changed.
5. Unit tests for cache freshness/invalidation.

**Exit criteria:** Build green; new unit tests pass; `WardrobeGridView` still works online (smoke via simulator launch).

**Blockers:** SwiftData migration error on existing installs → ship with migration-from-empty strategy (cache is populated on first launch, no reset needed). If strict-concurrency violations appear, add explicit `@ModelActor` isolation or fall back to `Actor`-wrapped cache. Three-strike rule: if SwiftData keeps fighting, switch to a simple in-memory `Actor` cache + UserDefaults-backed Codable persistence and log the downgrade.

### Phase 3 — Upload queue + idempotency (≤ 60 min)
**Scope:** Complete A1.

1. Create `WardrobeReDo/Services/Upload/UploadQueue.swift` — persistent queue of pending item saves, drains in background task with `RetryPolicy`.
2. Refactor `AddItemViewModel.save(userId:)` to enqueue rather than block. Keep the UI optimistic (return success to UI on enqueue, mark as "syncing" on item card).
3. Add `idempotency_key: UUID` client-generated field to `NewWardrobeItem` and `NewOutfit`.
4. Write migration `supabase/migrations/00010_idempotency_keys.sql` — add `idempotency_key UUID` column with partial unique index on `wardrobe_items` and `outfits`.
5. Update `OutfitRepository.saveOutfit` to use upsert-by-idempotency-key; this fixes the orphan-on-mid-save-crash bug without needing an Edge Function.

**Exit criteria:** Build green; unit tests for queue concurrency + idempotency green.

**Blockers:** `supabase` CLI not authenticated → commit migration file but don't run it. Log the `supabase db push` command to status doc.

### Phase 4 — ML telemetry (≤ 30 min)
**Scope:** Complete A1, prep A2.

1. Upgrade `MLDiagnosticsStore.swift`: add opt-in `logToSupabase(_ entry:)` method. Respect a `FeatureFlags.isMLTelemetryEnabled` flag (default false — user opts in).
2. Migration `supabase/migrations/00011_ml_inference_telemetry.sql` — table `ml_inference_telemetry (id uuid pk, user_id uuid, model text, latency_ms int, prediction_confidence float, prefill_fired bool, user_corrected bool, field_changed text, created_at timestamptz)`. RLS: user can insert own, no reads.
3. Wire into `AttributeClassifierService` and `MultiGarmentProposalService`.

**Exit criteria:** Build green. Smoke: run the DEBUG launch smoke test, verify events queue (to Supabase or local) without errors.

**Blockers:** Same as Phase 3 migration blocker — commit, don't push.

### Phase 5 — Edit Item form (≤ 45 min)
**Scope:** Part of A3 (the user-facing gap most likely to matter in dogfood).

1. Extract the form section of `AddItemView.swift` (roughly the "details" pane) into `WardrobeReDo/Views/Wardrobe/ItemFormView.swift`. Parameterize by `bindingsProvider`.
2. Create `EditItemViewModel` mirroring `AddItemViewModel` minus the capture pipeline.
3. Create `EditItemView` consuming `ItemFormView`.
4. Add `WardrobeRepository.updateItem(_:)`.
5. Wire "Edit" button in `ItemDetailView` toolbar.
6. Unit tests for `EditItemViewModel`.

**Exit criteria:** Build green; unit tests green. Manual sim smoke: open item detail → tap edit → change a field → save → return shows change.

**Blockers:** AddItemView extraction causes regression in multi-garment save loop → isolate the change to a new file, keep `AddItemView.swift` using the extracted form-view too (single source of truth). If the regression is stubborn, stop after extracting the read-only form preview, defer the mutating edit path to v1.1.

### Phase 6 — Seed pipeline (≤ 30 min)
**Scope:** Part of A3 (G5).

1. Create `scripts/seed_supabase.py` — reads `WardrobeReDo/Resources/SeedData/archetypes.json` + `rules.json`, upserts into `style_archetypes` + `style_rules` via the `supabase-py` client with service-role key.
2. Document usage in the script's docstring: `SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... python scripts/seed_supabase.py`.
3. **Do not execute.** Requires service-role key from user.
4. Add `scripts/seed_supabase.py` to repo.

**Exit criteria:** Script exists, dry-run locally (`--dry-run` flag prints what would be upserted without network calls). Status doc flags the manual run as a deferred task.

**Blockers:** None — this is a write-and-save task.

### Phase 7 — Integration tests (≤ 45 min)
**Scope:** Part of A3 (G7).

1. Add `WardrobeReDoIntegrationTests` target to `project.yml` (mark as "manual" — not in the default CI run).
2. Write 3 tests using `MockSupabaseClient` (or similar) + `TestFixtures`:
   - Test A: sign-in → add item → generate outfit → save → daily view lists it.
   - Test B: delete item → outfit generation still succeeds on remaining wardrobe.
   - Test C: multi-garment batch → all items share `source_photo_id`.
3. Regenerate xcodeproj (`xcodegen generate`).

**Exit criteria:** Tests compile and pass against mock repos. Note: true Supabase-instance integration is deferred to user (needs live branch).

**Blockers:** If existing test infrastructure can't be reused, fall back to end-to-end tests that hit the actual ViewModels + real style engine + mock repos. Log the decision.

### Phase 8 — Dogfood bootstrap (≤ 20 min)
**Scope:** Make dogfood operable (Tier C prereq).

1. Add a DEBUG-only "Report issue" button to `ProfileView` dev menu that opens the system Mail composer pre-filled with diagnostic info (app version, last 10 MLDiagnostics entries, last 10 os.log errors captured by a ring buffer).
2. Create `docs/plans/2026-04-19-auto-attribute-detection/DOGFOOD_RESULTS.md` skeleton entries for 7 days.
3. Commit `autonomous_attr_train.sh` recipe for attempt-3 to the plan doc (`--focal-gamma 1 --label-smoothing 0.0`) for when the user has RunPod access.

**Exit criteria:** Dev menu has Report button; dogfood log skeleton committed.

**Blockers:** None.

### Phase 9 — Merge prep (≤ 30 min)
**Scope:** A3 finale.

1. Run full `xcodebuild test` locally. Triage failures.
2. Draft PR body in `docs/PR_BODY_DRAFT.md` covering all 75+ commits, with phase-by-phase summary.
3. Push branch to origin (if not already).
4. Open PR to `main` via `gh pr create --draft` (draft because user hasn't confirmed merge timing).
5. Update `docs/SESSION_HANDOFF_BRIEF.md` appendix with autonomous-session summary.

**Exit criteria:** PR opened in draft state; status doc marks "ready for user review + merge decision".

**Blockers:** Test failures → triage, fix what's trivial, keep PR draft with a "known failures" section. Network issue pushing branch → keep local, log.

---

## Blocker taxonomy

### Soft blockers (save-and-continue)
- `supabase` CLI not authenticated → commit migration files, skip `db push`
- RunPod access unavailable → skip attempt-3, document recipe
- Sentry DSN missing → init is gated, continue
- Apple Developer Portal signing issue → skip TestFlight, dev-build is fine

### Hard blockers (stop, save, return control)
- `xcodebuild build` failing at HEAD *before* any changes (means environment broken, not our fault)
- `git push` rejected due to branch protection — document and hand back
- 3 consecutive failed attempts on the same specific error (same file, same line)
- Destructive operation required to proceed (force push, reset, drop table)

### Never block on
- Lint warnings (Swift 6 strict concurrency) — fix or suppress, never fail the phase
- Codable mismatches — add explicit CodingKeys / custom init, move on
- Untested edge cases — write the test or add a TODO with a spawn-task note

---

## Status doc contract

[AUTONOMOUS_IMPLEMENTATION_STATUS.md](./AUTONOMOUS_IMPLEMENTATION_STATUS.md) is updated after every commit. Structure:

```
# Autonomous Implementation Status

## Current phase: N — <name>
## Last commit: <sha> at <timestamp>

## Completed (N)
- [x] Phase 0.1 ...  (commit abc123)
...

## Blocked (N)
- [ ] Phase X.Y — <scope>
  - Attempted: <what was tried>
  - Error: <exact error>
  - Needs: <what user must do to unblock>
  - Next: <resume instructions>

## Skipped (N)
- [ ] Phase X.Y — deferred because <reason>

## Deferred to v1.1
- <thing>

## Session summary (written at end)
- Commits: N
- Phases done: N/9
- Build state: green/red
- Test state: X/Y passing
- Next action for user: <one sentence>
```

---

## Verification

**End-of-session checks (run before handing back):**
1. `git status` — clean working tree, all intended changes committed.
2. `xcodebuild build -scheme WardrobeReDo -sdk iphonesimulator` — green.
3. `xcodebuild test -scheme WardrobeReDo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` — green or only pre-existing failures.
4. `docs/AUTONOMOUS_IMPLEMENTATION_STATUS.md` fully populated with blockers + next actions.
5. PR opened as draft (Phase 9).
6. Memory updated if anything surprising came up (MEMORY.md).

---

## Safety rails

- **Never** commit `Secrets.plist`, `.runpod/config.toml`, or any SSH keys.
- **Never** force-push to any branch.
- **Never** run destructive Supabase operations (`drop`, `delete from` without where, `truncate`).
- **Never** skip git hooks (`--no-verify`).
- **Never** auto-approve a TestFlight build or app-store upload.
- On pre-commit-hook failure: fix the underlying issue, re-stage, create a **new** commit. Never `--amend`.

---

## Scope fences (do not do)

- Don't rewrite the style engine scorers. They're fine.
- Don't change the RF-DETR-Seg multi-garment model. Ship as-is.
- Don't add new feature flags beyond `isMLTelemetryEnabled`.
- Don't change the Supabase schema beyond migrations 00010, 00011.
- Don't introduce a second state-management library. `@Observable` + AppState stays.
- Don't add a second image loader. Kingfisher stays.
- Don't build an Edge Function for outfit generation in this session. Document as v1.1.

---

## Expected end state

When autonomous execution finishes (success path):
- `feature/photo-extraction-engine` has ~10–15 new commits covering A1, A2 (infra), A3.
- Draft PR open to `main` with clean phase-organized history.
- App has: offline cache, retry + idempotency, upload queue, crash reporting hook (Sentry DSN-gated), ML telemetry hook (flag-gated), Edit Item form, seed script, integration tests, in-app "Report issue" button.
- Known deferred items (attempt-3, seed run, TestFlight, Supabase `db push`, real Supabase integration tests) documented in status doc with precise resume instructions.
