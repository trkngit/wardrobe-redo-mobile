"""Download Fashionpedia from the CVDF S3 mirror (official source — has
instance segmentation polygons, unlike the HF `detection-datasets/`
mirror which is detection-only) and convert to the Roboflow-style COCO
directory layout that rfdetr's Trainer expects.

Output layout:
    <out_dir>/
        train/
            _annotations.coco.json
            <image_files>.jpg
        valid/
            _annotations.coco.json
            <image_files>.jpg

Filtered to the 33 Fashionpedia "main apparel" classes (the rest are
garment PARTS — sleeves, collars, hems — and attributes, which the iOS
app doesn't consume).

Idempotent: re-running skips already-extracted splits. Safe to Ctrl-C
and resume.

Usage:
    # Full dataset (~12 GB download, ~46K train + ~1.2K val images):
    python prepare_fashionpedia.py --out ./data/fashionpedia

    # Tiny subset for smoke testing (≤500 train, ≤100 val):
    python prepare_fashionpedia.py --out ./data/fashionpedia --max-train 500 --max-val 100

License reminder: annotations are CC BY 4.0, images are CC-licensed
subset (CVDF filter). Attribution credit lives in the app's About
screen already — see plan Section 4.
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import tarfile
import zipfile
from pathlib import Path
from typing import Any

try:
    import requests
    from tqdm import tqdm
except ImportError as exc:
    print(
        f"Missing dependency: {exc}. Install with:\n"
        f"  pip install -r notebooks/training/requirements.txt"
    )
    sys.exit(1)


# -- Fashionpedia taxonomy -------------------------------------------------
#
# The 46-class raw Fashionpedia taxonomy is published in
# `instances_attributes_{train,val}2020.json` categories section. These
# 33 entries are what the Swift-side `ClothingCategory.fromFashionpediaClass`
# consumes; garment-part classes (sleeve, collar, etc.) get dropped.
#
# MUST stay in sync with:
#   - WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift
#     (fashionpediaLabels)
#   - WardrobeReDo/Models/Enums/ClothingCategory.swift
#     (fromFashionpediaClass)
#
# Drift here is caught by the Swift-side test
# `everyLabelEitherMapsOrIsExplicitlyExcluded`.
FASHIONPEDIA_MAIN_CLASSES: list[str] = [
    "shirt_blouse", "top_t-shirt_sweatshirt", "sweater", "cardigan",
    "jacket", "vest", "coat", "cape",
    "pants", "shorts", "skirt", "tights_stockings",
    "dress", "jumpsuit",
    "shoe", "boot", "sandal", "sock", "leg_warmer",
    "glasses", "hat", "headband", "scarf", "tie",
    "bag_wallet", "belt",
    "glove", "watch", "ring", "bracelet", "earring", "necklace",
    "umbrella",
]


# -- CVDF mirror URLs ------------------------------------------------------
#
# Official Fashionpedia download links per the dataset's GitHub README:
#   https://github.com/cvdfoundation/fashionpedia
#
# These URLs are stable — CVDF hosts datasets permanently for reproducibility.
CVDF_IMAGE_BASE = "https://s3.amazonaws.com/ifashionist-dataset/images"
CVDF_ANNOT_BASE = "https://s3.amazonaws.com/ifashionist-dataset/annotations"

SPLITS = {
    "train": {
        "images_archive": f"{CVDF_IMAGE_BASE}/train2020.zip",
        "annotations": f"{CVDF_ANNOT_BASE}/instances_attributes_train2020.json",
        "out_subdir": "train",
    },
    "val": {
        "images_archive": f"{CVDF_IMAGE_BASE}/val_test2020.zip",
        "annotations": f"{CVDF_ANNOT_BASE}/instances_attributes_val2020.json",
        "out_subdir": "valid",
    },
}


def download(url: str, dest: Path, desc: str | None = None) -> None:
    """Stream-download with a progress bar. Skips if dest already exists
    and is non-empty.
    """
    if dest.exists() and dest.stat().st_size > 0:
        print(f"  already present: {dest.name} ({dest.stat().st_size / 1e6:.1f} MB)")
        return

    dest.parent.mkdir(parents=True, exist_ok=True)
    with requests.get(url, stream=True, timeout=60) as resp:
        resp.raise_for_status()
        total = int(resp.headers.get("Content-Length", 0)) or None
        with (
            open(dest, "wb") as fh,
            tqdm(
                total=total,
                unit="B",
                unit_scale=True,
                unit_divisor=1024,
                desc=desc or dest.name,
            ) as bar,
        ):
            for chunk in resp.iter_content(chunk_size=1 << 20):
                fh.write(chunk)
                bar.update(len(chunk))


def extract_archive(archive: Path, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as z:
            members = z.namelist()
            for m in tqdm(members, desc=f"extract {archive.name}"):
                z.extract(m, out_dir)
    elif archive.suffix in {".tar", ".gz", ".tgz"}:
        with tarfile.open(archive) as t:
            t.extractall(out_dir)
    else:
        raise ValueError(f"unknown archive format: {archive}")


def _resolve_allowed_category_ids(
    annotation_json: dict[str, Any],
) -> dict[int, int]:
    """Return {old_category_id: new_contiguous_id} for the classes we ship.

    rfdetr expects contiguous category IDs starting at 1 (0 = background).
    We map each retained Fashionpedia category to its position in
    FASHIONPEDIA_MAIN_CLASSES, +1.
    """
    name_to_new_id = {name: i + 1 for i, name in enumerate(FASHIONPEDIA_MAIN_CLASSES)}
    old_to_new: dict[int, int] = {}
    for cat in annotation_json["categories"]:
        name = cat["name"]
        if name in name_to_new_id:
            old_to_new[cat["id"]] = name_to_new_id[name]
    expected = set(FASHIONPEDIA_MAIN_CLASSES)
    found = {
        cat["name"]
        for cat in annotation_json["categories"]
        if cat["name"] in expected
    }
    missing = expected - found
    if missing:
        print(
            f"  WARNING: these classes aren't in the CVDF taxonomy: {sorted(missing)}.\n"
            f"  Downstream class mapping in the Swift enum may need fixes."
        )
    return old_to_new


def _build_filtered_coco(
    raw: dict[str, Any],
    old_to_new: dict[int, int],
    image_id_whitelist: set[int] | None = None,
) -> dict[str, Any]:
    """Emit a COCO JSON filtered to (a) our 33 main classes, (b) any
    image that still has at least one surviving annotation, and (c) an
    optional image-ID whitelist (for subsetting during smoke tests).
    """
    new_categories = [
        {"id": i + 1, "name": name, "supercategory": "fashionpedia"}
        for i, name in enumerate(FASHIONPEDIA_MAIN_CLASSES)
    ]

    kept_ann: list[dict[str, Any]] = []
    surviving_image_ids: set[int] = set()
    for ann in raw["annotations"]:
        if ann["category_id"] not in old_to_new:
            continue
        if image_id_whitelist is not None and ann["image_id"] not in image_id_whitelist:
            continue
        kept_ann.append(
            {
                "id": ann["id"],
                "image_id": ann["image_id"],
                "category_id": old_to_new[ann["category_id"]],
                "bbox": ann["bbox"],
                "area": ann["area"],
                "iscrowd": ann.get("iscrowd", 0),
                # segmentation may be polygon list or RLE dict — pass through.
                "segmentation": ann.get("segmentation", []),
            }
        )
        surviving_image_ids.add(ann["image_id"])

    kept_img = [
        {
            "id": img["id"],
            "file_name": img["file_name"],
            "width": img["width"],
            "height": img["height"],
            # strip license / flickr_url / date_captured — rfdetr doesn't use them
            # and they bloat the JSON by 2-3x.
        }
        for img in raw["images"]
        if img["id"] in surviving_image_ids
    ]

    return {
        "info": raw.get("info", {"description": "Fashionpedia filtered"}),
        "licenses": raw.get("licenses", []),
        "categories": new_categories,
        "images": kept_img,
        "annotations": kept_ann,
    }


def prepare_split(
    split: str,
    work_dir: Path,
    out_dir: Path,
    max_images: int | None,
) -> None:
    cfg = SPLITS[split]
    split_out = out_dir / cfg["out_subdir"]
    split_out.mkdir(parents=True, exist_ok=True)
    ann_out = split_out / "_annotations.coco.json"

    archive_cache = work_dir / Path(cfg["images_archive"]).name
    annot_cache = work_dir / Path(cfg["annotations"]).name

    # 1. Download raw archive + annotations.
    print(f"\n[{split}] download")
    download(cfg["images_archive"], archive_cache)
    download(cfg["annotations"], annot_cache)

    # 2. Load raw annotations, filter to our classes.
    print(f"[{split}] filter annotations")
    with open(annot_cache) as fh:
        raw = json.load(fh)
    old_to_new = _resolve_allowed_category_ids(raw)

    # 3. Pick the image-ID whitelist if this is a subset run.
    whitelist: set[int] | None = None
    if max_images is not None:
        # Deterministically take the first `max_images` images that
        # still have ≥1 surviving annotation.
        surviving = {
            ann["image_id"]
            for ann in raw["annotations"]
            if ann["category_id"] in old_to_new
        }
        ordered = [img["id"] for img in raw["images"] if img["id"] in surviving]
        whitelist = set(ordered[:max_images])
        print(f"[{split}] subset to {len(whitelist)} images (of {len(surviving)} available)")

    # 4. Build + write the filtered COCO JSON.
    filtered = _build_filtered_coco(raw, old_to_new, whitelist)
    print(
        f"[{split}] kept "
        f"{len(filtered['images']):,} images / "
        f"{len(filtered['annotations']):,} annotations / "
        f"{len(filtered['categories'])} classes"
    )
    with open(ann_out, "w") as fh:
        json.dump(filtered, fh)

    # 5. Extract only the images we need (sparse extract — faster than
    #    unzipping the whole 11 GB archive, especially for subset runs).
    needed_files = {img["file_name"] for img in filtered["images"]}
    print(f"[{split}] sparse-extract {len(needed_files):,} images")
    extracted = 0
    skipped = 0
    with zipfile.ZipFile(archive_cache) as z:
        for member in z.namelist():
            # CVDF zips use a top-level dir (train2020/ or val_test2020/).
            # strip it so output is split_out/foo.jpg not split_out/train2020/foo.jpg.
            name = Path(member).name
            if not name or name not in needed_files:
                continue
            dest = split_out / name
            if dest.exists() and dest.stat().st_size > 0:
                skipped += 1
                continue
            with z.open(member) as src, open(dest, "wb") as dst:
                shutil.copyfileobj(src, dst)
            extracted += 1
    print(
        f"[{split}] extracted {extracted:,} new images "
        f"({skipped:,} already present); total {extracted + skipped:,}/{len(needed_files):,}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("./data/fashionpedia"),
        help="Output directory for the COCO-layout dataset (default: ./data/fashionpedia)",
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=Path("./data/fashionpedia/_raw"),
        help="Cache directory for downloaded archives + annotation JSONs "
        "(default: ./data/fashionpedia/_raw)",
    )
    parser.add_argument(
        "--max-train",
        type=int,
        default=None,
        help="Cap training-split image count (for smoke tests)",
    )
    parser.add_argument(
        "--max-val",
        type=int,
        default=None,
        help="Cap val-split image count (for smoke tests)",
    )
    parser.add_argument(
        "--splits",
        nargs="+",
        choices=list(SPLITS.keys()),
        default=list(SPLITS.keys()),
        help="Which splits to prepare (default: all)",
    )
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    args.work_dir.mkdir(parents=True, exist_ok=True)

    for split in args.splits:
        cap = args.max_train if split == "train" else args.max_val
        prepare_split(split, args.work_dir, args.out, cap)

    print(f"\nDone. Dataset ready at {args.out.resolve()}")
    print(f"Structure:")
    for child in sorted(args.out.iterdir()):
        if child.is_dir() and not child.name.startswith("_"):
            entries = sum(1 for _ in child.iterdir())
            print(f"  {child.name}/  ({entries:,} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
