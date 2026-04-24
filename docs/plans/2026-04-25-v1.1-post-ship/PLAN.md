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
| 3 | IN PROGRESS | PR [#3](https://github.com/trkngit/wardrobe-redo-mobile/pull/3) — `chore(ci): bump action pins to Node-24 compatible majors` | waiting on self-hosted CI green |
| 4 | IN PROGRESS | this commit | — |
| 5 | IN PROGRESS | this commit | this file |
| 6 | DONE | `git worktree remove` | worktree work already squash-merged in PR #1 |
| 7 | PENDING | — | — |
| 8 | PENDING | — | — |
| 9 | PENDING | — | 3-strike abort rule armed |
| 10 | PENDING | — | 3-strike abort rule armed |

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
