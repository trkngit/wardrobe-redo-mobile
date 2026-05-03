# RunPod runbook — Fashionpedia fine-tune, Core ML export

Copy-pasteable step-by-step for training `RFDETRSegFashion.mlpackage`
on RunPod inside a **\$30 budget**. Two phases: a \$2 smoke test on a
4090 that de-risks the entire pipeline, then a \$22–25 production run
on an H100 80GB that produces the ship-quality model.

> **Permanent plan:** `docs/plans/2026-04-18-multi-garment-detection.md`
> **Notebook:** `notebooks/training/2026-04-multi-garment.ipynb` (exploratory; the runbook's scripts are authoritative)
> **Scripts (authoritative):** `notebooks/training/scripts/{probe_env,prepare_fashionpedia,train,export_coreml}.py`

---

## Budget envelope

| Phase | GPU | Cost | Time | Purpose |
|---|---|---|---|---|
| 0 | laptop (CPU) | \$0 | 5 min | `probe_env.py` — verify local env + rfdetr API |
| 1 | RunPod RTX 4090 (community) | ~\$2 | ~3 hrs | smoke test: 500-image subset, 2 epochs, Core ML export |
| 2 | RunPod H100 80GB (community) | ~\$22–25 | ~10 hrs | production: full Fashionpedia, 8–10 epochs @ 1024², batch 8 |
| — | reserve | ~\$3–6 | — | retries, rescue runs |

**Total: \$24–27.** If phase 1 fails, the \$2 buys you the information
needed to pivot (e.g. Core ML export blocker → fall back to the SAM 2
Tiny + classifier path from plan Section 2).

---

## Phase 0 — Local probe (free, on your Mac)

```bash
cd "~/Projects/Coding/Wardrobe Re-Do"

# One-time env setup
python3.11 -m venv .venv-train
source .venv-train/bin/activate
pip install -r notebooks/training/requirements.txt

# Probe (no GPU, no dataset download — just API + import checks)
python notebooks/training/scripts/probe_env.py
```

**Expected:** all six checks PASS. If any FAIL, fix the env before
spending a cent on GPU.

Common fixes:
- `rfdetr import` fails → likely a torch/torchvision version mismatch.
  Re-run `pip install -r notebooks/training/requirements.txt --force-reinstall`.
- `HF streaming` skipped with a network error → fine, CVDF is the real
  source. Proceed.
- `coremltools convert round-trip` fails → wheel corrupt; reinstall
  coremltools 8.1 specifically.

---

## Phase 1 — Smoke test on RTX 4090 (~\$2, ~3 hrs)

### 1.1 Boot the pod

On RunPod (https://www.runpod.io/console/gpu-browse):

- **GPU:** RTX 4090 (24 GB), community cloud tier (cheapest — \~\$0.34–0.69/hr)
- **Template:** "PyTorch 2.5.1" (prebuilt) or "RunPod PyTorch 2.5"
- **Disk:** 50 GB (enough for a 500-image subset + deps)
- **Ports:** expose 8888 if you want Jupyter, otherwise SSH-only is fine

### 1.2 On the pod, clone + install

```bash
# Inside the pod's shell (RunPod web terminal or SSH)
cd /workspace
git clone https://github.com/trkngit/wardrobe-redo-mobile.git
cd wardrobe-redo-mobile
git checkout feature/photo-extraction-engine

# Python env
python -m venv .venv
source .venv/bin/activate
pip install -r notebooks/training/requirements.txt

# Sanity: confirm GPU is visible
python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
# Expect: True NVIDIA GeForce RTX 4090
```

### 1.3 Prep a tiny dataset subset (~5 min)

```bash
python notebooks/training/scripts/prepare_fashionpedia.py \
    --out ./data/fashionpedia \
    --max-train 500 \
    --max-val 100
```

This downloads + filters ~600 images (tens of MB, not the full ~12 GB
archive). Output should be:

```
data/fashionpedia/
  train/  (501 entries: 500 jpg + 1 json)
  valid/  (101 entries: 100 jpg + 1 json)
```

### 1.4 Smoke-test training (~2 hrs)

```bash
python notebooks/training/scripts/train.py \
    --dataset-dir ./data/fashionpedia \
    --output-dir ./checkpoints \
    --epochs 2 \
    --batch-size 2 \
    --resolution 768
```

(rfdetr 1.4's `TrainConfig` has no per-epoch step cap; the 500-image
smoke dataset from step 1.3 does the same throttling via dataset size
— ~250 steps/epoch at batch-size 2.)

**Success signal:** `train.py` exits 0, `checkpoints/` contains at
least `last.pth` or `best.pth`. The model will be GARBAGE (intentional)
— we only care that the training loop ran without crashing.

**If `train.py` crashes on an `RFDETRSegSmall.train(...)` kwarg:** the
rfdetr API has drifted. Fix is small — edit `scripts/train.py`'s
`train_kwargs` dict to match the actual signature (run
`python -c "from rfdetr import RFDETRSegSmall; import inspect; print(inspect.signature(RFDETRSegSmall.train))"`
to see the current one). Commit the fix, push, re-pull on the pod.

### 1.5 Smoke-test Core ML export (~10 min)

```bash
python notebooks/training/scripts/export_coreml.py \
    --checkpoint ./checkpoints/best.pth \
    --out ./checkpoints/coreml \
    --resolution 768
```

Should produce:
- `checkpoints/coreml/RFDETRSegFashion_fp16.mlpackage` (~70–90 MB at 768²)
- `checkpoints/coreml/RFDETRSegFashion.mlpackage` (~20–30 MB after palettization)

**This is the moment of truth.** If Core ML conversion fails here,
it'll fail on the production run too. Fix or pivot BEFORE phase 2.

Failure modes:
- `aten::upsample_bicubic2d not supported`: rfdetr's decoder has a
  dynamic upsample. Fix: pre-bake position embeddings via a warmup
  pass (`export_coreml.py` already does this; if it still fails, the
  warmup shape is wrong).
- `TracerWarning: ... tensor with a different shape`: add `strict=False`
  to `torch.jit.trace` (already set).
- `MIL compile error on softmax`: FP16 overflow; force FP32 softmax
  via `ct.convert(..., compute_precision=ct.precision.FLOAT32)` for
  the softmax op specifically.

### 1.6 Pull the smoke-test .mlpackage back to the Mac

```bash
# Still on the pod
cd /workspace/wardrobe-redo-mobile/checkpoints/coreml
tar czf RFDETRSegFashion_smoketest.tar.gz RFDETRSegFashion.mlpackage
# Note the path — you'll `scp` or wget this back to your Mac.
```

```bash
# On your Mac
scp runpod:/workspace/wardrobe-redo-mobile/checkpoints/coreml/RFDETRSegFashion_smoketest.tar.gz ~/Downloads/
cd "~/Projects/Coding/Wardrobe Re-Do"
tar xzf ~/Downloads/RFDETRSegFashion_smoketest.tar.gz \
    -C WardrobeReDo/Models/CoreML/

xcodegen generate
xcodebuild -scheme WardrobeReDo -sdk iphonesimulator build
# Open app, flip FeatureFlags.isMultiGarmentEnabled in Settings → Developer,
# take a photo → verify multi-pick cover appears (even with garbage proposals
# — just proves the pipeline is wired).
```

### 1.7 Kill the pod

**IMPORTANT:** RunPod charges while the pod exists, not only while
you're using it. Stop or terminate the pod as soon as the smoke test
is done. Terminate (not stop) to delete the volume and avoid storage
charges.

---

## Phase 2 — Production training on H100 80GB (~\$22–25, ~10 hrs)

Gated on phase 1 success. If Core ML export worked at smoke-test scale,
it'll work at production scale.

### 2.1 Boot the pod

- **GPU:** H100 PCIe 80GB, community cloud (\~\$2.49/hr) — 2–3× A100 throughput for DETR
- **Template:** PyTorch 2.5.1
- **Disk:** 150 GB (full Fashionpedia is ~12 GB unzipped + checkpoints)
- **Check:** compute capability sm_90 visible — `torch.cuda.get_device_capability(0)` should return `(9, 0)`

### 2.2 Clone + install (same as 1.2)

### 2.3 Prep the full dataset (~15 min download + ~10 min extract)

```bash
python notebooks/training/scripts/prepare_fashionpedia.py \
    --out ./data/fashionpedia
# (no --max-train / --max-val flags this time)
```

Expected: ~45K train + ~1.2K val images, ~8–10 GB on disk.

### 2.4 Production training (~9 hrs)

```bash
python notebooks/training/scripts/train.py \
    --dataset-dir ./data/fashionpedia \
    --output-dir ./checkpoints \
    --epochs 10 \
    --batch-size 8 \
    --grad-accum-steps 2 \
    --resolution 1024 \
    --lr 1e-4 \
    --num-workers 8
```

**Run in a tmux / screen session so a disconnected SSH doesn't kill
the job:**

```bash
tmux new -s train
# run the python command above
# detach: Ctrl-B then D
# reattach: tmux attach -t train
```

### 2.5 Monitor progress

In a second SSH session or via RunPod's web terminal:

```bash
# GPU utilization (should be 85–99% during training)
nvidia-smi -l 5

# Per-step metrics — rfdetr writes tensorboard logs to output_dir
tensorboard --logdir ./checkpoints --host 0.0.0.0 --port 6006
# Expose port 6006 in RunPod to view on laptop
```

**Green-light checkpoints:**
- Epoch 1: train loss dropping, val mAP > 0 (sanity — loss is decreasing)
- Epoch 3: val mAP > 15 (learning, not stuck)
- Epoch 6: val mAP > 25 (on track for the 30 target)
- Epoch 10: val mAP ≥ 30 on collapsed 6 classes (SHIP)

If epoch 3 shows val mAP stuck near 0: bug. Kill the run, investigate.
Don't burn 7 more hours chasing a misconfigured model.

### 2.6 Core ML export (~15 min)

```bash
python notebooks/training/scripts/export_coreml.py \
    --checkpoint ./checkpoints/best.pth \
    --out ./checkpoints/coreml \
    --resolution 1024
```

Expected: `RFDETRSegFashion.mlpackage` around 30–50 MB. If larger than
100 MB, the plan's Background Assets delivery path (Section 9) is
required instead of bundling.

### 2.7 Pull back + ship

```bash
# On the pod
cd /workspace/wardrobe-redo-mobile/checkpoints/coreml
tar czf RFDETRSegFashion.tar.gz RFDETRSegFashion.mlpackage
```

```bash
# On Mac
scp runpod:/workspace/wardrobe-redo-mobile/checkpoints/coreml/RFDETRSegFashion.tar.gz ~/Downloads/
cd "~/Projects/Coding/Wardrobe Re-Do"
rm -rf WardrobeReDo/Models/CoreML/RFDETRSegFashion.mlpackage
tar xzf ~/Downloads/RFDETRSegFashion.tar.gz -C WardrobeReDo/Models/CoreML/

xcodegen generate
xcodebuild test -scheme WardrobeReDo -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
# 461/461 should still pass

# On-device verification: see plan Section 5 "ANE residency verification"
# + the post-export checklist in the notebook (cell 17).
```

### 2.8 Kill the pod (same discipline as 1.7)

Terminate, not stop. Save the tar.gz somewhere durable (Google Drive,
S3, whatever) — retraining costs \$20+ and takes hours.

---

## After the model ships

1. Commit the `.mlpackage` to the repo (`git lfs track "**/*.mlpackage"`
   if it's not already in LFS — check `.gitattributes`). Push to the
   `feature/photo-extraction-engine` branch.
2. Flip `FeatureFlags.isMultiGarmentEnabled` default to `true` in
   `WardrobeReDo/Config/FeatureFlags.swift` (this is Commit 9 of the
   canonical plan).
3. Update `docs/plans/INDEX.md` status to `SHIPPED` and link the
   merged PR.
4. Delete `~/.claude/plans/unified-mapping-honey.md` — the ephemeral
   scratch is no longer needed; `docs/plans/` is authoritative.

---

## Failure-mode decision tree

```
Phase 1 smoke test fails
├── Training loop crashes (rfdetr API drift)
│   └── Fix train.py, redeploy (<30 min, <$1)
├── Core ML convert fails on a specific op
│   ├── Known DETR op (upsample_bicubic2d, etc.) → apply the fix in
│   │   export_coreml.py's "Known failure modes" comment
│   └── Unknown op → pivot to SAM 2 Tiny + classifier (plan §2 backup).
│       Remaining $28 funds that path instead.
└── Convert succeeds but .mlpackage predicts garbage on device
    └── FP16 overflow. Re-export with compute_precision=FLOAT32 on
        attention layers.

Phase 2 training underperforms
├── Val mAP plateau below 20 by epoch 5
│   ├── Undertrained? → push to epoch 12
│   └── Underparameterized? → the plan's Small variant may be wrong;
│       pivot to Medium (more params, same Apache 2.0 license)
├── OOM at batch 8 @ 1024² on H100
│   └── Drop to batch 4, grad-accum-steps=4 (effective batch 16)
└── Run gets evicted from community cloud
    └── RunPod auto-resumes from last checkpoint on restart; use
        --resume ./checkpoints/last.pth
```

---

## Attribution checklist (ship requirement)

Before the App Store submission that carries the trained model:

- [ ] About screen shows "Garment detection powered by Fashionpedia (Jia et al., 2020)" + the CC BY 4.0 link
- [ ] `NOTICES.md` or equivalent in the repo lists:
  - Fashionpedia dataset — CC BY 4.0 (https://fashionpedia.github.io/home/data_license.html)
  - RF-DETR-Seg-Small weights — Apache 2.0 (Roboflow)
  - Any transitive model cards (DINOv2 backbone if pretrained weights are used unmodified)
- [ ] Privacy manifest updated to reflect on-device ML inference (no server-side data)
