# Session Log — 2026-04-18 — Training Scripts + rfdetr 1.4 API Alignment

**Branch:** `feature/photo-extraction-engine`
**Shipped commits:** `c2581ac` (runbook + scripts), `8cbf350` (rfdetr 1.4 API alignment), `f2e9a77` (Section 0.1 + 0.2 plan mirror), `2ee02f1` (INDEX refresh), this commit.
**Next action:** Phase 1 RunPod pod boot, in a fresh Claude Code session. See `docs/plans/2026-04-18-multi-garment-detection.md` Section 0.1.

---

## 1. Why this session existed

Prior work on this branch (Commits 0–8, see plan execution log) shipped all iOS-side plumbing for multi-garment detection behind `FeatureFlags.isMultiGarmentEnabled` (default OFF). The flag-flip (Commit 9) is blocked on a trained `RFDETRSegFashion.mlpackage`. The training notebook (`notebooks/training/2026-04-multi-garment.ipynb`) was a scaffold with commented-out cells — not runnable as-is. This session's job was to turn that scaffold into a pipeline that survives contact with a real GPU pod without burning the user's $30 RunPod credit on preventable bugs.

The user's standing directive from the original planning cycle:
> "come up with plans and courses of actions that will reduce the processes of debugging and save both time and token use"

So the engineering discipline was: **fail at $0 before failing at $X/hr**.

---

## 2. What shipped

### 2.1 `c2581ac` — RunPod $30 runbook + runnable training scripts

Replaced the scaffold with four real scripts + a runbook:

| File | Purpose |
|---|---|
| `notebooks/training/scripts/probe_env.py` | CPU-only laptop probe: validates all pinned imports, introspects rfdetr API surface, streams one HF Fashionpedia record, round-trips `torch.jit.trace`, round-trips `coremltools.convert`, imports the 6-bit palettizer. 6 checks, exit 0 iff all green. Cost per run: $0. |
| `notebooks/training/scripts/prepare_fashionpedia.py` | Downloads Fashionpedia from **CVDF S3 mirror** (has polygons — HF `detection-datasets/fashionpedia` mirror is detection-only), filters to the 33 main apparel classes, emits Roboflow-style COCO dirs (`train/_annotations.coco.json` + jpegs, same layout for `valid/`). `--max-train / --max-val` flags enable smoke-test subsets. |
| `notebooks/training/scripts/train.py` | Production training CLI wrapping `rfdetr.RFDETRSegSmall.train(...)`. Writes `run_summary.json` sidecar so post-run grading has structured numbers (duration, hyperparams, versions). |
| `notebooks/training/scripts/export_coreml.py` | Trace → `ct.convert(...)` → 6-bit k-means palettize (`per_grouped_channel`, group_size=16) → optional copy into `WardrobeReDo/Models/CoreML/`. Documents known DETR-family conversion failure modes (upsample_bicubic2d, dynamic shapes, FP16 softmax overflow). |
| `notebooks/training/RUNPOD_RUNBOOK.md` | Copy-paste two-phase plan: $2 smoke on RTX 4090 → $24 production on H100. Green-light checkpoints per epoch, failure-mode decision tree, teardown discipline. |

Budget ceiling at `c2581ac` time: smoke $2 + production $22-25 + reserve $3-6 = $27-31 against $30 credit.

### 2.2 `8cbf350` — rfdetr 1.4 API alignment

Running `probe_env.py` locally after `c2581ac` exposed a pattern: **every place we'd guessed at the rfdetr API was wrong**. rfdetr 1.4 wraps the actual `nn.Module` inside a thin `RFDETRSegSmall` class whose constructor accepts `**kwargs` routed through two Pydantic configs (`TrainConfig`, `ModelConfig`). The wrapper does NOT expose `.eval()`, `.load_state_dict()`, or any nn.Module surface — those live on the inner module retrieved via `.get_model()`.

Fixes by file:

