"""Fashionpedia attribute → iOS enum lookup module.

This is the Python-side source of truth for the attribute mapping
decisions recorded in
`docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md`
§ Section 6. Both the dataset preparer and the training script consume
this module — keeping the mapping centralized makes drift obvious.

Under **Option C** (the reviewer-signed-off scope, see taxonomy § Section
0), the module maps:
  - 5 Fashionpedia fit/length attributes → `FitAttribute` cases
  - 12 Fashionpedia subcategory-hint attributes → `ClothingSubcategory` cases
    (consumed by the iOS rules layer, NOT by the trained classifier)
  - 0 texture attributes (intentionally empty — Fashionpedia carries no
    main-fabric-type labels)

The `FitAttribute.structured` case has no Fashionpedia source and is
therefore absent from `FIT_ATTR_ID_TO_ENUM`. It's derived at iOS-runtime
from subcategory heuristics (see `RulesTable.swift`).

Behavioral contracts codified here (also listed in BLOCKERS.md):
  - P2-1: `cropped` gating — attr 146 is only valid for top-like
    categories. Non-top categories carrying attr 146 get their cropped
    signal dropped. See `resolve_fit_label`.
  - P2-2: multi-label tie-break — when an annotation has both attr 146
    (cropped) AND one of {135, 136, 137} (fit), prefer `cropped`
    (more specific). Ambiguous dual fits (e.g. both 135 and 137) cause
    `resolve_fit_label` to return None, signalling "drop this sample".
  - P2-6: class-name normalization happens in `normalize_class_name`.
"""
from __future__ import annotations

from typing import Iterable, Optional


# -- iOS enum raw values (stringly-typed; Swift is source of truth) -----
#
# These strings MUST match the rawValues in:
#   WardrobeReDo/Models/Enums/StyleEnums.swift (FitAttribute)
#   WardrobeReDo/Models/Enums/ClothingSubcategory.swift
#
# Drift is caught by a preparer-side smoke test that reads the Swift
# enums and asserts every rawValue referenced here still exists.
FIT_OVERSIZED = "oversized"
FIT_RELAXED = "relaxed"
FIT_REGULAR = "regular"
FIT_SLIM = "slim"
FIT_CROPPED = "cropped"
# NB: FitAttribute.structured is intentionally absent — no Fashionpedia
# source. Derived on iOS from subcategory rules (blazer, suit jacket).


# -- Fashionpedia attribute id → FitAttribute (Section 6a) --------------
#
# Explicit fit attributes. Attr 146 "above-the-hip (length)" is our
# signal for `cropped` but ONLY for top-like categories — guarded by
# `_TOP_LIKE_CATEGORIES` below.
FIT_ATTR_ID_TO_ENUM: dict[int, str] = {
    135: FIT_SLIM,       # "tight (fit)" → slim
    136: FIT_REGULAR,    # "regular (fit)"
    137: FIT_RELAXED,    # "loose (fit)" → relaxed
    138: FIT_OVERSIZED,  # "oversized"
    146: FIT_CROPPED,    # "above-the-hip (length)" — top-like only
}

# Three fit attributes that label the "snugness" axis (mutually
# exclusive). Attr 146 (cropped) is orthogonal — an item can be
# "regular fit AND cropped length".
FIT_SNUGNESS_ATTR_IDS: set[int] = {135, 136, 137, 138}
FIT_LENGTH_ATTR_IDS: set[int] = {146}


# -- Fashionpedia category names that accept the "cropped" signal -------
#
# Normalized (underscore_joined, lowercased) forms. Keep in sync with
# `prepare_fashionpedia.py::FASHIONPEDIA_MAIN_CLASSES`.
_TOP_LIKE_CATEGORIES: set[str] = {
    "shirt_blouse",
    "top_t-shirt_sweatshirt",
    "sweater",
    "cardigan",
    "jacket",
    "vest",
}


# -- Fashionpedia attribute id → ClothingSubcategory hint (Section 6b) --
#
# These are NOT training labels — they're consumed by the iOS rules
# engine to refine `ClothingSubcategory.fromFashionpediaClass`. Listed
# here for traceability so a future Phase 5 follow-up can re-emit them
# into a Swift lookup table without re-deriving the mapping from scratch.
#
# Note: many of these hints require gating on the main category name
# (mini skirt + mini dress share attr 149). See taxonomy § Section 6b
# for the per-attribute gating rules.
SUBCATEGORY_HINT_ATTR_IDS: dict[int, str] = {
    8: "cropTop",
    16: "hoodie",
    17: "blazer",
    36: "jeans",
    38: "leggings",
    50: "shorts",
    149: "mini",          # + main_class ∈ {skirt, dress}
    153: "midi",          # + main_class ∈ {skirt, dress}
    154: "maxi",          # + main_class = dress
    183: "vneck",
    198: "turtleneck",
    # 65 "skater (skirt)" would hint aLineSkirt — no matching iOS case yet
}


