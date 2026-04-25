import Testing
@testable import WardrobeReDo

/// Coverage of `SeededRNG`, the SplitMix64 generator that powers the
/// "Generate New Outfits" re-roll path.
///
/// We only assert the contract callers actually rely on:
///   1. Same seed → same sequence (reproducibility for re-runs).
///   2. Different seeds → different first draws (re-rolls don't
///      coincidentally repeat the previous ordering).
///   3. Zero seed is sanitized (the SplitMix64 mixer emits 0 forever
///      from state 0; the type guards against that).
///
/// We deliberately do **not** assert exact bit patterns of `next()` —
/// that would couple the test to the SplitMix64 constants and make
/// future RNG swaps painful.
@Suite("SeededRNG") struct SeededRNGTests {

    @Test func sameSeedProducesSameSequence() {
        var a = SeededRNG(seed: 42)
        var b = SeededRNG(seed: 42)

        let firstA = (0..<8).map { _ in a.next() }
        let firstB = (0..<8).map { _ in b.next() }

        #expect(firstA == firstB)
    }

    @Test func differentSeedsProduceDifferentSequences() {
        var a = SeededRNG(seed: 1)
        var b = SeededRNG(seed: 2)

        let firstA = (0..<4).map { _ in a.next() }
        let firstB = (0..<4).map { _ in b.next() }

        #expect(firstA != firstB)
    }

    @Test func zeroSeedDoesNotEmitConstantZero() {
        // The SplitMix64 mixer's fixed-point at state==0 is 0 — the
        // initializer salts this away. Without the salt every `next()`
        // would return 0 and `Double.random(using:)` would never advance.
        var rng = SeededRNG(seed: 0)
        let draws = (0..<6).map { _ in rng.next() }

        #expect(!draws.allSatisfy { $0 == 0 })
        // And consecutive draws aren't all identical either.
        #expect(Set(draws).count > 1)
    }

    @Test func doubleRandomIsReproducibleWithSameSeed() {
        // The actual usage in OutfitGenerationService:
        //   `Double.random(in: 0..<0.2, using: &rng)` per archetype.
        // Same seed must drive the same per-archetype scoring noise.
        var a = SeededRNG(seed: 0xDEADBEEF)
        var b = SeededRNG(seed: 0xDEADBEEF)

        let drawsA = (0..<10).map { _ in Double.random(in: 0..<0.2, using: &a) }
        let drawsB = (0..<10).map { _ in Double.random(in: 0..<0.2, using: &b) }

        #expect(drawsA == drawsB)
        // And every draw is in the requested half-open interval.
        #expect(drawsA.allSatisfy { $0 >= 0 && $0 < 0.2 })
    }
}
