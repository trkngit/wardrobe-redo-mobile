"""Phase 3 — Single-head MobileNetV3-Small fit classifier.

Trains on the manifest produced by `prepare_attribute_dataset.py`.
Option C scope: fit-only, 5 classes (oversized, relaxed, regular, slim,
cropped). No texture head — see
`docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md`
Section 0 and `BLOCKERS.md#D-2`.

Produces:
    <out_dir>/attr_last.pth        — latest epoch checkpoint
    <out_dir>/attr_best.pth        — best val macro-F1 checkpoint
    <out_dir>/attr_metrics.json    — per-epoch train/val stats + per-class F1
    <out_dir>/run_summary.json     — top-level run metadata (for auditing)

Smoke recipe (laptop CPU, ~2 min, proves the script wires end-to-end):
    # After running the dataset preparer with --max-train 500 --max-val 100.
    python train_attributes.py \\
        --dataset-root ./data/attr-dataset \\
        --out ./checkpoints/attr-smoke \\
        --epochs 2 \\
        --batch-size 32 \\
        --smoke

Production recipe (RunPod H100, ~3 hrs for 20 epochs):
    python train_attributes.py \\
        --dataset-root /workspace/training/attr-dataset \\
        --out /workspace/training/attr-runs/$(date +%Y%m%d-%H%M) \\
        --epochs 20 \\
        --batch-size 128 \\
        --num-workers 8

Design notes:
  - Backbone: `torchvision.models.mobilenet_v3_small` with ImageNet
    weights. Kept in torchvision (no new dep) instead of timm per
    `notebooks/training/requirements.txt`.
  - Loss: class-weighted cross-entropy. Weights =
    `clip(max_count / class_count, 1.0, 10.0)` (BLOCKERS.md#P2-3). Clamp
    at 10 prevents the 670-annotation `oversized` class from dominating
    the gradient; raw 37× weighting fits to noise otherwise.
  - Sampler: `WeightedRandomSampler` with inverse-frequency weights so
    each training batch oversamples rare classes. Val stays unweighted
    so reported metrics are honest.
  - Best selection: val **macro-F1**, not top-1. Top-1 is gamed by the
    `regular` majority (~41% of the corpus).
  - Calibration: per-epoch bucketing of predictions by confidence into
    20 bins, with realized accuracy per bin. The conf ≥ 0.80 bucket
    is the one we care about (underwrites iOS pre-fill threshold).

See docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md
for the full Phase 3 contract (target metrics, failure modes,
export handoff).
"""
from __future__ import annotations

import argparse
import csv
import json
import random
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any

# Sibling-script import for the label contract.
sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    import numpy as np
    import torch
    import torch.nn as nn
    from PIL import Image
    from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler
    from torchvision import transforms
    from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small
    from tqdm import tqdm
except ImportError as exc:
    print(
        f"Missing dependency: {exc}. Install with:\n"
        f"  pip install -r notebooks/training/requirements.txt"
    )
    sys.exit(1)

from fashionpedia_attr_to_ios_enum import (
    TRAINABLE_FIT_LABELS,
    fit_label_to_index,
)


# -- Constants -----------------------------------------------------------

NUM_CLASSES = len(TRAINABLE_FIT_LABELS)
assert NUM_CLASSES == 5, (
    f"TRAINABLE_FIT_LABELS has {NUM_CLASSES} entries; expected 5. "
    f"Option C sign-off locked the 5-class fit-only scope — if this "
    f"changed, update BLOCKERS.md and the iOS decode side together."
)

# ImageNet normalization — matches the pretrained backbone's training
# distribution. Deviating kills transfer performance.
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]

CROP_SIZE = 224  # MobileNetV3-Small input; matches preparer's output.

# Class-weight clamp bounds per BLOCKERS.md#P2-3.
WEIGHT_MIN = 1.0
WEIGHT_MAX = 10.0

