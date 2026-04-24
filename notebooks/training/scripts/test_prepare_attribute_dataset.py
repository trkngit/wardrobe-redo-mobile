"""Smoke tests for the Phase 2 dataset preparer.

Locks in the behavioral contracts from BLOCKERS.md (P2-1 through P2-7)
without depending on the 12 GB Fashionpedia download. Uses synthetic
in-memory data to exercise every pure function + a round-trip through
`process_split` against a fake annotation JSON and a generated image zip.

Usage:
    ./.venv-train/bin/python notebooks/training/scripts/test_prepare_attribute_dataset.py

Exit code 0 = all contracts hold. Nonzero = at least one assertion failed.
"""
from __future__ import annotations

import io
import json
import shutil
import sys
import tempfile
import traceback
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from PIL import Image  # noqa: E402

from fashionpedia_attr_to_ios_enum import (  # noqa: E402
    TRAINABLE_FIT_LABELS,
    fit_index_to_label,
    fit_label_to_index,
    normalize_class_name,
    resolve_fit_label,
)
from prepare_attribute_dataset import (  # noqa: E402
    CROP_SIZE,
    _bbox_passes_filters,
    _clamp_bbox,
    _square_pad_and_resize,
    process_split,
)


# -- Tiny test harness — no pytest dep --------------------------------


_failures: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  ok   — {name}")
    else:
        print(f"  FAIL — {name}: {detail}")
        _failures.append(f"{name}: {detail}")


def run(name: str, fn) -> None:
    print(f"\n== {name} ==")
    try:
        fn()
    except Exception as exc:  # pragma: no cover — surfaced to stdout
        tb = traceback.format_exc()
        _failures.append(f"{name}: {exc}\n{tb}")
        print(f"  EXCEPTION — {exc}\n{tb}")


# -- Contract tests for resolve_fit_label (P2-1 + P2-2) ----------------


def test_resolve_fit_label_single_snugness():
    # Single snugness attr → that label.
    check("135 (tight) on top → slim", resolve_fit_label([135], "shirt_blouse") == "slim")
    check("136 (regular) on dress → regular", resolve_fit_label([136], "dress") == "regular")
    check("137 (loose) on pants → relaxed", resolve_fit_label([137], "pants") == "relaxed")
    check("138 (oversized) on sweater → oversized", resolve_fit_label([138], "sweater") == "oversized")


def test_resolve_fit_label_ambiguous_multi_fit():
    # P2-2: conflicting snugness attrs → skip.
    check(
        "135 + 137 ambiguous → None",
        resolve_fit_label([135, 137], "shirt_blouse") is None,
    )
    check(
        "136 + 138 ambiguous → None",
        resolve_fit_label([136, 138], "sweater") is None,
    )


def test_resolve_fit_label_cropped_gating():
    # P2-1: attr 146 only on top-like categories.
    check("146 on top → cropped", resolve_fit_label([146], "shirt_blouse") == "cropped")
    check("146 on t-shirt blob → cropped", resolve_fit_label([146], "top_t-shirt_sweatshirt") == "cropped")
    check("146 on sweater → cropped", resolve_fit_label([146], "sweater") == "cropped")
    check("146 on cardigan → cropped", resolve_fit_label([146], "cardigan") == "cropped")
    check("146 on vest → cropped", resolve_fit_label([146], "vest") == "cropped")
    check("146 on jacket → cropped", resolve_fit_label([146], "jacket") == "cropped")
    # Non-top categories: silently drop.
    check("146 on dress → None (not top)", resolve_fit_label([146], "dress") is None)
    check("146 on skirt → None", resolve_fit_label([146], "skirt") is None)
    check("146 on pants → None", resolve_fit_label([146], "pants") is None)
    check("146 on shoe → None", resolve_fit_label([146], "shoe") is None)


def test_resolve_fit_label_tie_break():
    # P2-2 tie-break: cropped wins over snugness on top-like.
    check(
        "146 + 136 on top → cropped",
        resolve_fit_label([146, 136], "shirt_blouse") == "cropped",
    )
    check(
        "146 + 135 on sweater → cropped",
        resolve_fit_label([146, 135], "sweater") == "cropped",
    )
    # On non-top, 146 is dropped → fall back to snugness.
    check(
        "146 + 136 on dress → regular (146 dropped)",
        resolve_fit_label([146, 136], "dress") == "regular",
    )


def test_resolve_fit_label_no_signal():
    check("empty attrs → None", resolve_fit_label([], "shirt_blouse") is None)
    check("unrelated attrs → None", resolve_fit_label([17, 36, 183], "shirt_blouse") is None)


# -- normalize_class_name (P2-6) --------------------------------------


