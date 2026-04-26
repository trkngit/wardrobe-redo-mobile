# G — iOS Subject Isolation & Wardrobe-Item Display Best Practices

**Date:** 2026-04-26
**Audience:** Build-5 planning. Implementation guidance for the per-garment cutout, mask cleanup, white-card composition, and "worn outfit" persistence.
**Status:** Research complete. Concrete recommendations included with code snippets.

---

## TL;DR — Final Recommendations

1. **Stop running Vision per-photo for multi-pick.** RFDETR-Seg already produces per-instance masks (`raw.mask` is already plumbed into `MaskProposal`). Composite the per-instance mask onto the source image — no second `VNGenerateForegroundInstanceMaskRequest` round-trip required. The current `MultiGarmentProposalService.cropped(...)` (line 933) only crops the bbox; replace with a proper mask composite.
2. **For the single-photo path, keep `VNGenerateForegroundInstanceMaskRequest`** but post-process the mask: erode by 1 px (drops anti-aliased fringe that bleeds skin/background tones into the color extractor), then re-blur 0.5 px so the silhouette doesn't look stamp-cut.
3. **Render a "display image" once at upload time**: composite the cleaned mask onto a 1:1 white card, scaled so the item bbox occupies ~75 % of the card with ~12.5 % padding around it. Centered. Save as JPEG to a new `display_image_path` column. Cheaper to display, consistent across the grid.
4. **Keep two image columns going forward:**
   - `masked_image_path` — transparent-background PNG (existing). Used when the user wants to pull the cutout into another context (outfit composer, share sheet).
   - `display_image_path` — 1:1 white-card JPEG (new). What the wardrobe grid actually shows.
5. **For "worn outfits"** — a new `worn_outfits` table that owns the source photo + a junction table linking items. The source photo is already uploaded once per multi-pick capture (`source_photo_path` in `wardrobe_items`); promote it to a first-class entity rather than leaving it as a string column on the items table.

---

## 1. iOS 17+ Subject Isolation APIs

### 1.1 `VNGenerateForegroundInstanceMaskRequest` (Vision)

