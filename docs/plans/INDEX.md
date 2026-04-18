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
| [2026-04-18-multi-garment-detection](./2026-04-18-multi-garment-detection.md) | IN PROGRESS | 2026-04-18 | — | RF-DETR-Seg + Fashionpedia: detect multiple garments in one photo, multi-pick UI, sequential per-item save loop |

## Memory pointer

The auto-loaded MEMORY.md for this project points here. The pointer lives at:

```
/Users/tarkansurav/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/memory/MEMORY.md
```

When starting new planning work, future Claude sessions should read this INDEX.md first to avoid re-deriving decisions already made.
