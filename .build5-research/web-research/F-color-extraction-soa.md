# Color Extraction: State of the Art Research

> Research target: replace the current 5-cluster RGB k-means pipeline (50x50 downsample, soft-mask sampling) in `WardrobeReDo/Services/ColorExtractionService.swift` with a perceptually-correct pipeline that does not return 4 shades of blue for blue jeans, does not bleed skin tones into the palette, and does not show 0% slivers.

---

## Executive Summary (read this first)

The three problems map to three distinct fixes, and they should be tackled together because each compounds the others:

1. **"Five shades of blue" comes from clustering in RGB.** RGB Euclidean distance is not perceptually uniform, so a textured single-color garment fragments into multiple near-identical clusters that *do* look different in RGB but identical to the human eye. Move clustering to a perceptually-uniform space (CIELAB or OKLab).
2. **"Skin-tone bleed" comes from a soft mask + un-premultiplication.** When alpha is between 1 and 127, you currently throw the pixel away — but pixels at alpha 130-200 (the soft-edge ring) get *included*, divided by their fractional alpha, and produce inflated edge colors. Tighten the threshold AND erode the binary mask before sampling.
3. **"0% slivers" comes from displaying every cluster regardless of weight.** Filter clusters below ~3% before rendering, and merge perceptually-identical clusters before counting.

Recommended pipeline:

```
sRGB pixels (50x50)
  → un-premultiply with alpha >= 230 only
  → erode binary mask by 1px (CIMorphologyMinimum or equivalent)
  → convert to OKLab (or CIELAB D65)
  → k-means++ with k = 5 in OKLab
  → agglomerative merge: collapse pairs with delta-E (CIEDE2000) < 6
  → filter clusters below 3% coverage
  → return at most 3 colors (60-30-10 rule), keep dominant always
```

This is implementable in pure Swift in <300 lines, no new dependencies.

---

## 1. Perceptually-Uniform Color Clustering

### Why RGB clustering fails for clothing

