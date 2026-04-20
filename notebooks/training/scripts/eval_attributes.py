"""Phase 3 — Evaluate a trained fit classifier checkpoint.

Loads `attr_best.pth` (or any other .pth produced by
`train_attributes.py`) and emits:

    <report_dir>/confusion_matrix.png       — seaborn heatmap, 5×5
    <report_dir>/calibration.png            — conf-bucket realized accuracy
    <report_dir>/per_class.json             — precision/recall/F1/support
    <report_dir>/summary.json               — top-line numbers + file links
    stdout                                  — markdown-formatted table

The summary.json is the machine-readable grade card the pod runbook
consumes to decide whether the checkpoint is shippable (see
ATTRIBUTE_TRAINING_PLAN.md § 5 target metrics).

Usage:
    python eval_attributes.py \\
        --checkpoint ./checkpoints/attr-run/attr_best.pth \\
        --dataset-root ./data/attr-dataset \\
        --report-dir ./checkpoints/attr-run/eval

Flags:
    --split val        Which manifest split to evaluate (default "val").
                       Use "train" only for debugging overfit.
    --batch-size 256   Larger batches OK — no backprop.

Why separate from train_attributes.py:
  The trainer already runs eval every epoch, but this script produces
  plots + the persistent PNG artifacts. Keeping plotting out of the
  training loop keeps training fast + crash-tolerant (matplotlib at
  epoch 18 dying shouldn't kill the run).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    import matplotlib
    matplotlib.use("Agg")  # headless — pods have no display.
    import matplotlib.pyplot as plt
    import numpy as np
    import seaborn as sns
    import torch
    import torch.nn as nn
    from torch.utils.data import DataLoader
except ImportError as exc:
    print(
        f"Missing dependency: {exc}. Install with:\n"
        f"  pip install -r notebooks/training/requirements.txt"
    )
    sys.exit(1)

from fashionpedia_attr_to_ios_enum import TRAINABLE_FIT_LABELS
from train_attributes import (
    CALIBRATION_BINS,
    FitManifestDataset,
    build_model,
    build_val_transform,
    evaluate,
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkpoint", type=Path, required=True)
    p.add_argument("--dataset-root", type=Path, required=True)
    p.add_argument("--report-dir", type=Path, required=True)
    p.add_argument("--split", default="val", choices=["train", "val"])
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--num-workers", type=int, default=4)
    return p.parse_args()


def plot_confusion(
    confusion: np.ndarray, labels: list[str], out_path: Path
) -> None:
    """Row-normalized confusion (each row sums to 1 — highlights per-class
    error modes, not sample count skew)."""
    fig, ax = plt.subplots(figsize=(7, 6))
    row_sums = confusion.sum(axis=1, keepdims=True).clip(min=1)
    normed = confusion / row_sums
    sns.heatmap(
        normed,
        annot=confusion,
        fmt="d",
        xticklabels=labels,
        yticklabels=labels,
        cmap="Blues",
        vmin=0.0,
        vmax=1.0,
        cbar_kws={"label": "row-normalized"},
        ax=ax,
    )
    ax.set_xlabel("predicted")
    ax.set_ylabel("true")
    ax.set_title("Fit classifier — confusion (counts, row-normalized shade)")
    fig.tight_layout()
    fig.savefig(out_path, dpi=160)
    plt.close(fig)


def plot_calibration(
    calibration: list[dict[str, Any]], out_path: Path
) -> None:
    """Reliability diagram — y is realized accuracy, x is predicted conf.
    A well-calibrated model hugs y=x. Bubble size = bin count so
    tiny-support bins visually de-emphasize."""
    centers = [(b["bin_lo"] + b["bin_hi"]) / 2 for b in calibration]
    realized = [b["realized_acc"] for b in calibration]
    counts = [b["count"] for b in calibration]
    fig, ax = plt.subplots(figsize=(7, 6))
    ax.plot([0, 1], [0, 1], linestyle="--", color="gray", label="ideal")
    scatter = ax.scatter(
        centers,
        realized,
        s=[max(c * 0.5, 10) for c in counts],
        c=counts,
        cmap="viridis",
        alpha=0.8,
        edgecolor="k",
    )
    ax.axvline(0.80, color="red", linestyle=":", label="pre-fill threshold (0.80)")
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.set_xlabel("predicted confidence")
    ax.set_ylabel("realized accuracy")
    ax.set_title("Calibration — bubble size ∝ bin count")
    ax.legend(loc="lower right")
    fig.colorbar(scatter, ax=ax, label="bin count")
    fig.tight_layout()
    fig.savefig(out_path, dpi=160)
    plt.close(fig)


def format_markdown_table(
    per_class: dict[str, dict[str, float]],
    labels: list[str],
) -> str:
    lines = [
        "| label      | precision | recall | F1    | support |",
        "| ---------- | --------- | ------ | ----- | ------- |",
    ]
    for label in labels:
        stats = per_class.get(label, {})
        lines.append(
            f"| {label:<10} "
            f"| {stats.get('precision', 0.0):>9.3f} "
            f"| {stats.get('recall', 0.0):>6.3f} "
            f"| {stats.get('f1', 0.0):>5.3f} "
            f"| {stats.get('support', 0):>7d} |"
        )
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    args.report_dir.mkdir(parents=True, exist_ok=True)

    device = torch.device(
        "cuda" if torch.cuda.is_available()
        else ("mps" if torch.backends.mps.is_available() else "cpu")
    )

    transform = build_val_transform()
    dataset = FitManifestDataset(args.dataset_root, args.split, transform)
    loader = DataLoader(
        dataset,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.num_workers,
        pin_memory=(device.type == "cuda"),
    )

    model = build_model().to(device)
    payload = torch.load(args.checkpoint, map_location=device)
    state = payload["model"] if isinstance(payload, dict) and "model" in payload else payload
    model.load_state_dict(state)
    # Loss is computed for reference only. Weights unset — this is
    # evaluation, not training; unweighted loss is the honest val loss.
    criterion = nn.CrossEntropyLoss()

    stats = evaluate(model, loader, criterion, device)

    confusion = np.asarray(stats["confusion"], dtype=np.int64)
    confusion_path = args.report_dir / "confusion_matrix.png"
    plot_confusion(confusion, TRAINABLE_FIT_LABELS, confusion_path)

    calibration_path = args.report_dir / "calibration.png"
    plot_calibration(stats["calibration"], calibration_path)

    per_class_path = args.report_dir / "per_class.json"
    with open(per_class_path, "w") as fh:
        json.dump(stats["per_class"], fh, indent=2)

    summary = {
        "checkpoint": str(args.checkpoint),
        "split": args.split,
        "num_samples": len(dataset),
        "top1": stats["top1"],
        "macro_f1": stats["macro_f1"],
        "high_conf": stats["high_conf"],
        "labels": TRAINABLE_FIT_LABELS,
        "calibration_bins": CALIBRATION_BINS,
        "artifacts": {
            "confusion_matrix": str(confusion_path),
            "calibration": str(calibration_path),
            "per_class": str(per_class_path),
        },
    }
    with open(args.report_dir / "summary.json", "w") as fh:
        json.dump(summary, fh, indent=2)

    # Markdown to stdout — the pod operator pastes this straight into
    # ATTRIBUTE_TRAINING_PLAN.md or a session log.
    print()
    print(f"### Fit classifier eval — {args.checkpoint.name} ({args.split})")
    print()
    print(f"- samples:           {len(dataset):,}")
    print(f"- val top-1:         {stats['top1']:.3f}")
    print(f"- val macro-F1:      {stats['macro_f1']:.3f}")
    hc = stats["high_conf"]
    print(
        f"- hi-conf (≥{hc['threshold']:.2f}): "
        f"{hc['count']:,} samples, realized acc {hc['realized_acc']:.3f}"
    )
    print()
    print(format_markdown_table(stats["per_class"], TRAINABLE_FIT_LABELS))
    print()
    print(f"artifacts → {args.report_dir.resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