**`probe_env.py::_check_rfdetr_api`** — swap method-existence assertion:
```python
# before
required_methods = ["train", "eval", "predict"]  # .eval() is nn.Module's, not the wrapper's

# after
required_methods = ["train", "export", "predict", "get_model"]
```
And introspect the Pydantic configs directly so upstream field renames are caught at $0:
```python
from rfdetr.config import ModelConfig, TrainConfig
train_fields = set(TrainConfig.model_fields.keys())
expected_train_fields = {
    "dataset_dir", "epochs", "batch_size", "grad_accum_steps", "lr",
    "output_dir", "num_workers", "dataset_file", "segmentation_head",
    "class_names",
}
assert not (expected_train_fields - train_fields), ...
model_fields = set(ModelConfig.model_fields.keys())
expected_model_fields = {
    "num_classes", "resolution", "segmentation_head", "pretrain_weights",
}
```

**`train.py`** — three interrelated fixes:
1. Removed `--max-steps-per-epoch` CLI flag entirely (TrainConfig has no such field). Smoke test now throttles via `prepare_fashionpedia.py --max-train 500 --max-val 100` (dataset-size throttle, not per-epoch step cap).
2. Moved `resolution` and `segmentation_head=True` into the `RFDETRSegSmall(...)` constructor — they're ModelConfig fields (shape the graph at construct time), not TrainConfig fields. The wrong placement silently loads wrong-shaped weights into wrong slots.
3. Added the seg-variant required kwargs to `train_kwargs`: `dataset_file="roboflow"`, `segmentation_head=True`, `class_names=FASHIONPEDIA_MAIN_CLASSES`.
4. Resume path: `model.get_model().load_state_dict(state["model"])` instead of the wrapper's nonexistent `.load_state_dict`.

**`export_coreml.py`**:
1. Deleted the `_inner_module()` helper that probed `("model", "detector", "net", "_model")` attributes — obsolete; use `model.get_model()` directly.
2. `_load_checkpoint(checkpoint, resolution)` — resolution must be passed so the inference graph matches training.
3. Constructor kwarg fix: `pretrain_weights=None` (real rfdetr 1.4 kwarg) not `pretrained=False` (invalid). `pretrain_weights=None` skips the ~129 MB COCO weight download at inference-time load — we're about to overwrite params with the fine-tuned checkpoint anyway.

**`RUNPOD_RUNBOOK.md`** — removed `--max-steps-per-epoch 250` from the smoke command; added a note that smoke throttling happens at dataset prep time (500 train / 100 val) instead of at training-step level.

### 2.3 Local probe green

After `8cbf350`:
```
============================================================
Wardrobe Re-Do — training env probe (local, CPU-only)
============================================================
[pinned imports resolve]          PASS  (torch 2.5.1, coremltools 8.1, rfdetr 1.4, datasets 3.1.0)
[rfdetr API surface]              PASS
[HF Fashionpedia schema]          PASS
[torch.jit.trace]                 PASS
[coremltools convert round-trip]  PASS
[coremltools palettizer import]   PASS
PASSED: 6/6 checks
```

### 2.4 `f2e9a77` + `2ee02f1` + this commit — documentation

- `f2e9a77` — mirrored plan Section 0.1 (RunPod execution plan) + 0.2 (this session-log + patterns handoff plan) into the canonical repo plan.
- `2ee02f1` — refreshed `docs/plans/INDEX.md` one-liner.
- **This commit** — the session log you're reading + raw-transcript pointer.

Next: a patterns commit, then push.

---

## 3. What we deliberately did NOT do

- **Did not boot a RunPod pod.** Execution deferred to a fresh Claude Code session. This session had already been compacted once; a fresh session starts with full context budget and warm prompt cache, which matters over the Phase 1 (~3 hr) + Phase 2 (~13 hr) horizon.
- **Did not flip `FeatureFlags.isMultiGarmentEnabled`.** That's Commit 9, blocked on a real trained `.mlpackage`.
- **Did not edit any iOS Swift code.** The iOS side is correct; pure artifact generation is the remaining work.
- **Did not copy the raw JSONL chat transcript into the repo.** It stays in Claude's project storage and is referenced by a pointer file — too large and privacy-noisy to commit.