def test_normalize_class_name():
    check("'shirt, blouse' → 'shirt_blouse'", normalize_class_name("shirt, blouse") == "shirt_blouse")
    check("'T-shirt, top, sweatshirt' → 'top_t-shirt_sweatshirt'-like",
          normalize_class_name("T-shirt, top, sweatshirt") == "t-shirt_top_sweatshirt")
    check("already underscore passthrough", normalize_class_name("pants") == "pants")
    check("trims whitespace", normalize_class_name("  dress  ") == "dress")
    check("empty stays empty", normalize_class_name("") == "")


# -- Label index round-trip ------------------------------------------


def test_fit_label_index_roundtrip():
    for label in TRAINABLE_FIT_LABELS:
        idx = fit_label_to_index(label)
        back = fit_index_to_label(idx)
        check(f"roundtrip {label} ↔ {idx}", back == label)


# -- BBox geometry (P2-5) --------------------------------------------


def test_clamp_bbox():
    # Normal case.
    check("in-bounds bbox", _clamp_bbox((10, 20, 100, 50), 300, 300) == (10, 20, 110, 70))
    # Overflow on right edge.
    check("right overflow clamped", _clamp_bbox((250, 0, 100, 100), 300, 100) == (250, 0, 300, 100))
    # Negative x.
    check("negative x clamped to 0", _clamp_bbox((-10, 0, 50, 50), 300, 300) == (0, 0, 40, 50))
    # Zero-area collapse → None.
    check("zero-area → None", _clamp_bbox((0, 0, 0, 0), 300, 300) is None)
    check("off-image → None", _clamp_bbox((1000, 1000, 50, 50), 300, 300) is None)


def test_bbox_filters():
    # 224x224 bbox in a 1000x1000 image → area fraction = ~0.05, aspect 1.0. Pass.
    check("reasonable bbox passes", _bbox_passes_filters((0, 0, 224, 224), 1000, 1000) is True)
    # 10x10 bbox in 1000x1000 → area = 0.0001 < 0.02. Fail.
    check("tiny bbox rejected", _bbox_passes_filters((0, 0, 10, 10), 1000, 1000) is False)
    # 500x100 bbox → aspect 5 > 4. Fail.
    check("very-wide bbox rejected", _bbox_passes_filters((0, 0, 500, 100), 1000, 1000) is False)
    # 100x500 bbox → aspect 0.2 < 0.25. Fail.
    check("very-tall bbox rejected", _bbox_passes_filters((0, 0, 100, 500), 1000, 1000) is False)


def test_square_pad_and_resize():
    # Rect input → square output.
    rect = Image.new("RGB", (100, 50), (255, 0, 0))
    out = _square_pad_and_resize(rect, size=64)
    check("output is 64x64", out.size == (64, 64))
    check("output is RGB", out.mode == "RGB")
    # Top-left corner should be padding (gray), center should still be red.
    check("corner padded", out.getpixel((0, 0)) != (255, 0, 0))
    check("center preserved", out.getpixel((32, 32)) == (255, 0, 0))


# -- End-to-end process_split smoke (synthetic Fashionpedia data) -----


def _make_synthetic_fashionpedia_zip(archive_path: Path, image_filenames: list[str], size=(1024, 1024)) -> None:
    """Create a zip with solid-color JPEGs — just enough to exercise
    the preparer's image-reading path."""
    with zipfile.ZipFile(archive_path, "w") as z:
        for idx, name in enumerate(image_filenames):
            img = Image.new("RGB", size, ((idx * 37) % 255, (idx * 59) % 255, (idx * 97) % 255))
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=85)
            z.writestr(f"images/{name}", buf.getvalue())


def _make_synthetic_annotation_json() -> dict:
    return {
        "categories": [
            {"id": 1, "name": "shirt, blouse"},      # top-like
            {"id": 2, "name": "dress"},              # non-top
            {"id": 3, "name": "pants"},              # non-top
            {"id": 4, "name": "sweater"},            # top-like
        ],
        "images": [
            {"id": 101, "file_name": "img_101.jpg", "width": 1024, "height": 1024},
            {"id": 102, "file_name": "img_102.jpg", "width": 1024, "height": 1024},
            {"id": 103, "file_name": "img_103.jpg", "width": 1024, "height": 1024},
        ],
        "annotations": [
            # Shirt with regular fit → keep as regular.
            {"id": 1001, "image_id": 101, "category_id": 1,
             "bbox": [100, 100, 400, 500], "attribute_ids": [136]},
            # Dress with attr 146 (cropped) → drop (non-top gating).
            {"id": 1002, "image_id": 101, "category_id": 2,
             "bbox": [500, 100, 400, 600], "attribute_ids": [146]},
            # Sweater with 146 + 136 → tie-break wins cropped.
            {"id": 1003, "image_id": 102, "category_id": 4,
             "bbox": [100, 100, 300, 300], "attribute_ids": [146, 136]},
            # Pants with attr 137 (relaxed) → keep.
            {"id": 1004, "image_id": 102, "category_id": 3,
             "bbox": [500, 400, 400, 500], "attribute_ids": [137]},
            # Ambiguous dual snugness → drop.
            {"id": 1005, "image_id": 103, "category_id": 1,
             "bbox": [100, 100, 400, 400], "attribute_ids": [135, 137]},
            # Tiny bbox → drop by area filter.
            {"id": 1006, "image_id": 103, "category_id": 1,
             "bbox": [10, 10, 20, 20], "attribute_ids": [136]},
            # No fit attrs → drop (no signal).
            {"id": 1007, "image_id": 103, "category_id": 2,
             "bbox": [200, 200, 300, 300], "attribute_ids": []},
        ],
    }


