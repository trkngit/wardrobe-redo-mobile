import CoreImage
import CoreML
import CoreVideo
import Foundation
import UIKit
import os.log

extension MultiGarmentProposalService {
    // MARK: - Smart shoe-pair merge

    /// Heuristic for "these two shoe boxes look like the left and right
    /// shoe of the same pair." Tuned for selfie / full-body captures
    /// where both feet are visible side-by-side. Returns false when the
    /// two boxes are stacked vertically, are very different sizes, or
    /// are too far apart horizontally — those configurations are more
    /// likely to be two distinct pairs of shoes laid out in a flat-lay.
    ///
    /// Rules (all must hold):
    ///   * Vertical mid-points within 10% of each other (same band)
    ///   * Width and height ratios both < 1.5× (similar size)
    ///   * Horizontal gap between the inner edges < average shoe width
    ///     (they're touching or close to touching, not "across the room")
    ///
    /// Both bounding boxes are expected in normalized [0,1] image
    /// coordinates — same convention the rest of post-processing uses.
    /// `static` so unit tests can verify against synthetic CGRects.
    static func looksLikeShoePair(_ a: CGRect, _ b: CGRect) -> Bool {
        let yDelta = abs(a.midY - b.midY)
        guard yDelta < 0.10 else { return false }

        let widthRatio = max(a.width, b.width) / max(min(a.width, b.width), 0.0001)
        guard widthRatio < 1.5 else { return false }
        let heightRatio = max(a.height, b.height) / max(min(a.height, b.height), 0.0001)
        guard heightRatio < 1.5 else { return false }

        let (left, right) = a.minX < b.minX ? (a, b) : (b, a)
        let gap = right.minX - left.maxX
        let avgWidth = (left.width + right.width) / 2
        return gap < avgWidth
    }

    /// True when two shoe-class detections look like the same physical
    /// foot photographed from slightly different angles or zooms — i.e.
    /// proposal-level redundancy from the model emitting near-duplicate
    /// queries.
    ///
    /// **Why proximity, not IoU containment.** The previous 70%-IoU
    /// containment heuristic missed real-world cases. Supabase production
    /// data (build-4 batch) confirmed two shoe detections of the same
    /// foot at slightly different zooms produced bounding boxes that
    /// don't actually overlap enough to trip a containment check, but
    /// whose centroids land within a hand-width of each other. The
    /// proximity check catches those reliably.
    ///
    /// **Tuning.**
    ///   * dx < 0.18 — same physical foot photographed across the
    ///     image plane lands within 18% horizontal-image-width tolerance.
    ///     Two genuinely different feet (left + right) of a wearer
    ///     typically land 5-15% apart in horizontal centroid.
    ///   * dy < 0.10 — same foot stays inside a 10%-image-height band.
    ///     Front-foot vs back-foot in a walking pose can spread further
    ///     vertically; left + right of a standing pose stay tight.
    ///
    /// Returns false for the "left foot vs right foot of the same pair"
    /// case (often dx ≈ 0.10-0.15 — borderline). That's intentional:
    /// `collapseShoePairs` runs `looksLikeShoePair` afterward to catch
    /// the legitimate left+right collapse. The proximity check is
    /// strictly tighter — only catches near-duplicates.
    ///
    /// Both bounding boxes in normalized [0,1] image coordinates.
    static func looksLikeSameShoeDetection(_ a: CGRect, _ b: CGRect) -> Bool {
        let centroidA = CGPoint(x: a.midX, y: a.midY)
        let centroidB = CGPoint(x: b.midX, y: b.midY)
        let dx = abs(centroidA.x - centroidB.x)
        let dy = abs(centroidA.y - centroidB.y)
        // Real-world shoe pair detections: same physical foot photographed
        // at different angles/zooms produces detections with centroids
        // close horizontally and vertically (in normalized image coords).
        return dx < 0.18 && dy < 0.10
    }

