import CoreImage
import CoreML
import CoreVideo
import Foundation
import UIKit
import os.log

extension MultiGarmentProposalService {
    // MARK: - Preprocessing

    /// Convert `image` into the `CVPixelBuffer` shape the model expects.
    /// Falls back to 1024×1024 if the model doesn't declare a fixed
    /// image constraint.
    static func preprocessedPixelBuffer(for image: UIImage, model: MLModel) -> CVPixelBuffer? {
        guard let cg = image.cgImage else { return nil }
        let inputs = model.modelDescription.inputDescriptionsByName
        let key = imageInputName(for: model)
        let constraint = key.flatMap { inputs[$0]?.imageConstraint }
        let width = constraint?.pixelsWide ?? 1024
        let height = constraint?.pixelsHigh ?? 1024
        return SAM2Extractor.pixelBuffer(from: cg, width: width, height: height)
    }

    static func imageInputName(for model: MLModel) -> String? {
        let inputs = model.modelDescription.inputDescriptionsByName
        let preferred = ["image", "input_image", "image_input", "pixel_values", "images"]
        if let hit = preferred.first(where: { inputs[$0]?.type == .image }) {
            return hit
        }
        return inputs.first(where: { $0.value.type == .image })?.key
    }

    // MARK: - DETR output decode

    /// Intermediate representation between the raw tensors and the
    /// user-facing `MaskProposal`. Kept internal so post-processing
    /// helpers (NMS, class map, mask composite) can be pure functions.
    struct RawDetection {
        let boundingBox: CGRect      // normalized [0,1] origin top-left
        let score: Float             // 0…1 objectness
        let rawClass: String         // Fashionpedia label or "unknown"
        let mask: CVPixelBuffer?     // source-res reconstruction (nil when mask head absent)
        /// Build 47 — second instance mask for a merged shoe pair. When
        /// `collapseShoePairs` fuses a left+right pair into one proposal,
        /// the loser's mask rides here so `compositeMaskedItem` can OR
        /// the two silhouettes and show BOTH shoes in the single cutout
        /// (the "shoe pair should show both shoes" request). Nil for
        /// every normal single-instance detection. Defaulted so the
        /// decode-path constructor and tests are unchanged.
        var secondaryMask: CVPixelBuffer? = nil
    }

    /// Best-effort decode of DETR-style outputs. RF-DETR's export names
    /// haven't fully stabilised in coremltools, so we probe a handful of
    /// likely names and decode the first matching set.
    ///
    /// Split out so tests can exercise post-processing by constructing
    /// `RawDetection` arrays directly without needing a live MLModel.
    static func decodeDETROutput(from prediction: MLFeatureProvider) -> [RawDetection] {
        // Preferred output names (RF-DETR 1.4 segmentation export).
        let boxKeys = ["pred_boxes", "boxes", "detection_boxes"]
        let scoreKeys = ["pred_scores", "scores", "detection_scores", "validity"]
        let classKeys = ["pred_classes", "classes", "class_ids", "detection_classes"]
        let logitKeys = ["pred_logits", "class_logits", "logits"]
        let maskKeys = ["pred_masks", "masks", "mask_logits", "segmentation"]

        guard let boxes = multiArray(for: boxKeys, in: prediction) else { return [] }

        let scores = multiArray(for: scoreKeys, in: prediction)
        let logits = multiArray(for: logitKeys, in: prediction)
        let classes = multiArray(for: classKeys, in: prediction)
        let masks = multiArray(for: maskKeys, in: prediction)
        // The segmentation head emits a per-query logits tensor of shape
        // `[1, num_queries, mask_H, mask_W]` (RFDETR-Seg-Small Fashionpedia
        // export verified via `xcrun coremlc metadata`: `pred_masks`
        // Float32 [1, 100, 192, 192]). We decode each query's slice into a
        // CVPixelBuffer at native model resolution and let
        // `compositeMaskedItem` scale it up to source extent.

        // Resolve how many queries the model emitted.
        let queryCount = boxes.shape[safe: 1]?.intValue ?? 0
        guard queryCount > 0 else { return [] }

        // Decode the mask tensor once into a flat buffer so we don't re-read
        // the boxed `MLMultiArray` accessor 36 K times per query. The decoder
        // returns nil on shape mismatch / nil tensor — every per-query
        // `decodeMask` call then falls through to `mask: nil` and the
        // existing rect-crop fallback in `compositeMaskedItem`. No new crash
        // paths introduced.
        let maskContext = masks.flatMap(MaskTensorContext.init(masks:))

        var result: [RawDetection] = []
        result.reserveCapacity(queryCount)

        for q in 0 ..< queryCount {
            let bbox = decodeBoundingBox(boxes, queryIndex: q)
            let rawScore = decodeScore(scores: scores, logits: logits, queryIndex: q)
            let rawClass = decodeClassLabel(classes: classes, logits: logits, queryIndex: q)
            let mask = maskContext.flatMap { ctx in
                decodeMask(from: ctx, queryIndex: q)
            }
            result.append(RawDetection(
                boundingBox: bbox,
                score: rawScore,
                rawClass: rawClass,
                mask: mask
            ))
        }
        return result
    }

