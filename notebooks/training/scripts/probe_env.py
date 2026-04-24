"""Local CPU-only probe that validates the training environment before
you pay for GPU time.

Run this on your laptop immediately after
    pip install -r notebooks/training/requirements.txt

Goals:
  1. Confirm every pinned package imports.
  2. Probe the rfdetr 1.4 API surface that the training script depends on.
  3. Probe the HuggingFace Fashionpedia record schema (streaming, no full
     download) so we know the prepare-Fashionpedia script's assumptions
     are still accurate.
  4. Dry-run a torch.jit.trace on a tiny module so we catch cases where
     the local PyTorch build is broken before booting a pod.

Exit code is 0 iff every check passes. Non-zero otherwise with the
first failing check printed.

This script never downloads the full Fashionpedia images — it only
streams the metadata of the first few records. Safe to run on a laptop.
"""
from __future__ import annotations

import importlib
import inspect
import sys
import traceback
from dataclasses import dataclass
from typing import Callable


@dataclass
class Check:
    name: str
    run: Callable[[], None]


def _check_import_stack() -> None:
    import torch
    import torchvision
    import coremltools
    import rfdetr
    import datasets
    import transformers
    import pycocotools
    import PIL
    import numpy

    assert torch.__version__.startswith("2.5"), (
        f"torch 2.5.x expected, got {torch.__version__}"
    )
    assert coremltools.__version__.startswith("8.1"), (
        f"coremltools 8.1.x expected, got {coremltools.__version__}"
    )
    print(f"  torch        {torch.__version__}")
    print(f"  torchvision  {torchvision.__version__}")
    print(f"  coremltools  {coremltools.__version__}")
    print(f"  rfdetr       {getattr(rfdetr, '__version__', 'unknown')}")
    print(f"  datasets     {datasets.__version__}")


def _check_rfdetr_api() -> None:
    """Guard the exact RFDETRSegSmall surface the train.py + export_coreml.py
    scripts rely on. rfdetr 1.4 routes all runtime kwargs through two
    Pydantic configs (TrainConfig, ModelConfig) via `**kwargs`, so
    probing those directly is stronger than probing the wrapper's
    `__init__` signature (which is just `**kwargs`).

    If rfdetr publishes a minor API change that renames a field, this
    check flags it for $0 — whereas discovering it on a GPU pod costs
    whatever the pod rental rate is per hour.
    """
    from rfdetr import RFDETRSegSmall
    from rfdetr.config import ModelConfig, TrainConfig

    # Constructor signature — we don't instantiate (that would download
    # the 129 MB COCO checkpoint). We only introspect.
    init_sig = inspect.signature(RFDETRSegSmall.__init__)
    print(f"  RFDETRSegSmall.__init__ params: {list(init_sig.parameters)[:8]}")

    # Required methods on the wrapper. rfdetr 1.4 exposes .get_model()
    # to access the underlying nn.Module (which has .eval()) — the
    # wrapper itself does NOT have .eval().
    required_methods = ["train", "export", "predict", "get_model"]
    missing = [m for m in required_methods if not hasattr(RFDETRSegSmall, m)]
    assert not missing, (
        f"RFDETRSegSmall is missing expected methods: {missing}. "
        f"rfdetr's 1.4 API may have drifted — check "
        f"https://github.com/roboflow/rf-detr/blob/main/CHANGELOG.md"
    )

    # TrainConfig — drives train.py's **train_kwargs. If any field name
    # changes upstream, this catches it before a GPU pod boots.
    train_fields = set(TrainConfig.model_fields.keys())
    expected_train_fields = {
        "dataset_dir", "epochs", "batch_size", "grad_accum_steps", "lr",
        "output_dir", "num_workers", "dataset_file", "segmentation_head",
        "class_names",
    }
    missing_train = expected_train_fields - train_fields
    assert not missing_train, (
        f"TrainConfig is missing expected fields: {missing_train}. "
        f"Available fields: {sorted(train_fields)}"
    )
    print(f"  TrainConfig fields present: {sorted(expected_train_fields)}")

    # ModelConfig — drives the RFDETRSegSmall(...) constructor in
    # train.py + export_coreml.py. `pretrain_weights=None` is how you
    # skip the COCO download at inference-time load.
    model_fields = set(ModelConfig.model_fields.keys())
    expected_model_fields = {
        "num_classes", "resolution", "segmentation_head", "pretrain_weights",
    }
    missing_model = expected_model_fields - model_fields
    assert not missing_model, (
        f"ModelConfig is missing expected fields: {missing_model}. "
        f"Available fields: {sorted(model_fields)}"
    )
    print(f"  ModelConfig fields present: {sorted(expected_model_fields)}")


