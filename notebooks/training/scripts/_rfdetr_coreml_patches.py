"""Monkey-patches applied to rfdetr before Core ML tracing.

Why this exists
---------------
`coremlc` (the Core ML compiler baked into Xcode, and the runtime ML Program
validator) enforces a hard ``rank <= 5`` limit on tensor shapes inside ops
like reshape. RF-DETR-Seg's multi-scale deformable attention naturally
produces a rank-6 tensor at:

    sampling_offsets.view(N, Len_q, n_heads, n_levels, n_points, 2)

and then broadcasts with rank-6 reference_points/offset_normalizer to get a
rank-6 `sampling_locations` tensor that's consumed by
`ms_deform_attn_core_pytorch`.

coremltools 8.1 also enforces this at conversion time. Our first export
bypassed the conversion-time check via
`_mil_program.Program._check_invalid_tensor_rank = lambda self: None` —
which let the `.mlpackage` write but produced an artifact that `coremlc`
rejects at compile time:

    coremlc: error: ... in operation sampling_offsets_1:
    Rank of the shape parameter must be between 0 and 5 (inclusive) in reshape

The fix is graph-level: fold the `n_heads * n_levels` axes into one
dimension so the tensor flow stays rank-5. The weights are unaffected, so
no retraining is needed — we just re-trace and re-convert.

Layout convention
-----------------
`sampling_offsets` linear layer naturally writes bias/weights as
`(n_heads, n_levels, n_points, 2)` flattened to 1D (see
`MSDeformAttn._reset_parameters`). After the linear projection we therefore
use the view `(N, Len_q, HL, n_points, 2)` where `HL = n_heads * n_levels`
and the layout is heads-major, levels-minor (index = h*n_levels + l).
`reference_points` and `offset_normalizer` are tiled across `n_heads` to
match, which is a rank-5 expand+reshape — well within coremlc's limits.

Call this before instantiating any `RFDETRSegSmall` / `RFDETRSegLarge` —
the patches target class methods, so timing only matters relative to
importing rfdetr (which must happen first).
"""
from __future__ import annotations

import torch
import torch.nn.functional as F

from rfdetr.models.ops.modules import ms_deform_attn as _ms_mod
from rfdetr.models.ops.functions import ms_deform_attn_func as _ms_func


