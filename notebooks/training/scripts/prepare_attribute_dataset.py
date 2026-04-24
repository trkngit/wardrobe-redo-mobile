"""Phase 2 dataset preparer — Fashionpedia → fit-attribute training crops.

Under Option C of the auto-attribute-detection plan, this script
produces the training corpus for a single-head MobileNetV3-Small fit
classifier (5 classes: oversized, relaxed, regular, slim, cropped).
Texture classification is deferred to v1.1; this preparer does NOT emit
texture labels.

Output layout:

    <out_dir>/
        train/
            <annotation_id>.jpg            # 224x224 square-padded crops
            …
        val/
            …
        manifest.csv                       # one row per kept crop
        manifest_meta.json                 # class counts + filter stats

manifest.csv columns:
    split            — "train" | "val"
    image_path       — path relative to <out_dir> (portable; P2-7)
    annotation_id    — Fashionpedia annotation id (for traceability)
    image_id         — Fashionpedia source image id
    main_class       — normalized Fashionpedia category name
    fit_label_name   — iOS FitAttribute.rawValue
    fit_label_idx    — integer index into TRAINABLE_FIT_LABELS
    bbox_w / bbox_h  — source bbox dims in pixels (pre-padding)

manifest_meta.json carries the class-imbalance stats Phase 3 needs
(P2-3): total crops per label so `train_attributes.py` can apply
inverse-frequency class weights without a second scan.

Filter pipeline (P2-1 … P2-7 from BLOCKERS.md):
  1. Annotation must have a resolvable fit label via
     `resolve_fit_label` — drops ambiguous multi-fit samples and
     non-top-like categories tagged with attr 146 (cropped).
  2. BBox clamped to image bounds.
  3. Drop if `bbox_area / image_area < 0.02` (micro-annotations).
  4. Drop if `bbox_aspect > 4.0` or `< 0.25` (extreme strips).
  5. Pad bbox to square using neutral gray (128,128,128), then resize
     to 224×224.
  6. Emit one row per surviving annotation.

Idempotent: re-runs skip already-emitted crop files. Safe to Ctrl-C +
resume — the manifest is rebuilt from scratch but the crops aren't
re-encoded.

Usage:
    # Full training set — expects `prepare_fashionpedia.py` has already
    # downloaded the annotation JSONs + image zips into the default
    # cache (`./data/fashionpedia/_raw`).
    python prepare_attribute_dataset.py --out ./data/attr-dataset

    # Smoke test subset (fast iteration on laptop):
    python prepare_attribute_dataset.py \\
        --out ./data/attr-dataset \\
        --max-train 500 --max-val 100

    # Override the annotation / image cache location:
    python prepare_attribute_dataset.py \\
        --out ./data/attr-dataset \\
        --annotations-dir /workspace/fashionpedia/_raw \\
        --images-dir /workspace/fashionpedia/_raw

See docs/plans/2026-04-19-auto-attribute-detection.md Phase 2 +
docs/plans/2026-04-19-auto-attribute-detection/BLOCKERS.md.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
import zipfile
from collections import Counter
from io import BytesIO
from pathlib import Path
from typing import Any, Iterable

try:
    from PIL import Image
    from tqdm import tqdm
except ImportError as exc:
    print(
        f"Missing dependency: {exc}. Install with:\n"
        f"  pip install -r notebooks/training/requirements.txt"
    )
    sys.exit(1)

# Local-module import. This script lives in notebooks/training/scripts/
# alongside the lookup module; running via `python path/to/script.py`
# works because Python adds the script's dir to sys.path.
from fashionpedia_attr_to_ios_enum import (
    TRAINABLE_FIT_LABELS,
    fit_label_to_index,
    normalize_class_name,
    resolve_fit_label,
)


# -- Constants -----------------------------------------------------------

CROP_SIZE = 224  # MobileNetV3 input size.
NEUTRAL_PAD = (128, 128, 128)  # Mid-gray for square padding.
MIN_AREA_FRACTION = 0.02  # Drop bboxes smaller than 2% of image area.
MAX_ASPECT_RATIO = 4.0  # Drop very tall or very wide bboxes.

DEFAULT_ANNOT_CACHE = Path("./data/fashionpedia/_raw")
DEFAULT_IMAGES_CACHE = Path("./data/fashionpedia/_raw")

# Archive filenames `prepare_fashionpedia.py` leaves in the cache.
TRAIN_ANNOT_NAME = "instances_attributes_train2020.json"
VAL_ANNOT_NAME = "instances_attributes_val2020.json"
TRAIN_IMAGES_ARCHIVE = "train2020.zip"
VAL_IMAGES_ARCHIVE = "val_test2020.zip"


# -- Argparse ------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--out",
        type=Path,
        default=Path("./data/attr-dataset"),
        help="Output root for the attribute dataset (default: ./data/attr-dataset)",
    )
    p.add_argument(
        "--annotations-dir",
        type=Path,
        default=DEFAULT_ANNOT_CACHE,
        help="Dir holding the Fashionpedia annotation JSONs (default: ./data/fashionpedia/_raw)",
    )
    p.add_argument(
        "--images-dir",
        type=Path,
        default=DEFAULT_IMAGES_CACHE,
        help="Dir holding the Fashionpedia image zips (default: ./data/fashionpedia/_raw)",
    )
    p.add_argument(
        "--max-train",
        type=int,
        default=None,
        help="Cap kept train-split crops (for smoke tests)",
    )
    p.add_argument(
        "--max-val",
        type=int,
        default=None,
        help="Cap kept val-split crops (for smoke tests)",
    )
    p.add_argument(
        "--splits",
        nargs="+",
        choices=["train", "val"],
        default=["train", "val"],
        help="Which splits to process (default: both)",
    )
    return p.parse_args()


# -- BBox geometry helpers ----------------------------------------------


def _clamp_bbox(
    bbox: tuple[float, float, float, float],
    image_w: int,
    image_h: int,
) -> tuple[int, int, int, int] | None:
    """Clamp a COCO-format `[x, y, w, h]` bbox to image bounds. Returns
    integer `(x0, y0, x1, y1)` in pixel coords, or None if clamping
    collapses the bbox to zero area."""
    x, y, w, h = bbox
    x0 = max(0, int(round(x)))
    y0 = max(0, int(round(y)))
    x1 = min(image_w, int(round(x + w)))
    y1 = min(image_h, int(round(y + h)))
    if x1 - x0 <= 1 or y1 - y0 <= 1:
        return None
    return x0, y0, x1, y1


def _bbox_passes_filters(
    box: tuple[int, int, int, int],
    image_w: int,
    image_h: int,
) -> bool:
    """Apply P2-5 filters — area fraction + aspect ratio."""
    x0, y0, x1, y1 = box
    bw = x1 - x0
    bh = y1 - y0
    image_area = image_w * image_h
    if image_area <= 0:
        return False
    area_frac = (bw * bh) / image_area
    if area_frac < MIN_AREA_FRACTION:
        return False
    aspect = bw / bh
    if aspect > MAX_ASPECT_RATIO or aspect < 1.0 / MAX_ASPECT_RATIO:
        return False
    return True


def _square_pad_and_resize(
    crop: Image.Image,
    size: int = CROP_SIZE,
    pad_color: tuple[int, int, int] = NEUTRAL_PAD,
) -> Image.Image:
    """Pad a rectangular crop to a square with `pad_color`, then resize
    to `size × size`. Preserves aspect ratio (no squashing) — the model
    sees a centered garment on a neutral gray field."""
    w, h = crop.size
    side = max(w, h)
    canvas = Image.new("RGB", (side, side), pad_color)
    canvas.paste(crop, ((side - w) // 2, (side - h) // 2))
    return canvas.resize((size, size), Image.Resampling.BILINEAR)


# -- Annotation loading --------------------------------------------------


def _load_annotations(path: Path) -> dict[str, Any]:
    if not path.exists():
        sys.exit(f"error: annotation file not found: {path}")
    print(f"  loading {path.name} ({path.stat().st_size / 1e6:.1f} MB)…")
    with open(path) as fh:
        return json.load(fh)


# -- Per-annotation processing ------------------------------------------


def _resolve_label(
    ann: dict[str, Any],
    cat_by_id: dict[int, str],
) -> tuple[str, str] | None:
    """Run the taxonomy filter. Returns `(main_class, fit_label)` or
    None when the annotation has no usable fit signal."""
    cat_id = ann.get("category_id")
    if cat_id is None or cat_id not in cat_by_id:
        return None
    main_class = normalize_class_name(cat_by_id[cat_id])
    attr_ids = ann.get("attribute_ids") or []
    fit_label = resolve_fit_label(attr_ids, main_class)
    if fit_label is None:
        return None
    return main_class, fit_label


def _crop_and_write(
    image: Image.Image,
    bbox_xyxy: tuple[int, int, int, int],
    out_path: Path,
) -> None:
    """Crop → square-pad → resize → write JPEG. Idempotent: skips if
    the output already exists at non-zero size."""
    if out_path.exists() and out_path.stat().st_size > 0:
        return
    out_path.parent.mkdir(parents=True, exist_ok=True)
    crop = image.crop(bbox_xyxy)
    squared = _square_pad_and_resize(crop)
    if squared.mode != "RGB":
        squared = squared.convert("RGB")
    squared.save(out_path, format="JPEG", quality=90)


# -- Split processing ----------------------------------------------------


def _iter_image_members(
    zip_path: Path,
    needed: set[str],
) -> Iterable[tuple[str, bytes]]:
    """Yield `(basename, bytes)` for image entries whose basename is in
    `needed`. Uses a single pass over the zip index — faster than
    opening by name for each annotation, especially for large subsets."""
    with zipfile.ZipFile(zip_path) as z:
        for member in z.namelist():
            name = Path(member).name
            if name not in needed:
                continue
            with z.open(member) as src:
                yield name, src.read()


def _build_needed_index(
    raw: dict[str, Any],
    split_rows: list[dict[str, Any]],
) -> tuple[dict[int, dict[str, Any]], set[str]]:
    """Pre-compute image-id → image-meta and the set of image basenames
    we'll need to read from the archive. Only images that back at least
    one kept annotation are loaded."""
    image_by_id = {img["id"]: img for img in raw["images"]}
    needed_ids = {r["image_id"] for r in split_rows}
    needed_names = {image_by_id[i]["file_name"] for i in needed_ids}
    return image_by_id, needed_names


def process_split(
    split: str,
    annot_path: Path,
    archive_path: Path,
    out_dir: Path,
    max_crops: int | None,
) -> tuple[list[dict[str, Any]], Counter]:
    """Process one split. Returns the manifest rows + per-label counter."""
    print(f"\n[{split}] resolving labels")
    raw = _load_annotations(annot_path)
    cat_by_id = {c["id"]: c["name"] for c in raw["categories"]}

    # Pass 1: filter annotations + resolve labels. This is pure-CPU and
    # avoids touching any image file — fast way to decide which images
    # we even need to read.
    planned: list[dict[str, Any]] = []
    filter_stats: Counter = Counter()
    for ann in raw["annotations"]:
        filter_stats["total"] += 1
        resolved = _resolve_label(ann, cat_by_id)
        if resolved is None:
            filter_stats["no_fit_label"] += 1
            continue
        main_class, fit_label = resolved
        planned.append(
            {
                "annotation_id": ann["id"],
                "image_id": ann["image_id"],
                "main_class": main_class,
                "fit_label_name": fit_label,
                "fit_label_idx": fit_label_to_index(fit_label),
                "bbox": ann["bbox"],  # defer clamping/filtering to pass 2
            }
        )
    print(
        f"[{split}] label-resolved {len(planned):,} annotations "
        f"(dropped {filter_stats['no_fit_label']:,} without fit signal)"
    )

    if max_crops is not None and len(planned) > max_crops:
        print(f"[{split}] capping to --max-{split} {max_crops:,}")
        planned = planned[:max_crops]

    # Pass 2: load each needed image once, process every annotation that
    # references it. This is the expensive phase — we try to minimize
    # zip reads.
    image_by_id, needed_names = _build_needed_index(raw, planned)
    rows_by_image: dict[int, list[dict[str, Any]]] = {}
    for row in planned:
        rows_by_image.setdefault(row["image_id"], []).append(row)

    print(f"[{split}] reading {len(needed_names):,} source images from {archive_path.name}")
    kept_rows: list[dict[str, Any]] = []
    label_counter: Counter = Counter()

    split_out = out_dir / split
    split_out.mkdir(parents=True, exist_ok=True)

    filename_to_image_id: dict[str, int] = {
        image_by_id[r["image_id"]]["file_name"]: r["image_id"]
        for r in planned
    }

    with tqdm(total=len(needed_names), desc=f"{split} crops", unit="img") as bar:
        for basename, payload in _iter_image_members(archive_path, needed_names):
            bar.update(1)
            try:
                image = Image.open(BytesIO(payload))
                image.load()
                if image.mode != "RGB":
                    image = image.convert("RGB")
            except Exception as exc:
                filter_stats["image_decode_error"] += 1
                print(f"  warn: could not decode {basename}: {exc}")
                continue

            image_id = filename_to_image_id.get(basename)
            if image_id is None:
                continue
            image_w, image_h = image.size

            for row in rows_by_image.get(image_id, []):
                clamped = _clamp_bbox(row["bbox"], image_w, image_h)
                if clamped is None:
                    filter_stats["bbox_clamp_collapsed"] += 1
                    continue
                if not _bbox_passes_filters(clamped, image_w, image_h):
                    filter_stats["bbox_filter_rejected"] += 1
                    continue
                x0, y0, x1, y1 = clamped
                bbox_w = x1 - x0
                bbox_h = y1 - y0

                crop_filename = f"{row['annotation_id']}.jpg"
                out_path = split_out / crop_filename
                try:
                    _crop_and_write(image, clamped, out_path)
                except Exception as exc:
                    filter_stats["crop_write_error"] += 1
                    print(f"  warn: could not write crop for ann {row['annotation_id']}: {exc}")
                    continue

                # manifest row — path is stored relative to out_dir.
                relative_path = f"{split}/{crop_filename}"
                kept_rows.append(
                    {
                        "split": split,
                        "image_path": relative_path,
                        "annotation_id": row["annotation_id"],
                        "image_id": row["image_id"],
                        "main_class": row["main_class"],
                        "fit_label_name": row["fit_label_name"],
                        "fit_label_idx": row["fit_label_idx"],
                        "bbox_w": bbox_w,
                        "bbox_h": bbox_h,
                    }
                )
                label_counter[row["fit_label_name"]] += 1

    print(
        f"[{split}] kept {len(kept_rows):,} crops "
        f"(dropped {filter_stats['bbox_clamp_collapsed']:,} clamp + "
        f"{filter_stats['bbox_filter_rejected']:,} filter + "
        f"{filter_stats['image_decode_error']:,} decode + "
        f"{filter_stats['crop_write_error']:,} write)"
    )
    print(f"[{split}] label distribution: {dict(label_counter.most_common())}")
    return kept_rows, label_counter


# -- Manifest emission ---------------------------------------------------


def write_manifest(
    rows: list[dict[str, Any]],
    out_dir: Path,
    label_counters: dict[str, Counter],
) -> None:
    manifest_path = out_dir / "manifest.csv"
    meta_path = out_dir / "manifest_meta.json"

    fieldnames = [
        "split",
        "image_path",
        "annotation_id",
        "image_id",
        "main_class",
        "fit_label_name",
        "fit_label_idx",
        "bbox_w",
        "bbox_h",
    ]
    with open(manifest_path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    total = len(rows)
    meta = {
        "scope": "Option C (fit-only, single-head)",
        "labels": TRAINABLE_FIT_LABELS,
        "total_crops": total,
        "class_counts_by_split": {
            split: dict(counter.most_common())
            for split, counter in label_counters.items()
        },
        "class_counts_total": dict(
            sum(label_counters.values(), Counter()).most_common()
        ),
        "filter_constants": {
            "crop_size": CROP_SIZE,
            "min_area_fraction": MIN_AREA_FRACTION,
            "max_aspect_ratio": MAX_ASPECT_RATIO,
            "pad_color": list(NEUTRAL_PAD),
        },
    }
    with open(meta_path, "w") as fh:
        json.dump(meta, fh, indent=2)

    print(f"\nwrote {total:,} manifest rows → {manifest_path}")
    print(f"wrote label metadata          → {meta_path}")


# -- Entrypoint ----------------------------------------------------------


def main() -> int:
    args = parse_args()
    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    annot_by_split = {
        "train": args.annotations_dir / TRAIN_ANNOT_NAME,
        "val": args.annotations_dir / VAL_ANNOT_NAME,
    }
    archive_by_split = {
        "train": args.images_dir / TRAIN_IMAGES_ARCHIVE,
        "val": args.images_dir / VAL_IMAGES_ARCHIVE,
    }

    all_rows: list[dict[str, Any]] = []
    counters_by_split: dict[str, Counter] = {}
    for split in args.splits:
        cap = args.max_train if split == "train" else args.max_val
        annot_path = annot_by_split[split]
        archive_path = archive_by_split[split]
        if not annot_path.exists():
            sys.exit(
                f"error: {annot_path} not found. Run "
                f"`prepare_fashionpedia.py` first to download "
                f"Fashionpedia annotations + images."
            )
        if not archive_path.exists():
            sys.exit(
                f"error: {archive_path} not found. Run "
                f"`prepare_fashionpedia.py` first to download "
                f"Fashionpedia images."
            )
        rows, counter = process_split(
            split=split,
            annot_path=annot_path,
            archive_path=archive_path,
            out_dir=out_dir,
            max_crops=cap,
        )
        all_rows.extend(rows)
        counters_by_split[split] = counter

    write_manifest(all_rows, out_dir, counters_by_split)
    print(f"\nDone. Dataset ready at {out_dir.resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