# -- Category-name normalization (P2-6) ---------------------------------
#
# Fashionpedia v2 emits display-form names like "shirt, blouse" and
# "t-shirt, top, sweatshirt". The rest of our pipeline uses the
# underscore-joined forms ("shirt_blouse", "top_t-shirt_sweatshirt"),
# which are what `ClothingCategory.fromFashionpediaClass` and
# `prepare_fashionpedia.py::FASHIONPEDIA_MAIN_CLASSES` expect.
def normalize_class_name(raw: str) -> str:
    """Collapse Fashionpedia display-form category names to their
    underscore-joined canonical form.

    Examples:
        "shirt, blouse"            → "shirt_blouse"
        "t-shirt, top, sweatshirt" → "top_t-shirt_sweatshirt"
        "bag, wallet"              → "bag_wallet"
        "pants"                    → "pants"

    Whitespace is trimmed, commas become underscores, and the result is
    lowercased. The rare class name that arrives already normalized
    (e.g. "shoe") passes through untouched.
    """
    if not raw:
        return raw
    # Fashionpedia is inconsistent: most names are "display, form" but
    # a few archaic ones like "top_t-shirt_sweatshirt" already use
    # underscores. Running the replace chain is idempotent.
    collapsed = raw.strip().lower().replace(", ", "_").replace(",", "_")
    # Collapse any double-underscores from stray double-spaces.
    while "__" in collapsed:
        collapsed = collapsed.replace("__", "_")
    return collapsed


# -- Fit-label resolution (P2-1 + P2-2) ---------------------------------


def resolve_fit_label(
    attribute_ids: Iterable[int],
    main_category_name: str,
) -> Optional[str]:
    """Resolve an annotation's fit label under Option C.

    Returns:
        The iOS `FitAttribute.rawValue` to train on, or `None` if the
        annotation is ambiguous (skip) or has no fit signal (skip).

    Behavior:
        1. Intersect the attribute ids with our 5 mapped fit attrs.
        2. If attr 146 (cropped) is present BUT the main category is
           not top-like, drop the cropped signal silently (P2-1).
        3. If >1 snugness attr is present (e.g. both "tight" and
           "loose"), return None — the annotation is ambiguous (P2-2).
        4. If cropped + a snugness attr are both valid, prefer cropped
           (more specific label — P2-2 tie-break).
        5. If exactly one snugness attr is present, return it.
        6. If no valid fit attr survives, return None (annotation has
           no fit signal; skip it).

    Empty input returns None.
    """
    attr_set = {aid for aid in attribute_ids if aid in FIT_ATTR_ID_TO_ENUM}
    if not attr_set:
        return None

    normalized_main = normalize_class_name(main_category_name)

    # P2-1: drop `cropped` signal for non-top-like categories.
    has_cropped = 146 in attr_set and normalized_main in _TOP_LIKE_CATEGORIES
    snugness_attrs = attr_set & FIT_SNUGNESS_ATTR_IDS

    # P2-2: ambiguous dual fit → skip.
    if len(snugness_attrs) > 1:
        return None

    # P2-2 tie-break: cropped wins over snugness (e.g. a "regular +
    # cropped" tee is trained as cropped, because cropped is the more
    # specific label and regular is the majority class anyway).
    if has_cropped:
        return FIT_CROPPED

    if len(snugness_attrs) == 1:
        return FIT_ATTR_ID_TO_ENUM[next(iter(snugness_attrs))]

    # All that's left is attr 146 on a non-top category, which we
    # silently drop above.
    return None


# -- Exhaustive label list (for training) -------------------------------


# Order matters — the Core ML export writes labels in this order into
# `AttributeClassifier.mlpackage` metadata, and the iOS side decodes
# `argmax(fit_probs)` into `FitAttribute` using the same index. Keep in
# lock-step with `AttributeClassifierService.fitLabels` (minus
# `structured` which we don't train).
TRAINABLE_FIT_LABELS: list[str] = [
    FIT_OVERSIZED,
    FIT_RELAXED,
    FIT_REGULAR,
    FIT_SLIM,
    FIT_CROPPED,
]


def fit_label_to_index(label: str) -> int:
    """Stable index lookup for `TRAINABLE_FIT_LABELS`. Training emits
    integer labels per row; this is the single place that turns a
    rawValue into that integer."""
    return TRAINABLE_FIT_LABELS.index(label)


def fit_index_to_label(index: int) -> str:
    """Inverse of `fit_label_to_index`. Used by eval/confusion-matrix
    code."""
    return TRAINABLE_FIT_LABELS[index]
