#!/usr/bin/env python3
"""Build the DeepFashion2 benchmark subset used by run_benchmark.swift.

DeepFashion2 ships under a research-only licence and is distributed via a
signed request form (see https://github.com/switchablenorms/DeepFashion2).
We do NOT commit any of those assets to the repo — they live in
``~/wardrobe-benchmark/`` outside the tree and `.gitignore` has a belt-and-
suspenders rule in case anyone points the script at the workspace.

What this script actually does:

1. Validates that `~/wardrobe-benchmark/DeepFashion2/validation/image/` and
   `.../annotation/` exist. If not, prints the exact steps to obtain them.
2. Picks a deterministic 300-image subset from the validation split (seeded
   so reruns hit the same images — reports are then comparable across
   commits).
3. Writes `~/wardrobe-benchmark/benchmark_manifest.json` listing each chosen
   image, its annotation file, and the clothing categories it contains.

This script never modifies the DeepFashion2 download directory. It only
reads and writes to `~/wardrobe-benchmark/`.
"""

from __future__ import annotations

import hashlib
import json
import os
import random
import sys
from pathlib import Path
from typing import Iterable

BENCHMARK_ROOT = Path.home() / "wardrobe-benchmark"
DEEPFASHION_ROOT = BENCHMARK_ROOT / "DeepFashion2"
IMAGE_DIR = DEEPFASHION_ROOT / "validation" / "image"
ANNOTATION_DIR = DEEPFASHION_ROOT / "validation" / "annos"
MANIFEST_PATH = BENCHMARK_ROOT / "benchmark_manifest.json"
SUBSET_SIZE = 300
RANDOM_SEED = "wardrobe-redo-phase4"

ACCESS_INSTRUCTIONS = f"""
DeepFashion2 is research-only and not bundled with this repo.

To obtain the validation split:

  1. Fill out the access form:
     https://github.com/switchablenorms/DeepFashion2/blob/master/DATASET_LICENSE.md
  2. Download `validation.zip` (≈ 4 GB) when the maintainers email you the link.
  3. Extract the contents so the paths below exist:

       {IMAGE_DIR}
       {ANNOTATION_DIR}

The extracted tree NEVER goes into the repo — `.gitignore` ignores
`~/wardrobe-benchmark/` and the path is under $HOME anyway.

Once the paths exist, rerun:

    python3 scripts/build_benchmark.py
"""


def ensure_paths_exist() -> None:
    missing = [p for p in (IMAGE_DIR, ANNOTATION_DIR) if not p.is_dir()]
    if missing:
        sys.stderr.write(ACCESS_INSTRUCTIONS)
        sys.stderr.write("\nMissing paths:\n")
        for p in missing:
            sys.stderr.write(f"  • {p}\n")
        sys.exit(1)


def iter_image_files() -> Iterable[Path]:
    for p in sorted(IMAGE_DIR.iterdir()):
        if p.suffix.lower() in {".jpg", ".jpeg", ".png"}:
            yield p


def deterministic_subset(items: list[Path], size: int, seed: str) -> list[Path]:
    rng = random.Random(hashlib.sha256(seed.encode("utf-8")).digest())
    pool = list(items)
    rng.shuffle(pool)
    return sorted(pool[:size], key=lambda p: p.name)


def read_annotation(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def categories_in_annotation(annotation: dict) -> list[str]:
    cats: set[str] = set()
    for key, value in annotation.items():
        if not key.startswith("item"):
            continue
        if isinstance(value, dict) and "category_name" in value:
            cats.add(str(value["category_name"]))
    return sorted(cats)


def main() -> int:
    ensure_paths_exist()
    BENCHMARK_ROOT.mkdir(parents=True, exist_ok=True)

    images = list(iter_image_files())
    if not images:
        sys.stderr.write(f"No images found in {IMAGE_DIR}\n")
        return 1

    chosen = deterministic_subset(images, SUBSET_SIZE, RANDOM_SEED)
    entries: list[dict] = []
    for image_path in chosen:
        stem = image_path.stem
        annotation_path = ANNOTATION_DIR / f"{stem}.json"
        annotation = read_annotation(annotation_path) if annotation_path.is_file() else {}
        entries.append({
            "image": str(image_path.relative_to(BENCHMARK_ROOT)),
            "annotation": str(annotation_path.relative_to(BENCHMARK_ROOT)) if annotation_path.is_file() else None,
            "categories": categories_in_annotation(annotation),
        })

    manifest = {
        "version": 1,
        "source": "DeepFashion2 validation split",
        "license": "research-only — not redistributable",
        "seed": RANDOM_SEED,
        "subset_size": SUBSET_SIZE,
        "count": len(entries),
        "entries": entries,
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=False))
    print(f"Wrote {MANIFEST_PATH} with {len(entries)} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