# Calibration buckets: we care about how well conf≥0.80 predictions
# realize accuracy. 20 bins gives a 5-pt resolution on the [0, 1] axis.
CALIBRATION_BINS = 20


# -- Dataset -------------------------------------------------------------


class FitManifestDataset(Dataset):
    """Loads (image, fit_label_idx) pairs from the preparer's manifest.

    Rows are filtered by split up-front so __len__ and __getitem__ are
    cheap. Images are read lazily and transformed on-the-fly.

    Invariants:
      - `manifest.csv` paths are RELATIVE to `dataset_root` (P2-7).
      - `fit_label_idx` values come straight from the preparer and
        match `TRAINABLE_FIT_LABELS` by index.
    """

    def __init__(
        self,
        dataset_root: Path,
        split: str,
        transform: transforms.Compose,
    ) -> None:
        self.dataset_root = dataset_root
        self.split = split
        self.transform = transform
        self.rows = self._load_rows()

    def _load_rows(self) -> list[dict[str, Any]]:
        manifest_path = self.dataset_root / "manifest.csv"
        if not manifest_path.exists():
            raise FileNotFoundError(
                f"{manifest_path} not found. Run prepare_attribute_dataset.py"
                f" first."
            )
        rows: list[dict[str, Any]] = []
        with open(manifest_path, newline="") as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                if row["split"] != self.split:
                    continue
                rows.append(
                    {
                        "image_path": row["image_path"],
                        "label_idx": int(row["fit_label_idx"]),
                        "label_name": row["fit_label_name"],
                    }
                )
        if not rows:
            raise RuntimeError(
                f"Manifest has zero rows for split='{self.split}'. "
                f"Check that the preparer ran with this split enabled."
            )
        return rows

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, int]:
        row = self.rows[idx]
        image_path = self.dataset_root / row["image_path"]
        # Preparer emits RGB JPEGs; convert defensively in case of alpha.
        image = Image.open(image_path).convert("RGB")
        tensor = self.transform(image)
        return tensor, row["label_idx"]

    def label_counter(self) -> Counter:
        counter: Counter = Counter()
        for row in self.rows:
            counter[row["label_name"]] += 1
        return counter


# -- Augmentations -------------------------------------------------------


def build_train_transform() -> transforms.Compose:
    """Train-time augmentations.

    Mild by design — Fashionpedia crops already have varied backgrounds
    and poses; aggressive aug would degrade the fit signal (e.g., a
    crop that's heavily rotated loses "oversized" cues).
    """
    return transforms.Compose(
        [
            transforms.Resize(CROP_SIZE),
            transforms.CenterCrop(CROP_SIZE),
            transforms.RandomHorizontalFlip(p=0.5),
            transforms.ColorJitter(brightness=0.2, contrast=0.2, saturation=0.2),
            transforms.ToTensor(),
            transforms.Normalize(mean=IMAGENET_MEAN, std=IMAGENET_STD),
            transforms.RandomErasing(p=0.25, scale=(0.02, 0.15)),
        ]
    )


def build_val_transform() -> transforms.Compose:
    """Val-time transforms — deterministic only."""
    return transforms.Compose(
        [
            transforms.Resize(CROP_SIZE),
            transforms.CenterCrop(CROP_SIZE),
            transforms.ToTensor(),
            transforms.Normalize(mean=IMAGENET_MEAN, std=IMAGENET_STD),
        ]
    )


# -- Model ---------------------------------------------------------------


def build_model(num_classes: int = NUM_CLASSES) -> nn.Module:
    """MobileNetV3-Small with the classifier head swapped to `num_classes`.

    The last Linear in torchvision's `classifier` block maps 1024 → 1000
    (ImageNet). We swap it to 1024 → num_classes while keeping the
    `nn.Hardswish()` + `nn.Dropout` before it intact.
    """
    weights = MobileNet_V3_Small_Weights.IMAGENET1K_V1
    model = mobilenet_v3_small(weights=weights)
    in_features = model.classifier[-1].in_features
    model.classifier[-1] = nn.Linear(in_features, num_classes)
    return model


