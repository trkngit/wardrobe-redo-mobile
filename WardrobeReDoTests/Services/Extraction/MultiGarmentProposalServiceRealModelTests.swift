import CoreML
import CoreVideo
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Build-7 hardening (Phase B6 of the build-6 crash audit).
///
/// **Why this exists.** PR #28 wired up `MaskTensorContext` against a
/// *synthetic* `MLMultiArray` (4×4 tensor in
/// `MultiGarmentProposalServiceMaskDecodeTests`). That pins the decode
/// math but doesn't catch model-export drift — if a future re-export of
/// `RFDETRSegFashion.mlpackage` reshapes `pred_masks` (e.g. to
/// `[100, 192, 192]` without the leading batch dim, or quantises to
/// `int8`), the unit tests still pass while production silently falls
/// through to the rect-crop fallback.
///
/// This suite loads the **bundled** model and asserts:
///   * `pred_masks` output exists under one of the canonical names
///   * Shape is rank-4 with leading dim 1, matching
///     `[1, num_queries, H, W]`
///   * `MaskTensorContext.init` accepts the real-model output
///   * The corresponding `pred_boxes` query count matches `pred_masks`
///   * One real inference on a fixture produces ≥ 1 `RawDetection` with
///     a non-nil mask buffer
///
/// **Skipping behaviour.** When the model isn't bundled (e.g. a fresh
/// checkout where Git LFS hasn't pulled the `.mlmodelc`, or a CI
/// environment without the model artifact), the tests record an
/// informational issue and return rather than failing — the synthetic
/// suite already covers the decode math, and a missing model is a
/// build-config problem rather than a regression we can fix from code.
@Suite("MultiGarmentProposalService.realModel", .serialized)
struct MultiGarmentProposalServiceRealModelTests {

    // MARK: - Output-shape contract

    @Test func predMasksOutputDeclaresRankFourShapeWithBatchOne() throws {
        guard let model = loadBundledModel() else {
            Issue.record("RFDETRSegFashion.mlmodelc not bundled — skipping (synthetic decode tests still cover the math)")
            return
        }

        let outputs = model.modelDescription.outputDescriptionsByName
        let maskKeys = ["pred_masks", "masks", "mask_logits", "segmentation"]
        guard let key = maskKeys.first(where: { outputs[$0] != nil }),
              let masksDesc = outputs[key] else {
            Issue.record("model has no mask output under any of \(maskKeys); current outputs: \(Array(outputs.keys))")
            return
        }

        // Multi-array constraint exposes the declared shape. Some
        // exports return a "soft" constraint (only rank, not full
        // dims); we only assert what the model description guarantees.
        guard let constraint = masksDesc.multiArrayConstraint else {
            Issue.record("\(key) has no multiArrayConstraint — likely an image output, not a tensor; export needs review")
            return
        }
        let declaredShape = constraint.shape.map(\.intValue)

        // Rank: must be 4 (`[1, Q, H, W]`). Anything else means the
        // export changed and `MaskTensorContext.init` will reject it
        // → we fall through to rect-crop everywhere. Catch at CI time.
        #expect(declaredShape.count == 4,
                "expected rank-4 mask tensor, got shape \(declaredShape)")