def _rank5_forward(
    self,
    query,
    reference_points,
    input_flatten,
    input_spatial_shapes,
    input_level_start_index,
    input_padding_mask=None,
):
    """Drop-in replacement for `MSDeformAttn.forward` that keeps the
    traced graph within rank-5. Semantically equivalent to the original
    — produces the same sampling_locations values, just reshaped.
    """
    N, Len_q, _ = query.shape
    N, Len_in, _ = input_flatten.shape
    assert (input_spatial_shapes[:, 0] * input_spatial_shapes[:, 1]).sum() == Len_in

    value = self.value_proj(input_flatten)
    if input_padding_mask is not None:
        value = value.masked_fill(input_padding_mask[..., None], float(0))

    HL = self.n_heads * self.n_levels
    sampling_offsets = self.sampling_offsets(query).view(
        N, Len_q, HL, self.n_points, 2
    )
    attention_weights = self.attention_weights(query).view(
        N, Len_q, self.n_heads, self.n_levels * self.n_points
    )

    if reference_points.shape[-1] == 2:
        # (n_levels, 2) in (w, h) order — matches the rank-6 original.
        offset_normalizer = torch.stack(
            [input_spatial_shapes[..., 1], input_spatial_shapes[..., 0]], -1
        )
        # Tile per-level normalizer across n_heads → (HL, 2).
        normalizer_hl = (
            offset_normalizer.unsqueeze(0)
            .expand(self.n_heads, -1, -1)
            .reshape(HL, 2)
        )
        # Tile per-level reference_points across n_heads → (N, Len_q, HL, 2).
        ref_hl = (
            reference_points.unsqueeze(2)
            .expand(N, Len_q, self.n_heads, self.n_levels, 2)
            .reshape(N, Len_q, HL, 2)
        )
        sampling_locations = (
            ref_hl[:, :, :, None, :]
            + sampling_offsets / normalizer_hl[None, None, :, None, :]
        )
    elif reference_points.shape[-1] == 4:
        ref_center = reference_points[..., :2]
        ref_size = reference_points[..., 2:]
        ref_center_hl = (
            ref_center.unsqueeze(2)
            .expand(N, Len_q, self.n_heads, self.n_levels, 2)
            .reshape(N, Len_q, HL, 2)
        )
        ref_size_hl = (
            ref_size.unsqueeze(2)
            .expand(N, Len_q, self.n_heads, self.n_levels, 2)
            .reshape(N, Len_q, HL, 2)
        )
        sampling_locations = (
            ref_center_hl[:, :, :, None, :]
            + sampling_offsets
            / self.n_points
            * ref_size_hl[:, :, :, None, :]
            * 0.5
        )
    else:
        raise ValueError(
            "Last dim of reference_points must be 2 or 4, but get {} instead.".format(
                reference_points.shape[-1]
            )
        )
    # sampling_locations shape: (N, Len_q, HL, n_points, 2) — rank 5.
    attention_weights = F.softmax(attention_weights, -1)

    value = (
        value.transpose(1, 2)
        .contiguous()
        .view(N, self.n_heads, self.d_model // self.n_heads, Len_in)
    )
    output = _rank5_core_pytorch(
        value,
        input_spatial_shapes,
        sampling_locations,
        attention_weights,
        n_heads=self.n_heads,
        n_levels=self.n_levels,
    )
    output = self.output_proj(output)
    return output


def _rank5_core_pytorch(
    value, value_spatial_shapes, sampling_locations, attention_weights,
    n_heads, n_levels,
):
    """Rank-5 variant of `ms_deform_attn_core_pytorch`.

    Expects `sampling_locations` shape (B, Len_q, HL, P, 2) with
    HL = n_heads * n_levels and heads-major layout (index h*n_levels + l).
    """
    B, n_heads_v, head_dim, _ = value.shape
    _, Len_q, HL, P, _ = sampling_locations.shape
    assert n_heads_v == n_heads
    assert HL == n_heads * n_levels

    value_list = value.split([H * W for H, W in value_spatial_shapes], dim=3)
    sampling_grids = 2 * sampling_locations - 1  # (B, Len_q, HL, P, 2)

    sampling_value_list = []
    for lid_, (H, W) in enumerate(value_spatial_shapes):
        value_l_ = value_list[lid_].reshape(B * n_heads, head_dim, H, W)
        # For level lid_, pull strided slice across heads:
        # indices [lid_, lid_ + n_levels, lid_ + 2*n_levels, ...].
        sampling_grid_l_ = sampling_grids[:, :, lid_::n_levels, :, :]
        # (B, Len_q, n_heads, P, 2) -> (B, n_heads, Len_q, P, 2) -> (B*n_heads, Len_q, P, 2)
        sampling_grid_l_ = sampling_grid_l_.transpose(1, 2).flatten(0, 1)
        sampling_value_l_ = F.grid_sample(
            value_l_,
            sampling_grid_l_,
            mode="bilinear",
            padding_mode="zeros",
            align_corners=False,
        )
        sampling_value_list.append(sampling_value_l_)

    # attention_weights: (B, Len_q, n_heads, L*P) -> (B*n_heads, 1, Len_q, L*P)
    attention_weights = attention_weights.transpose(1, 2).reshape(
        B * n_heads, 1, Len_q, n_levels * P
    )
    # Stack per-level outputs: (B*n_heads, head_dim, Len_q, L, P) -> (..., L*P).
    sv = torch.stack(sampling_value_list, dim=-2).flatten(-2)
    output = (sv * attention_weights).sum(-1).view(B, n_heads * head_dim, Len_q)
    return output.transpose(1, 2).contiguous()


def apply_rank5_patches() -> None:
    """Swap in the rank-5 forward pass + core function. Idempotent."""
    _ms_mod.MSDeformAttn.forward = _rank5_forward
    _ms_func.ms_deform_attn_core_pytorch = _rank5_core_pytorch
