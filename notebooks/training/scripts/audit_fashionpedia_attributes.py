"""Audit the 294 fine-grained attribute annotations inside the
Fashionpedia train split and emit a reviewable inventory CSV.

Context:
    The dataset we already train on (prepared via `prepare_fashionpedia.py`)
    ships a second annotation vocabulary beyond the 46 main apparel classes:
    ~294 fine-grained attributes (materials, silhouettes, necklines, sleeve
    lengths, lengths, fits, closure types, etc.). `prepare_fashionpedia.py`
    keeps only the main-class bboxes and drops these attributes entirely.

    Phase 1 of the auto-attribute-detection plan needs to decide which of
    those 294 attributes map to the iOS `TextureType` / `FitAttribute`
    enums, so the Phase 3 multi-head classifier has something to predict.
    This script produces the machine-readable side of that decision.

Output:
    docs/plans/2026-04-19-auto-attribute-detection/
        fashionpedia_attribute_inventory.csv

    Columns:
        attr_id               — numeric Fashionpedia attribute id
        attr_name             — e.g. "cotton", "oversized (fit)"
        attr_supercategory    — e.g. "textile finishing, manufacturing techniques"
        global_count          — how many annotations carry this attribute
        global_fraction       — global_count / total annotations (0..1)
        top_category_1..3     — the three Fashionpedia classes this attribute
                                co-occurs with most often, with their counts
        coverage_note         — free-text hint: e.g. "material" / "silhouette"

    A summary block is also printed to stdout: total annotation count,
    fraction with ≥1 attribute, per-supercategory coverage.

Usage:
    # Expects the train-split annotation json downloaded by
    # `prepare_fashionpedia.py` in the same layout.
    python audit_fashionpedia_attributes.py \\
        --annotations ./data/fashionpedia/instances_attributes_train2020.json \\
        --out ./docs/plans/2026-04-19-auto-attribute-detection/fashionpedia_attribute_inventory.csv

    # Optional: --top-n 5 to widen the top-category column fanout
    # Optional: --min-count 10 to drop long-tail attributes with <10 occurrences

Idempotent: overwrites the CSV. No network calls. Pure metadata work — runs
in a few seconds on a laptop.

See docs/plans/2026-04-19-auto-attribute-detection.md Phase 1.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument(
        "--annotations",
        type=Path,
        required=True,
        help="Path to instances_attributes_train2020.json",
    )
    p.add_argument(
        "--out",
        type=Path,
        required=True,
        help="Path to write the inventory CSV",
    )
    p.add_argument(
        "--top-n",
        type=int,
        default=3,
        help="Number of top co-occurring categories to emit per attribute (default: 3)",
    )
    p.add_argument(
        "--min-count",
        type=int,
        default=0,
        help="Drop attributes with fewer than this many occurrences (default: 0 = keep all)",
    )
    return p.parse_args()


def load_annotations(path: Path) -> dict[str, Any]:
    if not path.exists():
        sys.exit(f"error: annotations file not found: {path}")
    print(f"loading {path.name} ({path.stat().st_size / 1e6:.1f} MB)…")
    with open(path) as fh:
        return json.load(fh)


def audit(
    data: dict[str, Any],
    top_n: int,
    min_count: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Return (rows, summary_stats)."""
    attributes = data.get("attributes", [])
    categories = data.get("categories", [])
    annotations = data.get("annotations", [])

    if not attributes:
        sys.exit("error: 'attributes' key is empty — is this the wrong annotation file?")

    attr_by_id: dict[int, dict[str, Any]] = {a["id"]: a for a in attributes}
    cat_by_id: dict[int, str] = {c["id"]: c["name"] for c in categories}

    # Per-attribute counters
    global_count: Counter[int] = Counter()
    per_cat_count: dict[int, Counter[int]] = defaultdict(Counter)  # attr_id -> {cat_id: count}

    # Coverage tracking
    anns_with_any_attr = 0
    total_anns = len(annotations)

    for ann in annotations:
        attr_ids = ann.get("attribute_ids", []) or []
        cat_id = ann.get("category_id")
        if attr_ids:
            anns_with_any_attr += 1
        for attr_id in attr_ids:
            global_count[attr_id] += 1
            if cat_id is not None:
                per_cat_count[attr_id][cat_id] += 1

    # Build rows
    rows: list[dict[str, Any]] = []
    for attr_id, attr_def in sorted(attr_by_id.items()):
        count = global_count.get(attr_id, 0)
        if count < min_count:
            continue
        top_cats = per_cat_count[attr_id].most_common(top_n)
        row: dict[str, Any] = {
            "attr_id": attr_id,
            "attr_name": attr_def.get("name", ""),
            "attr_supercategory": attr_def.get("supercategory", ""),
            "global_count": count,
            "global_fraction": round(count / total_anns, 6) if total_anns else 0.0,
        }
        for rank in range(top_n):
            if rank < len(top_cats):
                cat_id, cat_count = top_cats[rank]
                row[f"top_category_{rank + 1}"] = f"{cat_by_id.get(cat_id, f'id={cat_id}')} ({cat_count})"
            else:
                row[f"top_category_{rank + 1}"] = ""
        row["coverage_note"] = _infer_bucket(attr_def.get("supercategory", ""))
        rows.append(row)

    # Summary stats
    per_super: Counter[str] = Counter()
    for attr_def in attr_by_id.values():
        per_super[attr_def.get("supercategory", "")] += 1
    summary = {
        "total_annotations": total_anns,
        "annotations_with_any_attribute": anns_with_any_attr,
        "coverage_fraction": round(anns_with_any_attr / total_anns, 4) if total_anns else 0.0,
        "total_attributes": len(attr_by_id),
        "attributes_emitted": len(rows),
        "per_supercategory_attribute_count": dict(per_super.most_common()),
    }
    return rows, summary


