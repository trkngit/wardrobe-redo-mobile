# Fetching Phase 4 extraction fixtures

`scripts/fetch_fixtures.py` replaces the hand-capture + hand-trace workflow
that used to live in `WardrobeReDoTests/Fixtures/Extraction/capture-brief.md`
with a one-shot downloader + curator. It pulls two **CC-BY 4.0** Roboflow
Universe projects, rasterises their instance masks to alpha PNGs, buckets
each image into a scenario (clean background / cluttered / on-person), picks
ten from each bucket, and writes the committed fixture set.

This is an **owner-only task**, run once per dataset refresh. The fixtures
themselves are committed; CI reruns against those committed files without
touching this script.

## Prerequisites

### 1. Python env

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install roboflow pillow numpy
```

Python 3.10+ recommended. The script uses `from __future__ import annotations`
so 3.9 works too, but `roboflow` has pinned deps that install more cleanly on
3.10+.

### 2. One of the two input paths

The script supports two ways to acquire the raw datasets. Pick whichever is
easier for your setup.

#### Path A — Roboflow free-tier API (recommended)

1. Create a free Roboflow account at https://roboflow.com (no credit card).
2. Open https://app.roboflow.com/settings/api and copy your private key.
3. Export it before running the script:

   ```bash
   export ROBOFLOW_API_KEY=<your key>
   ```

The SDK caches downloads in the work dir the script creates, so re-runs are
fast.

#### Path B — Manual ZIP download (airgapped / no account)

For each of the two datasets, open the project in a browser, click **Download
Dataset** → **Export as** → **COCO Segmentation** → **Download zip to
computer**, and save the resulting ZIPs somewhere stable. Then export the
paths:

```bash
export ROBOFLOW_ZIP_YANELYS=/absolute/path/to/clothing-segmentation.zip
export ROBOFLOW_ZIP_CLOTHING_TEST=/absolute/path/to/clothing-detection-test.zip
```

Dataset URLs:

| Env var                          | Roboflow project URL                                                         |
|----------------------------------|------------------------------------------------------------------------------|
| `ROBOFLOW_ZIP_YANELYS`           | https://universe.roboflow.com/yanelys/clothing-segmentation                  |
| `ROBOFLOW_ZIP_CLOTHING_TEST`     | https://universe.roboflow.com/clothing-detection/clothing-detection-test     |

If both the API key and ZIP env var are set, the ZIP takes precedence (it's
more reliable offline).

## Run it

```bash
# Preview the curation without writing anything — useful for spot-checking
# category coverage and bucket sizes before committing.
python3 scripts/fetch_fixtures.py --dry-run

# Commit the 30 fixtures + masks + ATTRIBUTIONS.md + manifest.json.
python3 scripts/fetch_fixtures.py
```

Output on success looks like:

```
• [YANELYS] extracting ZIP /Users/you/Downloads/clothing-segmentation.zip
• [YANELYS] parsed 1084 image(s) with masks
• [CLOTHING_TEST] extracting ZIP /Users/you/Downloads/clothing-detection-test.zip
• [CLOTHING_TEST] parsed 62 image(s) with masks

Scoring images (this takes a minute)…

Bucket pool sizes after scoring:
  clean_bg: 328 candidate(s)
  cluttered: 291 candidate(s)
  on_person: 57 candidate(s)

Writing fixtures…
  • WardrobeReDoTests/Fixtures/Extraction/clean_bg_01.jpg (from YANELYS:img_0001)
  • WardrobeReDoTests/Fixtures/Extraction/clean_bg_02.jpg (from YANELYS:img_0047)
  …

Category coverage across 30 fixtures:
    top: 12
    bottom: 7
    dress: 4
    shoes: 3
    outerwear: 2
    accessory: 2
    other: 0

✓ Wrote 30 fixtures to WardrobeReDoTests/Fixtures/Extraction/ (+ ATTRIBUTIONS.md, manifest.json).