    // MARK: - Mask decode

    /// Pre-flattened, sigmoided, thresholded mask tensor — built once per
    /// inference so per-query `decodeMask` calls are an O(H·W) memcpy
    /// rather than re-reading the boxed `MLMultiArray` accessor.
    ///
    /// The flattening + sigmoid + threshold runs once for the whole tensor
    /// (Q × H × W elements) regardless of how many queries we ultimately
    /// keep. This is fine: at the model's native size (100 × 192 × 192 ≈
    /// 3.7 M floats) the work is well below 10 ms on Neural Engine
    /// post-processing budget.
    struct MaskTensorContext {
        let queryCount: Int
        let height: Int
        let width: Int
        /// Binary [0, 1] values, length `queryCount * height * width`,
        /// row-major within each query slice. Stored as `UInt8` so the
        /// downstream `CVPixelBuffer` write is a direct memcpy.
        let binary: [UInt8]

        /// Build a `MaskTensorContext` from the raw `MLMultiArray`.
        /// Returns nil on shape mismatch — caller falls through to the
        /// existing nil-mask path so the rect-crop fallback always runs.
        init?(masks: MLMultiArray) {
            // Expect [1, Q, H, W]. Anything else means the export changed
            // shape and the safe move is to disable mask decode rather
            // than risk index-out-of-bounds.
            let shape = masks.shape.map(\.intValue)
            guard shape.count == 4, shape[0] == 1 else {
                staticLogger.warning(
                    "decodeMask.shapeMismatch shape=\(shape, privacy: .public)"
                )
                return nil
            }
            self.queryCount = shape[1]
            self.height = shape[2]
            self.width = shape[3]
            let total = queryCount * height * width
            guard total > 0 else {
                staticLogger.warning(
                    "decodeMask.emptyTensor shape=\(shape, privacy: .public)"
                )
                return nil
            }

            // Read once into a Float buffer. `MLMultiArray.dataType`
            // determines the underlying layout; the shipped model exports
            // Float32 (verified via `xcrun coremlc metadata`) but we
            // tolerate Float16 too in case a future export step quantises.
            var flat = [UInt8](repeating: 0, count: total)
            switch masks.dataType {
            case .float32:
                masks.withUnsafeBufferPointer(ofType: Float32.self) { buffer in
                    Self.thresholdAndCopy(buffer: buffer, total: total, into: &flat)
                }
            case .float16:
                // Float16 isn't a stand-alone Swift type; coerce via
                // `withUnsafeBytes` and read 2-byte chunks. Use the
                // higher-precision Float promotion path so the sigmoid
                // call site is identical to the Float32 case. Rare in
                // practice but cheap to guard against.
                masks.withUnsafeBytes { rawPtr in
                    guard let base = rawPtr.baseAddress else { return }
                    let elementCount = rawPtr.count / 2
                    let count = min(elementCount, total)
                    for i in 0..<count {
                        let bits = base.load(fromByteOffset: i * 2, as: UInt16.self)
                        let value = Float(Self.float32FromFloat16Bits(bits))
                        let prob = 1.0 / (1.0 + expf(-value))
                        flat[i] = prob > 0.5 ? 255 : 0
                    }
                }
            case .float64:
                masks.withUnsafeBufferPointer(ofType: Double.self) { buffer in
                    let count = min(buffer.count, total)
                    for i in 0..<count {
                        let prob = 1.0 / (1.0 + exp(-buffer[i]))
                        flat[i] = prob > 0.5 ? 255 : 0
                    }
                }
            default:
                staticLogger.warning(
                    "decodeMask.unsupportedDtype dtype=\(String(describing: masks.dataType), privacy: .public)"
                )
                return nil
            }
            self.binary = flat
        }

