"""Local de-risk: run the rank-5-patched Core ML export against a
random-init RFDETRSegSmall on CPU, then invoke `xcrun coremlc compile`
on the resulting .mlpackage to confirm the compiler actually accepts the
rank-5 graph.

Purpose
-------
Before committing 3 hours of pod time to a real training run, verify
locally that the rank-5 patch produces a graph coremlc will compile.
If this fails, we debug the patch now — not after training finishes.

Weights are random, so inference results are meaningless. This is a
graph-shape test only.

Usage
-----
    ./.venv-train/bin/python notebooks/training/scripts/test_coreml_local_random.py

Exit code 0 = coremlc accepted the graph. Nonzero = something rejected.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from _rfdetr_coreml_patches import apply_rank5_patches
apply_rank5_patches()

import coremltools as ct  # noqa: E402
import torch  # noqa: E402
from rfdetr import RFDETRSegSmall  # noqa: E402


RESOLUTION = 768  # match training resolution; matches planned production resolution


def main() -> int:
    out_dir = Path(tempfile.mkdtemp(prefix="rank5_local_test_"))
    print(f"[0/4] workdir: {out_dir}")

    print("[1/4] instantiate RFDETRSegSmall(random weights)")
    model = RFDETRSegSmall(
        resolution=RESOLUTION,
        segmentation_head=True,
        pretrain_weights=None,
    )
    inner = model.model.model.cpu()
    inner.eval()
    inner.export()

    print("[2/4] torch.jit.trace")
    example = torch.rand(1, 3, RESOLUTION, RESOLUTION)
    with torch.no_grad():
        _ = inner(example)
        traced = torch.jit.trace(inner, example, strict=False)

    print("[3/4] coremltools convert (FP32, iOS17, ALL compute units)")
    image_input = ct.ImageType(
        name="image",
        shape=(1, 3, RESOLUTION, RESOLUTION),
        scale=1.0 / 255.0,
        bias=[0.0, 0.0, 0.0],
    )
    mlmodel = ct.convert(
        traced,
        inputs=[image_input],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT32,
    )
    mlpkg = out_dir / "RFDETRSegFashion_fp16_random.mlpackage"
    mlmodel.save(str(mlpkg))
    print(f"   saved {mlpkg}")

    print("[4/4] xcrun coremlc compile (this is the real rank check)")
    compile_dir = out_dir / "compiled"
    compile_dir.mkdir()
    result = subprocess.run(
        ["xcrun", "coremlc", "compile", str(mlpkg), str(compile_dir)],
        capture_output=True,
        text=True,
    )
    print("--- coremlc stdout ---")
    print(result.stdout)
    print("--- coremlc stderr ---")
    print(result.stderr)
    if result.returncode != 0:
        print(f"FAIL: coremlc exited {result.returncode}")
        print(f"(keeping workdir for inspection: {out_dir})")
        return result.returncode

    print(f"PASS: coremlc accepted the rank-5 graph")
    shutil.rmtree(out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