    /// Reduces same-class shoe detections that look like a pair down
    /// to one box, keeping the higher-scored side. For 3+ shoe boxes,
    /// iteratively prunes near-duplicate redundancies (same physical
    /// foot at different angles/zooms) before the pair check, then caps
    /// the remaining shoes at 2 per photo (left + right of one pair —
    /// rest are model noise, not legitimate distinct items).
    ///
    /// Treats every shoe-family Fashionpedia label (`shoe`, `boot`,
    /// `sandal`) as the same class for pair purposes — left and right
    /// are mirror images regardless of subtype.
    static func collapseShoePairs(_ detections: [RawDetection]) -> [RawDetection] {
        let shoeLabels: Set<String> = ["shoe", "boot", "sandal"]
        var nonShoes: [RawDetection] = []
        var shoes: [RawDetection] = []
        for d in detections {
            if shoeLabels.contains(d.rawClass) {
                shoes.append(d)
            } else {
                nonShoes.append(d)
            }
        }

        // Iteratively drop redundant shoe boxes (proximity-based — same
        // physical foot at different angles). Runs before the pair check
        // so a near-duplicate pair doesn't slip past as a "pair."
        shoes = pruneShoeRedundancies(shoes)

        // Build 44 — pair detection BEFORE the hard cap. The earlier
        // algorithm capped at 2 highest-confidence first, which broke
        // a legitimate same-class pair (e.g. left+right boot) when a
        // third shoe-family detection happened to score higher than
        // one half of the pair. Concretely: 2 boots (scores 0.82 + 0.75)
        // plus 1 sneaker (score 0.78) used to collapse to "boot 0.82 +
        // sneaker 0.78" and the boot pair was destroyed.
        //
        // New algorithm — greedy per-class pair walk:
        //   1. Sort all shoes descending by score.
        //   2. For each unpaired shoe, look for the highest-scoring
        //      unpaired same-rawClass partner that geometrically
        //      satisfies `looksLikeShoePair`. If found, collapse
        //      both into the higher-scored one.
        //   3. After the walk, apply the hard cap.
        //
        // Same-rawClass requirement prevents a boot+sneaker false-pair
        // collapse: the legitimate pair semantics only hold within a
        // single Fashionpedia label.
        shoes = collapseSameClassPairs(shoes)

        // Hard cap at 2 shoe items per source photo (left + right foot,
        // OR two distinct shoes from two different physical pairs after
        // same-class pair-collapse). Real-world wardrobe captures don't
        // legitimately contain 3+ distinct shoes — anything over 2
        // after pair collapse is model noise. Keep the 2 highest-
        // confidence survivors.
        if shoes.count > 2 {
            shoes = Array(shoes.sorted { $0.score > $1.score }.prefix(2))
        }

        return nonShoes + shoes
    }

    /// Greedy walk over `shoes` looking for same-`rawClass` pairs that
    /// satisfy `looksLikeShoePair`. Build 47: a confirmed pair is FUSED
    /// into one detection whose bbox is the union of both boxes and which
    /// carries both instance masks (winner's `mask` + partner's
    /// `secondaryMask`) so `compositeMaskedItem` renders BOTH shoes in
    /// the single cutout — the "shoe pair should show both shoes"
    /// request. Earlier builds kept only the higher-scored single
    /// detection, so the saved item was a lone shoe. Unpaired shoes pass
    /// through unchanged.
    private static func collapseSameClassPairs(_ shoes: [RawDetection]) -> [RawDetection] {
        guard shoes.count >= 2 else { return shoes }
        let sorted = shoes.sorted { $0.score > $1.score }
        var consumed = Set<Int>()
        var result: [RawDetection] = []
        for i in sorted.indices {
            if consumed.contains(i) { continue }
            let anchor = sorted[i]
            var partnerIndex: Int?
            for j in (i + 1)..<sorted.count {
                if consumed.contains(j) { continue }
                let candidate = sorted[j]
                guard candidate.rawClass == anchor.rawClass else { continue }
                if looksLikeShoePair(anchor.boundingBox, candidate.boundingBox) {
                    partnerIndex = j
                    break
                }
            }
            if let j = partnerIndex {
                // Pair confirmed — fuse into one union detection. Anchor
                // (higher score) drives class/score; partner's mask rides
                // along so both shoes appear in the cutout.
                let partner = sorted[j]
                consumed.insert(j)
                result.append(RawDetection(
                    boundingBox: anchor.boundingBox.union(partner.boundingBox),
                    score: anchor.score,
                    rawClass: anchor.rawClass,
                    mask: anchor.mask,
                    secondaryMask: partner.mask
                ))
            } else {
                result.append(anchor)
            }
            consumed.insert(i)
        }
        return result
    }

    /// Iteratively drops the lower-scored member of any shoe-class
    /// detection pair where the two boxes' centroids are close enough
    /// to be the same physical foot (see `looksLikeSameShoeDetection`).
    /// Stops when no near-duplicate pair remains. Ordering by score
    /// descending makes the survivor deterministic.
    private static func pruneShoeRedundancies(_ shoes: [RawDetection]) -> [RawDetection] {
        guard shoes.count > 1 else { return shoes }

        var remaining = shoes.sorted { $0.score > $1.score }
        var changed = true
        while changed {
            changed = false
            for i in 0..<remaining.count {
                var didCollapse = false
                for j in (i + 1)..<remaining.count {
                    if looksLikeSameShoeDetection(
                        remaining[i].boundingBox,
                        remaining[j].boundingBox
                    ) {
                        // `remaining[i]` has the higher score (sorted
                        // descending) — drop the lower-scored copy.
                        // The `while changed` re-entry restarts iteration
                        // from the top with the shrunken array, so we
                        // only need to break the inner loop here.
                        remaining.remove(at: j)
                        changed = true
                        didCollapse = true
                        break
                    }
                }
                if didCollapse { break }
            }
        }
        return remaining
    }

}
