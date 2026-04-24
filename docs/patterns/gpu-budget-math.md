# Pattern: GPU Budget Math (Smoke + Production + Buffer)

**Problem.** You have a fixed GPU credit (a $10 voucher, a $30 prepay, a $200 grant). You need to fine-tune a model. The obvious split is "spend it all on the big run." That's wrong. A single large run that crashes at 80% burns the credit and leaves you with nothing to retry.

**Solution.** Three-way split: **smoke + production + retry buffer**. Size each against the credit. Ruthlessly rule out GPU SKUs that leave < 2× the expected debug cost as buffer.

---

## The three-way split

### Smoke run (~10% of credit)

Small dataset subset, small model, short epochs. The point is NOT to train a usable model — it's to prove the **pipeline** runs end-to-end without human in the loop: dataset prep → training → checkpoint save → export → artifact transfer.

A red smoke is a cheap lesson (diagnose, fix, rerun). A green smoke unblocks the production run.

Typical sizing: 500–2000 images, 1–3 epochs, 1–3 hours on a mid-tier GPU.

### Production run (~20–60% of credit)

Full dataset, real hyperparameters, enough epochs to hit your target metric. This is where real accuracy happens.

Size based on:
- Dataset size × epochs × throughput
- Whatever hyperparameter recipe the literature or the library's own README recommends
- Rounded up 20% for evaluation overhead and the occasional stall

### Retry buffer (≥ 30% of credit)

The money you haven't spent. Reserved for:
- A second production run if the first lands below target
- Debugging excursions if something misbehaves mid-train
- A hyperparameter ablation (one or two alternate runs)

**A credit ceiling that leaves < 2× the production cost as buffer is too small for that GPU SKU.** Downshift.

---

## Worked example: $30 credit for RF-DETR-Seg-Small fine-tune

RunPod community-cloud hourly rates at time of planning:
- RTX 4090 24 GB: $0.44/hr
- A100 40 GB: $1.19/hr
- H100 80 GB: $2.49/hr

Estimated wall-clock for Fashionpedia fine-tune (46k images, 10 epochs, resolution 1024, effective batch 8):
- RTX 4090 @ batch 4 + grad-accum 2: ~13 hrs
- A100 40 GB @ batch 8: ~10 hrs
- H100 80 GB @ batch 8: ~10 hrs (I/O bound, not compute bound, at this dataset size)

Smoke @ 500 images × 2 epochs × resolution 768 on any SKU is ~2 hrs on a 4090, less elsewhere.

### Candidate budgets

| SKU | Smoke cost | Production cost | Buffer remaining | Verdict |
|---|---|---|---|---|
| RTX 4090 | $0.88 | $5.72 | **$23.40** | **WIN** — 4× buffer vs production |
| A100 40 GB | $2.38 | $11.90 | $15.72 | OK, but buffer < 2× production; tight |
| H100 80 GB | $4.98 | $24.90 | **$0.12** | **RULE OUT** — no retry margin |

At $30, the H100 is infeasible for this project even though it's technically faster. The 4090 wins on risk-adjusted basis: you can afford three full production retries if needed.

If the credit were $100, the H100 math inverts (buffer $70, retry feasible), and the wall-clock savings matter more than the per-hour price premium.

### Effective batch trick

The 4090 has 24 GB VRAM. Batch 8 at resolution 1024² typically OOMs. **Gradient accumulation** gives you the gradient signal of a bigger batch without the memory spike: batch 4 + grad-accum 2 = effective batch 8, same optimizer step behavior.

This trick let the 4090 be competitive with the A100 at 40% of the hourly rate. It's usually the right move when VRAM is the bottleneck.

---

## Decision framework

When sizing a new GPU training run against a credit ceiling:

1. **List candidate GPU SKUs** with hourly rates (call the provider's API or scrape the dashboard).
2. **Estimate wall-clock per SKU** using throughput benchmarks from the model card or a prior training log. Round up 20%.
3. **Compute smoke + production costs** per SKU.
4. **Reject any SKU where `buffer < 2 × production`.** You can't afford to retry.
5. **Of the surviving SKUs, pick the cheapest-per-hour** (usually also the smallest VRAM that still fits your effective batch size).
6. **Plan the grad-accum split** so effective batch × grad-accum is the target batch size the hyperparam recipe assumes.

## The gates

Between smoke and production:
- [ ] smoke exited 0
- [ ] checkpoint file exists and is non-empty
- [ ] export pipeline produced a non-empty artifact
- [ ] artifact is reachable from the local machine (scp succeeds)

Between production mid-run and completion:
- [ ] val metric at early epoch > 0 (labels are flowing)
- [ ] val metric at mid-run > small positive threshold (training alive, trajectory plausible)
- [ ] val metric at late epoch ≥ target (or at least close enough that one more retry could hit it)

Any red → stop, use some of the buffer to diagnose, re-run only the step that broke.

## Anti-patterns

- **"Let's just run the big one and see."** You burn the credit. When it crashes at 80%, you have nothing left.
- **Spending smoke money on the same hyperparameters as production.** The smoke exists to validate the *pipeline*, not the model. Use smaller + shorter + cheaper hyperparams so you get quick feedback.
- **Ignoring the retry buffer.** Target mAP is a hope, not a promise. Budget for one retry minimum.
- **Premium SKUs with no buffer.** If an H100 leaves < 2× production as buffer, a 4090 with 4× buffer is the correct call even though it's slower.
- **Skipping the smoke "just this once."** The one time you skip is the time the pipeline breaks at minute 90 of a 10-hour run.

## When to size DIFFERENTLY

- **Research context with big quota.** If your credit is effectively unlimited, skip the smoke if the pipeline is proven — you already paid that de-risking cost in a previous project.
- **Known-good reproduction.** If you're re-running a recipe that worked last week with zero code changes, the smoke is redundant.
- **Time pressure.** If the deadline matters more than cost, a premium SKU with no retry margin MAY be right — but commit to that choice explicitly rather than stumbling into it.

## Source

This math was the Phase 1 / Phase 2 budget in the 2026-04-18 RunPod training plan for the Wardrobe Re-Do project ($30 credit → 4090 selection, $2 smoke + $6 production + $22 buffer). The SKU names are specific; the framework is general.