Next: run SegmentationIoUTests once on device, record each actual IoU,
subtract 5 pp per entry, and commit the tuned expected_iou_min values
back into manifest.json.
```

## Spot-check before committing

Before `git add`-ing the 60 new files, eyeball them:

1. Open a few `*.jpg` / matching `*.png` pairs in Preview — confirm the mask
   actually traces the clothing and not the background or a person's skin.
2. Reject any image that shows a recognisable face with no context
   (children, bystanders) or a prominent trademarked logo. Even under
   CC-BY, publishing them as test assets for a commercial app is
   uncomfortable. Use `--skip-ids` to drop them and re-run:

   ```bash
   python3 scripts/fetch_fixtures.py \
     --skip-ids YANELYS:img_0123,YANELYS:img_0456
   ```
3. Verify `ATTRIBUTIONS.md` was regenerated and lists all 30 images.

If more than 5 images fail the spot-check, the source pool may have shifted
since the project was curated. Re-run with a wider `--skip-ids` list, or
supply BYO photos to close the gap (see below).

## When a category is under-represented

If the script reports fewer than 2 images for a `ClothingCategory`, you have
two options:

**Option A — Let it be.** The IoU rig only needs category-level signal, not
perfect balance. Missing one shoe fixture is not a deal-breaker.

**Option B — BYO override.** Drop your own photo + hand-traced alpha PNG into
`WardrobeReDoTests/Fixtures/Extraction/` using the filename slot the script
would have picked (e.g. `cluttered_07.jpg` + `ground_truth/cluttered_07.png`),
then append a manifest entry by hand. Owner-captured overrides survive future
script re-runs as long as the target `--skip-ids` list keeps the auto-picker
out of that slot.

## Attribution obligation

The fixtures are CC-BY 4.0, which requires credit to the uploader. The script
emits `WardrobeReDoTests/Fixtures/Extraction/ATTRIBUTIONS.md` on every run,
listing each image with its uploader, source URL, SPDX tag, and fetch date.

**Important:** `ATTRIBUTIONS.md` ships only inside the XCTest bundle. It is
not compiled into the App Store binary. There is nothing to surface in the
user-facing Settings > About > Attributions screen — that screen still only
needs to credit the code-level dependencies (SAM2 Apache-2.0, etc.).

## Troubleshooting

**"No COCO annotations found under … for YANELYS."**
Roboflow export structures occasionally change. The script scans every
`_annotations.coco.json` recursively, so the usual culprit is that the ZIP
was exported in a non-COCO format. Re-export with **COCO Segmentation** (not
YOLO / Pascal VOC / Tensorflow).

**"No ROBOFLOW_API_KEY set and the ZIP env var is empty."**
You need either the API key or the matching ZIP. See "Prerequisites" above.

**"roboflow package not installed."**
Run `pip install roboflow` inside your venv, or use the ZIP path.

**Bucket ends up short (< 10 images).**
The source pool shifted (Roboflow projects are mutable). Options:
- Widen the middle band by editing the `edge_low`/`edge_high` percentiles
  in `bucket_images()`.
- Supply a third CC-BY source and add a `DatasetSpec` entry.
- Write a BYO trace for the missing slot — see "When a category is
  under-represented" above.

**Images look fine but masks are jagged / hollow.**
Roboflow polygon exports can include multi-part segments with holes. The
rasteriser fills each sub-polygon separately with `ImageDraw.polygon(...,
fill=255)`, which does NOT honour even-odd winding. If a specific image has
visible holes in the mask, the source annotation was probably authored with
a hole that the exporter didn't preserve. Use `--skip-ids` to drop that
image.

## License note

The script itself is part of the Wardrobe Re-Do repo (project license
applies). The fixtures it writes are CC-BY 4.0, properly attributed in
`ATTRIBUTIONS.md`. DeepFashion2, Fashionpedia, and other research-only
datasets are deliberately out of scope here — they live on
`~/wardrobe-benchmark/` and are downloaded by `scripts/build_benchmark.py`
for dev-only quality reports, never committed.
