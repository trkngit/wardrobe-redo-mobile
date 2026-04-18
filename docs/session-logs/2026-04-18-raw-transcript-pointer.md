# Raw Transcript Pointer — 2026-04-18 Session

This file is a **pointer** to the raw, un-compacted JSONL chat transcript for the 2026-04-18 multi-garment detection session. The transcript itself is NOT in the repo.

## Why not in-repo

- **Size.** Raw Claude Code session JSONL files are typically 1–20 MB and grow linearly with tool calls. This session had heavy tool use (script edits, probe runs, git operations, Bash output tailing) — large enough to be a noisy git blob.
- **Signal density.** The JSONL contains all internal tool calls, system reminders, and plan-mode scratch edits. The meaningful decisions, findings, and commit trail are already captured in:
  - `docs/plans/2026-04-18-multi-garment-detection.md` (Sections 0.1 + 0.2)
  - `docs/session-logs/2026-04-18-training-scripts-rfdetr-api-alignment.md`
  - `docs/patterns/*.md`
  - Git commits `c2581ac`, `8cbf350`, `f2e9a77`, `2ee02f1`, and the docs commits that follow.
- **Privacy.** Raw session files may contain full tool outputs including local paths, filesystem contents, and environment details that don't belong in a shared repo.

## Where the transcript lives

```
/Users/tarkansurav/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/118928d5-cdda-4951-b7cb-6d50c5eb0063.jsonl
```

The parent directory
```
/Users/tarkansurav/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/
```
is Claude Code's per-project storage. Every session for this project lands here as its own `<uuid>.jsonl` file.

## How to retrieve specific moments

### Read the full transcript

```bash
cat /Users/tarkansurav/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/118928d5-cdda-4951-b7cb-6d50c5eb0063.jsonl | less
```

Each line is a standalone JSON object representing one message, tool call, or tool result.

### Extract just user and assistant text messages

```bash
jq -r 'select(.type == "user" or .type == "assistant") | "[\(.type)] \(.message.content // .content // "")"' \
  /Users/tarkansurav/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/118928d5-cdda-4951-b7cb-6d50c5eb0063.jsonl \
  | less
```

### Find a specific tool call by name

```bash
jq -r 'select(.type == "tool_use" and .name == "Bash") | "\(.input.command // "")"' \
  /Users/tarkansurav/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/118928d5-cdda-4951-b7cb-6d50c5eb0063.jsonl
```

Replace `"Bash"` with any tool name (`Edit`, `Read`, `Grep`, `ExitPlanMode`, `mcp__Claude_in_Chrome__navigate`, …).

### Grep for a string across all project sessions

```bash
grep -l "rfdetr" /Users/tarkansurav/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/*.jsonl
```

### Replay a decision by timestamp

The JSONL has `timestamp` fields on every entry. Sort by timestamp if the file's line order has been perturbed:

```bash
jq -s 'sort_by(.timestamp) | .[]' \
  /Users/tarkansurav/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/118928d5-cdda-4951-b7cb-6d50c5eb0063.jsonl \
  > /tmp/session-sorted.jsonl
```

## Session identity

- **Session UUID:** `118928d5-cdda-4951-b7cb-6d50c5eb0063`
- **Date:** 2026-04-18
- **Branch:** `feature/photo-extraction-engine`
- **Head at start:** `da243e5`
- **Head at end (docs complete):** see `git log --oneline` for the latest `docs(...)` commits on the branch.

## Retention

Claude Code's project storage is local-only to the user's machine. It is NOT backed up automatically by the repo. If the user needs this transcript preserved long-term, they should `cp` it to a private backup location — this pointer file is just a breadcrumb, not a backup.

---

**Created:** 2026-04-18
**Maintained-by:** update this pointer if future sessions add to the same session-logs entry, or create sibling pointer files for new sessions with their own UUIDs.
