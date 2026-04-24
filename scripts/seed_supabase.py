#!/usr/bin/env python3
"""Seed `style_archetypes` + `style_rules` into Supabase from bundled JSON.

Migration `00002_seed_style_data.sql` only ships 12 of the 50 archetypes and
none of the 200 rules — the rest live in `WardrobeReDo/Resources/SeedData/*.json`
and are loaded as a bundled-JSON fallback by `StyleDataRepository`. That's
fine for on-device generation but blocks any future server-side outfit
generation (Edge Functions) and multi-device sync.

This script upserts the full 50 archetypes + 200 rules into the live
Postgres tables so the JSON fallback becomes a true disaster-recovery path
rather than the primary source.

-------------------------------------------------------------------------

USAGE

    # Preview what would be sent without touching the server
    python3 scripts/seed_supabase.py --dry-run

    # Against a specific project — URL from Supabase dashboard > Settings > API
    export SUPABASE_URL="https://<project-ref>.supabase.co"
    export SUPABASE_SERVICE_ROLE_KEY="<service role key — NOT anon key>"
    python3 scripts/seed_supabase.py

    # Limit to archetypes or rules only (e.g. when re-running after a fix)
    python3 scripts/seed_supabase.py --only archetypes
    python3 scripts/seed_supabase.py --only rules

The script is idempotent — re-running it against an already-seeded
database is a no-op other than refreshing updated JSON values. Upsert is
driven off the PK (`id` column), which is stable across re-runs because
the JSON files carry their own UUIDs.

-------------------------------------------------------------------------

SAFETY

The script requires the SERVICE ROLE key because RLS blocks INSERT on
style_archetypes/style_rules for non-privileged roles (policies only
grant SELECT to `authenticated`). NEVER commit the service role key to
git or drop it in the mobile bundle — it bypasses every RLS policy.

Run this once per environment (dev, staging, prod) when the canonical
JSON changes. There is no "undo" short of truncating both tables.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable

# Repo-relative paths; script sits in scripts/ so one level up is the root.
REPO_ROOT = Path(__file__).resolve().parent.parent
ARCHETYPES_JSON = REPO_ROOT / "WardrobeReDo" / "Resources" / "SeedData" / "archetypes.json"
RULES_JSON = REPO_ROOT / "WardrobeReDo" / "Resources" / "SeedData" / "rules.json"

# Chunking — PostgREST happily accepts big arrays, but a single HTTP round
# trip per chunk makes partial failures easier to diagnose (index in the
# chunk is the offending row).
CHUNK_SIZE = 50


def load_json(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        sys.exit(f"error: seed file not found: {path}")
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, list):
        sys.exit(f"error: expected list in {path}, got {type(data).__name__}")
    return data


def chunked(items: list[dict[str, Any]], size: int) -> Iterable[list[dict[str, Any]]]:
    for start in range(0, len(items), size):
        yield items[start : start + size]


def upsert(
    *,
    supabase_url: str,
    service_role_key: str,
    table: str,
    rows: list[dict[str, Any]],
    dry_run: bool,
) -> None:
    """Upsert `rows` into `table` via PostgREST.

    Uses `Prefer: resolution=merge-duplicates` so repeated runs update the
    existing row by PK (`id`). The service role key bypasses RLS — callers
    are responsible for keeping it out of source control.
    """
    if not rows:
        print(f"  ({table}) no rows to upsert — skipping")
        return

    endpoint = f"{supabase_url.rstrip('/')}/rest/v1/{table}"
    headers = {
        "apikey": service_role_key,
        "Authorization": f"Bearer {service_role_key}",
        "Content-Type": "application/json",
        # merge-duplicates = UPSERT on primary key. return=minimal keeps
        # response bodies empty, which matters when shipping 200 rules.
        "Prefer": "resolution=merge-duplicates,return=minimal",
    }

    total = len(rows)
    sent = 0
    for chunk in chunked(rows, CHUNK_SIZE):
        payload = json.dumps(chunk).encode("utf-8")
        if dry_run:
            print(
                f"  [dry-run] {table}: would POST {len(chunk)} rows "
                f"({sent + 1}–{sent + len(chunk)} of {total})"
            )
            sent += len(chunk)
            continue

        req = urllib.request.Request(endpoint, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                # `return=minimal` means status 201 with empty body on success.
                if resp.status not in (200, 201):
                    raise RuntimeError(
                        f"{table}: unexpected status {resp.status} — {resp.read().decode()}"
                    )
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            sys.exit(
                f"error: {table} upsert failed (HTTP {exc.code}) for rows "
                f"{sent}..{sent + len(chunk) - 1}:\n{body}"
            )
        except urllib.error.URLError as exc:
            sys.exit(f"error: {table} upsert network failure: {exc.reason}")

        sent += len(chunk)
        print(f"  ({table}) upserted {sent}/{total}")


def validate_rows(rows: list[dict[str, Any]], required_keys: set[str], label: str) -> None:
    """Best-effort schema check before hitting the wire.

    PostgREST will return 400/422 with a reasonable message if a column is
    missing, but catching it here means you see *all* offending rows in one
    pass rather than one-at-a-time on the server.
    """
    missing_by_row: list[tuple[int, set[str]]] = []
    for idx, row in enumerate(rows):
        missing = required_keys - set(row.keys())
        if missing:
            missing_by_row.append((idx, missing))
    if missing_by_row:
        lines = [f"  row {idx}: missing {sorted(missing)}" for idx, missing in missing_by_row[:5]]
        more = f"  ... and {len(missing_by_row) - 5} more" if len(missing_by_row) > 5 else ""
        sys.exit(
            f"error: {label} validation failed — {len(missing_by_row)} row(s) missing required keys:\n"
            + "\n".join(lines)
            + ("\n" + more if more else "")
        )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Upsert style_archetypes + style_rules into Supabase from bundled JSON.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Parse + validate + print the plan without contacting Supabase.",
    )
    parser.add_argument(
        "--only",
        choices=("archetypes", "rules"),
        help="Limit the run to one table (default: both).",
    )
    args = parser.parse_args()

    supabase_url = os.environ.get("SUPABASE_URL", "").strip()
    service_role_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()

    if not args.dry_run:
        if not supabase_url or not service_role_key:
            sys.exit(
                "error: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.\n"
                "Hint: export them from Supabase dashboard > Settings > API,\n"
                "or run with --dry-run to preview without network access."
            )

    archetypes = load_json(ARCHETYPES_JSON)
    rules = load_json(RULES_JSON)

    print(f"Loaded {len(archetypes)} archetypes, {len(rules)} rules.")

    # The JSON keys are 1:1 with the DB columns; a missing key on any row
    # would be a corrupted seed file, not a schema mismatch.
    archetype_required = {
        "id",
        "name",
        "family",
        "editorial_name",
        "description",
        "formality_min",
        "formality_max",
        "seasons",
        "occasions",
        "mood_keywords",
        "color_preferences",
        "texture_preferences",
        "proportion_preferences",
    }
    rule_required = {
        "id",
        "archetype_id",
        "slot_requirements",
        "weight",
        "boost_conditions",
        "penalty_conditions",
        "preferred_harmony",
        "proportion_rule",
        "texture_rule",
    }
    validate_rows(archetypes, archetype_required, "archetypes.json")
    validate_rows(rules, rule_required, "rules.json")

    # Integrity check: every rule's archetype_id must map to a loaded
    # archetype. Catches copy-paste errors in the JSON before Postgres
    # rejects the whole batch with an FK violation.
    archetype_ids = {a["id"] for a in archetypes}
    orphan_rules = [r["id"] for r in rules if r["archetype_id"] not in archetype_ids]
    if orphan_rules:
        sys.exit(
            f"error: {len(orphan_rules)} rule(s) reference archetype_ids that aren't in "
            f"archetypes.json. First few: {orphan_rules[:3]}"
        )

    if args.dry_run:
        print("DRY RUN — no network calls will be made.\n")

    if args.only in (None, "archetypes"):
        print(f"\nUpserting style_archetypes ({len(archetypes)} rows)...")
        upsert(
            supabase_url=supabase_url,
            service_role_key=service_role_key,
            table="style_archetypes",
            rows=archetypes,
            dry_run=args.dry_run,
        )

    if args.only in (None, "rules"):
        print(f"\nUpserting style_rules ({len(rules)} rows)...")
        upsert(
            supabase_url=supabase_url,
            service_role_key=service_role_key,
            table="style_rules",
            rows=rules,
            dry_run=args.dry_run,
        )

    if args.dry_run:
        print("\nDone (dry run).")
    else:
        print("\nDone. Verify with:")
        print("  select count(*) from style_archetypes;  -- expect 50")
        print("  select count(*) from style_rules;        -- expect 200")


if __name__ == "__main__":
    main()
