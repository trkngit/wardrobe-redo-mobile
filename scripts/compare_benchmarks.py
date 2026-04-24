#!/usr/bin/env python3
"""Diff two benchmark reports and fail if any category regressed.

Usage:
    python3 scripts/compare_benchmarks.py <baseline.json> <candidate.json> [--tolerance 0.03]

Exit codes:
    0  all categories within tolerance (report printed to stdout)
    1  at least one category regressed by more than --tolerance (default 3%)
    2  I/O or parsing error

Design notes:
    Compares `perCategory.<cat>.meanIoU` between the two reports. Categories
    present in both are scored; categories unique to either side are listed
    for awareness but do not fail the run.

    A negative delta (candidate lower than baseline) that exceeds the
    tolerance is a regression. Positive deltas are always welcome.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        sys.stderr.write(f"Failed to load {path}: {error}\n")
        sys.exit(2)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument(
        "--tolerance",
        type=float,
        default=0.03,
        help="Allowed meanIoU regression per category (default 0.03 = 3 percentage points).",
    )
    args = parser.parse_args(argv)

    baseline = load(args.baseline)
    candidate = load(args.candidate)

    base_cat = baseline.get("perCategory", {})
    cand_cat = candidate.get("perCategory", {})

    shared = sorted(set(base_cat) & set(cand_cat))
    only_baseline = sorted(set(base_cat) - set(cand_cat))
    only_candidate = sorted(set(cand_cat) - set(base_cat))

    print(f"Baseline:   {args.baseline.name}  commit={baseline.get('commit') or '—'}")
    print(f"Candidate:  {args.candidate.name}  commit={candidate.get('commit') or '—'}")
    print(f"Tolerance:  {args.tolerance:+.2%}  (negative delta > tolerance = fail)")
    print()
    print(f"{'Category':<22}{'Baseline':>10}{'Candidate':>12}{'Δ':>10}")
    print("-" * 54)

    regressions: list[tuple[str, float, float, float]] = []

    for category in shared:
        b = base_cat[category].get("meanIoU")
        c = cand_cat[category].get("meanIoU")
        if b is None or c is None:
            print(f"{category:<22}{'—':>10}{'—':>12}{'—':>10}")
            continue
        delta = c - b
        marker = "  ✗" if delta < -args.tolerance else "  ✓" if delta >= 0 else "   "
        print(f"{category:<22}{b:>10.3f}{c:>12.3f}{delta:>+10.3f}{marker}")
        if delta < -args.tolerance:
            regressions.append((category, b, c, delta))

    if only_baseline:
        print()
        print("Categories only in baseline:", ", ".join(only_baseline))
    if only_candidate:
        print("Categories only in candidate:", ", ".join(only_candidate))

    # Overall mean
    base_mean = baseline.get("meanIoU")
    cand_mean = candidate.get("meanIoU")
    if base_mean is not None and cand_mean is not None:
        print()
        print(f"Overall mean IoU:  baseline={base_mean:.3f}  candidate={cand_mean:.3f}  Δ={cand_mean - base_mean:+.3f}")

    if regressions:
        print()
        print(f"FAILED: {len(regressions)} category regression(s) exceed tolerance {args.tolerance:+.2%}")
        for name, b, c, delta in regressions:
            print(f"  • {name}: {b:.3f} → {c:.3f} (Δ {delta:+.3f})")
        return 1

    print()
    print("OK — no category regressions beyond tolerance.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
