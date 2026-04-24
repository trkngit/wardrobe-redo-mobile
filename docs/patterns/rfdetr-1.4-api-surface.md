# Reference: rfdetr 1.4 API Surface

A copy-paste reference for fine-tuning + exporting RF-DETR-Seg-Small with the [rfdetr](https://github.com/roboflow/rf-detr) 1.4 Python library. Written after a session where we hit every single upstream rename in this file — so consider this the cheat sheet.

**Scope.** Everything the training script + Core ML exporter touches. Not a tutorial. See Roboflow's README + blog for conceptual overview.

**Pinned version.** `rfdetr==1.4.0` (or whatever 1.4.x is latest; probe before relying on exact field names).

---

## 1. The wrapper ≠ an nn.Module

`RFDETRSegSmall` (and its siblings Nano/Medium/Large) is a thin Python wrapper around the actual `nn.Module`. The wrapper handles configuration via Pydantic. The real module is inside.

```python
from rfdetr import RFDETRSegSmall

model = RFDETRSegSmall(
    num_classes=33,
    resolution=1024,
    segmentation_head=True,
    pretrain_weights=None,   # skip the 129 MB COCO download
)

# Wrapper surface:
model.train(**kwargs)     # runs rfdetr's Trainer
model.predict(image)      # inference
model.export(...)         # export to ONNX / Core ML etc.
model.get_model()         # returns the inner nn.Module

# nn.Module surface is on the INNER module, NOT the wrapper:
inner = model.get_model()
inner.eval()
inner.load_state_dict(state_dict)
```

## 2. ModelConfig — constructor kwargs

Routed through `RFDETRSegSmall.__init__(**kwargs)` → `rfdetr.config.ModelConfig` (Pydantic).

```python
from rfdetr.config import ModelConfig
print(sorted(ModelConfig.model_fields.keys()))
```

Expected fields (as of 1.4):
- `num_classes: int` — number of target classes (EXCLUDING background). For Fashionpedia's 33 main classes, pass 33.
- `resolution: int` — square input resolution. MUST match training + export. Shapes the graph at construct time.
- `segmentation_head: bool` — True for the Seg variants; shapes the graph at construct time.
- `pretrain_weights: str | None` — path to pretrained weights, or `None` to skip the default COCO download. Pass `None` when you're about to overwrite params via `load_state_dict`.

**Gotchas:**
- `pretrained=True/False` is NOT a valid kwarg. The real one is `pretrain_weights`.
- `resolution` and `segmentation_head` CANNOT be passed to `train()` — they must be set at construction. Passing them as train kwargs silently fails.

## 3. TrainConfig — train() kwargs

Routed through `RFDETRSegSmall.train(**kwargs)` → `rfdetr.config.TrainConfig`.

```python
from rfdetr.config import TrainConfig
print(sorted(TrainConfig.model_fields.keys()))
```

Fields your scripts likely pass:
- `dataset_dir: str` — directory holding `train/` + `valid/` subdirs.
- `dataset_file: str` — schema hint. Pass `"roboflow"` if the layout is `<dir>/{train,valid}/_annotations.coco.json`.
- `epochs: int`
- `batch_size: int`
- `grad_accum_steps: int` — gradient accumulation for effective batch = batch_size × grad_accum_steps.
- `lr: float`
- `output_dir: str` — where `best.pth`, `last.pth`, and metrics files land.
- `num_workers: int` — DataLoader workers.
- `segmentation_head: bool` — MUST also be True for Seg variants, even though you already set it at construction. Yes, duplicated. Pass True in both places.
- `class_names: list[str]` — ordered list of class labels. rfdetr emits a labels file alongside the checkpoint using this list.

**What TrainConfig does NOT have:**
- `max_steps_per_epoch` or `max_steps` — if you want to smoke-test on a subset, throttle at dataset-prep time (e.g., your prepare script's `--max-train` / `--max-val` flags), NOT via a training-step cap.
- `resolution` — that's ModelConfig, not TrainConfig.

## 4. Dataset layout (`dataset_file="roboflow"`)

```
<dataset_dir>/
├── train/
│   ├── _annotations.coco.json
│   └── *.jpg
└── valid/
    ├── _annotations.coco.json
    └── *.jpg
```

The COCO JSON must include `images`, `annotations`, `categories`, with `annotations[].segmentation` as polygon lists if you want mask supervision for the seg variant.

## 5. Checkpoints

rfdetr writes checkpoints as:

```python
{
    "model": state_dict,
    "optimizer": optim_state,
    "epoch": int,
    ...
}
```

Best-val checkpoint is typically `best.pth`; latest is `last.pth`.

Loading for inference (e.g. in an export script):

```python
state = torch.load(checkpoint_path, map_location="cpu")
inner = model.get_model()
if isinstance(state, dict) and "model" in state:
    inner.load_state_dict(state["model"])
else:
    inner.load_state_dict(state)
inner.eval()
```

Do NOT call `model.load_state_dict(...)` on the wrapper — it has no such method.

## 6. Tracing for Core ML export

```python
inner = model.get_model()
inner.eval()

# Warmup — DETR-style positional embeddings can be lazy
example = torch.rand(1, 3, resolution, resolution)
with torch.no_grad():
    _ = inner(example)
    traced = torch.jit.trace(inner, example, strict=False)
```

The warmup forward pass is important: some DETR implementations compute positional embeddings lazily on first call. Without warmup, `torch.jit.trace` captures a dynamic path that Core ML can't convert cleanly.

## 7. Known Core ML export failure modes

Documented in this repo's `export_coreml.py` docstring. Summary:

- **`aten::upsample_bicubic2d` not supported.** Fix: bake a fixed positional embedding before tracing (the warmup above usually resolves this).
- **Dynamic shape from internal reshape.** Fix: `strict=False` on the trace; verify the resulting .mlpackage has static output shapes.
- **FP16 softmax overflow on certain backbones.** Fix: force FP32 softmax via a `ct.convert` kwarg if the mlpackage predicts garbage.

## 8. Minimal working train + export snippets

### Train

```python
from rfdetr import RFDETRSegSmall

model = RFDETRSegSmall(
    num_classes=33,
    resolution=1024,
    segmentation_head=True,  # at construction
)

model.train(
    dataset_dir="./data/fashionpedia",
    dataset_file="roboflow",
    epochs=10,
    batch_size=4,
    grad_accum_steps=2,
    lr=1e-4,
    output_dir="./checkpoints",
    num_workers=4,
    segmentation_head=True,  # also at train time
    class_names=FASHIONPEDIA_MAIN_CLASSES,  # 33-item list
)
```

### Export

```python
import torch, coremltools as ct
from coremltools.optimize.coreml import (
    OpPalettizerConfig, OptimizationConfig, palettize_weights,
)
from rfdetr import RFDETRSegSmall

# Skip the COCO download; we're about to overwrite params anyway
model = RFDETRSegSmall(
    num_classes=33,
    resolution=1024,
    segmentation_head=True,
    pretrain_weights=None,
)

state = torch.load("./checkpoints/best.pth", map_location="cpu")
inner = model.get_model()
inner.load_state_dict(state["model"] if "model" in state else state)
inner.eval()

# Trace
example = torch.rand(1, 3, 1024, 1024)
with torch.no_grad():
    _ = inner(example)  # warmup
    traced = torch.jit.trace(inner, example, strict=False)

# Convert
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 1024, 1024),
                          scale=1/255., bias=[0., 0., 0.])],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS17,
    compute_units=ct.ComputeUnit.ALL,
)

# 6-bit palettize
cfg = OpPalettizerConfig(nbits=6, mode="kmeans",
                         granularity="per_grouped_channel", group_size=16)
compressed = palettize_weights(mlmodel, OptimizationConfig(global_config=cfg))
compressed.save("RFDETRSegFashion.mlpackage")
```

## 9. Probe snippet (catch API drift at $0)

Drop this into a probe_env.py:

```python
import inspect
from rfdetr import RFDETRSegSmall
from rfdetr.config import ModelConfig, TrainConfig

required_methods = ["train", "export", "predict", "get_model"]
missing = [m for m in required_methods if not hasattr(RFDETRSegSmall, m)]
assert not missing, f"rfdetr API drift: missing methods {missing}"

expected_model_fields = {"num_classes", "resolution", "segmentation_head", "pretrain_weights"}
missing_model = expected_model_fields - set(ModelConfig.model_fields.keys())
assert not missing_model, f"ModelConfig drift: missing {missing_model}"

expected_train_fields = {
    "dataset_dir", "epochs", "batch_size", "grad_accum_steps", "lr",
    "output_dir", "num_workers", "dataset_file", "segmentation_head",
    "class_names",
}
missing_train = expected_train_fields - set(TrainConfig.model_fields.keys())
assert not missing_train, f"TrainConfig drift: missing {missing_train}"
```

Run this after every rfdetr upgrade. If it fails, the fix is locally cheap. If you skip it, the fix is at $X/hr on a GPU pod.

## 10. Upstream references

- Repo: https://github.com/roboflow/rf-detr
- Seg variant announcement: https://blog.roboflow.com/rf-detr-segmentation/
- iOS / Core ML notes: https://blog.roboflow.com/best-ios-object-detection-models/

## Source

This reference was compiled during the 2026-04-18 training-script session on the Wardrobe Re-Do project. Every "gotcha" and rename in this file corresponds to a real bug the probe caught or a real edit in commit `8cbf350`.