# -- Class weights + sampler --------------------------------------------


def compute_class_weights(
    label_counter: Counter,
    labels: list[str] = TRAINABLE_FIT_LABELS,
) -> torch.Tensor:
    """`max_count / class_count`, clipped to [WEIGHT_MIN, WEIGHT_MAX].

    Returns a tensor indexed by the same order as `TRAINABLE_FIT_LABELS`.
    Missing classes (count == 0) get WEIGHT_MAX so a truly empty class
    doesn't produce NaN gradients during training.
    """
    max_count = max(label_counter.values()) if label_counter else 0
    weights: list[float] = []
    for label in labels:
        count = label_counter.get(label, 0)
        if count == 0:
            weights.append(WEIGHT_MAX)
            continue
        w = max_count / count
        weights.append(float(min(max(w, WEIGHT_MIN), WEIGHT_MAX)))
    return torch.tensor(weights, dtype=torch.float32)


def build_sampler(
    dataset: FitManifestDataset,
    label_counter: Counter,
) -> WeightedRandomSampler:
    """Inverse-frequency sampler. Each sample's weight = 1 / count[label].

    Draws len(dataset) samples per epoch with replacement — so an
    epoch is one "pass" in expectation but rare classes appear more
    often.
    """
    per_label_weight = {
        label: 1.0 / max(label_counter.get(label, 1), 1)
        for label in TRAINABLE_FIT_LABELS
    }
    sample_weights = [
        per_label_weight[row["label_name"]] for row in dataset.rows
    ]
    return WeightedRandomSampler(
        weights=sample_weights,
        num_samples=len(dataset),
        replacement=True,
    )


# -- Train / eval loops --------------------------------------------------


def train_one_epoch(
    model: nn.Module,
    loader: DataLoader,
    optimizer: torch.optim.Optimizer,
    scheduler: Any,
    criterion: nn.Module,
    device: torch.device,
    scaler: "torch.amp.GradScaler",
    use_amp: bool,
    epoch: int,
    total_epochs: int,
) -> dict[str, float]:
    model.train()
    running_loss = 0.0
    correct = 0
    seen = 0
    pbar = tqdm(
        loader,
        desc=f"train {epoch + 1}/{total_epochs}",
        leave=False,
    )
    for images, labels in pbar:
        images = images.to(device, non_blocking=True)
        labels = labels.to(device, non_blocking=True)
        optimizer.zero_grad(set_to_none=True)
        with torch.autocast(
            device_type=device.type, enabled=use_amp, dtype=torch.float16
        ):
            logits = model(images)
            loss = criterion(logits, labels)
        if use_amp:
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
        else:
            loss.backward()
            optimizer.step()

        running_loss += loss.item() * images.size(0)
        preds = logits.argmax(dim=1)
        correct += (preds == labels).sum().item()
        seen += images.size(0)
        pbar.set_postfix(
            loss=f"{running_loss / max(seen, 1):.3f}",
            acc=f"{correct / max(seen, 1):.3f}",
        )

    if scheduler is not None:
        scheduler.step()

    return {
        "loss": running_loss / max(seen, 1),
        "acc": correct / max(seen, 1),
        "lr": optimizer.param_groups[0]["lr"],
    }


