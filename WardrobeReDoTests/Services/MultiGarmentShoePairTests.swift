import CoreGraphics
import Foundation
import Testing
@testable import WardrobeReDo

/// Coverage for `MultiGarmentProposalService.looksLikeShoePair(_:_:)`
/// and `collapseShoePairs(_:)` — the smart-merge path that collapses
/// left + right shoe detections of the same pair without touching
/// genuinely distinct shoes (rare two-pair flat-lay).
///
/// Boxes in normalized [0,1] image coordinates (x, y, width, height),
/// origin top-left, matching the rest of the multi-garment post-processing.
@Suite("MultiGarmentProposalService.shoePair") struct MultiGarmentShoePairTests {

    // MARK: - looksLikeShoePair (true positives)

    @Test func sideBySideShoesAtBottomOfFrameAreAPair() {
        // Two shoes at the bottom of a full-body capture, both ~10%
        // of the frame width, same horizontal band, touching.
        let left = CGRect(x: 0.30, y: 0.85, width: 0.10, height: 0.10)
        let right = CGRect(x: 0.41, y: 0.85, width: 0.10, height: 0.10)
        #expect(MultiGarmentProposalService.looksLikeShoePair(left, right))
    }

    @Test func slightlyOffsetVerticallyButWithinBandIsAPair() {
        // One foot slightly forward, ~5% Y delta — still within the
        // 10% band tolerance.
        let left = CGRect(x: 0.30, y: 0.85, width: 0.10, height: 0.10)
        let right = CGRect(x: 0.41, y: 0.90, width: 0.10, height: 0.10)
        #expect(MultiGarmentProposalService.looksLikeShoePair(left, right))
    }

    @Test func smallGapBetweenShoesIsAPair() {
        // Shoes ~1/4 of a shoe-width apart still counts as a pair.
        let left = CGRect(x: 0.30, y: 0.85, width: 0.10, height: 0.10)
        let right = CGRect(x: 0.43, y: 0.85, width: 0.10, height: 0.10)
        #expect(MultiGarmentProposalService.looksLikeShoePair(left, right))
    }

    // MARK: - looksLikeShoePair (true negatives)

    @Test func verticallyStackedShoesAreNotAPair() {
        // Y midpoints differ by 30% — definitely not the same horizontal band.
        let top = CGRect(x: 0.30, y: 0.40, width: 0.10, height: 0.10)
        let bottom = CGRect(x: 0.30, y: 0.85, width: 0.10, height: 0.10)
        #expect(!MultiGarmentProposalService.looksLikeShoePair(top, bottom))
    }

    @Test func differentSizedShoesAreNotAPair() {
        // The "right" shoe is 2× the width of the "left" — not a mirror
        // pair, more likely two distinct items.
        let left = CGRect(x: 0.30, y: 0.85, width: 0.05, height: 0.10)
        let right = CGRect(x: 0.41, y: 0.85, width: 0.20, height: 0.10)
        #expect(!MultiGarmentProposalService.looksLikeShoePair(left, right))
    }

    @Test func farApartShoesAreNotAPair() {
        // Gap is 3× the average shoe width — flat-lay of two pairs
        // in opposite corners of the frame, not a worn pair.
        let left = CGRect(x: 0.05, y: 0.85, width: 0.10, height: 0.10)
        let right = CGRect(x: 0.85, y: 0.85, width: 0.10, height: 0.10)
        #expect(!MultiGarmentProposalService.looksLikeShoePair(left, right))
    }

    // MARK: - collapseShoePairs

    @Test func twoShoeDetectionsThatPairCollapseToOne() {
        let pair = (
            MultiGarmentProposalService.RawDetection(
                boundingBox: CGRect(x: 0.30, y: 0.85, width: 0.10, height: 0.10),
                score: 0.91, rawClass: "shoe", mask: nil
            ),
            MultiGarmentProposalService.RawDetection(
                boundingBox: CGRect(x: 0.41, y: 0.85, width: 0.10, height: 0.10),
                score: 0.92, rawClass: "shoe", mask: nil
            )
        )
        let result = MultiGarmentProposalService.collapseShoePairs([pair.0, pair.1])
        #expect(result.count == 1)
        // Higher-scored side wins.
        #expect(result.first?.score == 0.92)
    }