def test_process_split_endtoend():
    with tempfile.TemporaryDirectory() as td:
        tmpdir = Path(td)

        # Fake annotation JSON on disk.
        annot_json = _make_synthetic_annotation_json()
        annot_path = tmpdir / "instances_attributes_train2020.json"
        with open(annot_path, "w") as fh:
            json.dump(annot_json, fh)

        # Fake image archive.
        archive_path = tmpdir / "train2020.zip"
        _make_synthetic_fashionpedia_zip(
            archive_path,
            ["img_101.jpg", "img_102.jpg", "img_103.jpg"],
        )

        out_dir = tmpdir / "out"
        rows, counter = process_split(
            split="train",
            annot_path=annot_path,
            archive_path=archive_path,
            out_dir=out_dir,
            max_crops=None,
        )

        # 3 annotations should survive: ann 1001 (regular), 1003 (cropped
        # via tie-break), 1004 (relaxed). The rest are dropped.
        expected_ids = {1001, 1003, 1004}
        actual_ids = {r["annotation_id"] for r in rows}
        check(
            f"survivors exactly {sorted(expected_ids)}",
            actual_ids == expected_ids,
            detail=f"got {sorted(actual_ids)}",
        )

        # Labels are correct.
        by_id = {r["annotation_id"]: r for r in rows}
        check("1001 labelled 'regular'", by_id[1001]["fit_label_name"] == "regular")
        check("1003 labelled 'cropped' (tie-break)", by_id[1003]["fit_label_name"] == "cropped")
        check("1004 labelled 'relaxed'", by_id[1004]["fit_label_name"] == "relaxed")

        # Class counter matches.
        check("counter sum == rows", sum(counter.values()) == len(rows))

        # Each surviving crop file exists at 224x224.
        for r in rows:
            crop_path = out_dir / r["image_path"]
            check(f"crop file exists: {r['image_path']}", crop_path.exists())
            with Image.open(crop_path) as im:
                check(
                    f"crop {r['annotation_id']} is {CROP_SIZE}x{CROP_SIZE}",
                    im.size == (CROP_SIZE, CROP_SIZE),
                )

        # Idempotence: re-running should not fail or change rows.
        rows2, counter2 = process_split(
            split="train",
            annot_path=annot_path,
            archive_path=archive_path,
            out_dir=out_dir,
            max_crops=None,
        )
        check("idempotent rerun same row count", len(rows2) == len(rows))
        check("idempotent rerun same labels", dict(counter2) == dict(counter))


# -- Entrypoint -------------------------------------------------------


def main() -> int:
    run("resolve_fit_label — single snugness", test_resolve_fit_label_single_snugness)
    run("resolve_fit_label — ambiguous multi-fit (P2-2)", test_resolve_fit_label_ambiguous_multi_fit)
    run("resolve_fit_label — cropped gating (P2-1)", test_resolve_fit_label_cropped_gating)
    run("resolve_fit_label — tie-break (P2-2)", test_resolve_fit_label_tie_break)
    run("resolve_fit_label — no signal", test_resolve_fit_label_no_signal)
    run("normalize_class_name (P2-6)", test_normalize_class_name)
    run("fit_label index roundtrip", test_fit_label_index_roundtrip)
    run("clamp_bbox (P2-5)", test_clamp_bbox)
    run("bbox_passes_filters (P2-5)", test_bbox_filters)
    run("square_pad_and_resize", test_square_pad_and_resize)
    run("process_split — synthetic end-to-end", test_process_split_endtoend)

    if _failures:
        print(f"\n{len(_failures)} FAILURE(S):")
        for f in _failures:
            print(f"  - {f}")
        return 1
    print("\nAll tests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