def evaluate(
    model: nn.Module,
    loader: DataLoader,
    criterion: nn.Module,
    device: torch.device,
) -> dict[str, Any]:
    """Val-set eval — returns top-1, macro-F1, per-class F1, confusion
    matrix, and calibration buckets.

    Calibration tells us how often the model is right when it claims
    confidence. The conf≥0.80 bucket realized-accuracy is the single
    metric that decides whether we can ship the pre-fill threshold.
    """
    model.eval()
    total_loss = 0.0
    seen = 0
    all_preds: list[int] = []
    all_labels: list[int] = []
    all_confs: list[float] = []

    with torch.no_grad():
        for images, labels in tqdm(loader, desc="val", leave=False):
            images = images.to(device, non_blocking=True)
            labels = labels.to(device, non_blocking=True)
            logits = model(images)
            loss = criterion(logits, labels)
            probs = torch.softmax(logits, dim=1)
            confs, preds = probs.max(dim=1)
            total_loss += loss.item() * images.size(0)
            seen += images.size(0)
            all_preds.extend(preds.cpu().tolist())
            all_labels.extend(labels.cpu().tolist())
            all_confs.extend(confs.cpu().tolist())

    preds_np = np.asarray(all_preds, dtype=np.int64)
    labels_np = np.asarray(all_labels, dtype=np.int64)
    confs_np = np.asarray(all_confs, dtype=np.float32)

    top1 = float((preds_np == labels_np).mean()) if seen else 0.0

    per_class: dict[str, dict[str, float]] = {}
    f1s: list[float] = []
    for idx, label_name in enumerate(TRAINABLE_FIT_LABELS):
        tp = int(((preds_np == idx) & (labels_np == idx)).sum())
        fp = int(((preds_np == idx) & (labels_np != idx)).sum())
        fn = int(((preds_np != idx) & (labels_np == idx)).sum())
        support = int((labels_np == idx).sum())
        precision = tp / (tp + fp) if (tp + fp) else 0.0
        recall = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = (
            2 * precision * recall / (precision + recall)
            if (precision + recall)
            else 0.0
        )
        per_class[label_name] = {
            "precision": precision,
            "recall": recall,
            "f1": f1,
            "support": support,
        }
        f1s.append(f1)

    macro_f1 = float(sum(f1s) / len(f1s)) if f1s else 0.0

    confusion = np.zeros((NUM_CLASSES, NUM_CLASSES), dtype=np.int64)
    for t, p in zip(labels_np.tolist(), preds_np.tolist()):
        confusion[t, p] += 1

    # Calibration buckets: for each conf bin, record count + realized
    # accuracy. Phase 4 / Phase 9 gate on the conf≥0.80 bin.
    bin_edges = np.linspace(0.0, 1.0, CALIBRATION_BINS + 1)
    calibration: list[dict[str, Any]] = []
    correct_np = (preds_np == labels_np).astype(np.int64)
    for i in range(CALIBRATION_BINS):
        lo, hi = bin_edges[i], bin_edges[i + 1]
        mask = (confs_np >= lo) & (confs_np < hi if i < CALIBRATION_BINS - 1 else confs_np <= hi)
        count = int(mask.sum())
        realized = float(correct_np[mask].mean()) if count else 0.0
        calibration.append(
            {"bin_lo": float(lo), "bin_hi": float(hi), "count": count, "realized_acc": realized}
        )

    # High-confidence summary: the single number we care about.
    high_conf_mask = confs_np >= 0.80
    high_conf_count = int(high_conf_mask.sum())
    high_conf_acc = (
        float(correct_np[high_conf_mask].mean()) if high_conf_count else 0.0
    )

    return {
        "loss": total_loss / max(seen, 1),
        "top1": top1,
        "macro_f1": macro_f1,
        "per_class": per_class,
        "confusion": confusion.tolist(),
        "calibration": calibration,
        "high_conf": {
            "threshold": 0.80,
            "count": high_conf_count,
            "realized_acc": high_conf_acc,
        },
    }


# -- Checkpoints ---------------------------------------------------------


def save_checkpoint(
    path: Path,
    model: nn.Module,
    optimizer: torch.optim.Optimizer,
    scheduler: Any,
    epoch: int,
    metrics: dict[str, Any],
) -> None:
    payload = {
        "model": model.state_dict(),
        "optimizer": optimizer.state_dict(),
        "scheduler": scheduler.state_dict() if scheduler is not None else None,
        "epoch": epoch,
        "metrics": metrics,
        "labels": TRAINABLE_FIT_LABELS,
    }
    torch.save(payload, path)