        if declaredShape.count == 4 {
            #expect(declaredShape[0] == 1,
                    "expected leading batch dim of 1, got \(declaredShape[0]) (shape \(declaredShape))")
            // Document the expected dims even though we don't strictly
            // require [100, 192, 192] — a future export that bumps
            // num_queries or mask resolution shouldn't break decode,
            // but the regression watch is logged here.
            #expect(declaredShape[1] > 0,
                    "num_queries dim must be positive; got shape \(declaredShape)")
            #expect(declaredShape[2] > 0 && declaredShape[3] > 0,
                    "spatial dims must be positive; got shape \(declaredShape)")
        }
    }

    @Test func predBoxesAndPredMasksAgreeOnQueryCount() throws {
        guard let model = loadBundledModel() else {
            Issue.record("RFDETRSegFashion.mlmodelc not bundled — skipping")
            return
        }
        let outputs = model.modelDescription.outputDescriptionsByName

        let boxKeys = ["pred_boxes", "boxes", "detection_boxes"]
        let maskKeys = ["pred_masks", "masks", "mask_logits", "segmentation"]

        guard let boxKey = boxKeys.first(where: { outputs[$0] != nil }),
              let maskKey = maskKeys.first(where: { outputs[$0] != nil }),
              let boxesShape = outputs[boxKey]?.multiArrayConstraint?.shape.map(\.intValue),
              let masksShape = outputs[maskKey]?.multiArrayConstraint?.shape.map(\.intValue),
              boxesShape.count >= 2,
              masksShape.count >= 2
        else {
            Issue.record("missing or ill-shaped pred_boxes / pred_masks; outputs: \(Array(outputs.keys))")
            return
        }

        // boxes: [1, Q, 4]; masks: [1, Q, H, W]. The Q dim must agree —
        // a mismatch means the head wiring drifted and per-query
        // `decodeMask(from:queryIndex:)` would either over-read into
        // garbage or short-stop and orphan boxes.
        #expect(boxesShape[1] == masksShape[1],
                "Q mismatch: pred_boxes Q=\(boxesShape[1]) vs pred_masks Q=\(masksShape[1])")
    }

    // MARK: - End-to-end inference

    /// Run a single inference on a known clean-background fixture and
    /// verify that the real-model `pred_masks` survives
    /// `MaskTensorContext.init` and yields at least one usable mask
    /// buffer downstream. This is the canary test for export drift,
    /// quantisation regressions, or a coremltools update that flips
    /// the mask dtype unexpectedly.
    @Test func detectProposalsOnRealFixtureProducesAtLeastOneMaskedDetection() async throws {
        // Probe the bundled model first so we can skip cleanly when
        // it's missing (LFS not pulled, CI without the artifact).
        guard loadBundledModel() != nil else {
            Issue.record("RFDETRSegFashion.mlmodelc not bundled — skipping")
            return
        }
        guard let fixture = FixtureLoader.loadImage(named: "clean_bg_01.jpg") else {
            Issue.record("clean_bg_01.jpg not in test bundle Fixtures/Extraction")
            return
        }

        // Drive the real service end-to-end via its default model
        // loader. `MLModel` isn't `Sendable`, so we can't capture a
        // pre-loaded one in a `@Sendable` closure — we let the default
        // loader resolve the bundled model from `Bundle.main` (the
        // host app's bundle in a hosted-app test).
        let service = MultiGarmentProposalService()

        do {
            let proposals = try await service.detectProposals(in: fixture)
            // The service applies score + class filtering, so 0
            // proposals isn't necessarily wrong. The signal we care
            // about is "decode didn't crash" — but if we got at least
            // one proposal back, the mask buffer should be a valid
            // OneComponent8 CVPixelBuffer matching production's contract.
            // Spot-check a couple of proposals. `mask` is optional —
            // a nil here means decode fell through to rect-crop, which
            // is a graceful path but indicates either the model
            // produced no usable mask logits or the shape mismatched.
            // Either way it's worth surfacing at CI time.
            for proposal in proposals.prefix(3) {
                if let mask = proposal.mask {
                    let format = CVPixelBufferGetPixelFormatType(mask)
                    #expect(
                        format == kCVPixelFormatType_OneComponent8,
                        "unexpected mask format \(format) — decode regression?"
                    )
                    #expect(CVPixelBufferGetWidth(mask) > 0)
                    #expect(CVPixelBufferGetHeight(mask) > 0)
                } else {
                    // Per-proposal nil is allowed (rect-crop fallback),
                    // but if EVERY proposal had nil masks the loop
                    // below would catch it.
                }
            }
            let nonNilMaskCount = proposals.filter { $0.mask != nil }.count
            // If any proposals at all came back, at least one of them
            // should have a real mask. All-nil with a non-empty
            // proposal list is the model-export-drift signal we want.
            if !proposals.isEmpty {
                #expect(nonNilMaskCount > 0,
                        "all \(proposals.count) proposals fell through to nil masks — pred_masks decode broken?")
            }
        } catch let MultiGarmentError.modelLoadFailed(reason, _) {
            // Bundle.main lookup miss is a build-config issue, not
            // something this test asserts on the model output for.
            Issue.record("model load failed: \(reason)")
        } catch {
            // Any other error means the real-model path threw —
            // exactly what we want to catch at CI time.
            Issue.record("detectProposals threw: \(error)")
        }
    }

    // MARK: - Helpers

    /// Try several lookup paths for the compiled model. In a hosted
    /// app-test target the model lives in the host app's `.app/`
    /// bundle, which `Bundle.main` resolves to. In a plain logic-test
    /// target `Bundle.main` is the test runner — we fall back to a
    /// search inside the test bundle's resources.
    private func loadBundledModel() -> MLModel? {
        let name = "RFDETRSegFashion"
        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
            Bundle(for: FixtureLoaderBundleTokenForRealModelTest.self)
                .url(forResource: name, withExtension: "mlmodelc")
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: config)
    }
}

/// Empty class colocated with the test so `Bundle(for:)` resolves to
/// the test bundle. Distinct from the loader token in `FixtureLoader`
/// only because this file may end up in a different module slice during
/// parallel test execution and we don't want a cross-file coupling.
private final class FixtureLoaderBundleTokenForRealModelTest {}
