# v1.1 Post-Ship Autonomous Continuation

## Status

IN PROGRESS — autonomous execution window opened 2026-04-24.

## Origin

The source plan lived in Claude's ephemeral plan-mode scratch area at
`~/.claude/plans/read-docs-session-handoff-brief-md-for-t-velvet-flamingo.md`
(generated after the PR #1 squash-merge landed at commit `13bd5d7`). This doc
is the durable, repo-tracked copy.

## One-line summary

Execute every v1.1 item that can land without user input (MCP + repo access
only), gate the higher-risk refactors on an automatic abort-on-red rule, and
leave the rest for a later window when you provide the missing credentials.

## Scope

### Autonomous (10 steps executed in this window)

| # | Step | Surface | Risk |
|---|------|---------|------|
| 1 | Apply pending Supabase migrations 00009 / 00010 / 00011 | Supabase MCP (`apply_migration`) | low — idempotent DDL |
| 2 | Seed 50 archetypes + 200 rules into prod Supabase | Supabase MCP (`execute_sql` UPSERTs) | low — idempotent UPSERT on primary key |
| 3 | Bump CI action pins to Node-24 compatible majors | `.github/workflows/ios-tests.yml` PR | low — PR-gated, CI-required-before-merge |
| 4 | Update repo docs post-merge | `docs/plans/INDEX.md`, `docs/AUTONOMOUS_IMPLEMENTATION_STATUS.md` | trivial — pure docs |
| 5 | Scaffold this v1.1 plan doc | `docs/plans/2026-04-25-v1.1-post-ship/PLAN.md` | trivial — pure docs |
| 6 | Remove stale `.claude/worktrees/determined-hertz-3eae4f/` | `git worktree remove` | trivial — branch merged into PR #1 |
| 7 | Add `swift-snapshot-testing` baseline | `project.yml` + `WardrobeReDoTests/Snapshot/ItemFormViewSnapshotTests.swift` | medium — SwiftPM dep + Swift 6 strict concurrency interaction |
| 8 | Full-matrix verification (`xcodebuild test` + CI green) | local + CI | gate — required green before 9/10 |
| 9 | Higher-risk: `UploadQueue` integration into `AddItemViewModel.save` | `AddItemViewModel.swift`, `AddItemViewModelTests.swift`, `MockUploadQueue.swift` | high — 3-strike abort on any substep red |
| 10 | Higher-risk: `AddItemView.detailsStep` → shared `ItemFormView` | `AddItemView.swift`, `ItemFormView.swift` | high — 3-strike abort on any substep red |

### Out of scope (explicitly not attempted autonomously)

- Sentry DSN provisioning — create the Sentry project, paste DSN into `WardrobeReDo/Secrets.plist`
- TestFlight distribution — Apple Developer Portal access required
- Attempt-3 classifier retrain — needs RunPod API key + ~$0.20 + ~45 min
- GitHub-hosted macOS minutes — billing resolution
- Physical dogfooding — the app must be used by a human for 7 days and the results written to `DOGFOOD_RESULTS.md`
- Any `auth.uid()`-bound RLS change that needs a real signed-in user to validate
- Attribute-classifier feature-flag flip — gated on dogfood data we can't generate

## Per-step outcomes (filled as execution proceeds)

| Step | Status | Commit / PR | Notes |
|------|--------|-------------|-------|
| 1 | DONE | migrations 00009 / 00010 / 00011 applied via Supabase MCP | verified via `list_migrations` |
| 2 | DONE | 25-row UPSERT batches via `execute_sql` | verified `select count(*)` returns 50 archetypes + 200 rules |
| 3 | DONE | PR [#3](https://github.com/trkngit/wardrobe-redo-mobile/pull/3) squash-merged as `639d04a` | CI green on self-hosted runner; actions/checkout@v6, cache@v5, upload-artifact@v7 (Node-24 compatible) |
| 4 | DONE | commit `0375096` on main | INDEX.md + AUTONOMOUS_IMPLEMENTATION_STATUS.md updated |
| 5 | DONE | commit `0375096` on main | this file |
| 6 | DONE | `git worktree remove` | worktree work already squash-merged in PR #1 |
| 7 | DONE | PR [#4](https://github.com/trkngit/wardrobe-redo-mobile/pull/4) squash-merged as `3005765` | swift-snapshot-testing 1.19.x wired in; baseline PNG 1170×2532 (iPhone 17 Pro @3x) committed under `WardrobeReDoTests/Snapshot/__Snapshots__/ItemFormViewSnapshotTests/testItemFormView_defaultState.1.png`; `record: .missing` so CI reruns verify instead of re-recording. First CI attempt failed from a self-hosted runner network drop during cache upload (not a test regression); rerun `24907548635` came back green. |
| 8 | DONE | PR [#5](https://github.com/trkngit/wardrobe-redo-mobile/pull/5) squash-merged as `c9cbf09` | main-run flake 24903701479 (`flagFlipsOnWithoutRestart` line 45) root-caused to missing `FeatureFlagTestIsolation.shared.acquire/release` wrap on the 3 MainActor tests that mutate `FeatureFlags.isMLTelemetryEnabled`. Post-merge main run 24907538110 green. |
| 9 | DONE | PR [#6](https://github.com/trkngit/wardrobe-redo-mobile/pull/6) squash-merged as `d060088` | S9.1–S9.4 complete (DI wire, save-path enqueue, sync UI preserved, `MockUploadQueue` + 2 new tests). First CI attempt 24908100779 failed on a cross-suite race: `UploadQueueTests` and `AddItemViewModelUploadQueueTests` both mutate the process-global `UploadQueue.shared` actor, and `@Suite(.serialized)` only serializes WITHIN a suite — the no-op handler from the sibling suite was draining my envelope mid-assertion. Fix in commit `64cdf9f`: new `UploadQueueTestIsolation` actor-semaphore wrapping every test that touches `UploadQueue.shared`. CI retest 24910243103 green; merged. Test count on main bumped to 597 Swift Testing + 1 snapshot + 3 XCTest = 601 green. |
| 10 | IN PROGRESS | PR [#7](https://github.com/trkngit/wardrobe-redo-mobile/pull/7) open, CI queued behind PR #6 | Single-commit swap of `AddItemView.detailsStep`'s 115 lines of duplicated form fields (category, sub, texture, fit, seasons, occasions) for one `ItemFormView(...)` call — the same shared component `EditItemView` has used since Phase 5. Sparkle "auto-detected" badge preserved via `isSectionAutoDetected: (Section) -> Bool` hook. Dead-code cleanup: removed duplicates of `chipButton` + `autoDetectedHeader` from AddItemView (both have identical siblings inside ItemFormView). Local `xcodebuild test` → 595 Swift Testing + 1 snapshot + 3 XCTest = 599/599 green on the pre-PR-6 base; snapshot baseline matched without re-record. Net: `AddItemView.swift` 700 → 588 lines (-112, -16%). |

## Risk controls

- **Supabase DDL:** all 00009 / 00010 / 00011 migrations use `IF NOT EXISTS` / `DROP POLICY IF EXISTS` — safe to rerun
- **Seed script:** UPSERT on primary key → reruns are idempotent
- **CI pin bumps:** PR-gated, green-CI-required-before-merge; automatic revert path documented if majors break self-hosted runner
- **Higher-risk refactors (Steps 9 + 10):** per-substep test gate, 3 consecutive reds aborts the step and documents the deferral here
- **Main branch:** direct commits only for docs (Steps 4 + 5). Everything else goes through a PR
- **No destructive git ops:** no `reset --hard`, no `push --force`, no schema-destructive migrations in this plan

## Verification signals

| Step | Success signal |
|------|----------------|
| 1 | `list_migrations` lists 00009 + 00010 + 00011 as applied; `get_advisors` recorded |
| 2 | `select count(*) from style_archetypes` = 50; `select count(*) from style_rules` = 200 |
| 3 | CI green on the action-pins PR; merged to main |
| 4 | `git log -1 main` shows the docs commit |
| 5 | this file exists and is committed |
| 6 | `git worktree list` shows only the primary worktree |
| 7 | test count 599+, snapshot PR merged |
| 8 | full-matrix run green at 599+/599+ |
| 9 | `grep -n uploadQueue WardrobeReDo/ViewModels/AddItemViewModel.swift` shows the wire AND tests green — OR this doc records the deferral |
| 10 | `grep -n ItemFormView WardrobeReDo/Views/Wardrobe/AddItemView.swift` shows the adoption AND tests green — OR this doc records the deferral |

## What remains on the v1.1 backlog after this window closes

- Sentry DSN provisioning and live crash-report smoke test
- Attempt-3 classifier retrain + flag flip (gated on dogfood)
- Live-Supabase integration harness (needs test branch credentials)
- TestFlight upload (Apple Developer Portal)
- Physical dogfood cycle (the app gets used by you for 7 days)
- Image-CDN cost/latency decision

## Provenance

Originating user request — verbatim:

> create the plan to implement most we can of the things you show above create a interrupt free conitnous plan that wont require my input
