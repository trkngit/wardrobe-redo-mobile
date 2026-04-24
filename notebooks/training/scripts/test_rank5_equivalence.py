"""Sanity check: the rank-5 monkey-patch must produce bit-for-bit equal
sampling values as the original rank-6 `MSDeformAttn.forward`, for the
same deterministic inputs.

Run before burning pod time on a full export — if this drifts, the patch
is wrong and the exported model would ship bad outputs even if Core ML
accepts the graph.
"""
from __future__ import annotations

import copy
import sys

import torch


def main() -> int:
    torch.manual_seed(0)

    # Import rfdetr BEFORE patches so we can snapshot the original callables.
    from rfdetr.models.ops.modules import ms_deform_attn as _ms_mod
    from rfdetr.models.ops.functions import ms_deform_attn_func as _ms_func

    # Snapshot originals.
    original_forward = _ms_mod.MSDeformAttn.forward
    original_core = _ms_func.ms_deform_attn_core_pytorch

    # Build two identical modules with identical weights.
    torch.manual_seed(42)
    mod_a = _ms_mod.MSDeformAttn(d_model=256, n_levels=4, n_heads=8, n_points=4)
    mod_a.eval()
    mod_b = copy.deepcopy(mod_a)  # identical weights, same buffer state

    # Inputs shaped like they'd flow through the real decoder.
    N, Len_q = 2, 300
    spatial_shapes = torch.tensor(
        [[96, 96], [48, 48], [24, 24], [12, 12]], dtype=torch.long
    )  # (n_levels, 2)
    level_start_index = torch.cat(
        (spatial_shapes.new_zeros((1,)), spatial_shapes.prod(1).cumsum(0)[:-1])
    )
    Len_in = int(spatial_shapes.prod(1).sum().item())

    torch.manual_seed(1234)
    query = torch.randn(N, Len_q, 256)
    reference_points = torch.rand(N, Len_q, 4, 2)  # [0, 1]
    input_flatten = torch.randn(N, Len_in, 256)
    # Include a padding mask to exercise that branch.
    padding_mask = torch.zeros(N, Len_in, dtype=torch.bool)
    padding_mask[0, -100:] = True

    # Baseline: original (rank-6) forward.
    with torch.no_grad():
        out_orig = original_forward(
            mod_a, query, reference_points, input_flatten, spatial_shapes,
            level_start_index, padding_mask,
        )

    # Apply patches AFTER we've captured the baseline.
    sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
    from _rfdetr_coreml_patches import apply_rank5_patches
    apply_rank5_patches()

    with torch.no_grad():
        out_patched = mod_b(
            query, reference_points, input_flatten, spatial_shapes,
            level_start_index, padding_mask,
        )

    # Restore originals so we don't leak state to other tests in this process.
    _ms_mod.MSDeformAttn.forward = original_forward
    _ms_func.ms_deform_attn_core_pytorch = original_core

    max_abs = (out_orig - out_patched).abs().max().item()
    max_rel = (
        (out_orig - out_patched).abs()
        / (out_orig.abs().clamp_min(1e-8))
    ).max().item()

    print(f"reference_points=2D branch")
    print(f"  max abs diff: {max_abs:.3e}")
    print(f"  max rel diff: {max_rel:.3e}")

    # Also exercise the 4D reference-points branch (used for segmentation head).
    torch.manual_seed(5678)
    reference_points_4 = torch.rand(N, Len_q, 4, 4)
    # Reset patch state for the second round.
    original_forward_b = _ms_mod.MSDeformAttn.forward
    original_core_b = _ms_func.ms_deform_attn_core_pytorch

    with torch.no_grad():
        out_orig_4 = original_forward(
            mod_a, query, reference_points_4, input_flatten, spatial_shapes,
            level_start_index, padding_mask,
        )
    apply_rank5_patches()
    with torch.no_grad():
        out_patched_4 = mod_b(
            query, reference_points_4, input_flatten, spatial_shapes,
            level_start_index, padding_mask,
        )
    _ms_mod.MSDeformAttn.forward = original_forward_b
    _ms_func.ms_deform_attn_core_pytorch = original_core_b

    max_abs_4 = (out_orig_4 - out_patched_4).abs().max().item()
    max_rel_4 = (
        (out_orig_4 - out_patched_4).abs()
        / (out_orig_4.abs().clamp_min(1e-8))
    ).max().item()

    print(f"reference_points=4D branch")
    print(f"  max abs diff: {max_abs_4:.3e}")
    print(f"  max rel diff: {max_rel_4:.3e}")

    # Both branches must match within fp32 noise.
    tol = 1e-5
    ok = max_abs < tol and max_abs_4 < tol
    print(f"\nresult: {'PASS' if ok else 'FAIL'} (tol={tol:.1e})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
