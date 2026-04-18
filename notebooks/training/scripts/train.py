"""Fine-tune RF-DETR-Seg-Small on the prepared Fashionpedia dataset.

Produces:
    <output_dir>/best.pth       — best-val-mAP checkpoint (rfdetr convention)
    <output_dir>/last.pth       — latest epoch
    <output_dir>/metrics.json   — per-epoch train/val stats

Run AFTER prepare_fashionpedia.py has populated --dataset-dir.

Smoke-test recipe (~3 hrs on RTX 4090, ~$2):
    # Cap the dataset at prepare time (rfdetr 1.4 has no per-epoch step cap).
    python prepare_fashionpedia.py \\
        --out ./data/fashionpedia \\
        --max-train 500 --max-val 100
    python train.py \\
        --dataset-dir ./data/fashionpedia \\
        --output-dir ./checkpoints \\
        --epochs 2 \\
        --batch-size 2 \\
        --resolution 768

Production recipe (~10 hrs on H100 80GB, ~$24):
    python train.py \\
        --dataset-dir ./data/fashionpedia \\
        --output-dir ./checkpoints \\
        --epochs 10 \\
        --batch-size 8 \\
        --resolution 1024 \\
        --lr 1e-4 \\
        --grad-accum-steps 2

Resolution / batch / epoch defaults match the plan Section 4. Deviations
get logged to run_summary.json so the resulting model is auditable after
the fact.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

# Sibling-script import for FASHIONPEDIA_MAIN_CLASSES so the class list
# stays in one place. prepare_fashionpedia.py lives next to this file.
sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    import torch
    from rfdetr import RFDETRSegSmall
    from prepare_fashionpedia import FASHIONPEDIA_MAIN_CLASSES
except ImportError as exc:
    print(
        f"Missing dependency: {exc}. Install with:\n"
        f"  pip install -r notebooks/training/requirements.txt"
    )
    sys.exit(1)


# 33 Fashionpedia "main apparel" classes. Single source of truth lives in
# prepare_fashionpedia.py; MUST match:
#   - WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift
#     (fashionpediaLabels)
#   - WardrobeReDo/Models/Enums/ClothingCategory.swift
#     (fromFashionpediaClass)
NUM_CLASSES = len(FASHIONPEDIA_MAIN_CLASSES)
assert NUM_CLASSES == 33, (
    f"FASHIONPEDIA_MAIN_CLASSES has {NUM_CLASSES} entries; expected 33. "
    f"Sync the Swift-side enum + label list if this was intentional."
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--dataset-dir",
        type=Path,
        required=True,
        help="Directory produced by prepare_fashionpedia.py "
        "(expects train/ + valid/ subdirs)",
    )
    p.add_argument(
        "--output-dir",
        type=Path,
        default=Path("./checkpoints"),
        help="Where to write .pth snapshots + metrics.json",
    )
    p.add_argument("--epochs", type=int, default=10)
    p.add_argument("--batch-size", type=int, default=4)
    p.add_argument("--grad-accum-steps", type=int, default=1)
    p.add_argument("--resolution", type=int, default=1024)
    p.add_argument("--lr", type=float, default=1e-4)
    p.add_argument(
        "--resume",
        type=Path,
        default=None,
        help="Resume from an earlier .pth checkpoint",
    )
    p.add_argument(
        "--num-workers",
        type=int,
        default=4,
        help="DataLoader workers — bump on beefier CPUs",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()

    # Validate dataset layout — fail fast if prepare_fashionpedia.py
    # hasn't been run.
    train_dir = args.dataset_dir / "train"
    valid_dir = args.dataset_dir / "valid"
    train_ann = train_dir / "_annotations.coco.json"
    valid_ann = valid_dir / "_annotations.coco.json"
    for must_exist in (train_dir, valid_dir, train_ann, valid_ann):
        if not must_exist.exists():
            print(
                f"FATAL: missing {must_exist}.\n"
                f"Run scripts/prepare_fashionpedia.py first."
            )
            return 1

    args.output_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("RF-DETR-Seg-Small — Fashionpedia fine-tune")
    print("=" * 60)
    print(f"  device         {torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU'}")
    print(f"  dataset        {args.dataset_dir}")
    print(f"  output         {args.output_dir}")
    print(f"  epochs         {args.epochs}")
    print(f"  batch size     {args.batch_size}")
    print(f"  grad accum     {args.grad_accum_steps}")
    print(f"  effective bs   {args.batch_size * args.grad_accum_steps}")
    print(f"  resolution     {args.resolution}")
    print(f"  lr             {args.lr}")
    print()

    t0 = time.time()

    # Construct the model. rfdetr 1.4 routes all constructor kwargs into
    # ModelConfig (Pydantic). Default `pretrain_weights` downloads the
    # COCO-pretrained RF-DETR-Seg-Small checkpoint (~129 MB) on first
    # instantiation. `resolution` + `segmentation_head` MUST be set at
    # construct time because they shape the model graph.
    model = RFDETRSegSmall(
        num_classes=NUM_CLASSES,
        resolution=args.resolution,
        segmentation_head=True,
    )

    if args.resume:
        print(f"Resuming from {args.resume}")
        state = torch.load(args.resume, map_location="cpu")
        # rfdetr checkpoints are typically {'model': state_dict, 'optimizer': ..., 'epoch': ...}
        # Load into the inner nn.Module via get_model() — the wrapper
        # itself does not expose .load_state_dict().
        inner = model.get_model()
        if isinstance(state, dict) and "model" in state:
            inner.load_state_dict(state["model"])
        else:
            inner.load_state_dict(state)

    # Kick off training. rfdetr.Trainer handles mixed precision, cosine
    # LR schedule, per-epoch val eval, and best-checkpoint selection
    # internally. We pass only the dials we actually tune.
    #
    # `dataset_file="roboflow"` tells rfdetr the on-disk layout is
    # `<dataset_dir>/{train,valid}/_annotations.coco.json` (which is
    # what prepare_fashionpedia.py emits).
    # `segmentation_head=True` + `class_names=...` are required for the
    # Seg variant; rfdetr uses class_names to emit a labels file
    # alongside the checkpoint.
    train_kwargs = {
        "dataset_dir": str(args.dataset_dir),
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "grad_accum_steps": args.grad_accum_steps,
        "lr": args.lr,
        "output_dir": str(args.output_dir),
        "num_workers": args.num_workers,
        "dataset_file": "roboflow",
        "segmentation_head": True,
        "class_names": FASHIONPEDIA_MAIN_CLASSES,
    }

    # rfdetr's train() writes metrics + checkpoints itself; we just wrap
    # it with wall-clock timing and a top-level run_summary.json.
    model.train(**train_kwargs)

    elapsed = time.time() - t0
    print(f"\nTraining done in {elapsed / 60:.1f} min ({elapsed:.0f} s)")

    # Emit a summary sidecar so the runbook's "grade the run" step has
    # structured numbers to parse.
    summary = {
        "duration_seconds": elapsed,
        "epochs_requested": args.epochs,
        "batch_size": args.batch_size,
        "grad_accum_steps": args.grad_accum_steps,
        "effective_batch_size": args.batch_size * args.grad_accum_steps,
        "resolution": args.resolution,
        "lr": args.lr,
        "num_classes": NUM_CLASSES,
        "dataset_dir": str(args.dataset_dir),
        "output_dir": str(args.output_dir),
        "rfdetr_version": getattr(__import__("rfdetr"), "__version__", "unknown"),
        "torch_version": torch.__version__,
    }
    summary_path = args.output_dir / "run_summary.json"
    with open(summary_path, "w") as fh:
        json.dump(summary, fh, indent=2)
    print(f"Wrote run summary to {summary_path}")

    # Sanity-check the output — rfdetr should have dropped at least
    # best.pth or last.pth into output_dir.
    ckpts = sorted(args.output_dir.glob("*.pth"))
    if not ckpts:
        print(
            "WARNING: no .pth checkpoint found in output_dir. rfdetr may\n"
            "have changed its output layout — inspect the directory."
        )
        return 2
    print(f"Checkpoints written: {[c.name for c in ckpts]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