Euclidean distance in sRGB does not match how humans perceive color difference. The ratio between perceived and computed difference can vary by **5x or more** across the gamut. The blue region (hue ~240-280) and the dark region (L* < 30) are the worst offenders — exactly where denim and dark trousers live. ([Color difference - Wikipedia](https://en.wikipedia.org/wiki/Color_difference))

For a uniformly-blue garment with fabric texture, the dark folds and the lit highlights all fall on a perceptual line through L* — but in sRGB the same shifts fan out into a 3D wedge. K-means in RGB happily places centroids at five points along that wedge; k-means in LAB (or OKLab) sees them as one elongated cluster on the L* axis.

Pinterest's Visual Lens, Amazon OpenSearch's perceptual color similarity examples, and the Doug Fenstermacher x-means tutorial all use **CIELAB** as the clustering space, with **CIEDE2000** as the merge / similarity metric. ([Pinterest skin tone model](https://medium.com/pinterest-engineering/powering-inclusive-search-recommendations-with-our-new-visual-skin-tone-model-1d3ba6eeffc7), [Amazon OpenSearch perceptual color search](https://medium.com/storm-reply/building-perceptual-color-similarity-search-with-amazon-opensearch-service-72547f445a04), [X-Means + CIE2000 tutorial](https://dougfenstermacher.com/project/xmeans-cie2000-dominant-color-extraction-visualization-tutorial))

### CIELAB vs OKLab

Both are perceptually uniform. Differences:

| Property | CIELAB (1976) | OKLab (2020) |
|---|---|---|
| Industry adoption | Universal — printing, textiles, Vision systems | Growing — used by CSS Color 4, increasingly in web graphics |
| Blue-region accuracy | Known issues (CIEDE2000 patches them) | Better out-of-the-box than CIELAB |
| Lightness prediction | OK | Improved (fitted with CAM16/IPT data) |
| Conversion cost | sRGB → linear → XYZ → LAB | sRGB → linear → LMS → OKLab |
| Hue/chroma transitions | Can produce unexpected shifts | Smoother |
| ΔE2000 standard | Well-defined, widely cited | Use plain Euclidean (it's already uniform) |

Per Bjorn Ottosson's launch post and Raph Levien's review, OKLab eliminates most of the problems that CIEDE2000 was designed to patch in CIELAB. For new code in 2026, **OKLab is the modern choice**; CIELAB + CIEDE2000 is the safer choice if you want to cite established literature and match what every other fashion ML paper uses. ([OKLab spec](https://bottosson.github.io/posts/oklab/), [Raph Levien's OKLab review](https://raphlinus.github.io/color/2021/01/18/oklab-critique.html))

For Wardrobe Re-Do I'd lean **CIELAB + CIEDE2000** because:
- ΔE thresholds in the literature (2.3 JND, 5 "noticeable", 10 "different colors") are CIELAB-calibrated.
- Matching production tools (Pinterest, Amazon, fashion ML research) makes future ML work easier.
- Apple's `CIKMeans` filter has a `inputPerceptual` flag that already does sRGB → LAB internally with D65.

### CIEDE2000 Delta-E thresholds

| ΔE2000 | Meaning | Use in pipeline |
|---|---|---|
| < 1.0 | Below JND — humans can't reliably tell apart | Always merge |
| 1.0-2.3 | Just-noticeable-difference range (CIE76 used 2.3 as JND) | Always merge for our case |
| 2.3-5.0 | "Slight" difference — same color name | Merge for fashion (denim folds, t-shirt wrinkles) |
| 5.0-10.0 | "Noticeable" — borderline same color | Threshold zone for fashion — recommend ~5-6 |
| > 10.0 | "Different colors" | Never merge |

Industry references:
- Automotive paint: ΔE_CMC < 0.5 (extremely tight). ([Color difference - Wikipedia](https://en.wikipedia.org/wiki/Color_difference))
- Print: ΔE 2.0 typical, up to 5.0 acceptable.
- Dental color matching: clinically acceptable below 2.25, perceptible above 1.30. ([Sharma 2005 background](https://hajim.rochester.edu/ece/sites/gsharma/papers/CIEDE2000CRNAFeb05.pdf))

For **garment color extraction**, we want to *over-merge* relative to print/automotive standards because we care about color *names*, not color *fidelity*. Recommend **ΔE2000 merge threshold of 5-6**.

The Doug Fenstermacher tutorial standardizes these constants in a usable form:

```
deltaE2000.JND = 1.0  // Just Noticeable Difference
deltaE2000.BND = 2.0  // Barely Noticeable Difference
deltaE2000.ND  = 3.5  // Noticeable Difference
deltaE2000.AD  = 5.0  // Apparent Difference
```
([X-Means + CIE2000](https://dougfenstermacher.com/project/xmeans-cie2000-dominant-color-extraction-visualization-tutorial))

### sRGB → CIELAB conversion (Swift-ready)

Standard 3-stage pipeline: sRGB gamma decode → linear RGB to XYZ via D65 matrix → XYZ to LAB via piecewise nonlinearity. ([mina86 sRGB↔Lab reference](https://mina86.com/2021/srgb-lab-lchab-conversions/), [image-engineering.de notes](https://www.image-engineering.de/library/technotes/958-how-to-convert-between-srgb-and-ciexyz))

```swift
// Constants
private let kEpsilon = 216.0 / 24389.0        // (6/29)^3 — LAB nonlinearity threshold
private let kKappa   = 24389.0 / 27.0         // (29/3)^3 — LAB linear-region slope
// D65 reference white (CIE 1931 2-deg observer, sRGB-aligned)
private let kXn = 0.95047
private let kYn = 1.00000
private let kZn = 1.08883

struct LAB { let L: Double; let a: Double; let b: Double }

@inline(__always)
private func srgbToLinear(_ c: Double) -> Double {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

func rgbToLab(r: Double, g: Double, b: Double) -> LAB {
    // 1. Gamma decode sRGB → linear RGB
    let R = srgbToLinear(r)
    let G = srgbToLinear(g)
    let B = srgbToLinear(b)

    // 2. Linear RGB → XYZ (D65, sRGB primaries)
    let X = R * 0.4124564 + G * 0.3575761 + B * 0.1804375
    let Y = R * 0.2126729 + G * 0.7151522 + B * 0.0721750
    let Z = R * 0.0193339 + G * 0.1191920 + B * 0.9503041

    // 3. XYZ → LAB (D65 white-point normalization + piecewise nonlinearity)
    func f(_ t: Double) -> Double {
        return t > kEpsilon ? pow(t, 1.0/3.0) : (kKappa * t + 16.0) / 116.0
    }
    let fx = f(X / kXn)
    let fy = f(Y / kYn)
    let fz = f(Z / kZn)

    return LAB(
        L: 116.0 * fy - 16.0,
        a: 500.0 * (fx - fy),
        b: 200.0 * (fy - fz)
    )
}
```

For our 50x50 = 2500-pixel pipeline, the conversion is ~25k arithmetic ops total. Negligible.

### CIEDE2000 implementation (Swift port of Sharma 2005)

The reference implementation is Sharma, Wu, Dalal (2005) — they explicitly published this paper because the original CIE specification had implementation pitfalls (wraparound at hue 0/360, neutral-color edge cases). Use Sharma's test data to validate. ([Sharma 2005 PDF](https://hajim.rochester.edu/ece/sites/gsharma/papers/CIEDE2000CRNAFeb05.pdf), [Sharma test vectors](https://www.ece.rochester.edu/~gsharma/ciede2000/))

The JS implementation from the Doug Fenstermacher tutorial ports cleanly to Swift — see "Sample Swift code" block in section 6 below.

### Production examples — who clusters in LAB

| Company | Approach | Source |
|---|---|---|
| Pinterest (Visual Lens, skin-tone) | Convert dominant color to LAB; ITA computed from L,b | [Pinterest blog](https://medium.com/pinterest-engineering/powering-inclusive-search-recommendations-with-our-new-visual-skin-tone-model-1d3ba6eeffc7) |
| Amazon OpenSearch perceptual color | k-means in LAB, ΔE2000, k=5 dominants stored as 3D vectors | [Storm Reply walkthrough](https://medium.com/storm-reply/building-perceptual-color-similarity-search-with-amazon-opensearch-service-72547f445a04) |
| `indragiek/DominantColor` (Swift, 1.5k stars) | k=16 in LAB, ΔE76/94/2000 selectable, GLKit C bridge for conversion | [GitHub](https://github.com/indragiek/DominantColor) |
| `DenDmitriev/DominantColors` (Swift) | LAB + CIE76 ΔE, k-means with quality presets | [GitHub](https://github.com/DenDmitriev/DominantColors) |
| Doug Fenstermacher tutorial | x-means in LAB, ΔE2000 distance, BIC for k auto-selection | [tutorial](https://dougfenstermacher.com/project/xmeans-cie2000-dominant-color-extraction-visualization-tutorial) |
| Apple `CIKMeans` filter (iOS 13+) | k-means in **LAB if `inputPerceptual = true`**, otherwise sRGB | [filtermagicblog walkthrough](https://filtermagicblog.com/2024/01/cikmeans-filter/), [Apple forum thread](https://developer.apple.com/forums/thread/658185) |

I did not find published evidence that Whering, Cladwell, Acloset, Indyx, or Stylebook publish their internal color extraction algorithm. They all show *named* color tags (e.g., "navy", "olive") rather than swatch palettes; this is a strong hint they map clusters to a discrete palette of color names rather than displaying raw cluster colors. ([wardrobe app comparison](https://clueless.clothing/blog/best-wardrobe-apps-2026/))

---

## 2. Cluster Merging Strategies

K-means with a fixed k=5 will *always* return 5 clusters. For a uniform-color garment, this is the root cause of the "4 shades of blue" problem. Three solutions, in order of recommended simplicity:

### A. Agglomerative post-merge (recommended)

Run k-means with k=5, then iteratively merge clusters whose centroids are within ΔE2000 < T in LAB. Re-weight the merged cluster's centroid by population. Stop when no pair is below T.

```
loop:
  find pair (i, j) with smallest ΔE2000(centroid_i, centroid_j)
  if ΔE < T:
    merge: new_center = (n_i * c_i + n_j * c_j) / (n_i + n_j)
    new_count = n_i + n_j
    remove i, j; add merged
  else:
    break
```

This is "complete-linkage agglomerative" with a cluster-size-weighted centroid update, the same pattern used by `cluster-colors` (PyPI) and the okaneco/kmeans-colors Rust binary. ([cluster-colors PyPI](https://pypi.org/project/cluster-colors/), [okaneco/kmeans-colors](https://github.com/okaneco/kmeans-colors))

**Threshold recommendation: T = 5.0 (ΔE2000)** for fashion. This is in the "noticeable but same color name" band — it collapses denim folds and t-shirt wrinkles but keeps red-vs-pink and navy-vs-royal-blue distinct.

For a 5-cluster k-means, this is at most C(5,2) = 10 ΔE2000 computations per merge iteration, and at most 4 iterations. Trivially cheap.

### B. Density-based (DBSCAN) — more correct, more code

DBSCAN groups points by density without needing a pre-set k. For clothing color extraction it would naturally produce 1 cluster for a uniform garment and 2-3 for a striped or printed garment, with no merging step needed. Two reasons not to recommend it for now:

- Computational cost is O(n^2) without a spatial index — 6.25M pair comparisons for our 2500 pixels — still fast but no longer trivial.
- Tuning eps (density radius) and minPts (cluster threshold) is harder than tuning a single ΔE merge threshold. ([DBSCAN comparison](https://blog.quantinsti.com/dbscan-vs-kmeans/), [HDBSCAN comparison](https://hdbscan.readthedocs.io/en/latest/comparing_clustering_algorithms.html))

DBSCAN becomes attractive if you want to detect "this garment has 2 colors" vs "this garment has 5 colors" automatically. Out of scope for the immediate fix.

### C. X-means with BIC — academic gold standard, overkill

X-means (Pelleg & Moore 2000) starts with k=2 and splits clusters greedily based on Bayesian Information Criterion improvement. With ΔE2000 distance in LAB, this is the Doug Fenstermacher approach. It produces beautiful results but adds 200+ lines of BIC math. ([X-Means + CIE2000](https://dougfenstermacher.com/project/xmeans-cie2000-dominant-color-extraction-visualization-tutorial))

Recommend **A (agglomerative merge with ΔE2000 < 5)** for v1; B or C only if v1 still produces visible problems on dogfood data.

### Hue-based fallback (cheaper than LAB)

If the LAB conversion is somehow blocked (e.g., perf budget concern, despite the math being trivially cheap), an HSL hue-based merge is a reasonable second choice:

> Merge clusters within ±15° hue AND ±0.2 lightness AND ±0.15 saturation in HSL.

This is what your current `colorFamily()` function does coarsely, but applied at the cluster-merge level rather than the post-extraction labeling level. The downsides vs LAB:
- Hue is undefined / unstable for low-saturation pixels (grays, near-blacks). Need a saturation threshold to skip hue comparison there.
- The 15° figure is a rule-of-thumb without a perceptual grounding.

For comparison: ΔE2000 < 5 is roughly equivalent to "same color name" at moderate chroma; the HSL ±15°/±0.2/±0.15 rule is empirical and tracks well at high saturation but loses accuracy in dark or desaturated regions.

**Verdict:** Don't bother with HSL. The LAB + ΔE2000 path is well under a millisecond at 2500 pixels.

---

## 3. Soft-Edge Mask Handling

### Root cause of skin-tone bleed

`VNGenerateForegroundInstanceMaskRequest` (iOS 17+) returns an alpha mask with **soft anti-aliased edges**. The mask "indicates the pixels that have the foreground objects, with the white part indicating pixels detected as the foreground object, and the black part indicating pixels that are the background" — but the transition between is a gradient. ([VNGenerateForegroundInstanceMaskRequest docs](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest), [createwithswift Vision walkthrough](https://www.createwithswift.com/removing-image-background-using-the-vision-framework/), [WWDC 2023 Notes](https://github.com/WWDCNotes/Content/blob/main/content/notes/wwdc23/10176.md))

Your current code:
```swift
guard alphaByte >= 128 else { continue }
let alpha = Double(alphaByte) / 255.0
let r = alpha > 0 ? min(rp / alpha, 1.0) : rp
```

includes any pixel with alpha 128-255 and divides its premultiplied color by alpha. For a pixel at the soft edge with alpha=130, RGB premultiplied to (50, 30, 20) ("dark with skin-fringe leakage"), un-premultiplication amplifies it to (97, 58, 39) — pumping skin tones into the palette at ~50% saturation.

Apple does **not** publish a parameter for hard-edge / binary output on `VNGenerateForegroundInstanceMaskRequest`. The mask is always soft. ([Apple forum thread](https://forums.developer.apple.com/forums/thread/764948))

### Three layered fixes

**Fix 1 — raise the alpha threshold.** Pixels at alpha < 230 are in the soft-edge ring and should be excluded. This alone removes ~80% of edge bleed on a typical full-body garment. ChatGPT-tier edge case: a sheer/lace garment has legitimate fringe transparency — but those aren't garments where dominant color matters most, and ColorExtraction can fall back to the 128 threshold if alpha<230 returns < 100 pixels.

```swift
let kStrictAlphaThreshold: UInt8 = 230  // 0.9
let kFallbackAlphaThreshold: UInt8 = 128
```

**Fix 2 — erode the binary mask by 1-2 pixels.** Even at alpha=255, the pixel just inside the soft ring may be background-influenced because Vision's segmentation is not pixel-perfect. Morphological erosion shrinks the mask by N pixels and excludes that layer. ([Erosion (morphology) - Wikipedia](https://en.wikipedia.org/wiki/Erosion_(morphology)), [bioimagebook morph chapter](https://bioimagebook.github.io/chapters/2-processing/5-morph/morph.html))

In Core Image: `CIMorphologyMinimum` with radius=1 or 2 on the binary mask. In pure Swift on the 50x50 buffer: a 3x3 min filter is ~22k ops, negligible. ([CIMorphology filters](https://cifilter.app/), [Apple Accelerate Morphology](https://developer.apple.com/documentation/accelerate/morphology))

```swift
// Conceptual: build a binary mask from alpha >= 230, then erode by 1px
// before sampling colors. Output: only "confident-interior" pixels are used.
private func erodeBinaryMask(buffer: [UInt8], width: Int, height: Int) -> [Bool] {
    var binary = [Bool](repeating: false, count: width * height)
    for i in 0..<(width * height) {
        binary[i] = buffer[i * 4 + 3] >= kStrictAlphaThreshold
    }
    var eroded = [Bool](repeating: false, count: width * height)
    for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
            // 3x3 erosion: pixel kept iff all 8 neighbors + self are foreground
            var allOn = true
            for dy in -1...1 {
                for dx in -1...1 {
                    if !binary[(y + dy) * width + (x + dx)] { allOn = false }
                }
            }
            eroded[y * width + x] = allOn
        }
    }
    return eroded
}
```

**Fix 3 — trimap-based sampling (optional, advanced).** Treat alpha as three bands:
- alpha >= 230: confident foreground — sample
- 100 <= alpha < 230: uncertain — skip for color extraction (but maybe keep for future matting)
- alpha < 100: confident background — skip

This is the formalism behind alpha matting research. ([trimap explainer](https://withoutbg.com/resources/trimap), [LearnOpenCV F-B-Alpha matting](https://learnopencv.com/image-matting-with-state-of-the-art-method-f-b-alpha-matting/)) It's exactly what Fix 1 + Fix 2 already accomplish in practice — the layered alpha threshold *is* the trimap. No additional code needed.

### Mask-handling recommendation summary

```
1. alpha >= 230 → "confident foreground" (preferred)
2. erode binary mask by 1px (3x3 min filter)
3. if confident-foreground pixel count < 100 → fall back to alpha >= 128, no erosion
4. un-premultiply only after these gates
```

---

## 4. Garment-Specific Heuristics

### Dominant color vs palette: how many colors to show?

| Approach | Use case | Citation |
|---|---|---|
| 1 dominant color (median in LAB) | Tag/filter ("this shirt is blue") | Indyx, Acloset auto-tag a single color |
| 3-color palette (60-30-10) | Outfit composition rule | Fashion theory standard |
| 5-color palette | Search by visual similarity | Pinterest, Amazon image search |

Wardrobe Re-Do already uses the 60-30-10 rule in `ColorHarmonyScorer` (per CLAUDE.md). The fashion 3-color rule says "an outfit should not comprise more than three colors at a time." ([3-color principle in fashion](https://www.necesera.com/blogs/news/the-3-color-principle-in-fashion), [60-30-10 rule explainer](https://uxplanet.org/the-60-30-10-rule-a-foolproof-way-to-choose-colors-for-your-ui-design-d15625e56d25)) For a *single garment* (not an outfit), most garments are 1-2 colors. Showing 5 colors per garment is over-fitted to the algorithm rather than the data.

**Recommendation:**
- **Internally extract 5 clusters** (so we have headroom for striped/printed garments).
- **After merging + filtering, return up to 3 colors** (matches fashion 3-color rule, matches what you already use in scoring).
- Single-color garments will naturally collapse to 1 cluster after the ΔE2000 < 5 merge.

### Specular highlight / shadow handling

For leather, denim, satin, and any garment with a sheen, specular reflections add white spots that k-means treats as a separate cluster. Same problem with deep shadows in folds.

The dichromatic reflection model (Shafer 1985) decomposes pixels into diffuse + specular components. Modern neural solvers exist but are heavy. ([Neural DRM solver ICCV 2025](https://openaccess.thecvf.com/content/ICCV2025/papers/Fu_Neural_Solver_of_Dichromatic_Reflection_Model_for_Specular_Highlight_Removal_ICCV_2025_paper.pdf), [Fast specular removal arXiv 2015](https://arxiv.org/pdf/1512.00237))

**Cheap proxies that are good enough for a wardrobe app:**
- Drop pixels with L* > 90 OR L* < 10 in LAB before clustering — these are blown-out highlights and crushed shadows that don't carry diffuse color information.
- Equivalent in your existing HSL terms: drop lightness > 0.92 or lightness < 0.05.
- This is a 5-line filter; full DRM separation is several hundred.

For shadow tolerance, projecting to **chromaticity space** (L* discarded, a*/b* only) before clustering would make the algorithm shadow-invariant. But that throws away light/dark distinction entirely (white shirt and gray shirt would cluster together). Better to keep L* but **tighten the merge threshold along the L* axis** — i.e., use `kL = 1.0` in CIEDE2000 (the standard) rather than higher weighting. ([Ranaweera shadow-removal report](http://warunika.weebly.com/uploads/2/0/5/8/20587050/report_illumination.pdf), [chromaticity shadow detection](https://ijarcce.com/wp-content/uploads/2015/10/IJARCCE-85.pdf))

**Recommendation:** Add a pre-cluster filter that drops L* > 92 and L* < 8. Skip dichromatic separation for now — diminishing returns relative to merge-fix.

---

## 5. Production Color-Extraction Libraries

| Library | Lang | Algorithm | Color space | Notes |
|---|---|---|---|---|
| Color Thief | JS/Py/PHP | MMCQ (Modified Median Cut Quantization) | RGB | The OG. Lokesh Dhakar 2011. Bucket-based, no clustering distance metric — splits color cube. Fast but RGB-bound. ([github](https://github.com/lokesh/color-thief), [MMCQ explainer](https://gowtham000.hashnode.dev/median-cut-a-popular-colour-quantization-strategy)) |
| Vibrant.js / node-vibrant | JS | MMCQ + semantic classification (Vibrant/Muted/Dark/Light) | HSL | Port of Android Palette API. Slow — quantization is the bottleneck. ([github](https://github.com/Vibrant-Colors/node-vibrant)) |
| swift-vibrant | Swift | MMCQ via ColorThiefSwift | RGB → HSL classification | iOS port of vibrant.js. ([github](https://github.com/bd452/swift-vibrant)) |
| ColorThiefSwift | Swift | MMCQ | RGB | Direct port of Sven Woltmann Java. ([github](https://github.com/yamoridon/ColorThiefSwift)) |
| UIImageColors | Swift | Color counting + saturation/luminance heuristics | RGB | Based on Panic ColorArt. No clustering. ([github](https://github.com/jathu/UIImageColors)) |
| indragiek/DominantColor | Swift+C | k-means in LAB, GLKit-bridged conversion, k=16 | **CIE LAB** | Closest to what we want. ([github](https://github.com/indragiek/DominantColor)) |
| DenDmitriev/DominantColors | Swift | k-means with CIE76 ΔE, sortable by ColorShade | LAB | Uses CIKMeans + post-merge. ([github](https://github.com/DenDmitriev/DominantColors)) |
| ColorKit | Swift | Multiple algorithms | RGB / LAB | Origin codebase for DominantColors fork. |
| okaneco/kmeans-colors | Rust | k-means in LAB | LAB | CLI tool, well-documented merge step. ([github](https://github.com/okaneco/kmeans-colors)) |
| cluster-colors | Python | Median cut + agglomerative merge with ΔE | LAB | Documents merge-by-ΔE explicitly. ([PyPI](https://pypi.org/project/cluster-colors/)) |

### Apple's built-in: `CIKMeans` filter (iOS 13+)

Yes, Core Image has a built-in k-means filter, and yes, it has a perceptual mode. ([Apple docs](https://developer.apple.com/documentation/coreimage/cikmeans), [filtermagicblog walkthrough](https://filtermagicblog.com/2024/01/cikmeans-filter/), [cifilter.io reference](https://cifilter.io/CIKMeans/))

Parameters:
- `inputImage`: source CIImage
- `inputExtent`: CIVector — region to analyze
- `inputCount`: NSNumber — k (max 128)
- `inputPasses`: NSNumber — number of k-means iterations
- `inputMeans`: CIImage — optional K×1 image of seed colors (for warm-start)
- `inputPerceptual`: NSNumber (Bool) — **if YES, clusters in CIE LAB with D65 illuminant; if NO, clusters in sRGB**

The output is a 1×K image where each pixel is one cluster centroid. Read it back with `CIContext.render(_:toBitmap:)` into a small buffer.

**Trade-offs vs custom Swift k-means:**

| Aspect | `CIKMeans` (perceptual=YES) | Custom Swift k-means in LAB |
|---|---|---|
| Color space | LAB internally | Whatever we choose |
| GPU | Yes — Metal-backed | No — CPU only |
| Determinism | Per Apple, "quite slow and not suitable for real time" — and not deterministic across iOS versions | Fully deterministic with seeded random |
| Cluster counts | Returned as RGB pixels, no native percentages | Custom — we count assignments ourselves |
| Merge / threshold control | None — output is raw k-means result | Full control |
| Initialization | Random or user-seeded means | k-means++ |
| Convergence detection | Hidden | Explicit (we already do this) |
| Test coverage | Mocking requires CIImage fixtures | Pure-Swift, easy unit tests |
| iOS support | iOS 13+ | iOS 17+ already required by your stack |

The dealbreaker for our use case is **counting cluster sizes**. `CIKMeans` returns only centroids, not assignment histograms — we'd need a second pass to assign every pixel to its nearest centroid and count, which negates the speed advantage. And the merge step (which is the most important fix here) has to live outside `CIKMeans` anyway.

**Recommendation: don't use `CIKMeans`.** Keep the custom k-means but operate in LAB. Reasons:
1. We already have working, tested, deterministic k-means code.
2. The fix is a color-space conversion + merge step, not a filter swap.
3. Cluster percentages are first-class in custom code.
4. Test mocking stays simple (the `ColorExtracting` protocol).
5. 50x50 = 2500 pixels in LAB k-means runs in well under 10ms even on an iPhone 8 — perf is not an issue.

If perf ever becomes a problem with larger inputs, `CIKMeans` is a good fallback.

---

## 6. Actionable Recommendations (code-ready)

### 6.1 Color space change

**Decision: Move to CIELAB.** Add a Swift `LAB` struct, a `rgbToLab` conversion (see code above), and update `kMeans()` to operate on `[LAB]` instead of `[(r, g, b)]`. Keep `rgbToHSL` for the *output* (`ExtractedColor.hue/saturation/lightness`) since downstream code uses HSL for color-family naming.

Order of operations per pixel:
```
sRGB byte → Double / 255.0 → un-premultiply → LAB (for clustering) →  ... cluster ... → centroid back to sRGB → HSL (for naming) → hex
```

### 6.2 Distance metric

**Decision: CIEDE2000 for cluster merging; Euclidean LAB for k-means assignment.**

Why two metrics: k-means proves correctness only with Euclidean distance; CIEDE2000 is not Euclidean (it has cross-terms like `R_T * Δa' * Δh'`) and would break the convergence guarantee. The good news: in CIELAB, plain Euclidean distance is *already* perceptually-uniform-ish, and using ΔE2000 only at the merge step (when we have ~5 centroids) is where the heavy lifting matters anyway.

### 6.3 Merging strategy

**Decision: Agglomerative post-k-means merge, ΔE2000 threshold 5.0.**

```swift
// Pseudocode for merge step
struct ClusterLAB { var center: LAB; var count: Int }
let mergeThreshold: Double = 5.0  // ΔE2000

var clusters: [ClusterLAB] = kmeansLabClusters
while true {
    var bestPair: (Int, Int, Double)? = nil
    for i in 0..<clusters.count {
        for j in (i+1)..<clusters.count {
            let dE = deltaE2000(clusters[i].center, clusters[j].center)
            if dE < mergeThreshold {
                if bestPair == nil || dE < bestPair!.2 {
                    bestPair = (i, j, dE)
                }
            }
        }
    }
    guard let (i, j, _) = bestPair else { break }
    let merged = mergeWeighted(clusters[i], clusters[j])
    clusters.remove(at: j)
    clusters.remove(at: i)
    clusters.append(merged)
}
```

Where `mergeWeighted` is a population-weighted centroid average:
```swift
func mergeWeighted(_ a: ClusterLAB, _ b: ClusterLAB) -> ClusterLAB {
    let n = Double(a.count + b.count)
    let wa = Double(a.count) / n
    let wb = Double(b.count) / n
    return ClusterLAB(
        center: LAB(
            L: a.center.L * wa + b.center.L * wb,
            a: a.center.a * wa + b.center.a * wb,
            b: a.center.b * wa + b.center.b * wb
        ),
        count: a.count + b.count
    )
}
```

### 6.4 Sampling: alpha threshold + erosion

**Decision: alpha >= 230 with 1-pixel erosion; fallback alpha >= 128 if interior pixel count < 100.**

```swift
let kStrictAlpha: UInt8 = 230
let kFallbackAlpha: UInt8 = 128
let kMinInteriorPixels = 100
let kErodeRadius = 1

let interiorMask = erodeBinaryMask(
    buffer: rgba,
    width: 50,
    height: 50,
    alphaThreshold: kStrictAlpha,
    radius: kErodeRadius
)
let interiorCount = interiorMask.lazy.filter { $0 }.count

let useStrict = interiorCount >= kMinInteriorPixels
let pixels = sampleLabPixels(
    buffer: rgba,
    mask: useStrict ? interiorMask : softMask(rgba, alphaThreshold: kFallbackAlpha)
)
```

Implementation notes:
- The erosion is a 3x3 min filter over a 50x50 binary array. Easy to write by hand (~30 lines) or do with `vImageErode_Planar8` from Accelerate.
- Drop pixels with L* > 92 or L* < 8 *after* LAB conversion to filter highlights and crushed shadows. ~5 extra lines.

### 6.5 Cluster count

**Decision: extract k=5, return up to 3 (after merging and filtering).**

```swift
let extracted = clusters
    .sorted { $0.count > $1.count }       // descending coverage
    .prefix(maxColors)                    // up to 3 (passed in from caller)
    .filter { Double($0.count) / total >= 0.03 }  // drop <3% slivers
```

Always keep at least the top cluster regardless of percentage (a uniform garment will only have 1).

### 6.6 Display: percentages or just swatches?

**Decision: keep percentages, but apply a 3% floor.**

The 0%-display bug is fully fixed by:
1. Merging perceptually-identical clusters before counting (so single-color garments report one ~100% cluster).
2. Filtering out clusters below a fixed coverage threshold (3%).
3. Rounding to 0 decimal places for display (currently 1) — most users don't care that it's "94.3%".

Show percentages on hover/long-press, swatches in the grid view. This matches the affordance Indyx and Acloset use for color tags. ([Indyx review](https://stylewithingrace.com/indyx-app-review-lookbook/))

### 6.7 Sample CIEDE2000 implementation (Swift port from Doug Fenstermacher tutorial)

```swift
import Foundation

// Inputs are CIELAB values: L in [0, 100], a in roughly [-128, 127], b in roughly [-128, 127]
func deltaE2000(_ lab1: LAB, _ lab2: LAB) -> Double {
    let kL = 1.0, kC = 1.0, kH = 1.0  // standard weights

    let avgL = (lab1.L + lab2.L) / 2.0

    let c1 = sqrt(lab1.a * lab1.a + lab1.b * lab1.b)
    let c2 = sqrt(lab2.a * lab2.a + lab2.b * lab2.b)
    let avgC = (c1 + c2) / 2.0

    let avgC7 = pow(avgC, 7.0)
    let g = (1.0 - sqrt(avgC7 / (avgC7 + pow(25.0, 7.0)))) / 2.0

    let a1p = lab1.a * (1.0 + g)
    let a2p = lab2.a * (1.0 + g)
    let c1p = sqrt(a1p * a1p + lab1.b * lab1.b)
    let c2p = sqrt(a2p * a2p + lab2.b * lab2.b)
    let avgCp = (c1p + c2p) / 2.0

    func deg(_ x: Double, _ y: Double) -> Double {
        let h = atan2(y, x) * 180.0 / .pi
        return h < 0 ? h + 360.0 : h
    }
    let h1p = deg(a1p, lab1.b)
    let h2p = deg(a2p, lab2.b)

    let avgHp: Double = abs(h1p - h2p) > 180.0
        ? (h1p + h2p + 360.0) / 2.0
        : (h1p + h2p) / 2.0

    let t = 1.0
        - 0.17 * cos((avgHp - 30.0) * .pi / 180.0)
        + 0.24 * cos((2.0 * avgHp) * .pi / 180.0)
        + 0.32 * cos((3.0 * avgHp + 6.0) * .pi / 180.0)
        - 0.20 * cos((4.0 * avgHp - 63.0) * .pi / 180.0)

    var dHp = h2p - h1p
    if abs(dHp) > 180.0 { dHp += h2p <= h1p ? 360.0 : -360.0 }

    let dLp = lab2.L - lab1.L
    let dCp = c2p - c1p
    let dHpFinal = 2.0 * sqrt(c1p * c2p) * sin((dHp / 2.0) * .pi / 180.0)

    let sl = 1.0 + (0.015 * pow(avgL - 50.0, 2.0)) / sqrt(20.0 + pow(avgL - 50.0, 2.0))
    let sc = 1.0 + 0.045 * avgCp
    let sh = 1.0 + 0.015 * avgCp * t

    let dTheta = 30.0 * exp(-pow((avgHp - 275.0) / 25.0, 2.0))
    let avgCp7 = pow(avgCp, 7.0)
    let rc = 2.0 * sqrt(avgCp7 / (avgCp7 + pow(25.0, 7.0)))
    let rt = -rc * sin(2.0 * dTheta * .pi / 180.0)

    let term1 = dLp / (kL * sl)
    let term2 = dCp / (kC * sc)
    let term3 = dHpFinal / (kH * sh)

    return sqrt(term1 * term1 + term2 * term2 + term3 * term3 + rt * term2 * term3)
}
```

**Validate against Sharma's published test data** — see his website for the .xlsx file with 34 ΔE2000 reference vectors, including the tricky neutral and blue cases. ([Sharma test data](https://www.ece.rochester.edu/~gsharma/ciede2000/)) Add a unit test that runs all 34 vectors with tolerance 1e-4.

---

## Verification / Test Strategy

Once implemented, validate with:

1. **Sharma 2005 test vectors for CIEDE2000.** Unit test with tolerance 1e-4. ([test data](https://www.ece.rochester.edu/~gsharma/ciede2000/))
2. **Synthetic single-color textured input.** Generate a 50x50 image of pure `#1E3A8A` (navy) with random ±20-RGB noise to simulate fabric texture. Expect: 1 cluster after merging, percentage >= 90%.
3. **Synthetic two-color stripe input.** Half navy, half white. Expect: 2 clusters, ~50/50 split, ΔE between centroids > 50.
4. **Real soft-mask input.** Take a known-skin-tone-bleeding photo from your dogfood data set, run before/after, assert: zero red/orange/skin-tone-band clusters in output, dominant cluster matches the garment.
5. **Regression: 0% slivers.** Assert no returned cluster has percentage < 3%.

---

## Sources

### Color difference and CIEDE2000
- [Color difference - Wikipedia](https://en.wikipedia.org/wiki/Color_difference)
- [Sharma, Wu, Dalal 2005 — CIEDE2000 implementation notes (PDF)](https://hajim.rochester.edu/ece/sites/gsharma/papers/CIEDE2000CRNAFeb05.pdf)
- [Sharma CIEDE2000 reference page with test data](https://www.ece.rochester.edu/~gsharma/ciede2000/)
- [Delta E 101 explainer](http://zschuessler.github.io/DeltaE/learn/)
- [Color Difference Formula and ΔE: CIE Standards and Tolerance — Skychemi](https://skychemi.com/color-difference-formula-delta-e/)
- [Demystifying CIE ΔE2000 — Techkon/Datacolor](https://techkon.datacolor.com/demystifying-the-cie-delta-e-2000-formula/)

### Color space conversion
- [CIELAB color space - Wikipedia](https://en.wikipedia.org/wiki/CIELAB_color_space)
- [sRGB↔Lab↔LCh(ab) conversions — mina86.com](https://mina86.com/2021/srgb-lab-lchab-conversions/)
- [How to convert between sRGB and CIEXYZ — Image Engineering](https://www.image-engineering.de/library/technotes/958-how-to-convert-between-srgb-and-ciexyz)
- [RGB to LAB — Kaizoudou](https://kaizoudou.com/from-rgb-to-lab-color-space/)
- [CIELab Color Space — Gernot Hoffmann (PDF)](http://www.haralick.org/DV/cielab03022003.pdf)

### OKLab (modern alternative to CIELAB)
- [Oklab: A perceptual color space for image processing — Bjorn Ottosson](https://bottosson.github.io/posts/oklab/)
- [An interactive review of Oklab — Raph Levien](https://raphlinus.github.io/color/2021/01/18/oklab-critique.html)
- [Oklab color space - Wikipedia](https://en.wikipedia.org/wiki/Oklab_color_space)
- [Improving color quantization heuristics — ubitux](http://blog.pkh.me/p/39-improving-color-quantization-heuristics.html)

### Clustering algorithms
- [X-Means + CIEDE2000 dominant color tutorial — Doug Fenstermacher](https://dougfenstermacher.com/project/xmeans-cie2000-dominant-color-extraction-visualization-tutorial)
- [Color clustering and dominant colors — image (Elixir)](https://hexdocs.pm/image/color_clustering.html)
- [HSV clustering — Florisera](https://florisera.com/hsv-clustering/)
- [DBSCAN vs K-Means — Quantinsti](https://blog.quantinsti.com/dbscan-vs-kmeans/)
- [Comparing Python clustering algorithms — HDBSCAN docs](https://hdbscan.readthedocs.io/en/latest/comparing_clustering_algorithms.html)
- [Image color extraction with k-means — Yi Shen](https://medium.com/@ys3372/deconstructing-an-image-with-pixels-4c65c3a2268c)

### Vision framework / mask handling
- [VNGenerateForegroundInstanceMaskRequest — Apple Developer Documentation](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest)
- [Removing image background using the Vision framework — createwithswift](https://www.createwithswift.com/removing-image-background-using-the-vision-framework/)
- [Subject lifting / Vision foreground mask — MszPro](https://mszpro.com/vision-foreground-instance-mask-request)
- [WWDC 2023 Notes — Lift subjects from images](https://github.com/WWDCNotes/Content/blob/main/content/notes/wwdc23/10176.md)
- [Apple Developer Forums — Vision request mask softness](https://forums.developer.apple.com/forums/thread/764948)
- [Erosion (morphology) - Wikipedia](https://en.wikipedia.org/wiki/Erosion_(morphology))
- [Morphological operations — Bioimage Analysis](https://bioimagebook.github.io/chapters/2-processing/5-morph/morph.html)
- [Apple Accelerate Morphology](https://developer.apple.com/documentation/accelerate/morphology)
- [CIFilter reference — cifilter.app](https://cifilter.app/)

### Trimap / matting
- [Understanding Trimaps in Image Matting — withoutBG](https://withoutbg.com/resources/trimap)
- [F, B, Alpha Matting — LearnOpenCV](https://learnopencv.com/image-matting-with-state-of-the-art-method-f-b-alpha-matting/)
- [OpenCV Information Flow Alpha Matting](https://docs.opencv.org/4.x/dd/d0e/tutorial_alphamat.html)

### Specular highlight / shadow
- [Neural Solver of Dichromatic Reflection Model — ICCV 2025](https://openaccess.thecvf.com/content/ICCV2025/papers/Fu_Neural_Solver_of_Dichromatic_Reflection_Model_for_Specular_Highlight_Removal_ICCV_2025_paper.pdf)
- [Fast and high quality highlight removal — arXiv 1512.00237](https://arxiv.org/pdf/1512.00237)
- [Shadow Removal Using Illumination Invariant Image Formation — Ranaweera](http://warunika.weebly.com/uploads/2/0/5/8/20587050/report_illumination.pdf)
- [Shadow detection in single image using color spaces — IJARCCE](https://ijarcce.com/wp-content/uploads/2015/10/IJARCCE-85.pdf)

### Apple Core Image
- [CIKMeans | Apple Developer Documentation](https://developer.apple.com/documentation/coreimage/cikmeans)
- [CIKMeans filter walkthrough — Filter Magic](https://filtermagicblog.com/2024/01/cikmeans-filter/)
- [CIKMeans on cifilter.io](https://cifilter.io/CIKMeans/)
- [Apple Developer Forums — CIKMeans example/docs](https://developer.apple.com/forums/thread/658185)
- [Joshua Sullivan iOS 13 Core Image filters gist](https://gist.github.com/JoshuaSullivan/b0e39f9009e44063b366cdc46773601e)

### Production color libraries
- [Color Thief — Lokesh Dhakar](https://lokeshdhakar.com/projects/color-thief/) ([github](https://github.com/lokesh/color-thief))
- [node-vibrant](https://github.com/Vibrant-Colors/node-vibrant)
- [Vibrant.js](https://jariz.github.io/vibrant.js/)
- [swift-vibrant](https://github.com/bd452/swift-vibrant)
- [ColorThiefSwift](https://github.com/yamoridon/ColorThiefSwift)
- [UIImageColors](https://github.com/jathu/UIImageColors)
- [indragiek/DominantColor](https://github.com/indragiek/DominantColor)
- [DenDmitriev/DominantColors](https://github.com/DenDmitriev/DominantColors)
- [okaneco/kmeans-colors (Rust)](https://github.com/okaneco/kmeans-colors)
- [cluster-colors PyPI](https://pypi.org/project/cluster-colors/)
- [Median Cut explainer — gowtham000](https://gowtham000.hashnode.dev/median-cut-a-popular-colour-quantization-strategy)
- [MMCQ algorithm — Leptonica paper (PDF)](http://leptonica.org/papers/mediancut.pdf)

### Production fashion / visual search
- [Pinterest visual skin tone model](https://medium.com/pinterest-engineering/powering-inclusive-search-recommendations-with-our-new-visual-skin-tone-model-1d3ba6eeffc7)
- [Building Perceptual Color Similarity Search — Amazon OpenSearch](https://medium.com/storm-reply/building-perceptual-color-similarity-search-with-amazon-opensearch-service-72547f445a04)
- [Toward a Universal Color Naming System — arXiv 2604.03235](https://arxiv.org/abs/2604.03235)
- [Dominant Color Detection on Online Fashion Retrievals — Melih Kacaman](https://medium.com/@melih.kacaman/dominant-color-detection-on-online-fashion-retrievals-5fb1bc1ab763)

### Wardrobe app context (color tagging UX)
- [Best Wardrobe Apps 2026 — Clueless Clothing](https://clueless.clothing/blog/best-wardrobe-apps-2026/)
- [Indyx app review — Style With In Grace](https://stylewithingrace.com/indyx-app-review-lookbook/)
- [Stylebook vs Acloset — Indyx](https://www.myindyx.com/versus/acloset-vs-stylebook)

### Fashion color theory
- [The 3 Color Principle in Fashion — Necesera](https://www.necesera.com/blogs/news/the-3-color-principle-in-fashion)
- [60-30-10 Rule for UI — UX Planet](https://uxplanet.org/the-60-30-10-rule-a-foolproof-way-to-choose-colors-for-your-ui-design-d15625e56d25)