---

## 4. Decision log (so future Claude doesn't re-derive)

| Decision | Choice | Reason |
|---|---|---|
| GPU for Phase 2 | RTX 4090, not H100 80GB | $30 credit ceiling. 4090 × $0.44/hr × 13 hr = $5.72 leaves $22 retry buffer; H100 leaves < $3 = no retry margin. Originally Section 2 favored H100 for throughput, but risk-adjusted math inverts it at this budget. |
| Pod creation tool | Chrome MCP | User logged into runpod.io in Chrome; DOM-aware clicks are faster + more reliable than computer-use pixels. |
| Training launch tool | Bash + SSH + tmux | Pod emits an SSH command; Bash runs it directly; tmux detaches the long train so a dropped SSH channel doesn't kill it. |
| Long log tailing | Monitor tool w/ grep filter | Stream `tail -f /root/train.log` filtered for `Epoch |mAP|Traceback|Error|CUDA out of memory|NaN|Killed` — silence never hides a crash. |
| Smoke throttle | Dataset-size cap, not per-step cap | rfdetr 1.4 TrainConfig has no per-epoch step limit. `prepare_fashionpedia.py --max-train 500 --max-val 100` produces a 500-image run that finishes in ~2 hrs on a 4090. |
| Effective batch size at production | batch 4 + grad-accum 2 = effective 8 | 4090's 24 GB VRAM OOMs at batch 8 × 1024². Gradient-accumulation gives the same gradient signal without the memory spike. |
| Phase 1 teardown | Stop (not Terminate) | Stop preserves disk for Phase 2 if we want to reuse the env; $0.10/GB/month × 50 GB ≈ $5/month, ignorable over days. |
| Phase 2 teardown | Terminate | Production run is expensive — don't leak hourly charges after scp. |
| Session strategy | Finish docs in this session, restart for execution | This session was compacted once; the 16+ hr execution horizon benefits more from a fresh context budget than from session continuity. tmux means session death isn't catastrophic. |

---

## 5. Reusable patterns extracted

This session generated patterns reusable across other app projects and GPU-training setups. See `docs/patterns/`:

- [`plan-storage-convention.md`](../patterns/plan-storage-convention.md) — mirror plan-mode scratch to `docs/plans/`; MEMORY.md pointer; INDEX.md format.
- [`probe-env-before-gpu-spend.md`](../patterns/probe-env-before-gpu-spend.md) — CPU-only API probe before GPU spend. Template = `notebooks/training/scripts/probe_env.py`.
- [`gpu-workflow-tool-split.md`](../patterns/gpu-workflow-tool-split.md) — Chrome MCP (authed web) + Bash (SSH/scp) + Monitor (log tail) + computer-use (native apps only).
- [`gpu-budget-math.md`](../patterns/gpu-budget-math.md) — sizing smoke + production + retry buffer against a fixed GPU credit.
- [`rfdetr-1.4-api-surface.md`](../patterns/rfdetr-1.4-api-surface.md) — `TrainConfig` + `ModelConfig` fields, `get_model()`, `pretrain_weights=None`, seg-variant kwargs.

---

## 6. Open items handed off to the next session

- **Phase 1 pod boot** — see Section 0.1 of `docs/plans/2026-04-18-multi-garment-detection.md`. Requires user chat confirmation before the Deploy click (first paid action, ~$2 expected).
- **Phase 2 production run** — blocked on a green Phase 1. ~$6 expected. Requires user chat confirmation before Deploy.
- **Commit 9 flag flip** — blocked on `.mlpackage` scp'd from Phase 2 pod back to local. Not this session's problem, not the next session's problem until Phase 2 is green.

---

## 7. Raw transcript

See [`2026-04-18-raw-transcript-pointer.md`](./2026-04-18-raw-transcript-pointer.md) for retrieval instructions. The JSONL transcript is not committed to the repo.

---

**Author:** Claude (Sonnet) in the Wardrobe Re-Do project
**User:** trknsrv@gmail.com
**Date:** 2026-04-18
