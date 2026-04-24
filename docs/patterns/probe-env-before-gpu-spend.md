# Pattern: Probe Env Before GPU Spend

**Problem.** You're about to fine-tune a model on a rented GPU pod ($X/hr). The training script works on your laptop — except you only ran it in a Jupyter notebook two weeks ago, the upstream library shipped a minor release since, and your pip lockfile has one stale transitive dep. Three minutes after you click Deploy, a `TypeError: unexpected keyword argument 'foo'` kills the run. You've paid $0.50 to learn something you could have learned at $0.

**Solution.** Write a CPU-only local probe that validates every assumption the training and export scripts make. Run it on your laptop after `pip install -r requirements.txt`. Don't touch a GPU until it prints `PASSED: N/N checks`.

Cost per probe run: $0. Cost per GPU-pod surprise: $/hr × whatever the boot + crash cycle takes.

---

## What the probe checks

A good probe covers five classes of failure:

### 1. Pinned imports resolve

Every package named in `requirements.txt` imports cleanly at the pinned version.

```python
import torch, torchvision, coremltools, <your-model-lib>, datasets, transformers, pycocotools
assert torch.__version__.startswith("2.5"), f"torch 2.5.x expected, got {torch.__version__}"
```

Catches: stale pins, missing packages, wrong Python version for the wheel, binary incompatibilities between pinned versions.

### 2. Framework API surface matches your scripts

Introspect the exact classes and methods your training + export scripts call.

```python
import inspect
from <your-model-lib> import YourModelWrapper
from <your-model-lib>.config import TrainConfig, ModelConfig

# Methods the scripts call on the wrapper
required = ["train", "export", "predict", "get_model"]
missing = [m for m in required if not hasattr(YourModelWrapper, m)]
assert not missing, f"Model wrapper missing: {missing}"

# Pydantic config fields the scripts pass as kwargs
train_fields = set(TrainConfig.model_fields.keys())
expected = {"dataset_dir", "epochs", "batch_size", "lr", "output_dir", ...}
missing = expected - train_fields
assert not missing, f"TrainConfig missing: {missing}"
```

Catches: upstream renames, deprecated methods, config field drift between library minor releases. This is the #1 highest-leverage check. API drift is the most common GPU-pod crash cause.

### 3. Dataset schema probe (streaming, no full download)

If you use HuggingFace / a remote dataset, stream one record and assert expected keys exist.

```python
from datasets import load_dataset
ds = load_dataset("<dataset>", split="train", streaming=True)
first = next(iter(ds))
assert "image" in first, "expected key 'image' missing"
assert "objects" in first or "annotations" in first, "annotation field schema has changed"
```

Catches: dataset schema drift on HuggingFace mirrors (happens more often than you'd think), network or auth failures that would block the real download on the pod.

### 4. `torch.jit.trace` round-trip on a minimal module

If your export pipeline uses tracing, verify tracing works locally on a throwaway Conv2d. A broken torch install (corrupted wheel, wrong ABI) will fail here before it fails on a real model.

```python
import torch
class Tiny(torch.nn.Module):
    def __init__(self): super().__init__(); self.conv = torch.nn.Conv2d(3, 8, 3, padding=1)
    def forward(self, x): return self.conv(x)
m = Tiny().eval()
traced = torch.jit.trace(m, torch.rand(1, 3, 32, 32))
assert traced(torch.rand(1, 3, 32, 32)).shape == torch.Size([1, 8, 32, 32])
```

### 5. Export-toolchain round-trip on a minimal module

If you convert to Core ML / ONNX / TensorRT, verify the toolchain can emit an artifact from the minimal module above. Catches broken coremltools installs, missing `cmake` or `protoc` bindings, permission issues on the save path.

```python
import coremltools as ct, tempfile
from pathlib import Path
ml = ct.convert(traced, inputs=[ct.TensorType(name="x", shape=(1, 3, 32, 32))],
                convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17)
with tempfile.TemporaryDirectory() as tmp:
    out = Path(tmp) / "tiny.mlpackage"
    ml.save(str(out))
    assert out.exists()
```

And probe any optimization API you use:

```python
from coremltools.optimize.coreml import OpPalettizerConfig, OptimizationConfig, palettize_weights
# Just the imports — if they work, the API shape is likely stable.
```

## Probe runner

Structure the probe as a list of independent checks with a clear exit code:

```python
@dataclass
class Check:
    name: str
    run: Callable[[], None]

CHECKS = [
    Check("pinned imports resolve", _check_import_stack),
    Check("framework API surface", _check_framework_api),
    Check("dataset schema", _check_dataset_schema),
    Check("torch.jit.trace round-trip", _check_torch_trace),
    Check("coremltools convert round-trip", _check_coremltools_convert),
    Check("palettizer API", _check_palettizer),
]

def main() -> int:
    failed = []
    for check in CHECKS:
        print(f"\n[{check.name}]")
        try:
            check.run()
            print("  PASS")
        except Exception as exc:
            print(f"  FAIL: {exc}")
            traceback.print_exc()
            failed.append((check.name, exc))
    if failed:
        print(f"\nFAILED: {len(failed)}/{len(CHECKS)} checks")
        return 1
    print(f"\nPASSED: {len(CHECKS)}/{len(CHECKS)} checks")
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

Exit code 0 = safe to boot the pod. Non-zero = fix locally, re-run, keep costing $0 per iteration.

## When to run the probe

- After every `pip install -r requirements.txt`.
- After every `git pull` that touches `requirements.txt` or the training scripts.
- Immediately before booting the GPU pod, as the last gate before paid actions.
- As the **first** command the pod runs after bootstrap, so the pod env is validated against the same checks as the laptop env. A laptop-green probe that fails on the pod means the pod image's Python differs — fix it before training, not during.

## What the probe should NOT do

- **Download the full dataset.** Stream one record; that's enough to check schema. The full download is the pod's job.
- **Instantiate the model** if that triggers a multi-hundred-MB weight download. Introspect the class instead.
- **Run real training.** Even one step. Training failures have different root causes than env failures; keep the probe focused.
- **Hit paid APIs.** Probing an OpenAI key by running a real completion costs money. If you must probe, use the free health endpoint or skip the probe for that API.

## Cost comparison

| Approach | Cost per iteration | Feedback loop |
|---|---|---|
| Probe locally, then boot | $0 local + $0.50 boot + train | Minutes to green on laptop, then paid work is green |
| Boot, run training, fail at minute 3 | $0.02 boot + $0.05 crash = $0.07 per crash, times N crashes | Each crash is a pod teardown + new boot + new bootstrap |

Five crashes at $0.07 each is $0.35 — less than one coffee. But the **wall-clock** cost is also real: each boot + bootstrap + crash + teardown cycle is 10–15 minutes. An afternoon of flailing turns into a morning of probing.

## Template

See `notebooks/training/scripts/probe_env.py` in this repo for a 250-line working template covering torch + coremltools + a model wrapper + HuggingFace datasets + a palettization toolchain. Copy it, swap the imports, adjust `expected_train_fields` / `expected_model_fields`, and you have a probe for your next ML project.

## Source

This pattern was extracted from the 2026-04-18 training scripts session on the Wardrobe Re-Do project. The probe caught an rfdetr 1.4 API drift that would have crashed a 4090 pod 30 seconds into a ~2 hour smoke run.