        private static func thresholdAndCopy(
            buffer: UnsafeBufferPointer<Float32>,
            total: Int,
            into flat: inout [UInt8]
        ) {
            let count = min(buffer.count, total)
            for i in 0..<count {
                let prob = 1.0 / (1.0 + expf(-buffer[i]))
                flat[i] = prob > 0.5 ? 255 : 0
            }
        }

        /// Bit-pattern conversion for Float16 → Float32 without bringing
        /// in a SIMD dependency. Following IEEE 754 binary16: 1 sign
        /// bit, 5 exponent bits, 10 fraction bits.
        fileprivate static func float32FromFloat16Bits(_ bits: UInt16) -> Float {
            let sign = UInt32(bits & 0x8000) << 16
            let exp = UInt32((bits >> 10) & 0x1F)
            let frac = UInt32(bits & 0x03FF)
            let f32Bits: UInt32
            if exp == 0 {
                if frac == 0 {
                    f32Bits = sign
                } else {
                    // Subnormal — normalise.
                    var e: Int32 = -1
                    var m: UInt32 = frac
                    repeat {
                        e += 1
                        m <<= 1
                    } while (m & 0x0400) == 0
                    let normExp = UInt32(127 - 15 - e)
                    let normFrac = (m & 0x03FF) << 13
                    f32Bits = sign | (normExp << 23) | normFrac
                }
            } else if exp == 0x1F {
                // Inf / NaN.
                f32Bits = sign | 0x7F800000 | (frac << 13)
            } else {
                let f32Exp = (exp + (127 - 15)) << 23
                f32Bits = sign | f32Exp | (frac << 13)
            }
            return Float(bitPattern: f32Bits)
        }
    }

    /// Extract a single per-instance mask from a pre-decoded
    /// `MaskTensorContext` and return it as a binary `CVPixelBuffer` at
    /// the model's native mask resolution. `compositeMaskedItem`
    /// upscales it to source extent via `CGAffineTransform` (existing
    /// path — no new dependency).
    ///
    /// Returns nil on out-of-range query index or pixel-buffer creation
    /// failure. Caller's `RawDetection.mask` becomes nil on failure and
    /// `compositeMaskedItem`'s rect-crop fallback runs unchanged. This
    /// is the safety net the planning brief asks for: no new crash paths.
    static func decodeMask(
        from ctx: MaskTensorContext,
        queryIndex q: Int
    ) -> CVPixelBuffer? {
        guard q >= 0, q < ctx.queryCount else {
            staticLogger.warning(
                "decodeMask.queryOutOfRange index=\(q, privacy: .public) total=\(ctx.queryCount, privacy: .public)"
            )
            return nil
        }
        let stride = ctx.height * ctx.width
        let base = q * stride
        let slice = ctx.binary[base..<(base + stride)]

        guard let buffer = makeBinaryMaskBuffer(
            from: Array(slice),
            width: ctx.width,
            height: ctx.height
        ) else {
            staticLogger.warning(
                "decodeMask.bufferCreateFailed queryIndex=\(q, privacy: .public)"
            )
            return nil
        }
        staticLogger.info(
            "decodeMask.success queryIndex=\(q, privacy: .public) shape=\(ctx.height, privacy: .public)x\(ctx.width, privacy: .public)"
        )
        return buffer
    }

