import CoreGraphics
import CoreML
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Unit + integration tests for `MultiGarmentProposalService`.
///
/// These tests do NOT require the real `RFDETRSegFashion.mlmodelc` to
/// be present — they exercise:
///   1. Graceful fallback when the model isn't bundled yet
///   2. Error types + messages
///   3. Pure post-processing helpers (NMS, decodeBoundingBox, etc.)
///
/// Once the trained model ships, a companion fixture-based test suite
/// will assert per-photo proposal counts + IoU against hand-traced
/// ground truth — that work is tracked under Commit 2 of the plan.
struct MultiGarmentProposalServiceTests {

    // MARK: - Graceful fallback

    @Test func detectThrowsModelLoadFailedWhenModelMissing() async {
        let service = MultiGarmentProposalService(modelLoader: { nil })
        let image = UIImage(systemName: "photo") ?? UIImage()

        do {
            _ = try await service.detectProposals(in: image)
            Issue.record("Expected .modelLoadFailed to be thrown")
        } catch let error as MultiGarmentError {
            switch error {
            case .modelLoadFailed:
                // expected
                break
            default:
                Issue.record("Expected modelLoadFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected MultiGarmentError, got \(error)")
        }
    }

    @Test func prewarmIsSafeWhenModelMissing() async {
        let service = MultiGarmentProposalService(modelLoader: { nil })
        await service.prewarm()  // Should not throw or hang.
        await service.prewarm()  // Second call is cheap (one-shot load).
    }

    @Test func loaderIsInvokedAtMostOnce() async {
        actor CallCounter { var value = 0; func increment() { value += 1 } }
        let counter = CallCounter()

        let service = MultiGarmentProposalService(modelLoader: {
            Task { await counter.increment() }
            return nil
        })

        await service.prewarm()
        await service.prewarm()
        _ = try? await service.detectProposals(in: UIImage())

        // Allow the async increments to flush.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let count = await counter.value
        #expect(count == 1, "Loader should be one-shot, saw \(count) calls")
    }

    // MARK: - Error payload

    @Test func modelLoadFailedCarriesDescriptiveReason() {
        let error: MultiGarmentError = .modelLoadFailed(
            reason: "Core ML model could not be loaded",
            modelPath: "RFDETRSegFashion.mlmodelc"
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("Model load failed"))
        #expect(description.contains("RFDETRSegFashion.mlmodelc"))
    }

    @Test func noValidPredictionsCarriesRawCountAndThreshold() {
        let error: MultiGarmentError = .noValidPredictions(rawCount: 42, threshold: 0.5)
        let description = error.errorDescription ?? ""
        #expect(description.contains("42"))
        #expect(description.contains("0.5"))
    }

    // MARK: - IoU helper

    @Test func iouIsZeroForDisjointRects() {
        let a = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let b = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        #expect(MultiGarmentProposalService.iou(a, b) == 0)
    }

    @Test func iouIsOneForIdenticalRects() {
        let a = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        let iou = MultiGarmentProposalService.iou(a, a)
        #expect(abs(iou - 1) < 0.001)
    }

    @Test func iouIsCorrectForPartialOverlap() {
        let a = CGRect(x: 0, y: 0, width: 0.4, height: 0.4)
        let b = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        // Intersection: 0.2 × 0.2 = 0.04
        // Union: 0.16 + 0.16 - 0.04 = 0.28
        // IoU ≈ 0.1428...
        let iou = MultiGarmentProposalService.iou(a, b)
        #expect(abs(iou - (0.04 / 0.28)) < 0.001)
    }

    // MARK: - NMS

    @Test func nmsDropsOverlappingLowerScoreDetection() {
        let high = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            score: 0.9,
            rawClass: "jacket",
            mask: nil
        )
        let overlap = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.01, y: 0.01, width: 0.5, height: 0.5),
            score: 0.7,
            rawClass: "jacket",
            mask: nil
        )
        let disjoint = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3),
            score: 0.8,
            rawClass: "skirt",
            mask: nil
        )

        let kept = MultiGarmentProposalService.applyNMS(
            [high, overlap, disjoint],
            threshold: 0.5
        )
        #expect(kept.count == 2)
        #expect(kept.contains(where: { $0.score == 0.9 }))
        #expect(kept.contains(where: { $0.score == 0.8 }))
        #expect(!kept.contains(where: { $0.score == 0.7 }))
    }

    @Test func nmsKeepsAllWhenNoOverlap() {
        let a = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
            score: 0.9,
            rawClass: "hat",
            mask: nil
        )
        let b = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            score: 0.8,
            rawClass: "shoe",
            mask: nil
        )
        let kept = MultiGarmentProposalService.applyNMS([a, b], threshold: 0.5)
        #expect(kept.count == 2)
    }

    // MARK: - MaskProposal construction

    @Test func makeProposalBuildsCorrectConfidenceBand() {
        let image = UIImage(systemName: "photo") ?? UIImage()

        let highRaw = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            score: 0.95,
            rawClass: "shirt_blouse",
            mask: nil
        )
        let mediumRaw = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            score: 0.7,
            rawClass: "shirt_blouse",
            mask: nil
        )
        let lowRaw = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            score: 0.55,
            rawClass: "shirt_blouse",
            mask: nil
        )

        let high = MultiGarmentProposalService.makeProposal(from: highRaw, sourceImage: image)
        let medium = MultiGarmentProposalService.makeProposal(from: mediumRaw, sourceImage: image)
        let low = MultiGarmentProposalService.makeProposal(from: lowRaw, sourceImage: image)

        // The SF Symbol image has no `cgImage` in some simulator
        // contexts, in which case makeProposal still returns a proposal
        // but with the source image unchanged. We care about the
        // confidence band + category mapping, which don't depend on
        // cropping success.
        #expect(high?.confidence == .high)
        #expect(medium?.confidence == .medium)
        #expect(low?.confidence == .low)

        #expect(high?.predictedCategory == .top)
        #expect(medium?.modelClassRaw == "shirt_blouse")
    }

    @Test func makeProposalCategorisesUnknownClassesAsNil() {
        let image = UIImage(systemName: "photo") ?? UIImage()
        let unknownRaw = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            score: 0.8,
            rawClass: "class_0",
            mask: nil
        )
        let proposal = MultiGarmentProposalService.makeProposal(from: unknownRaw, sourceImage: image)
        #expect(proposal?.predictedCategory == nil)
        #expect(proposal?.modelClassRaw == "class_0")
    }

    // MARK: - MaskProposal Hashable behaviour

    @Test func maskProposalsAreUniqueByID() {
        let a = MaskProposalFixture.make()
        let aCopy = MaskProposal(
            id: a.id,
            maskedImage: a.maskedImage,
            mask: nil,
            confidence: .low,              // different
            predictedCategory: .bottom,    // different
            boundingBox: a.boundingBox,
            detectionScore: 0.1,           // different
            modelClassRaw: "totally_different"
        )
        let b = MaskProposalFixture.make()

        // Equality is ID-based even when every other field differs.
        #expect(a == aCopy)
        #expect(a != b)

        let set: Set<MaskProposal> = [a, aCopy, b]
        #expect(set.count == 2)
    }
}