def _infer_bucket(supercategory: str) -> str:
    """Best-guess textual hint so reviewers can filter the CSV quickly.

    This is a label, NOT a taxonomy decision — the reviewer still has to
    commit to an iOS enum case in `ATTRIBUTE_TAXONOMY.md`.
    """
    s = supercategory.lower()
    if "textile" in s or "material" in s or "fabric" in s:
        return "texture-candidate"
    if "silhouette" in s or "fit" in s or "length" in s:
        return "fit-candidate"
    if "neckline" in s or "sleeve" in s or "collar" in s:
        return "subcategory-hint"
    if "closure" in s or "opening" in s:
        return "construction (skip)"
    return ""


def write_csv(rows: list[dict[str, Any]], path: Path, top_n: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "attr_id",
        "attr_name",
        "attr_supercategory",
        "global_count",
        "global_fraction",
        *[f"top_category_{i + 1}" for i in range(top_n)],
        "coverage_note",
    ]
    with open(path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} rows → {path}")


def print_summary(summary: dict[str, Any]) -> None:
    print("\n=== summary ===")
    print(f"total annotations:           {summary['total_annotations']:,}")
    print(
        f"annotations with ≥1 attribute: {summary['annotations_with_any_attribute']:,} "
        f"({summary['coverage_fraction']:.1%})"
    )
    print(f"total attributes defined:    {summary['total_attributes']}")
    print(f"attributes emitted to CSV:   {summary['attributes_emitted']}")
    print("\nattributes per supercategory (top 15):")
    for name, n in list(summary["per_supercategory_attribute_count"].items())[:15]:
        print(f"  {n:>4}  {name}")


def main() -> None:
    args = parse_args()
    data = load_annotations(args.annotations)
    rows, summary = audit(data, top_n=args.top_n, min_count=args.min_count)
    write_csv(rows, args.out, top_n=args.top_n)
    print_summary(summary)


if __name__ == "__main__":
    main()