    /// Wrap a row-major `UInt8` slice (0 or 255) into a
    /// `kCVPixelFormatType_OneComponent8` `CVPixelBuffer`. This is the
    /// format `CIImage(cvPixelBuffer:)` reads as a single-channel mask
    /// for use with `CIBlendWithMask`, matching the existing
    /// `compositeMaskedItem` consumer.
    fileprivate static func makeBinaryMaskBuffer(
        from values: [UInt8],
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        guard width > 0, height > 0, values.count == width * height else {
            staticLogger.warning(
                "makeBinaryMaskBuffer.invalidShape width=\(width, privacy: .public) height=\(height, privacy: .public) valuesCount=\(values.count, privacy: .public)"
            )
            return nil
        }
        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            nil,
            &output
        )
        guard status == kCVReturnSuccess, let pb = output else {
            // Build-7 hardening: surface allocation failures from the
            // field. `CVPixelBufferCreate` can return
            // `kCVReturnAllocationFailed` (-6660) on memory-constrained
            // devices; without this log the silent-nil return looks
            // identical to a malformed-input rejection upstream, masking
            // a real OOM signal.
            staticLogger.warning(
                "makeBinaryMaskBuffer.cvCreateFailed status=\(status, privacy: .public) width=\(width, privacy: .public) height=\(height, privacy: .public)"
            )
            return nil
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        guard let baseAddr = CVPixelBufferGetBaseAddress(pb) else {
            staticLogger.warning(
                "makeBinaryMaskBuffer.lockFailed width=\(width, privacy: .public) height=\(height, privacy: .public)"
            )
            return nil
        }
        let dst = baseAddr.assumingMemoryBound(to: UInt8.self)
        // Honour bytesPerRow — it may include row padding so a flat
        // memcpy of `width * height` bytes would scribble over padding
        // and leave subsequent rows offset.
        for y in 0..<height {
            let srcOffset = y * width
            let dstRow = dst.advanced(by: y * bytesPerRow)
            values.withUnsafeBufferPointer { srcBuf in
                guard let srcBase = srcBuf.baseAddress else { return }
                dstRow.update(from: srcBase.advanced(by: srcOffset), count: width)
            }
        }
        return pb
    }

    /// Decode one row of a `[1, Q, 4]` cxcywh tensor. DETR conventionally
    /// emits normalized cxcywh; we convert to origin-top-left `CGRect`.
    static func decodeBoundingBox(_ array: MLMultiArray, queryIndex q: Int) -> CGRect {
        let cx = array[safe: [0, q, 0]] ?? 0
        let cy = array[safe: [0, q, 1]] ?? 0
        let w = array[safe: [0, q, 2]] ?? 0
        let h = array[safe: [0, q, 3]] ?? 0

        let x = max(0, cx - w / 2)
        let y = max(0, cy - h / 2)
        return CGRect(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(min(1, w)),
            height: CGFloat(min(1, h))
        )
    }

    /// Prefer an explicit per-query score tensor; fall back to max-softmax
    /// over class logits.
    static func decodeScore(
        scores: MLMultiArray?,
        logits: MLMultiArray?,
        queryIndex q: Int
    ) -> Float {
        if let scores, let score = scores[safe: [0, q]] {
            // Raw scores may already be sigmoided or not. If > 1 we pass
            // through a sigmoid; otherwise accept as-is.
            return score > 1 ? 1 / (1 + expf(-score)) : score
        }
        if let logits {
            let classCount = logits.shape[safe: 2]?.intValue ?? 0
            guard classCount > 0 else { return 0 }
            var maxVal = -Float.greatestFiniteMagnitude
            for c in 0 ..< classCount {
                let v = logits[safe: [0, q, c]] ?? 0
                if v > maxVal { maxVal = v }
            }
            return 1 / (1 + expf(-maxVal))
        }
        return 0
    }