    @Test func twoShoesThatDontPairAreBothKept() {
        // One in the upper-left (probably a shoe in someone's hand),
        // one at the feet. Different bands → keep both.
        let upperLeft = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.10, y: 0.20, width: 0.10, height: 0.10),
            score: 0.80, rawClass: "shoe", mask: nil
        )
        let feet = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.40, y: 0.85, width: 0.10, height: 0.10),
            score: 0.95, rawClass: "shoe", mask: nil
        )
        let result = MultiGarmentProposalService.collapseShoePairs([upperLeft, feet])
        #expect(result.count == 2)
    }

    @Test func collapseLeavesNonShoeDetectionsUntouched() {
        let top = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.30, y: 0.20, width: 0.40, height: 0.40),
            score: 0.95, rawClass: "shirt_blouse", mask: nil
        )
        let pant = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.30, y: 0.55, width: 0.40, height: 0.40),
            score: 0.93, rawClass: "pants", mask: nil
        )
        let leftShoe = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.30, y: 0.92, width: 0.10, height: 0.06),
            score: 0.91, rawClass: "shoe", mask: nil
        )
        let rightShoe = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.41, y: 0.92, width: 0.10, height: 0.06),
            score: 0.92, rawClass: "shoe", mask: nil
        )
        let result = MultiGarmentProposalService.collapseShoePairs([top, pant, leftShoe, rightShoe])
        #expect(result.count == 3)
        #expect(result.contains { $0.rawClass == "shirt_blouse" })
        #expect(result.contains { $0.rawClass == "pants" })
        #expect(result.contains { $0.rawClass == "shoe" })
    }

    @Test func threePlusShoesFallThrough() {
        // Flat-lay of 3 shoes — we don't try to pair-match heuristically
        // beyond two; let the per-photo cap trim from there.
        let shoes = (0..<3).map { i in
            MultiGarmentProposalService.RawDetection(
                boundingBox: CGRect(x: 0.10 + Double(i) * 0.20, y: 0.85, width: 0.10, height: 0.10),
                score: 0.85 + Float(i) * 0.02, rawClass: "shoe", mask: nil
            )
        }
        let result = MultiGarmentProposalService.collapseShoePairs(shoes)
        #expect(result.count == 3)
    }

    // MARK: - looksLikeShoeRedundancy / wide-shot + close-up collapse

    @Test func closeUpFullyContainedInWideShotCollapsesToOne() {
        // The model produced both a wide-shot of a shoe at the bottom
        // of the frame AND a close-up zoom into the laces of the same
        // shoe. The close-up box (smaller) sits inside the wide-shot
        // box (larger). `looksLikeShoePair` fails (different sizes,
        // different Y positions); redundancy collapse must catch it.
        let wideShot = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.30, y: 0.70, width: 0.30, height: 0.25),
            score: 0.88, rawClass: "shoe", mask: nil
        )
        let closeUp = MultiGarmentProposalService.RawDetection(
            // Sits entirely inside `wideShot` (laces region).
            boundingBox: CGRect(x: 0.35, y: 0.75, width: 0.10, height: 0.08),
            score: 0.82, rawClass: "shoe", mask: nil
        )
        let result = MultiGarmentProposalService.collapseShoePairs([wideShot, closeUp])
        #expect(result.count == 1)
        // Higher-scored copy survives (wide-shot here).
        #expect(result.first?.score == 0.88)
    }

    @Test func sameSizeAdjacentBoxesStillCollapseViaPairPath() {
        // Regression: redundancy pruning must NOT swallow a real
        // left+right shoe pair. Side-by-side, similar size — the pair
        // path should still fire and collapse to one.
        let left = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.30, y: 0.85, width: 0.10, height: 0.10),
            score: 0.91, rawClass: "shoe", mask: nil
        )
        let right = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.41, y: 0.85, width: 0.10, height: 0.10),
            score: 0.92, rawClass: "shoe", mask: nil
        )
        let result = MultiGarmentProposalService.collapseShoePairs([left, right])
        #expect(result.count == 1)
        #expect(result.first?.score == 0.92)
    }

    @Test func twoDistinctShoesFarApartAreBothKept() {
        // Real two-pair flat-lay: opposite corners, no overlap, no
        // pair geometry. Neither the redundancy nor the pair check
        // should fire — both shoes survive.
        let one = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.05, y: 0.10, width: 0.15, height: 0.15),
            score: 0.85, rawClass: "shoe", mask: nil
        )
        let two = MultiGarmentProposalService.RawDetection(
            boundingBox: CGRect(x: 0.75, y: 0.80, width: 0.15, height: 0.15),
            score: 0.87, rawClass: "shoe", mask: nil
        )
        let result = MultiGarmentProposalService.collapseShoePairs([one, two])
        #expect(result.count == 2)
    }
}