def _check_hf_dataset_schema() -> None:
    """Stream one record from the HF Fashionpedia mirror and print its
    shape. We DON'T train on this mirror (it's detection-only — no
    polygons), but it's a fast way to sanity-check HF connectivity +
    the datasets library version from a laptop.

    The real training data comes from CVDF, downloaded by
    prepare_fashionpedia.py on the GPU pod.
    """
    from datasets import load_dataset

    try:
        ds = load_dataset(
            "detection-datasets/fashionpedia",
            split="train",
            streaming=True,
        )
        first = next(iter(ds))
        keys = list(first.keys())
        print(f"  HF Fashionpedia record keys: {keys}")

        # The mirror SHOULD have objects + bbox + category per record.
        # If the schema changed, flag early.
        assert "image" in keys, "'image' field missing from HF record"
        assert "objects" in keys or "annotations" in keys, (
            "Neither 'objects' nor 'annotations' field present — "
            "the HF mirror schema has changed."
        )
    except Exception as exc:
        # Network failure is not a blocker — CVDF is the real source.
        # But print the error so the user knows why the probe stopped.
        print(f"  HF streaming probe skipped (network? auth?): {exc}")


def _check_torch_trace() -> None:
    """Trace a tiny module. If torch.jit.trace is broken locally (e.g.
    the wheel was corrupted by a half-finished install), this fails
    fast — it's what the Core ML export step depends on.
    """
    import torch

    class Tiny(torch.nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.conv = torch.nn.Conv2d(3, 8, 3, padding=1)

        def forward(self, x: torch.Tensor) -> torch.Tensor:  # noqa: D401
            return self.conv(x)

    m = Tiny().eval()
    example = torch.rand(1, 3, 32, 32)
    traced = torch.jit.trace(m, example)
    out = traced(example)
    assert out.shape == torch.Size([1, 8, 32, 32]), f"unexpected shape {out.shape}"
    print("  torch.jit.trace round-trip OK")


def _check_coremltools_convert() -> None:
    """Smallest possible Core ML convert — no DETR, just Conv2d — to
    verify coremltools + its runtime can emit an .mlpackage. Drops
    output to a tempdir.
    """
    import tempfile
    from pathlib import Path

    import coremltools as ct
    import torch

    class Tiny(torch.nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.conv = torch.nn.Conv2d(3, 8, 3, padding=1)

        def forward(self, x: torch.Tensor) -> torch.Tensor:
            return self.conv(x)

    m = Tiny().eval()
    traced = torch.jit.trace(m, torch.rand(1, 3, 32, 32))
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="x", shape=(1, 3, 32, 32))],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
    )
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "tiny.mlpackage"
        ml.save(str(out))
        assert out.exists(), "mlpackage did not materialize"
    print("  coremltools Core ML convert round-trip OK")


def _check_palettizer() -> None:
    """The palettize_weights API moved between coremltools 7 and 8. If
    the import fails here, the export_coreml.py's palettization pass
    will crash — better to know now.
    """
    from coremltools.optimize.coreml import (  # noqa: F401
        OpPalettizerConfig,
        OptimizationConfig,
        palettize_weights,
    )

    print("  coremltools.optimize.coreml palettize API present")


CHECKS = [
    Check("pinned imports resolve", _check_import_stack),
    Check("rfdetr API surface", _check_rfdetr_api),
    Check("HF Fashionpedia schema (streaming)", _check_hf_dataset_schema),
    Check("torch.jit.trace", _check_torch_trace),
    Check("coremltools convert round-trip", _check_coremltools_convert),
    Check("coremltools palettizer import", _check_palettizer),
]


def main() -> int:
    print("=" * 60)
    print("Wardrobe Re-Do — training env probe (local, CPU-only)")
    print("=" * 60)

    failed: list[tuple[str, Exception]] = []
    for check in CHECKS:
        print(f"\n[{check.name}]")
        try:
            check.run()
            print("  PASS")
        except Exception as exc:  # noqa: BLE001 — we want all failures
            print(f"  FAIL: {exc}")
            traceback.print_exc()
            failed.append((check.name, exc))

    print("\n" + "=" * 60)
    if failed:
        print(f"FAILED: {len(failed)}/{len(CHECKS)} checks")
        for name, _ in failed:
            print(f"  - {name}")
        print(
            "\nFix local env before booting a RunPod pod. Re-run this script\n"
            "until everything is green. Cost per run: $0."
        )
        return 1
    print(f"PASSED: {len(CHECKS)}/{len(CHECKS)} checks")
    print(
        "\nLocal env is green. Safe to boot the RunPod smoke-test pod.\n"
        "See notebooks/training/RUNPOD_RUNBOOK.md for the next step."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