    /// Pull the argmax class name, mapping the model's integer class index
    /// to the Fashionpedia label string via `fashionpediaLabels`. When the
    /// index falls outside the known label set (future schema extension
    /// or a buggy export) we fall back to `"class_N"` so the raw number
    /// still shows up in `MaskProposal.modelClassRaw` for debugging —
    /// but `ClothingCategory.fromFashionpediaClass` will return `nil`
    /// for those so they never silently claim a category they aren't.
    static func decodeClassLabel(
        classes: MLMultiArray?,
        logits: MLMultiArray?,
        queryIndex q: Int
    ) -> String {
        if let classes, let idx = classes[safe: [0, q]] {
            return labelForIndex(Int(idx))
        }
        if let logits {
            let classCount = logits.shape[safe: 2]?.intValue ?? 0
            var bestIdx = 0
            var bestVal = -Float.greatestFiniteMagnitude
            for c in 0 ..< classCount {
                let v = logits[safe: [0, q, c]] ?? 0
                if v > bestVal {
                    bestVal = v
                    bestIdx = c
                }
            }
            return labelForIndex(bestIdx)
        }
        return "unknown"
    }

    /// Look up a Fashionpedia label by model class index. Exposed as
    /// `internal` so tests can assert index ↔ label round-trips without
    /// going through a full MLMultiArray synthesis.
    static func labelForIndex(_ index: Int) -> String {
        guard index >= 0, index < fashionpediaLabels.count else {
            classIndexLogger.debug(
                "pred_logits argmax=\(index, privacy: .public) outside fitted range [0,\(fashionpediaLabels.count - 1, privacy: .public)] — unfitted COCO slot"
            )
            return "class_\(index)"
        }
        return fashionpediaLabels[index]
    }

    private static let classIndexLogger = Logger(
        subsystem: "com.wardroberedo",
        category: "MultiGarmentClassIndex"
    )

    private static func multiArray(
        for keys: [String],
        in prediction: MLFeatureProvider
    ) -> MLMultiArray? {
        for key in keys {
            if let value = prediction.featureValue(for: key),
               value.type == .multiArray,
               let array = value.multiArrayValue {
                return array
            }
        }
        return nil
    }

    // MARK: - NMS

    /// Axis-aligned Non-Max Suppression over raw detections. Keeps the
    /// highest-scoring proposal per overlapping cluster.
    static func applyNMS(_ detections: [RawDetection], threshold: Float) -> [RawDetection] {
        let sorted = detections.sorted { $0.score > $1.score }
        var keep: [RawDetection] = []
        keep.reserveCapacity(sorted.count)

        for candidate in sorted {
            let overlap = keep.contains { existing in
                iou(candidate.boundingBox, existing.boundingBox) >= CGFloat(threshold)
            }
            if !overlap {
                keep.append(candidate)
            }
        }
        return keep
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.area > 0 else { return 0 }
        let union = a.area + b.area - intersection.area
        return intersection.area / union
    }

}

// MARK: - MLMultiArray convenience

private extension MLMultiArray {
    /// Safe indexed read that returns `nil` when the shape doesn't match
    /// the index, so post-processing helpers can defensively handle the
    /// variety of DETR export shapes coremltools emits.
    subscript(safe indices: [Int]) -> Float? {
        guard indices.count == shape.count else { return nil }
        for (i, dim) in indices.enumerated() {
            guard dim >= 0, dim < shape[i].intValue else { return nil }
        }
        let nsIndices = indices.map { NSNumber(value: $0) }
        return self[nsIndices].floatValue
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