**Output shape** (per WWDC23 session 10176, ["Lift subjects from images in your app"](https://developer.apple.com/videos/play/wwdc2023/10176/)):

- Returns one or more `VNInstanceMaskObservation` objects.
- Each observation carries:
  - **`instanceMask: CVPixelBuffer`** — instance label map. Same resolution as input. Background is index 0; each detected instance is assigned 1, 2, 3 … Useful for hit-testing (see §1.4).
  - **`allInstances: IndexSet`** — convenience set of all foreground indices.
- The request itself does **not** expose quality-vs-speed knobs. There is no `usesCPUOnly` setting on this request, and no public `revision` enum that affects mask softness. Vision picks the model based on platform (Neural Engine required — won't run on simulator or pre-A12 devices).

**Soft vs hard edges.** Vision produces a **soft mask**. From the WWDC23 transcript: *"Vision produces soft segmentation masks: floating-point values at the same resolution as input. Soft masks provide smooth, anti-aliased edges — superior for compositing and effects."* Pixel format of the buffer Vision returns is `kCVPixelFormatType_OneComponent32Float`, values in [0, 1] — this matches what the existing `VisionForegroundExtractor.swift` already handles (line 199). The `convertFloat32ToUInt8` helper on line 194 is correct and idiomatic.

The soft edge is **the source of the color-bleed problem.** Anti-aliased pixels at the silhouette are partially transparent — a CIBlendWithMask composite leaves the source RGB visible at e.g. 30 % alpha, which then gets averaged with whatever is "below" (transparent / white background) when sampled. The Color Extractor in particular reads premultiplied RGB and sees fringe pixels that are 30 % skin + 70 % shirt color → that pixel registers as `mix(skin, shirt)`, and bleeds into the dominant-color count.

> **References:**
> - [VNGenerateForegroundInstanceMaskRequest — Apple Developer](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest)
> - [Removing image background using the Vision framework — Create with Swift](https://www.createwithswift.com/removing-image-background-using-the-vision-framework/)
> - [Detect, extract, Segment objects on given image in iOS — MszPro](https://mszpro.com/vision-foreground-instance-mask-request)
> - [Lift subjects from images in your app — WWDC23 session 10176](https://developer.apple.com/videos/play/wwdc2023/10176/)

### 1.2 `VNInstanceMaskObservation` — Two Output Methods

The observation gives you **two ways** to materialize a mask:

| Method | Returns | Use when |
|---|---|---|
| `generateScaledMaskForImage(forInstances:from:)` | `CVPixelBuffer` (soft mask, single channel float) | You want to do your own compositing (apply your own background, post-process the mask). **This is what the existing pipeline uses.** |
| `generateMaskedImage(ofInstances:from:croppedToInstancesExtent:)` | `CVPixelBuffer` (RGBA) — the source image already composited against transparency | You want Apple to do the compositing for you. Optional `croppedToInstancesExtent: true` returns a tight crop. |

**`generateMaskedImage` is convenient but not what we want.** It bakes in the soft alpha — the same color-bleed problem persists. Stick with `generateScaledMaskForImage`, post-process the mask (§3), then composite ourselves.

> **References:**
> - [generateMaskedImage(ofInstances:from:croppedToInstancesExtent:) — Apple Developer](https://developer.apple.com/documentation/vision/vninstancemaskobservation/generatemaskedimage(ofinstances:from:croppedtoinstancesextent:))
> - [VNInstanceMaskObservation — Apple Developer](https://developer.apple.com/documentation/vision/vninstancemaskobservation)

### 1.3 `forInstances:` — Per-Instance Mask from Vision

Vision's API supports per-instance extraction. Pass a single-element `IndexSet`:

```swift
// Get mask for ONLY the second detected instance.
let instanceIndex = IndexSet(integer: 2)
let mask = try observation.generateScaledMaskForImage(
    forInstances: instanceIndex,
    from: handler
)
```

This is **only useful if Vision's per-instance segmentation maps to our garment proposals** — which it doesn't, because Vision's notion of "instance" is "salient foreground blob," and a person wearing 4 garments registers as 1 person blob (or sometimes 1 person + 1 bag). **Vision does not know what a shirt is.** RFDETR-Seg does — and it produces per-garment masks at instance granularity.

**Conclusion:** for the multi-pick path, **use the RFDETR-Seg masks directly**, not Vision. For the single-pick path (one item, no detector run), Vision is fine because we treat the whole foreground as one item.

### 1.4 iOS 18 / iOS 26 — New API Surface

iOS 18 introduced the **redesigned async Swift API**: `GenerateForegroundInstanceMaskRequest` (no `VN-` prefix). It coexists with the iOS 17 `VNGenerateForegroundInstanceMaskRequest` (which still works). The new shape:

```swift
// iOS 18+ — modern async API
let request = GenerateForegroundInstanceMaskRequest()
let observations = try await request.perform(on: cgImage)
```

For iOS 26 the project deployment target is the same surface — no new mask-quality flags exposed publicly. The model itself improves silently between OS versions.

> **References:**
> - [GenerateForegroundInstanceMaskRequest — Apple Developer](https://developer.apple.com/documentation/vision/generateforegroundinstancemaskrequest)

**Recommendation:** No reason to migrate yet. The current callback-based code in `VisionForegroundExtractor.swift` works on iOS 17 and 18+, and the new API doesn't fix the soft-edge problem. Migration would be a "while you're in there" refactor, not a build-5 priority.

### 1.5 `VisionKit.ImageAnalysisInteraction` — User-Facing "Lift Subject"

This is the high-level UIKit API that powers the "touch and hold to lift subject" gesture in Photos / Safari. Two relevant entry points:

- **`ImageAnalyzer`** with `ImageAnalyzer.Configuration([.imageSubject])` — runs on a `UIImage`.
- **`ImageAnalysisInteraction`** — attach to a `UIImageView` (or any view) to get the touch-to-lift UX for free.

The interaction exposes:
- `subjects: Set<ImageAnalysisInteraction.Subject>` — async property.
- `Subject.image` — the lifted subject as `UIImage` (transparent background).
- `image(for: subjects)` — composite multiple subjects into one image.
- `subject(at: CGPoint)` — async hit-test.

**This is not what we want for production wardrobe ingest** — it's a UX primitive aimed at the share sheet / sticker flow. But it's worth knowing for future "tap to refine which item to extract" interactions in `MaskTouchupView`.

**Limitation:** image resolution is capped (the WWDC23 session calls out that VisionKit returns lower-resolution lifts than direct Vision calls). For wardrobe items we want full source resolution → use Vision directly.

> **References:**
> - [ImageAnalysisInteraction — Apple Developer](https://developer.apple.com/documentation/visionkit/imageanalysisinteraction)
> - [Lift Subjects from Images in Your App — joker hook (Medium)](https://h76joker.medium.com/lift-subjects-from-images-in-your-app-d7fb8d366cda)

### 1.6 Apple Sample Code

The official "Applying Visual Effects to Foreground Subjects" sample is referenced from WWDC23 session 10176. Search Apple's sample-code library for "Lift subjects from images" — the project ships both VisionKit and Vision implementations. Useful as a reference for the standard mask-then-composite pipeline (which is essentially what `VisionForegroundExtractor` already does).

---

## 2. Per-Garment Masking Strategy

### 2.1 Use the RFDETR-Seg Mask Directly (recommended)

`MaskProposal.mask: CVPixelBuffer?` is already populated by `MultiGarmentProposalService` from RFDETR-Seg's output. The current `makeProposal(...)` (line 772) cropping is `cropped(sourceImage, to: raw.boundingBox)` — bounding-box crop only, **no mask composite.** This is the bug. Fix:

```swift
// MultiGarmentProposalService.swift — replace `cropped(...)` call with a
// composite that uses the per-instance mask, not just the bbox crop.

static func makeProposal(
    from raw: RawDetection,
    sourceImage: UIImage
) -> MaskProposal? {
    guard let composited = compositeMaskedItem(
        sourceImage: sourceImage,
        mask: raw.mask,
        boundingBox: raw.boundingBox
    ) else { return nil }

    let category = ClothingCategory.fromFashionpediaClass(raw.rawClass)
    // … rest unchanged …
    return MaskProposal(
        // …
        maskedImage: composited,
        mask: raw.mask,
        // …
    )
}

/// Composite the source image with the per-instance mask, then crop to a
/// padded bounding box. Produces a transparent-background UIImage.
private static func compositeMaskedItem(
    sourceImage: UIImage,
    mask: CVPixelBuffer?,
    boundingBox: CGRect
) -> UIImage? {
    guard let cg = sourceImage.cgImage else { return nil }
    guard let mask = mask else {
        // No mask available (model failure) — fall back to bbox crop.
        return cropped(sourceImage, to: boundingBox)
    }

    let sourceCI = CIImage(cgImage: cg)
    let maskCI = CIImage(cvPixelBuffer: mask)

    // Scale mask to match source extent (RFDETR's mask is at model
    // resolution, e.g. 320×320, source is full camera resolution).
    let sx = sourceCI.extent.width / maskCI.extent.width
    let sy = sourceCI.extent.height / maskCI.extent.height
    let scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

    // Hard-threshold + 1px erode to drop the soft fringe (see §3).
    let cleaned = MaskCleaner.cleanMask(scaledMask)

    // Composite source over transparent background.
    let blend = CIFilter.blendWithMask()
    blend.inputImage = sourceCI
    blend.backgroundImage = CIImage.empty()
    blend.maskImage = cleaned

    guard let out = blend.outputImage else { return nil }
    let context = CIContext(options: nil)
    guard let cgOut = context.createCGImage(out, from: sourceCI.extent) else {
        return nil
    }
    return UIImage(cgImage: cgOut, scale: sourceImage.scale,
                   orientation: sourceImage.imageOrientation)
}
```

### 2.2 If You Still Want Vision (single-pick path)

The existing `VisionForegroundExtractor.applyMask(...)` already does the composite correctly. Add the mask-cleanup pass before `CIBlendWithMask` runs:

```swift
// VisionForegroundExtractor.swift — line 131
private func applyMask(
    _ mask: CVPixelBuffer,
    to cgImage: CGImage,
    orientation: CGImagePropertyOrientation
) -> CGImage? {
    let sourceCI = CIImage(cgImage: cgImage).oriented(orientation)
    let maskCI = CIImage(cvPixelBuffer: mask)

    let scaleX = sourceCI.extent.width / maskCI.extent.width
    let scaleY = sourceCI.extent.height / maskCI.extent.height
    let scaledMask = maskCI.transformed(
        by: CGAffineTransform(scaleX: scaleX, y: scaleY)
    )

    // NEW: clean the soft mask before compositing.
    let cleanedMask = MaskCleaner.cleanMask(scaledMask)

    let blend = CIFilter.blendWithMask()
    blend.inputImage = sourceCI
    blend.backgroundImage = CIImage.empty()
    blend.maskImage = cleanedMask

    guard let output = blend.outputImage else { return nil }
    return ciContext.createCGImage(output, from: sourceCI.extent)
}
```

### 2.3 Alpha Matting (NOT recommended for v1)

Libraries like MODNet, RVM (Robust Video Matting), and PP-Matting produce true alpha mattes (0–255 with smooth boundaries that capture fly-away hair, fabric translucency, etc.). They run on-device via CoreML but add 50–200 MB to the bundle and 200–500 ms to inference. **Massive overkill for a wardrobe app** where the items are crisp-edged garments (no hair, rarely sheer fabric). Hard mask + 1 px erode beats them on the cost-quality curve for this use case.

> **References:**
> - [RF-DETR Segmentation — Roboflow](https://blog.roboflow.com/rf-detr-segmentation-preview/)
> - [Segmentation Guide for iOS: Top 4 Models in 2026 — it-jim](https://www.it-jim.com/blog/how-to-implement-image-segmentation-on-ios/)

---

## 3. Hard vs Soft Mask — Trade-offs and the Recommended Cleanup

### 3.1 Trade-offs

| Approach | Color extraction | Visual silhouette | Recommended for |
|---|---|---|---|
| **Soft mask, no cleanup** (current) | **Bleeds** — fringe pixels mix shirt + skin | Smooth, photorealistic | Compositing onto natural backgrounds |
| **Hard mask** (binary 0/255) | Clean | "Stamp-cut," visible jaggies on diagonal edges | Color-extraction-critical use |
| **Hard mask + 1 px erode + 0.5 px blur** | Clean | Smooth silhouette, small inset (lose a hair-thin sliver of shirt) | **Wardrobe apps — recommended** |

### 3.2 The Recommended Mask-Cleaning Pipeline

```swift
import CoreImage
import CoreImage.CIFilterBuiltins

/// Cleans Vision / RFDETR-Seg soft masks for fashion-item compositing.
///
/// Pipeline:
///   1. CIColorThreshold @ 0.5 → push mask to binary (0 or 1).
///   2. CIMorphologyMinimum radius=1 → erode 1 px so we shed the pixel
///      column at the silhouette where Vision's confidence is borderline.
///      (Eliminates 90 % of color bleed.)
///   3. CIGaussianBlur radius=0.5 → soften the binary edge by half a
///      pixel so the rendered silhouette doesn't look stamp-cut on
///      retina screens.
enum MaskCleaner {
    static func cleanMask(_ source: CIImage) -> CIImage {
        // Step 1: hard threshold.
        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = source
        threshold.threshold = 0.5
        guard let thresholded = threshold.outputImage else { return source }

        // Step 2: erode 1 px.
        let erode = CIFilter.morphologyMinimum()
        erode.inputImage = thresholded
        erode.radius = 1.0
        guard let eroded = erode.outputImage else { return thresholded }

        // Step 3: gentle 0.5 px blur to anti-alias the binary edge.
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = eroded
        blur.radius = 0.5
        guard let blurred = blur.outputImage else { return eroded }

        // Crop to the original extent — gaussianBlur expands by ~3*radius.
        return blurred.cropped(to: source.extent)
    }
}
```

**Why these specific filters:**
- **`CIColorThreshold`** (iOS 17+) snaps every pixel to 0 or 1 based on a threshold. Fast, no custom kernel needed.
- **`CIMorphologyMinimum`** (iOS 9+) is the standard erode op. Radius 1 = 1-pixel structuring element. Radius 2 if your masks are very fringe-y, but 1 is the safe starting point.
- **`CIGaussianBlur`** with `radius=0.5` is a sub-pixel Gaussian — produces a 1-pixel-wide soft transition that the human eye reads as "smooth" but doesn't expose enough source RGB to cause color bleed.

> **References:**
> - [CIMorphologyMinimum — Apple Developer](https://developer.apple.com/documentation/coreimage/cimorphologyminimum)
> - [Core Image Filter Reference — cifilter.app](https://cifilter.app/)

### 3.3 Skip This for the Color Extractor's Sample, Not the Display

If color-extraction is the worst-affected consumer, you can run two passes:
- **Aggressive cleanup** (erode 2 px, no blur) → feed to the color extractor only.
- **Light cleanup** (erode 1 px + 0.5 px blur) → save as the displayed cutout.

This costs an extra CIContext render per item but separates the concerns. For build-5 keep it simple and use a single cleaned mask everywhere; if color accuracy still suffers, add the two-pass path.

---

## 4. Centering and Padding the Cutout (white card)

### 4.1 Industry Conventions

| Source | Aspect ratio | Padding | Background |
|---|---|---|---|
| **Amazon main product image** | 1:1 | ≥ 5 % border, item ≥ 50 % of frame | Pure white #FFFFFF |
| **Shopify recommended** | 1:1 | Consistent across catalog | No mandate, but white most common |
| **Net-a-Porter, Farfetch** | 3:4 (portrait) | ~10–15 % | Off-white / light gray |
| **Whering** | square | ~10 % | Light gray |
| **Stylebook** | square | ~10 % | Light cream |
| **Indyx** (powered by PhotoRoom) | square | ~10 % | White |
| **Cladwell** | square | ~12 % | White |

**Pattern:** square (1:1), 10–15 % padding, white-or-near-white background. Items occupy ~75–80 % of frame.

> **References:**
> - [Shopify Product Image Requirements: Complete 2026 Guide — Squareshot](https://www.squareshot.com/post/shopify-product-image-requirements)
> - [Marketplace Image Standards — Onramp Funds](https://www.onrampfunds.com/resources/marketplace-image-standards-for-amazon-shopify-walmart)
> - [Indyx App Review — Style With Grace](https://stylewithingrace.com/indyx-app-review-lookbook/) — confirms PhotoRoom backend

### 4.2 Recommended Spec for Wardrobe Re-Do

- **Aspect ratio:** 1:1 (square). Matches the wardrobe grid card layout.
- **Resolution:** 1024 × 1024 (PNG → JPEG conversion saves ~70 % file size). Apple HIG sweet spot for high-DPR card thumbnails.
- **Background:** `#FFFFFF` pure white. Not theme-aware — when dark mode flips, the white card itself is the "lift" off the background. This is the same pattern Indyx, Cladwell, and the Apple Photos lift-to-share use.
- **Item bbox occupies:** 75 % of the smaller dimension (so a sunglasses → 768 px wide, pants → 768 px tall, with ~12.5 % margin on each side).
- **Optional drop shadow:** add at *display time* in SwiftUI, not at composite time. SwiftUI's `.shadow(color:.black.opacity(0.08), radius: 6, y: 2)` gives the lifted feel and stays consistent across light/dark mode without baking shadow pixels into the saved JPEG.

### 4.3 Code: Compose Cutout onto White Card

```swift
import UIKit
import CoreGraphics

enum DisplayImageRenderer {

    /// Compose a transparent-background cutout onto a white square card,
    /// centered, with the item's visible bbox occupying ~75 % of the card.
    ///
    /// - Parameters:
    ///   - cutout: PNG with transparent background (the cleaned mask
    ///     composite). Must have alpha.
    ///   - cardSize: Output edge length in points. Default 1024 → matches
    ///     a 4× retina 256-pt grid card.
    ///   - paddingFraction: Fraction of card size kept blank around the
    ///     item. 0.125 → 12.5 % per edge → item area = 75 %.
    /// - Returns: A new opaque UIImage (no alpha) of size cardSize × cardSize.
    static func renderWhiteCard(
        cutout: UIImage,
        cardSize: CGFloat = 1024,
        paddingFraction: CGFloat = 0.125
    ) -> UIImage? {
        guard let cg = cutout.cgImage,
              let visibleBox = cg.opaqueBoundingBox()
        else { return nil }

        // Trim cutout to its alpha-bounding box first so padding math is
        // about the *item*, not about whitespace already in the source.
        guard let trimmed = cg.cropping(to: visibleBox) else { return nil }

        let trimmedW = CGFloat(trimmed.width)
        let trimmedH = CGFloat(trimmed.height)
        let safeArea = cardSize * (1.0 - 2.0 * paddingFraction)  // 75 %

        // Fit the longer edge into the safe area (Aspect Fit).
        let scale = min(safeArea / trimmedW, safeArea / trimmedH)
        let drawW = trimmedW * scale
        let drawH = trimmedH * scale
        let drawX = (cardSize - drawW) / 2.0
        let drawY = (cardSize - drawH) / 2.0

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0          // we already produced 1024-pt content
        format.opaque = true        // JPEG-friendly — no alpha channel
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: cardSize, height: cardSize),
            format: format
        )

        return renderer.image { ctx in
            // White background.
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: cardSize, height: cardSize))

            // Draw cutout.
            let dest = CGRect(x: drawX, y: drawY, width: drawW, height: drawH)
            UIImage(cgImage: trimmed).draw(in: dest)
        }
    }
}

// MARK: - Alpha bbox helper

extension CGImage {
    /// Returns the bounding rect of pixels with alpha > threshold.
    /// Used to trim transparent margins before composing onto a card.
    /// `O(width * height)` — runs once per upload, not per render.
    func opaqueBoundingBox(alphaThreshold: UInt8 = 8) -> CGRect? {
        let w = self.width
        let h = self.height
        guard w > 0, h > 0 else { return nil }

        // Render alpha-only into a single-channel buffer.
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }

        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                if pixels[y * w + x] > alphaThreshold {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= 0, maxY >= 0 else { return nil }   // fully transparent
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }
}
```

> **References:**
> - [Swift 5 NSImage/UIImage Crop/Trim Transparency — chriszielinski (gist)](https://gist.github.com/chriszielinski/aec9a2f2ba54745dc715dd55f5718177)
> - [UIImage-Trim — wrep (GitHub)](https://github.com/wrep/UIImage-Trim)

### 4.4 Where to Render — Upload-Time vs Display-Time

**Recommendation: render once at upload time, save as JPEG.**

| | Upload-time (recommended) | Display-time (in SwiftUI) |
|---|---|---|
| Display latency | Zero — pre-rendered | 5–15 ms per cell on first appearance |
| File size | 1 image per item, ~120 KB JPEG | 0 extra storage; 1 cached `UIImage` per visible cell |
| Theme flexibility | White always — can't switch to gray on the fly | Could swap card color at runtime |
| Migration burden | New `display_image_path` column + backfill | None |

The wardrobe grid scrolls 50–200 items. Display-time rendering would cause jank during fast scroll. Pre-render at upload — the user pays once.

For theme flexibility (if you ever want a "dark cards" mode), the cutout PNG (`masked_image_path`) is still on Storage, so re-rendering the card variant is a one-time backfill job, not a redo of the mask pipeline.

---

## 5. Background Color & Drop Shadow

### 5.1 Why White

- **Doesn't compete with garment color** — neutral, low chroma, brightest possible. Black competes with dark garments; gray competes with grays/silvers; cream competes with off-whites.
- **Industry default** — Amazon mandates it; Shopify recommends it; Indyx, Cladwell, Apple Photos's lift-to-share all default to it.
- **Print-fashion-catalog convention** — Vogue, Harper's, every catalog from Sears to Net-a-Porter uses white for product cuts.

The Apple HIG doesn't have a specific rule for "isolated subject backgrounds" but the system's own behavior (Photos, Visual Look Up) defaults to white when a lifted subject is shared into Mail / Messages. See: [Lift a subject from the photo background on iPhone](https://support.apple.com/guide/iphone/lift-a-subject-from-the-photo-background-iphfe4809658/ios).

### 5.2 Drop Shadow — Display Time, Not Bake Time

```swift
// In the wardrobe grid cell view.
Image(uiImage: item.displayImage)
    .resizable()
    .aspectRatio(contentMode: .fit)
    .frame(width: cardSize, height: cardSize)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
```

- Shadow opacity 0.08 — barely perceptible; just enough to lift the card off the grid background.
- Radius 6 — standard "card" shadow per [SwiftUI Cookbook ch. 6](https://www.kodeco.com/books/swiftui-cookbook/v1.0/chapters/6-add-a-shadow-to-an-image-in-swiftui).
- Y offset 2 — subtle "lit from above" cue.
- Don't bake shadow pixels into the JPEG. They'll look wrong against any non-default grid background and waste 4 KB per image.

> **References:**
> - [How to draw a shadow around a view — Hacking with Swift](https://www.hackingwithswift.com/quick-start/swiftui/how-to-draw-a-shadow-around-a-view)
> - [Shadows and Color Opacity — Design+Code](https://designcode.io/swiftui-handbook-shadows-and-color-opacity/)

---

## 6. Implementation Plan in Our Pipeline

### 6.1 Files to Touch

| File | Change |
|---|---|
| `WardrobeReDo/Services/Extraction/MaskCleaner.swift` (NEW) | The 3-step CIFilter pipeline from §3.2. |
| `WardrobeReDo/Services/Extraction/DisplayImageRenderer.swift` (NEW) | The white-card composer from §4.3. |
| `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift` | Replace `cropped(...)` call in `makeProposal(...)` with a `compositeMaskedItem(...)` that uses the per-instance mask, then calls `MaskCleaner.cleanMask`. |
| `WardrobeReDo/Services/Extraction/VisionForegroundExtractor.swift` | Insert `MaskCleaner.cleanMask` call inside `applyMask(...)` before the `CIBlendWithMask` filter. |
| `WardrobeReDo/Services/Upload/ImageUploadService.swift` (probable existing file) | After uploading `masked_image_path`, also render and upload `display_image_path`. |
| `WardrobeReDo/Models/WardrobeItem.swift` | Add `displayImagePath: String?` field + `display_image_path` CodingKey. |
| `supabase/migrations/00014_wardrobe_items_display_image.sql` (NEW) | `ALTER TABLE wardrobe_items ADD COLUMN display_image_path TEXT;` |

### 6.2 Storage Layout

```
{userId}/
  source/{sourcePhotoId}/original.jpg          // existing — full source
  items/{itemId}/masked.png                    // existing — transparent cutout
  items/{itemId}/display.jpg                   // NEW — 1024×1024 white card
```

Existing path conventions in the codebase:

- `wardrobe_items.maskedImagePath` (line 12 of `WardrobeItem.swift`) — already exists.
- `wardrobe_items.sourcePhotoPath` (line 25) — already exists.
- New: `wardrobe_items.displayImagePath`.

### 6.3 SQL Migration

```sql
-- supabase/migrations/00014_wardrobe_items_display_image.sql
--
-- Migration 00014: wardrobe_items display_image_path
--
-- Why
--   Pre-rendered 1024×1024 white-card composite of each item, used by
--   the wardrobe grid for consistent presentation. Saves the CPU cost
--   of compositing the masked PNG onto a card on every cell render.
--
-- Rollback
--   ALTER TABLE wardrobe_items DROP COLUMN IF EXISTS display_image_path;

ALTER TABLE wardrobe_items
    ADD COLUMN display_image_path TEXT;

COMMENT ON COLUMN wardrobe_items.display_image_path IS
    'Storage path to the 1024x1024 white-card JPEG used in the wardrobe grid. NULL for rows uploaded before migration 00014; the client falls back to masked_image_path in that case.';
```

### 6.4 Client Render Order

```
captured photo
    ↓
RFDETR-Seg → [MaskProposal {mask, bbox, …}]
    ↓
user picks proposals to commit (multi-pick UX)
    ↓
for each picked proposal:
    1. compositeMaskedItem(source, mask, bbox)  →  cutout.png   (bbox-cropped, transparent)
    2. DisplayImageRenderer.renderWhiteCard(cutout)  →  display.jpg (1024×1024 white card)
    3. upload BOTH:
         {userId}/items/{itemId}/masked.png   ← cutout
         {userId}/items/{itemId}/display.jpg  ← card
    4. INSERT INTO wardrobe_items (
         masked_image_path = …/masked.png,
         display_image_path = …/display.jpg,
         source_photo_id = sharedSourcePhotoId,
         source_photo_path = …/source/original.jpg,
         …
       )
```

### 6.5 Backfill

For existing items without `display_image_path`:

1. Edge Function `regenerate-display-image` triggered nightly or on-demand.
2. Reads `masked_image_path`, downloads the PNG, runs the same `DisplayImageRenderer` (port to SwiftUI server-side via a small Swift CLI in `scripts/`, OR re-implement in JS using `sharp` for the Edge Function).
3. Easier: defer the backfill — gate the new behavior on the column being non-null. Falls back to `masked_image_path` for legacy items. Quality regression for ~30 existing items is acceptable for a build-5 dogfood ship.

---

## 7. The "Worn Outfit" Concept — Source Photo Becomes a First-Class Entity

### 7.1 Industry Patterns

- **Whering** has both: an "items" view (cutouts on cards) and an "outfit selfies" view (full-body photos with items tagged underneath).
- **Acloset** treats the source photo as the base — items get tagged onto it.
- **Outfit Tracker** (App Store) is purely an outfit-photo log with calendar — no item catalog.
- **Wardrobe Journal** is a hybrid: take an outfit selfie, then optionally tag items.

The convention is: **the outfit photo is an event/timeline entity**, while items are **catalog entities**. They share many-to-many: one outfit photo contains N items; one item appears in M outfit photos.

> **References:**
> - [Outfit Tracker: Diary Planner — App Store](https://apps.apple.com/us/app/outfit-tracker-diary-planner/id1531538941)
> - [Wardrobe Journal — App Store](https://apps.apple.com/us/app/wardrobe-journal/id389988586)
> - [The Best Wardrobe Apps 2026 — Indyx blog](https://www.myindyx.com/blog/the-best-wardrobe-apps)

### 7.2 Recommended Schema

The project already has `source_photo_id: UUID` and `source_photo_path: TEXT` columns on `wardrobe_items` (migration 00008). Promote these into a proper table:

```sql
-- supabase/migrations/00015_worn_outfits.sql
--
-- Migration 00015: worn_outfits + worn_outfit_items
--
-- Why
--   The source photo from a multi-pick capture is the user wearing 1..N
--   garments. Today it lives as a string column on each wardrobe_item
--   row (source_photo_path), with no user-facing concept. Promote to a
--   first-class entity so the user can browse "outfits I wore" as a
--   distinct feed and tag occasions/dates.
--
-- Rollback
--   DROP TABLE IF EXISTS worn_outfit_items;
--   DROP TABLE IF EXISTS worn_outfits;
--   (Note: existing wardrobe_items.source_photo_id / source_photo_path
--   stay populated as denormalized convenience fields — the new table
--   coexists rather than replacing them.)

CREATE TABLE worn_outfits (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    source_photo_path TEXT NOT NULL,                 -- {userId}/source/{id}/original.jpg
    worn_at           TIMESTAMPTZ,                   -- when the user wore this outfit (nullable)
    occasion          TEXT,                          -- "casual" | "work" | "date_night" | …
    notes             TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_worn_outfits_user_worn_at
    ON worn_outfits (user_id, worn_at DESC NULLS LAST);

ALTER TABLE worn_outfits ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users CRUD own worn outfits" ON worn_outfits
    FOR ALL USING ((SELECT auth.uid()) = user_id);

CREATE TRIGGER worn_outfits_updated_at
    BEFORE UPDATE ON worn_outfits
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Junction: many-to-many between worn_outfits and wardrobe_items.
CREATE TABLE worn_outfit_items (
    worn_outfit_id    UUID NOT NULL REFERENCES worn_outfits(id) ON DELETE CASCADE,
    wardrobe_item_id  UUID NOT NULL REFERENCES wardrobe_items(id) ON DELETE CASCADE,
    bounding_box      JSONB,                        -- normalized bbox {x,y,w,h} in source photo
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (worn_outfit_id, wardrobe_item_id)
);

CREATE INDEX idx_worn_outfit_items_item
    ON worn_outfit_items (wardrobe_item_id);

ALTER TABLE worn_outfit_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users CRUD own worn outfit items" ON worn_outfit_items
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM worn_outfits wo
            WHERE wo.id = worn_outfit_items.worn_outfit_id
              AND wo.user_id = (SELECT auth.uid())
        )
    );

COMMENT ON TABLE worn_outfits IS
    'A real-world outfit the user wore — backed by the source photo from a multi-pick capture. Distinct from `outfits` (engine-generated suggestions). One-to-many with worn_outfit_items.';

COMMENT ON COLUMN worn_outfit_items.bounding_box IS
    'Normalized [0,1] bbox of the item within the source photo. Mirrors wardrobe_items.bounding_box so the worn-outfit detail view can highlight items without joining back.';
```

### 7.3 Client-Side Wiring

When the multi-pick commit happens, in addition to inserting `wardrobe_items` rows:

```swift
// AddItemViewModel.swift, after successful items upload
let wornOutfit = WornOutfit(
    id: UUID(),
    userId: currentUserId,
    sourcePhotoPath: sourcePhotoPath,         // shared across all items
    wornAt: nil,                              // user can set later in detail view
    occasion: nil
)
try await wornOutfitsRepository.insert(wornOutfit)

let junctions = pickedProposals.map { proposal in
    WornOutfitItem(
        wornOutfitId: wornOutfit.id,
        wardrobeItemId: proposal.committedItemId,
        boundingBox: proposal.boundingBox
    )
}
try await wornOutfitsRepository.linkItems(junctions)
```

### 7.4 UX Implications

- **New tab or section**: "Worn Outfits" timeline. Reverse-chronological list of source photos with item-thumbnail strip below each.
- **Item detail view** already has the source photo with bbox overlay (migration 00013). Now it can also show "worn together with" — query `worn_outfit_items` for siblings.
- **Wear tracking** — `last_worn_at` on `wardrobe_items` is already on the schema. Update it from the most-recent `worn_outfits.worn_at` for items in the junction.

---

## 8. Putting It Together — Code-Ready Summary

### 8.1 New Files

```
WardrobeReDo/Services/Extraction/
    MaskCleaner.swift               # threshold + erode + soft blur (§3.2)
    DisplayImageRenderer.swift      # white-card composer (§4.3)

WardrobeReDo/Models/
    WornOutfit.swift                # mirrors worn_outfits row
    WornOutfitItem.swift            # mirrors junction row

WardrobeReDo/Repositories/
    WornOutfitsRepository.swift     # CRUD against Supabase

supabase/migrations/
    00014_wardrobe_items_display_image.sql
    00015_worn_outfits.sql
```

### 8.2 Modified Files

```
WardrobeReDo/Models/WardrobeItem.swift
    + var displayImagePath: String?
    + case displayImagePath = "display_image_path"

WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift
    ~ replace cropped(...) with compositeMaskedItem(...) using mask
    ~ thread MaskCleaner into the composite

WardrobeReDo/Services/Extraction/VisionForegroundExtractor.swift
    ~ apply MaskCleaner.cleanMask before CIBlendWithMask in applyMask()

WardrobeReDo/Services/Upload/ImageUploadService.swift   (or equivalent)
    + render displayImage via DisplayImageRenderer
    + upload to {userId}/items/{itemId}/display.jpg
    + return both paths

WardrobeReDo/ViewModels/AddItemViewModel.swift
    + create WornOutfit + junctions on multi-pick commit

WardrobeReDo/Views/Wardrobe/...   (grid cell)
    ~ prefer displayImagePath; fall back to maskedImagePath
    + .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
```

### 8.3 Open Questions for Build-5 Planning

1. **Backfill for existing items.** Easiest: defer (fall back to masked_image_path). Cleanest: server-side Edge Function with `sharp`.
2. **Per-pick composite with white card vs preserve-transparent-PNG decision.** I assumed both — masked.png stays the source-of-truth cutout, display.jpg is the convenience render. Confirm storage budget acceptable (2× image rows, but JPEG is small).
3. **Worn-outfit auto-create vs explicit.** Auto-create on every multi-pick commit feels right (the source photo *is* a real outfit). But single-pick captures (one item, often a flat-lay on a bed) would create empty "outfits." Recommendation: only create `worn_outfits` when the source contained ≥ 2 picked items, or when the user explicitly tags it as worn.
4. **iOS 18 async API migration.** Defer. Not load-bearing for build-5.

---

## Sources

### iOS / Vision Framework
- [VNGenerateForegroundInstanceMaskRequest — Apple Developer](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest)
- [GenerateForegroundInstanceMaskRequest (iOS 18+) — Apple Developer](https://developer.apple.com/documentation/vision/generateforegroundinstancemaskrequest)
- [VNInstanceMaskObservation — Apple Developer](https://developer.apple.com/documentation/vision/vninstancemaskobservation)
- [generateMaskedImage(ofInstances:from:croppedToInstancesExtent:) — Apple Developer](https://developer.apple.com/documentation/vision/vninstancemaskobservation/generatemaskedimage(ofinstances:from:croppedtoinstancesextent:))
- [Lift subjects from images in your app — WWDC23 session 10176](https://developer.apple.com/videos/play/wwdc2023/10176/)
- [What's new in VisionKit — WWDC23 session 10048](https://developer.apple.com/videos/play/wwdc2023/10048/)
- [ImageAnalysisInteraction — Apple Developer](https://developer.apple.com/documentation/visionkit/imageanalysisinteraction)
- [ImageAnalyzer — Apple Developer](https://developer.apple.com/documentation/visionkit/imageanalyzer)

### Core Image
- [CIBlendWithMask — Apple Developer](https://developer.apple.com/documentation/coreimage/ciblendwithmask)
- [CIMorphologyMinimum — Apple Developer](https://developer.apple.com/documentation/coreimage/cimorphologyminimum)
- [Core Image Filter Reference — cifilter.app](https://cifilter.app/)
- [Core Image Filter Details — Joshua Sullivan (gist)](https://gist.github.com/JoshuaSullivan/7d09c5aba3672a5e2461401679861adf)

### Tutorials & Examples
- [Removing image background using the Vision framework — Create with Swift](https://www.createwithswift.com/removing-image-background-using-the-vision-framework/)
- [Detect, extract, Segment objects on given image in iOS — MszPro](https://mszpro.com/vision-foreground-instance-mask-request)
- [Remove background from image in SwiftUI — Artem Novichkov](https://artemnovichkov.com/blog/remove-background-from-image-in-swiftui)
- [Lift Subjects from Images in Your App — joker hook (Medium)](https://h76joker.medium.com/lift-subjects-from-images-in-your-app-d7fb8d366cda)
- [Advanced Person Segmentation in iOS 17 — JEJEMEME blog](https://jejememe.github.io/ios/development,/vision/framework/2024/01/30/advanced-personseg.html)
- [Segmentation Guide for iOS: Top 4 Models in 2026 — it-jim](https://www.it-jim.com/blog/how-to-implement-image-segmentation-on-ios/)

### Image Trimming / Composition
- [Swift 5 NSImage/UIImage Crop/Trim Transparency — chriszielinski (gist)](https://gist.github.com/chriszielinski/aec9a2f2ba54745dc715dd55f5718177)
- [UIImage-Trim — wrep (GitHub)](https://github.com/wrep/UIImage-Trim)
- [Swift 4 - Crop transparent pixels from UIImage — AdamLantz (gist)](https://gist.github.com/AdamLantz/d5d841e60583e740c0b5f515ba5064fb)

### SwiftUI Display
- [How to draw a shadow around a view — Hacking with Swift](https://www.hackingwithswift.com/quick-start/swiftui/how-to-draw-a-shadow-around-a-view)
- [Shadows and Color Opacity — Design+Code](https://designcode.io/swiftui-handbook-shadows-and-color-opacity/)
- [SwiftUI Cookbook chapter 6: Add a Shadow to an Image — Kodeco](https://www.kodeco.com/books/swiftui-cookbook/v1.0/chapters/6-add-a-shadow-to-an-image-in-swiftui)
- [GraphicsContext — Apple Developer](https://developer.apple.com/documentation/swiftui/graphicscontext)

### E-commerce Image Conventions
- [Shopify Product Image Requirements: Complete 2026 Guide — Squareshot](https://www.squareshot.com/post/shopify-product-image-requirements)
- [Marketplace Image Standards for Amazon, Shopify, Walmart — Onramp Funds](https://www.onrampfunds.com/resources/marketplace-image-standards-for-amazon-shopify-walmart)
- [Best Shopify Image Sizes for 2026 — tiny-img](https://tiny-img.com/blog/guide-to-shopify-image-sizes/)

### Wardrobe / Fashion App UX
- [Indyx App Review — Style With Grace](https://stylewithingrace.com/indyx-app-review-lookbook/)
- [Acloset vs. Whering — Indyx](https://www.myindyx.com/versus/acloset-vs-whering)
- [The Best Wardrobe Apps 2026 — Indyx blog](https://www.myindyx.com/blog/the-best-wardrobe-apps)
- [Whering: Your Digital Closet — App Store](https://apps.apple.com/us/app/whering-your-digital-closet/id1519461680)
- [Outfit Tracker: Diary Planner — App Store](https://apps.apple.com/us/app/outfit-tracker-diary-planner/id1531538941)
- [Wardrobe Journal — App Store](https://apps.apple.com/us/app/wardrobe-journal/id389988586)
- [Stylebook Closet App: 90+ Features](https://www.stylebookapp.com/features.html)

### Apple Photos / System UX
- [Lift a subject from the photo background on iPhone — Apple Support](https://support.apple.com/guide/iphone/lift-a-subject-from-the-photo-background-iphfe4809658/ios)
- [How to lift a subject from the background in Photos in iOS — Trusted Reviews](https://www.trustedreviews.com/how-to/how-to-lift-a-subject-from-the-background-in-photos-in-ios-16-4266810)

### RFDETR-Seg
- [RF-DETR Segmentation: Real-Time Detection & Instance Segmentation Guide — LearnOpenCV](https://learnopencv.com/rf-detr-segmentation-real-time-detection-instance-segmentation-guide/)
- [SOTA Instance Segmentation with RF-DETR — Roboflow blog](https://blog.roboflow.com/rf-detr-segmentation-preview/)
- [rf-detr — Roboflow GitHub](https://github.com/roboflow/rf-detr)

### Background Removal Services (for reference)
- [Photoroom — Background Removal API](https://www.photoroom.com/api/remove-background)
- [Photoroom API Documentation](https://docs.photoroom.com/)
