# Pattern: Durable Plan Storage

**Problem.** You use plan mode in Claude Code. The plan mode scratch file (`~/.claude/plans/<slug>.md`) is ephemeral — it gets overwritten every plan-mode session. Context compaction can drop your plan on the floor. The next session has no memory of why earlier decisions were made.

**Solution.** Mirror approved plans into the project repo under `docs/plans/`. Point your project's MEMORY.md at the index. Every future Claude session for this project auto-loads the pointer and finds every plan ever made, instantly.

This is the convention we use. It costs ~5 minutes per plan and saves hours of re-derivation.

---

## Directory layout

```
<repo-root>/docs/plans/
├── INDEX.md                                  # one row per plan
├── YYYY-MM-DD-<slug>.md                      # the canonical plan
├── YYYY-MM-DD-<slug>-research.md             # long-form research artifacts (optional)
└── archive/                                  # shipped or abandoned plans
    └── YYYY-MM-DD-<old-slug>.md
```

## Per-plan file structure

```markdown
# <Project> — <Plan Title>

**Plan slug:** `YYYY-MM-DD-<slug>`
**Status:** PROPOSED | IN PROGRESS | BLOCKED | SHIPPED | ABANDONED — <one-line nuance>
**Estimated cycle time:** <weeks>
**Estimated total cost:** <$>

## Execution log

| Commit | Status | SHA | Notes |
|---|---|---|---|
| 1 — <what> | shipped | `abc1234` | <one line> |
| 2 — <what> | in progress | — | <one line> |

---

## 0 — Permanent Plan Storage Convention (MUST READ NEXT TIME)

<brief paragraph explaining this convention so the file is self-documenting>

---

## 1 — Context
<why this plan exists>

## 2-N — Plan sections
<decisions, architecture, commits, verification, risks>

## N+1 — User Request (Verbatim)
> <quoted user messages that originated this plan>

Date: <ISO>
Plan author: Claude (Sonnet) in plan mode for <project>
```

## INDEX.md format

```markdown
# <Project> — Engineering Plans Index

## Statuses

| Slug | Status | Started | Shipped | One-liner |
|------|--------|---------|---------|-----------|
| [YYYY-MM-DD-slug](./YYYY-MM-DD-slug.md) | IN PROGRESS (<detail>) | YYYY-MM-DD | — | <10-word summary> |
```

Columns are fixed. Keep the one-liner under ~15 words so the table stays scannable.

## MEMORY.md pointer

Append one line to the project's auto-loaded MEMORY.md:

```markdown
- [Plan Index](../../../../<path-to-repo>/docs/plans/INDEX.md) — every active and shipped engineering plan for the project. Read this first when planning new work.
```

Path varies. On macOS it's typically:

```
/Users/<you>/.claude/projects/-<path-with-dashes-instead-of-slashes>/memory/MEMORY.md
```

The next Claude session for this project will auto-load this file via its CLAUDE.md, follow the pointer to INDEX.md, and find every plan.

## Ephemeral vs durable

| Location | Durability | When to use |
|---|---|---|
| `~/.claude/plans/<slug>.md` | Ephemeral — overwritten each plan-mode session | In-flight drafting. Never the final resting place. |
| `<repo>/docs/plans/<slug>.md` | Durable — git-tracked | Source of truth. Copy the scratch plan here on approval. |

## Execution steps (once, per plan)

1. After ExitPlanMode + user approval in plan mode, copy the scratch plan to `docs/plans/YYYY-MM-DD-<slug>.md`. Same content verbatim.
2. Create or update `docs/plans/INDEX.md` with a new row for the plan.
3. Add or verify the MEMORY.md pointer (step is idempotent — don't duplicate the line if already there).
4. Commit as `docs(plans): seed docs/plans + YYYY-MM-DD-<slug>` (or `docs(plans): add YYYY-MM-DD-<slug>` for subsequent plans).
5. Cross-link the first implementation commit back to the plan in its commit message.

## Updates during execution

- Update the **Execution log** table in the plan file after every commit that implements it. SHA + status + one-line note.
- Flip the **Status** line when the plan transitions (PROPOSED → IN PROGRESS → SHIPPED / ABANDONED).
- Update the INDEX.md one-liner on every state change.
- When a plan ships, move it to `docs/plans/archive/` and update INDEX.md. Don't delete — historical decisions are valuable.

## Why this works

- **Survives compaction.** Plans live in git, not in Claude's context.
- **Auto-loaded.** MEMORY.md pointer means the next Claude session sees the index without you having to remind it.
- **Searchable.** `grep -r "decision" docs/plans/` finds every decision across every plan.
- **Peer-readable.** Humans on the project read the same file Claude does.
- **Zero lock-in.** Plain markdown in git. Works with any editor, any tool, any future AI assistant.

## Anti-patterns

- **Don't** treat `~/.claude/plans/*.md` as durable. It's scratch. Every plan-mode session may overwrite it.
- **Don't** paste entire plans into commit messages. Link to the plan file.
- **Don't** let the `Execution log` table drift from the actual commit history. Update it as part of each implementation commit.
- **Don't** skip the INDEX.md update — future you (and future Claude) reads the index first.
- **Don't** commit raw chat transcripts into `docs/plans/`. They belong in `docs/session-logs/` or in an out-of-repo pointer.

## Minimal working example

Smallest viable setup for a new project:

```bash
mkdir -p docs/plans
cat > docs/plans/INDEX.md <<'EOF'
# <Project> — Engineering Plans Index

## Statuses

| Slug | Status | Started | Shipped | One-liner |
|------|--------|---------|---------|-----------|
EOF
git add docs/plans/INDEX.md
git commit -m "docs(plans): seed plans index"
```

Then add your first plan as `docs/plans/YYYY-MM-DD-<slug>.md` and a row in INDEX.md, and point MEMORY.md at it.

## Source

This pattern was distilled from Section 0 of `docs/plans/2026-04-18-multi-garment-detection.md` in the Wardrobe Re-Do project. It is project-agnostic — the only project-specific bits are the repo root path in the MEMORY.md pointer.
