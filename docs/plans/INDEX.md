# Wardrobe Re-Do — Engineering Plans Index

This directory is the **source of truth** for every significant engineering plan on Wardrobe Re-Do. Plans authored in Claude's plan-mode scratch area (`~/.claude/plans/`) are **ephemeral** — they get overwritten on every new plan-mode session and must not be treated as durable. As soon as a plan is approved, copy it here so it survives context compaction, is visible to any future Claude session that reads the repo, and becomes a git-tracked artifact.

## Convention

```
docs/plans/
├── INDEX.md                                          # this file
├── 2026-04-18-multi-garment-detection.md             # per-plan canonical doc
├── 2026-04-18-multi-garment-detection-research.md    # long-form research artifacts
└── archive/                                          # shipped or abandoned plans
```

Every plan file has:

- A `## Status` line near the top, updated as work progresses (`PROPOSED` → `IN PROGRESS` → `SHIPPED` / `ABANDONED`)
- Cross-links to PRs / commits as they land
- A footer quoting the originating user request verbatim + date

## Statuses

| Slug | Status | Started | Shipped | One-liner |
|------|--------|---------|---------|-----------|
| [2026-04-18-multi-garment-detection](./2026-04-18-multi-garment-detection.md) | SHIPPED — merged in PR [#1](https://github.com/trkngit/wardrobe-redo-mobile/pull/1) as squash-commit `13bd5d7` | 2026-04-18 | 2026-04-24 | RF-DETR-Seg + Fashionpedia: detect multiple garments in one photo, multi-pick UI, sequential per-item save loop |
| [2026-04-18-autonomous-5hr-window](./2026-04-18-autonomous-5hr-window.md) | SHIPPED P1+P2 (bbox AP@0.5=0.65 / segm=0.64); P3 SHIPPED with PR [#1](https://github.com/trkngit/wardrobe-redo-mobile/pull/1) squash-commit `13bd5d7` | 2026-04-18 | 2026-04-18 | Autonomous Phase-1 finish + pre-authorized Phase-2 full train with guardrails, budget caps, and phone push dispatch |
| [2026-04-19-multi-garment-crash-recovery](./2026-04-19-multi-garment-crash-recovery.md) | PROPOSED (v1.1 punch-list item) | — | — | Persist `pendingProposalQueue` to SwiftData so a mid-batch jetsam doesn't lose unsaved garments |
| [2026-04-19-auto-attribute-detection](./2026-04-19-auto-attribute-detection.md) | SHIPPED — merged in PR [#1](https://github.com/trkngit/wardrobe-redo-mobile/pull/1) as squash-commit `13bd5d7`; flag-flip + dogfood aggregation still pending | 2026-04-19 | 2026-04-24 | Auto-detect category / texture / fit / seasons / occasions from the capture and pre-select them on the Add Item form; user-editable; correction tracking via new `detected_attributes` JSONB column |
| [2026-04-25-v1.1-post-ship](./2026-04-25-v1.1-post-ship/PLAN.md) | SHIPPED — 10 of 10 steps; PRs #3–#7 all squash-merged | 2026-04-24 | 2026-04-25 | Apply pending migrations + seed prod + bump CI pins + snapshot baseline + UploadQueue + ItemFormView consolidation |

## Memory pointer

The auto-loaded MEMORY.md for this project points here. The pointer lives at:

```
/Users/tarkansurav/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/memory/MEMORY.md
```

When starting new planning work, future Claude sessions should read this INDEX.md first to avoid re-deriving decisions already made.
