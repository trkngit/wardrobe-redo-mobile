#!/usr/bin/env python3
"""Fetch the 30-image Phase 4 fixture set from CC-BY 4.0 public datasets.

Replaces the owner-captured fixture flow (30 manual photos + 2 hours of hand
tracing) with a one-shot downloader + curator. Pulls two Roboflow Universe
projects, both explicitly licensed CC-BY 4.0:

  * StreetVision "Clothing" — 2,889 images across 18 clothing classes with
    instance masks (bag, dress, glasses, hat, mask, shirt, and more). Used
    for `clean_bg_*` and `cluttered_*` scenarios; bucketed by background
    edge density.
  * Roboflow "Fashion Assistant Segmentation" — 239 worn-on-person
    examples with instance masks across 10 clothing classes. Used for
    `on_person_*`.

Both arrive as COCO-format annotations (polygon segments). For each image we
rasterise the union of its clothing polygons into an alpha PNG, then pick
ten from each of three scenario buckets — clean background, cluttered
background, worn on a person — and commit them as the reproducible IoU
fixture set. Attribution obligations are met by emitting
`ATTRIBUTIONS.md` alongside the fixtures; that file ships only inside the
XCTest bundle, so no App Store binary impact.

DeepFashion2 (research-only) is a separate concern and stays on
`~/wardrobe-benchmark/` — see scripts/build_benchmark.py.

-------------------------------------------------------------------------

USAGE

    python3 -m venv .venv && source .venv/bin/activate
    pip install roboflow pillow numpy

    # Path A — programmatic download via Roboflow free-tier API
    export ROBOFLOW_API_KEY=<your key>
    python3 scripts/fetch_fixtures.py --dry-run   # preview curation
    python3 scripts/fetch_fixtures.py             # write the 30 fixtures

    # Path B — airgapped / no Roboflow account. Download each dataset
    # manually from the linked Roboflow project URL, then:
    export ROBOFLOW_ZIP_STREETVISION=/path/to/streetvision-clothing.zip
    export ROBOFLOW_ZIP_FASHION_ASSISTANT=/path/to/fashion-assistant-segmentation.zip
    python3 scripts/fetch_fixtures.py

The script is idempotent: re-running it overwrites the same 30 files with
the same content (datasets are deterministic, curation is seeded).

-------------------------------------------------------------------------

OUTPUT LAYOUT

    WardrobeReDoTests/Fixtures/Extraction/
      clean_bg_01.jpg .. clean_bg_10.jpg
      cluttered_01.jpg .. cluttered_10.jpg
      on_person_01.jpg .. on_person_10.jpg
      ground_truth/
        clean_bg_01.png .. on_person_10.png
      ATTRIBUTIONS.md   (regenerated every run)
      manifest.json     (regenerated; _comment preserved)

See scripts/fetch_fixtures.README.md for troubleshooting.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import io
import json
import os
import random
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

try:
    import numpy as np
    from PIL import Image, ImageDraw
except ImportError as exc:  # pragma: no cover — instructional
    sys.stderr.write(
        "Missing dependency: "
        f"{exc.name}. Install with: pip install pillow numpy roboflow\n"
    )
    sys.exit(2)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURES_DIR = REPO_ROOT / "WardrobeReDoTests" / "Fixtures" / "Extraction"
MASKS_DIR = FIXTURES_DIR / "ground_truth"
MANIFEST_PATH = FIXTURES_DIR / "manifest.json"
ATTRIBUTIONS_PATH = FIXTURES_DIR / "ATTRIBUTIONS.md"

MAX_LONG_EDGE = 3000  # px — soft limit for committed JPEGs
PER_BUCKET_COUNT = 10
BUCKETS = ("clean_bg", "cluttered", "on_person")
RANDOM_SEED = "wardrobe-redo-phase4-fixtures"


@dataclass(frozen=True)
class DatasetSpec:
    """Metadata for one Roboflow Universe project we ingest."""

    key: str                  # internal identifier used in env vars
    workspace: str            # Roboflow workspace slug
    project: str              # Roboflow project slug
    version: int              # Roboflow export version
    license_spdx: str         # SPDX tag for the ATTRIBUTIONS.md emitter
    license_human: str        # Human-readable licence name
    source_url: str           # Linkable project URL for attribution
    uploader: str             # Attribution uploader name
    intent: str               # "studio" (StreetVision) or "on_person"
    env_zip_var: str          # Override env var for ZIP path


DATASETS: dict[str, DatasetSpec] = {
    # Primary studio / cluttered pool. 1,331 CC-BY 4.0 images across 18
    # clothing classes (bag, dress, glasses, hat, mask, shirt, and more).
    # Replaces the originally-planned `yanelys/clothing-segmentation`,
    # which exists on Universe but has no downloadable version.
    "STREETVISION": DatasetSpec(
        key="STREETVISION",
        workspace="streetvision",
        project="clothing-8kbxo",
        version=2,
        license_spdx="CC-BY-4.0",
        license_human="Creative Commons Attribution 4.0 International",
        source_url="https://universe.roboflow.com/streetvision/clothing-8kbxo",
        uploader="StreetVision (Roboflow Universe)",
        intent="studio",
        env_zip_var="ROBOFLOW_ZIP_STREETVISION",
    ),
    # On-person pool. 239 CC-BY 4.0 images across 10 worn-clothing classes
    # (jacket, shirt, hoodie, pants, shorts, sneaker, baseball cap, sunglasses,
    # and more). Curated by Roboflow themselves, so the COCO-Segmentation
    # export is reliably downloadable. Replaces the originally-planned
    # `clothing-detection/clothing-detection-test`, whose v1 export is broken.
    "FASHION_ASSISTANT": DatasetSpec(
        key="FASHION_ASSISTANT",
        workspace="roboflow-jvuqo",
        project="fashion-assistant-segmentation",
        version=5,
        license_spdx="CC-BY-4.0",
        license_human="Creative Commons Attribution 4.0 International",
        source_url="https://universe.roboflow.com/roboflow-jvuqo/fashion-assistant-segmentation",
        uploader="Roboflow Fashion Assistant (Roboflow Universe)",
        intent="on_person",
        env_zip_var="ROBOFLOW_ZIP_FASHION_ASSISTANT",
    ),
}


# Map Roboflow category names onto our internal ClothingCategory values.
# The scoring rig only needs "at least twice per category across the 30"
# — exact category labels are noted in manifest.json for downstream tools.
# Unrecognised labels map to "other" so no image is silently dropped.
CATEGORY_MAP: dict[str, str] = {
    "shirt": "top",
    "t-shirt": "top",
    "tshirt": "top",
    "tee": "top",
    "top": "top",
    "blouse": "top",
    "sweater": "top",
    "hoodie": "top",
    "sweatshirt": "top",
    "long_sleeve": "top",
    "short_sleeve": "top",
    "long_sleeve_top": "top",
    "short_sleeve_top": "top",
    "pants": "bottom",
    "trousers": "bottom",
    "jeans": "bottom",
    "shorts": "bottom",
    "skirt": "bottom",
    "short_pants": "bottom",
    "long_pants": "bottom",
    "dress": "dress",
    "gown": "dress",
    "jumpsuit": "dress",
    "long_sleeve_dress": "dress",
    "short_sleeve_dress": "dress",
    "vest_dress": "dress",
    "sling_dress": "dress",
    "shoe": "shoes",
    "shoes": "shoes",
    "sneaker": "shoes",
    "boot": "shoes",
    "heel": "shoes",
    "sandal": "shoes",
    "jacket": "outerwear",
    "coat": "outerwear",
    "blazer": "outerwear",
    "cardigan": "outerwear",
    "vest": "outerwear",
    "bag": "accessory",
    "hat": "accessory",
    "cap": "accessory",
    "baseball_cap": "accessory",
    "scarf": "accessory",
    "belt": "accessory",
    "glasses": "accessory",
    "sunglasses": "accessory",
    "mask": "accessory",        # face mask, present in StreetVision
    "tie": "accessory",
}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Fetch and curate Phase 4 extraction fixtures.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Download + bucket but do not write fixtures; just print stats.",
    )
    p.add_argument(
        "--skip-ids",
        default="",
        help=(
            "Comma-separated list of dataset-qualified image IDs to exclude "
            "(e.g. STREETVISION:img_0123,STREETVISION:img_0456). Use after manual "
            "spot-check finds bad traces or sensitive content."
        ),
    )
    p.add_argument(
        "--work-dir",
        default=None,
        help=(
            "Cache directory for downloaded ZIPs / extracted annotations. "
            "Defaults to a tempdir that is cleaned on exit."
        ),
    )
    return p.parse_args()


# ---------------------------------------------------------------------------
# Dataset acquisition
# ---------------------------------------------------------------------------


def acquire_dataset(spec: DatasetSpec, work_dir: Path) -> Path:
    """Return a path to a directory containing this dataset's COCO splits.

    Tries the ZIP env var first (preferred — works offline, reproducible),
    then falls back to the Roboflow API when a key is available.
    """
    target = work_dir / spec.key
    if target.is_dir() and any(target.rglob("_annotations.coco.json")):
        return target

    zip_env = os.environ.get(spec.env_zip_var)
    if zip_env:
        zip_path = Path(zip_env).expanduser()
        if not zip_path.is_file():
            sys.stderr.write(
                f"{spec.env_zip_var} points to a missing file: {zip_path}\n"
            )
            sys.exit(1)
        print(f"• [{spec.key}] extracting ZIP {zip_path}")
        target.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(target)
        return target

    api_key = os.environ.get("ROBOFLOW_API_KEY")
    if not api_key:
        sys.stderr.write(
            f"No {spec.env_zip_var} set and ROBOFLOW_API_KEY is empty.\n"
            f"Either pre-download the ZIP from {spec.source_url} and set\n"
            f"{spec.env_zip_var}=/path/to/it.zip, or set ROBOFLOW_API_KEY\n"
            f"to a Roboflow free-tier key.\n"
        )
        sys.exit(1)

    try:
        from roboflow import Roboflow  # type: ignore
    except ImportError:
        sys.stderr.write(
            "roboflow package not installed. pip install roboflow — or pre-"
            f"download the ZIP and set {spec.env_zip_var}.\n"
        )
        sys.exit(2)

    print(f"• [{spec.key}] downloading via Roboflow API ({spec.source_url})")
    rf = Roboflow(api_key=api_key)
    project = rf.workspace(spec.workspace).project(spec.project)
    version = project.version(spec.version)
    target.mkdir(parents=True, exist_ok=True)
    # Roboflow's SDK writes into cwd by default; chdir for the duration.
    prev = Path.cwd()
    try:
        os.chdir(target)
        version.download("coco-segmentation")
    finally:
        os.chdir(prev)
    return target


# ---------------------------------------------------------------------------
# COCO parsing
# ---------------------------------------------------------------------------


@dataclass
class CocoImage:
    """Minimal record of one image + all its clothing polygons."""

    dataset_key: str
    source_image_id: str       # stable identifier for skip lists
    image_path: Path
    polygons: list[list[float]]  # flat [x, y, x, y, ...] lists
    categories: list[str]        # raw Roboflow category names
    intent: str                  # mirrors DatasetSpec.intent


# Filename prefix patterns we drop at parse time.
#
# `yt-` — Roboflow uploaders include per-second screengrabs from YouTube
# videos. The grabs from a single video share framing and often contain
# burnt-in text overlays, thumbnails, etc. — a single-source bias that's
# bad for IoU-regression diversity, independent of any licence story.
#
# `maxresdefault` — `maxresdefault.jpg` is YouTube's default high-res
# thumbnail filename. Anything with that stem is a YouTube thumbnail, which
# in this dataset consistently comes loaded with burnt-in network logos and
# title text (Sky News, "THE HISTORY OF…", etc.). Same single-source-bias
# + text-overlay quality problem as `yt-*`.
FILENAME_STEM_SKIP_PREFIXES: tuple[str, ...] = ("yt-", "maxresdefault")
FILENAME_STEM_SKIP_EXACT: frozenset[str] = frozenset({
    # Product-catalogue montage: rasterises to many disjoint mask regions
    # rather than a single-item extraction test.
    "Drill-Header_MASKS_jpg",
    # News / editorial composites — bystander faces, not a single garment.
    "79118685-0-image-a-20_1702975471223_jpg",
    "images6_jpg",
    "images31_jpg",
    "images42_jpg",
    "images47_jpg",
    "images51_jpg",
    "images64_jpg",
    "hijack-swordvauxhall-london-1989-copy-e1698857091949_jpg",
    # Album-art / music-promo overlays with bystander faces.
    "0_JS249742059-1_jpg",
    "images32_jpg",
    # Product / editorial screengrabs with burnt-in advertising text overlays.
    "image13_jpeg",
    "images36_jpg",
    "0027874721_10_jpg",
    # Amazon product-grid montage (multiple items in a single frame).
    "81AIWMgs0L-_AC_UY1000__jpg",
})


def _should_skip_filename(stem: str) -> bool:
    if any(stem.startswith(prefix) for prefix in FILENAME_STEM_SKIP_PREFIXES):
        return True
    # The Roboflow export appends `.rf.<hash>` to augmented copies, so
    # exact-stem matching needs to compare against the pre-augmentation base.
    base = augmentation_base_id(stem)
    return base in FILENAME_STEM_SKIP_EXACT


def parse_coco_split(annotations_json: Path, dataset_key: str, intent: str) -> list[CocoImage]:
    """Parse a single Roboflow COCO JSON file into CocoImage records."""
    with annotations_json.open("r", encoding="utf-8") as f:
        coco = json.load(f)

    images_by_id = {img["id"]: img for img in coco.get("images", [])}
    categories_by_id = {c["id"]: c["name"] for c in coco.get("categories", [])}

    # Group annotations by image_id.
    grouped: dict[int, list[dict]] = {}
    for ann in coco.get("annotations", []):
        grouped.setdefault(ann["image_id"], []).append(ann)

    split_dir = annotations_json.parent
    out: list[CocoImage] = []
    for image_id, annotations in grouped.items():
        img_meta = images_by_id.get(image_id)
        if not img_meta:
            continue
        file_name = img_meta["file_name"]
        image_path = split_dir / file_name
        if not image_path.is_file():
            continue

        stem = Path(file_name).stem
        if _should_skip_filename(stem):
            continue

        polygons: list[list[float]] = []
        categories: list[str] = []
        for ann in annotations:
            seg = ann.get("segmentation")
            if not isinstance(seg, list):  # RLE masks skipped
                continue
            # COCO polygon lists may be nested one level (list of polygons
            # for multi-part segments). Flatten by keeping each sub-polygon
            # separately so concave holes still rasterise correctly.
            for poly in seg:
                if isinstance(poly, list) and len(poly) >= 6:
                    polygons.append(poly)
            cat = categories_by_id.get(ann.get("category_id"))
            if cat:
                categories.append(cat)

        if not polygons:
            continue

        out.append(CocoImage(
            dataset_key=dataset_key,
            source_image_id=stem,
            image_path=image_path,
            polygons=polygons,
            categories=categories,
            intent=intent,
        ))
    return out


def ingest_dataset(spec: DatasetSpec, extracted_dir: Path) -> list[CocoImage]:
    """Walk every split directory under `extracted_dir` and parse COCO JSONs."""
    all_records: list[CocoImage] = []
    for ann_path in sorted(extracted_dir.rglob("_annotations.coco.json")):
        all_records.extend(parse_coco_split(ann_path, spec.key, spec.intent))
    if not all_records:
        sys.stderr.write(
            f"No COCO annotations found under {extracted_dir} for {spec.key}.\n"
            "Did the ZIP expand into an unexpected layout?\n"
        )
        sys.exit(1)
    return all_records


# ---------------------------------------------------------------------------
# Rasterisation + scoring
# ---------------------------------------------------------------------------


def rasterise_mask(image_size: tuple[int, int], polygons: list[list[float]]) -> np.ndarray:
    """Rasterise the union of polygon segments into a uint8 alpha array."""
    w, h = image_size
    canvas = Image.new("L", (w, h), 0)
    draw = ImageDraw.Draw(canvas)
    for flat in polygons:
        points = [(float(flat[i]), float(flat[i + 1])) for i in range(0, len(flat) - 1, 2)]
        if len(points) >= 3:
            draw.polygon(points, fill=255)
    return np.array(canvas, dtype=np.uint8)


def sobel_edge_mean(gray: np.ndarray, background_mask: np.ndarray) -> float:
    """Mean edge magnitude in the background (mask-excluded) region.

    Uses np.gradient, which matches Sobel's first-order approximation well
    enough for relative ranking. Avoids a scipy dependency.
    """
    if not background_mask.any():
        return 0.0
    gy, gx = np.gradient(gray.astype(np.float32))
    mag = np.hypot(gx, gy)
    return float(mag[background_mask].mean())


@dataclass
class ScoredImage:
    record: CocoImage
    coverage: float
    bg_edge: float
    bg_variance: float
    bucket: str | None  # assigned by bucket_images()


def score_images(records: list[CocoImage]) -> list[ScoredImage]:
    scored: list[ScoredImage] = []
    for rec in records:
        try:
            with Image.open(rec.image_path) as im:
                im = im.convert("RGB")
                w, h = im.size
                arr = np.array(im, dtype=np.uint8)
        except OSError:
            continue

        mask = rasterise_mask((w, h), rec.polygons)
        coverage = float((mask > 127).mean())
        if coverage < 0.03 or coverage > 0.95:
            # Tiny or full-frame masks — skip; they are either bad annotations
            # or not useful for the extractor rig.
            continue

        gray = np.mean(arr, axis=2)
        bg_mask = mask < 128
        bg_edge = sobel_edge_mean(gray, bg_mask)
        bg_var = float(arr[bg_mask].std()) if bg_mask.any() else 0.0

        scored.append(ScoredImage(
            record=rec,
            coverage=coverage,
            bg_edge=bg_edge,
            bg_variance=bg_var,
            bucket=None,
        ))
    return scored


def bucket_images(scored: list[ScoredImage]) -> dict[str, list[ScoredImage]]:
    """Assign each scored image to a scenario bucket.

    `on_person` is determined by source dataset intent — the Clothing
    Detection Test set is explicitly worn-on-people and nothing else.

    For the StreetVision studio set we split on a percentile threshold of
    background edge density: bottom 40% → clean_bg candidates, top 40% →
    cluttered candidates. The middle 20% is reserved as fallback.
    """
    on_person = [s for s in scored if s.record.intent == "on_person"]
    studio = [s for s in scored if s.record.intent == "studio"]

    buckets: dict[str, list[ScoredImage]] = {b: [] for b in BUCKETS}

    for s in on_person:
        s.bucket = "on_person"
        buckets["on_person"].append(s)

    if studio:
        edges = np.array([s.bg_edge for s in studio])
        variances = np.array([s.bg_variance for s in studio])
        edge_low = float(np.percentile(edges, 40))
        edge_high = float(np.percentile(edges, 60))
        var_low = float(np.percentile(variances, 40))
        for s in studio:
            if s.bg_edge <= edge_low and s.bg_variance <= var_low:
                s.bucket = "clean_bg"
                buckets["clean_bg"].append(s)
            elif s.bg_edge >= edge_high:
                s.bucket = "cluttered"
                buckets["cluttered"].append(s)
            # else: middle band, left unassigned as fallback pool

        # Fallback: if clean or cluttered buckets fell short, pull from the
        # nearest edge of the studio pool.
        unassigned = [s for s in studio if s.bucket is None]
        unassigned.sort(key=lambda s: s.bg_edge)
        while len(buckets["clean_bg"]) < PER_BUCKET_COUNT and unassigned:
            pick = unassigned.pop(0)
            pick.bucket = "clean_bg"
            buckets["clean_bg"].append(pick)
        while len(buckets["cluttered"]) < PER_BUCKET_COUNT and unassigned:
            pick = unassigned.pop()
            pick.bucket = "cluttered"
            buckets["cluttered"].append(pick)

    return buckets


# ---------------------------------------------------------------------------
# Curation
# ---------------------------------------------------------------------------


def augmentation_base_id(source_image_id: str) -> str:
    """Collapse Roboflow augmentation variants to their source photo.

    Roboflow's export pipeline duplicates each source image N times with a
    `.rf.<hash>` suffix so a single photo contributes 3-5 near-identical
    rows. Without dedup the picker will happily select 3 copies of the
    same shirt. We want 30 distinct source photos.
    """
    lower = source_image_id.lower()
    idx = lower.find(".rf.")
    if idx >= 0:
        return source_image_id[:idx]
    return source_image_id


def curate(buckets: dict[str, list[ScoredImage]]) -> dict[str, list[ScoredImage]]:
    """Trim each bucket to exactly PER_BUCKET_COUNT entries, deterministically.

    Two-stage pick:
      1. Dedup by (dataset_key, augmentation_base_id) so we never pick two
         augmentation variants of the same source photo.
      2. Within each dedup'd pool, prefer category diversity — walk the
         sorted candidates in order and accept the first image from each
         new category until we have 2 per category or the target count is
         reached, then fill the rest by the bucket's sort preference.

    Bucket sort preferences (tie-broken by source_image_id for reproducibility):
      * `clean_bg`:  lowest bg_edge (cleanest backgrounds first)
      * `cluttered`: highest bg_edge (busiest first)
      * `on_person`: seeded shuffle (all samples have similar intent)
    """
    rng = random.Random(hashlib.sha256(RANDOM_SEED.encode()).digest())
    curated: dict[str, list[ScoredImage]] = {}

    for bucket, items in buckets.items():
        if bucket == "clean_bg":
            items.sort(key=lambda s: (s.bg_edge, s.record.source_image_id))
        elif bucket == "cluttered":
            items.sort(key=lambda s: (-s.bg_edge, s.record.source_image_id))
        else:  # on_person
            pool = list(items)
            rng.shuffle(pool)
            items = pool

        # Stage 1 — dedup augmentation duplicates.
        seen_base: set[tuple[str, str]] = set()
        deduped: list[ScoredImage] = []
        for s in items:
            base = augmentation_base_id(s.record.source_image_id)
            key = (s.record.dataset_key, base)
            if key in seen_base:
                continue
            seen_base.add(key)
            deduped.append(s)

        # Stage 2 — category-diverse pick.
        picks: list[ScoredImage] = []
        category_counts: dict[str, int] = {}
        remaining: list[ScoredImage] = []
        CATEGORY_SOFT_CAP = 2  # prefer ≤2 of any single category per bucket
        for s in deduped:
            cat = primary_category(s.record.categories)
            if category_counts.get(cat, 0) < CATEGORY_SOFT_CAP and len(picks) < PER_BUCKET_COUNT:
                picks.append(s)
                category_counts[cat] = category_counts.get(cat, 0) + 1
            else:
                remaining.append(s)

        # Stage 3 — top up any remaining slots by original sort order.
        for s in remaining:
            if len(picks) >= PER_BUCKET_COUNT:
                break
            picks.append(s)

        curated[bucket] = picks[:PER_BUCKET_COUNT]

    return curated


def apply_skip_ids(scored: list[ScoredImage], skip_ids: set[str]) -> list[ScoredImage]:
    if not skip_ids:
        return scored
    kept = []
    dropped = 0
    for s in scored:
        qualified = f"{s.record.dataset_key}:{s.record.source_image_id}"
        if qualified in skip_ids:
            dropped += 1
            continue
        kept.append(s)
    if dropped:
        print(f"• skipped {dropped} image(s) from --skip-ids")
    return kept


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------


def resize_preserve_ratio(im: Image.Image, max_long_edge: int) -> Image.Image:
    w, h = im.size
    long_edge = max(w, h)
    if long_edge <= max_long_edge:
        return im
    scale = max_long_edge / long_edge
    return im.resize((int(w * scale), int(h * scale)), Image.LANCZOS)


def write_fixture(scored: ScoredImage, bucket: str, index: int) -> tuple[Path, Path]:
    """Write one photo + one mask and return their paths (relative to FIXTURES_DIR)."""
    stem = f"{bucket}_{index:02d}"
    image_out = FIXTURES_DIR / f"{stem}.jpg"
    mask_out = MASKS_DIR / f"{stem}.png"

    with Image.open(scored.record.image_path) as im:
        im = im.convert("RGB")
        original_size = im.size
        resized = resize_preserve_ratio(im, MAX_LONG_EDGE)
        resized.save(image_out, format="JPEG", quality=90, optimize=True)

    mask_full = rasterise_mask(original_size, scored.record.polygons)
    mask_img = Image.fromarray(mask_full, mode="L")
    if mask_img.size != resized.size:
        mask_img = mask_img.resize(resized.size, Image.NEAREST)
    # Alpha PNG — black transparent background, white opaque clothing.
    alpha_rgba = Image.new("RGBA", mask_img.size, (0, 0, 0, 0))
    white = Image.new("RGBA", mask_img.size, (255, 255, 255, 255))
    alpha_rgba.paste(white, mask=mask_img)
    alpha_rgba.save(mask_out, format="PNG", optimize=True)

    return image_out, mask_out


def fixture_iou_floor(bucket: str) -> float:
    return {
        "clean_bg": 0.82,
        "cluttered": 0.65,
        "on_person": 0.45,
    }[bucket]


def primary_category(raw_labels: list[str]) -> str:
    """Pick a single internal category name for manifest display.

    Tries a few normalisation variants to absorb the casing / hyphen /
    underscore differences Roboflow projects use (e.g. "T-Shirt",
    "t-shirt", "tshirt", "t_shirt" all map to the same internal bucket).
    """
    for label in raw_labels:
        lower = label.lower().strip()
        variants = {
            lower,
            lower.replace(" ", "_"),
            lower.replace(" ", "-"),
            lower.replace("-", "_"),
            lower.replace("_", "-"),
            lower.replace(" ", "").replace("-", "").replace("_", ""),
        }
        for variant in variants:
            if variant in CATEGORY_MAP:
                return CATEGORY_MAP[variant]
    return "other"


BYO_MARKER = "## BYO additions"


def emit_attributions(curated: dict[str, list[ScoredImage]]) -> None:
    """Write per-image CC-BY attribution with fetch date.

    Everything after a `## BYO additions` heading in the existing file is
    preserved verbatim so owner-supplied attributions survive re-runs.
    """
    fetched = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [
        "# Fixture Attributions",
        "",
        (
            "The images and masks in this directory are sourced from public "
            "datasets licensed under CC-BY 4.0. Attribution is required and "
            "provided below. This file ships inside the XCTest bundle only; "
            "the App Store binary does not include these fixtures."
        ),
        "",
        (
            "Fetched on {date} by `scripts/fetch_fixtures.py`. "
            "Re-run the script to regenerate. BYO additions in a "
            "`## BYO additions` section at the end are preserved."
        ).format(date=fetched),
        "",
        "## Per-image credits",
        "",
    ]
    for bucket in BUCKETS:
        lines.append(f"### {bucket}")
        lines.append("")
        for i, scored in enumerate(curated[bucket], start=1):
            spec = DATASETS[scored.record.dataset_key]
            filename = f"{bucket}_{i:02d}.jpg"
            lines.append(
                f"- `{filename}` — [{spec.uploader}]({spec.source_url}), "
                f"image `{scored.record.source_image_id}`, "
                f"{spec.license_human} ({spec.license_spdx}), fetched {fetched}."
            )
        lines.append("")
    lines.append("## Source projects")
    lines.append("")
    for spec in DATASETS.values():
        lines.append(
            f"- **{spec.uploader}** — {spec.source_url} "
            f"({spec.license_human}, {spec.license_spdx})"
        )
    lines.append("")

    # Preserve a BYO trailing block if the owner has added one.
    if ATTRIBUTIONS_PATH.is_file():
        try:
            existing = ATTRIBUTIONS_PATH.read_text(encoding="utf-8")
            marker_idx = existing.find(BYO_MARKER)
            if marker_idx >= 0:
                byo_block = existing[marker_idx:].rstrip() + "\n"
                lines.append(byo_block)
        except OSError:
            pass

    ATTRIBUTIONS_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def emit_manifest(curated: dict[str, list[ScoredImage]]) -> None:
    """Write manifest.json, preserving the long-form `_comment` header."""
    fixtures: list[dict] = []
    for bucket in BUCKETS:
        for i, scored in enumerate(curated[bucket], start=1):
            stem = f"{bucket}_{i:02d}"
            fixtures.append({
                "image": f"{stem}.jpg",
                "mask": f"ground_truth/{stem}.png",
                "category": primary_category(scored.record.categories),
                "scenario": bucket,
                "source_dataset": scored.record.dataset_key,
                "source_image_id": scored.record.source_image_id,
                "expected_iou_min": fixture_iou_floor(bucket),
                "notes": (
                    f"coverage={scored.coverage:.2f}, "
                    f"bg_edge={scored.bg_edge:.2f}, "
                    f"bg_var={scored.bg_variance:.2f}"
                ),
            })

    existing_comment = None
    if MANIFEST_PATH.is_file():
        try:
            prior = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
            existing_comment = prior.get("_comment")
        except (OSError, ValueError):
            pass

    manifest = {
        "_comment": existing_comment or (
            "Auto-generated by scripts/fetch_fixtures.py. "
            "Thirty CC-BY 4.0 images + masks sourced from Roboflow Universe."
        ),
        "version": 1,
        "fixtures": fixtures,
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Summary / validation
# ---------------------------------------------------------------------------


def report_category_coverage(curated: dict[str, list[ScoredImage]]) -> None:
    """Print category distribution and warn when any category is under-represented."""
    from collections import Counter
    counts: Counter[str] = Counter()
    for bucket in BUCKETS:
        for scored in curated[bucket]:
            counts[primary_category(scored.record.categories)] += 1

    print("\nCategory coverage across 30 fixtures:")
    for cat in ("top", "bottom", "dress", "shoes", "outerwear", "accessory", "other"):
        count = counts.get(cat, 0)
        marker = "⚠" if count < 2 and cat != "other" else " "
        print(f"  {marker} {cat}: {count}")
    missing = [cat for cat in ("top", "bottom", "dress", "shoes", "outerwear", "accessory")
               if counts.get(cat, 0) < 2]
    if missing:
        print(
            "\n⚠ Category gap: the following categories appear fewer than 2× — "
            "consider adding owner photos + traces to cover: "
            f"{', '.join(missing)}"
        )


def report_bucket_sizes(buckets: dict[str, list[ScoredImage]]) -> None:
    print("\nBucket pool sizes after scoring:")
    for bucket in BUCKETS:
        print(f"  {bucket}: {len(buckets[bucket])} candidate(s)")
    for bucket in BUCKETS:
        if len(buckets[bucket]) < PER_BUCKET_COUNT:
            print(
                f"\n⚠ {bucket} bucket has only {len(buckets[bucket])} images — "
                f"need {PER_BUCKET_COUNT}. Either supply BYO photos + traces "
                "for the gap or widen the source datasets."
            )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def ensure_output_dirs() -> None:
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    MASKS_DIR.mkdir(parents=True, exist_ok=True)


def clear_previous_fixtures() -> None:
    """Remove any prior script-generated fixtures so reruns stay clean."""
    for bucket in BUCKETS:
        for i in range(1, PER_BUCKET_COUNT + 1):
            stem = f"{bucket}_{i:02d}"
            for path in (FIXTURES_DIR / f"{stem}.jpg", MASKS_DIR / f"{stem}.png"):
                if path.exists():
                    path.unlink()


def main() -> int:
    args = parse_args()
    skip_ids = {s.strip() for s in args.skip_ids.split(",") if s.strip()}

    temp_cleanup: tempfile.TemporaryDirectory | None = None
    if args.work_dir:
        work_dir = Path(args.work_dir).expanduser().resolve()
        work_dir.mkdir(parents=True, exist_ok=True)
    else:
        temp_cleanup = tempfile.TemporaryDirectory(prefix="wardrobe-fixtures-")
        work_dir = Path(temp_cleanup.name)

    try:
        # 1. Acquire + parse both datasets.
        all_records: list[CocoImage] = []
        for spec in DATASETS.values():
            extracted = acquire_dataset(spec, work_dir)
            records = ingest_dataset(spec, extracted)
            print(f"• [{spec.key}] parsed {len(records)} image(s) with masks")
            all_records.extend(records)

        # 2. Score + bucket.
        print("\nScoring images (this takes a minute)…")
        scored = score_images(all_records)
        scored = apply_skip_ids(scored, skip_ids)
        buckets = bucket_images(scored)
        report_bucket_sizes(buckets)

        curated = curate(buckets)

        # 3. Dry-run summary or real write.
        if args.dry_run:
            print("\n-- DRY RUN — no files written --")
            for bucket in BUCKETS:
                print(f"\n{bucket} picks:")
                for i, s in enumerate(curated[bucket], start=1):
                    print(
                        f"  {i:02d}. {s.record.dataset_key}:{s.record.source_image_id} "
                        f"(coverage={s.coverage:.2f}, bg_edge={s.bg_edge:.2f})"
                    )
            report_category_coverage(curated)
            return 0

        ensure_output_dirs()
        clear_previous_fixtures()
        print("\nWriting fixtures…")
        for bucket in BUCKETS:
            if len(curated[bucket]) < PER_BUCKET_COUNT:
                sys.stderr.write(
                    f"\nAborting: {bucket} only produced "
                    f"{len(curated[bucket])}/{PER_BUCKET_COUNT} images.\n"
                    "Re-run with a wider source pool or supply BYO traces.\n"
                )
                return 1
            for i, scored_item in enumerate(curated[bucket], start=1):
                img, mask = write_fixture(scored_item, bucket, i)
                print(
                    f"  • {img.relative_to(REPO_ROOT)} "
                    f"(from {scored_item.record.dataset_key}:{scored_item.record.source_image_id})"
                )

        emit_attributions(curated)
        emit_manifest(curated)
        report_category_coverage(curated)
        print(
            f"\n✓ Wrote 30 fixtures to {FIXTURES_DIR.relative_to(REPO_ROOT)} "
            f"(+ ATTRIBUTIONS.md, manifest.json)."
        )
        print(
            "\nNext: run SegmentationIoUTests once on device, record each "
            "actual IoU, subtract 5 pp per entry, and commit the tuned "
            "expected_iou_min values back into manifest.json."
        )
        return 0
    finally:
        if temp_cleanup is not None:
            temp_cleanup.cleanup()


if __name__ == "__main__":
    sys.exit(main())