# -- CLI -----------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dataset-root", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--epochs", type=int, default=20)
    p.add_argument("--batch-size", type=int, default=128)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--weight-decay", type=float, default=1e-4)
    p.add_argument("--warmup-epochs", type=int, default=1)
    p.add_argument("--num-workers", type=int, default=4)
    p.add_argument(
        "--no-amp",
        action="store_true",
        help="Disable mixed-precision. Default is autocast on CUDA, off on CPU.",
    )
    p.add_argument(
        "--resume",
        type=Path,
        default=None,
        help="Resume from an attr_last.pth checkpoint.",
    )
    p.add_argument("--seed", type=int, default=0)
    p.add_argument(
        "--smoke",
        action="store_true",
        help=(
            "Smoke-run mode: 1–2 epochs, smaller log cadence, no AMP. Use "
            "together with --epochs 2 --batch-size 32 against a subset "
            "dataset (preparer with --max-train 500 --max-val 100)."
        ),
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)

    device = torch.device(
        "cuda" if torch.cuda.is_available()
        else ("mps" if torch.backends.mps.is_available() else "cpu")
    )
    use_amp = (not args.no_amp) and device.type == "cuda" and not args.smoke

    # Datasets
    train_tf = build_train_transform()
    val_tf = build_val_transform()
    train_ds = FitManifestDataset(args.dataset_root, "train", train_tf)
    val_ds = FitManifestDataset(args.dataset_root, "val", val_tf)

    # Class weights + sampler rely on the training split's label counts.
    train_counter = train_ds.label_counter()
    val_counter = val_ds.label_counter()
    class_weights = compute_class_weights(train_counter).to(device)
    sampler = build_sampler(train_ds, train_counter)

    train_loader = DataLoader(
        train_ds,
        batch_size=args.batch_size,
        sampler=sampler,
        num_workers=args.num_workers,
        pin_memory=(device.type == "cuda"),
        drop_last=True,
    )
    val_loader = DataLoader(
        val_ds,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.num_workers,
        pin_memory=(device.type == "cuda"),
    )

    # Model + optimizer + scheduler
    model = build_model().to(device)
    optimizer = torch.optim.AdamW(
        model.parameters(), lr=args.lr, weight_decay=args.weight_decay
    )
    # Linear warmup → cosine decay. warmup_epochs=1 is tiny but the fit
    # task is small enough that a long warmup wastes cycles.
    def lr_lambda(current_epoch: int) -> float:
        if current_epoch < args.warmup_epochs:
            return float(current_epoch + 1) / max(args.warmup_epochs, 1)
        progress = (current_epoch - args.warmup_epochs) / max(
            args.epochs - args.warmup_epochs, 1
        )
        return 0.5 * (1.0 + float(np.cos(np.pi * progress)))

    scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer, lr_lambda)
    criterion = nn.CrossEntropyLoss(weight=class_weights)

    # GradScaler lives across epochs — its scale factor adapts with
    # training. Re-creating per-epoch throws that calibration away.
    scaler = torch.amp.GradScaler(device.type, enabled=use_amp)

    start_epoch = 0
    best_macro_f1 = -1.0
    metrics_log: list[dict[str, Any]] = []

    if args.resume and args.resume.exists():
        payload = torch.load(args.resume, map_location=device)
        model.load_state_dict(payload["model"])
        optimizer.load_state_dict(payload["optimizer"])
        if payload.get("scheduler") is not None:
            scheduler.load_state_dict(payload["scheduler"])
        start_epoch = int(payload["epoch"]) + 1
        print(f"Resumed from {args.resume} at epoch {start_epoch}")

    # Banner — matches train.py style so a pod operator reading the log
    # sees a familiar layout.
    print("=" * 60)
    print("MobileNetV3-Small fit classifier (Option C, 5 classes)")
    print("=" * 60)
    print(f"  device         {device} ({'amp' if use_amp else 'fp32'})")
    print(f"  dataset root   {args.dataset_root}")
    print(f"  train / val    {len(train_ds):,} / {len(val_ds):,}")
    print(f"  classes        {TRAINABLE_FIT_LABELS}")
    print(f"  train counts   {dict(train_counter.most_common())}")
    print(f"  val counts     {dict(val_counter.most_common())}")
    print(f"  class weights  {[round(float(w), 3) for w in class_weights.tolist()]}")
    print(f"  epochs         {args.epochs} (start {start_epoch})")
    print(f"  batch size     {args.batch_size}")
    print(f"  lr             {args.lr} (warmup {args.warmup_epochs})")
    print(f"  out            {args.out}")
    print()

    t0 = time.time()
    for epoch in range(start_epoch, args.epochs):
        train_stats = train_one_epoch(
            model=model,
            loader=train_loader,
            optimizer=optimizer,
            scheduler=scheduler,
            criterion=criterion,
            device=device,
            scaler=scaler,
            use_amp=use_amp,
            epoch=epoch,
            total_epochs=args.epochs,
        )
        val_stats = evaluate(
            model=model, loader=val_loader, criterion=criterion, device=device
        )

        epoch_row = {
            "epoch": epoch,
            "train": train_stats,
            "val": {
                "loss": val_stats["loss"],
                "top1": val_stats["top1"],
                "macro_f1": val_stats["macro_f1"],
                "high_conf": val_stats["high_conf"],
                "per_class": val_stats["per_class"],
            },
        }
        metrics_log.append(epoch_row)

        # Per-class F1 summary line — the single most informative log row.
        pc = val_stats["per_class"]
        pc_fmt = " ".join(
            f"{name[:3]}={pc[name]['f1']:.2f}" for name in TRAINABLE_FIT_LABELS
        )
        print(
            f"epoch {epoch + 1:>2}/{args.epochs} "
            f"— train loss {train_stats['loss']:.3f} acc {train_stats['acc']:.3f}"
            f" | val loss {val_stats['loss']:.3f} top1 {val_stats['top1']:.3f}"
            f" macroF1 {val_stats['macro_f1']:.3f}"
            f" | {pc_fmt}"
            f" | hi-conf {val_stats['high_conf']['count']}@{val_stats['high_conf']['realized_acc']:.3f}"
        )

        # Save last every epoch; save best only on macro-F1 improvement.
        save_checkpoint(
            args.out / "attr_last.pth",
            model,
            optimizer,
            scheduler,
            epoch,
            val_stats,
        )
        if val_stats["macro_f1"] > best_macro_f1:
            best_macro_f1 = val_stats["macro_f1"]
            save_checkpoint(
                args.out / "attr_best.pth",
                model,
                optimizer,
                scheduler,
                epoch,
                val_stats,
            )
            print(f"  ✓ new best macro-F1 {best_macro_f1:.3f} — saved attr_best.pth")

        # Flush metrics per epoch so a ctrl-C / pod yank leaves a
        # readable metrics.json behind.
        with open(args.out / "attr_metrics.json", "w") as fh:
            json.dump(metrics_log, fh, indent=2)

    elapsed = time.time() - t0
    summary = {
        "scope": "Option C (fit-only, single-head)",
        "num_classes": NUM_CLASSES,
        "labels": TRAINABLE_FIT_LABELS,
        "epochs_run": args.epochs - start_epoch,
        "batch_size": args.batch_size,
        "lr": args.lr,
        "best_macro_f1": best_macro_f1,
        "duration_seconds": elapsed,
        "dataset_root": str(args.dataset_root),
        "torch_version": torch.__version__,
        "torchvision_version": getattr(
            __import__("torchvision"), "__version__", "unknown"
        ),
    }
    with open(args.out / "run_summary.json", "w") as fh:
        json.dump(summary, fh, indent=2)
    print(
        f"\nDone in {elapsed / 60:.1f} min. Best val macro-F1 = {best_macro_f1:.3f}"
    )
    print(f"Checkpoints + metrics at {args.out.resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
