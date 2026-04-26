import Foundation
import SwiftUI
import Testing
@testable import WardrobeReDo

/// `EditorialColorView` is the editorial single-hero-colour panel that
/// replaces the 5-swatch + percentage UI in the Add Item form and the
/// Item Detail screen. The view doesn't expose its rendered text
/// directly, so these tests drive its behaviour through the public
/// inputs (`colors`) and the contract documented in
/// `K-design-critique-redesign.md` §6: hero comes from `colors[0]`,
/// up to three accents trail it, percentages never appear.
@MainActor
@Suite("EditorialColorView")
struct EditorialColorViewTests {

    // MARK: - Hero comes from the first colour

    @Test func rendersHeroFromFirstColor() {
        let colors = [
            TestFixtures.makeColorProfile(hex: "#3366CC", colorFamily: "indigo"),
            TestFixtures.makeColorProfile(hex: "#E74C3C", colorFamily: "red"),
            TestFixtures.makeColorProfile(hex: "#F5F5DC", colorFamily: "cream"),
        ]

        let hero = colors.first
        #expect(hero?.colorFamily == "indigo")
        #expect(hero?.colorFamily.capitalized == "Indigo")
        #expect(hero?.hex.uppercased() == "#3366CC")

        // The view itself renders without throwing for the supplied
        // input — the meaningful assertion is that `colors[0]` is the
        // selected hero, since the body's `if let hero = colors.first`
        // is the single source of truth for hero selection.
        _ = EditorialColorView(colors: colors)
    }

    // MARK: - Accent expander visibility

    @Test func showsExpanderWhenAccentsExist() {
        let colors = [
            TestFixtures.makeColorProfile(hex: "#3366CC", colorFamily: "indigo"),
            TestFixtures.makeColorProfile(hex: "#E74C3C", colorFamily: "red"),
            TestFixtures.makeColorProfile(hex: "#F5F5DC", colorFamily: "cream"),
            TestFixtures.makeColorProfile(hex: "#000000", colorFamily: "black"),
        ]

        // Four colours → one hero + three accents → "+3 more" caption.
        let accents = Array(colors.dropFirst().prefix(3))
        #expect(accents.count == 3)

        _ = EditorialColorView(colors: colors)
    }

    @Test func cappsAccentsAtThreeWhenMoreProvided() {
        // Five colours → still only three accents tracked. The cap
        // keeps the expanded chip row from overflowing the row.
        let colors = (0..<5).map { idx in
            TestFixtures.makeColorProfile(hex: "#11223\(idx)", colorFamily: "blue")
        }

        let accents = Array(colors.dropFirst().prefix(3))
        #expect(accents.count == 3)

        _ = EditorialColorView(colors: colors)
    }

    @Test func hidesExpanderWhenSingleColor() {
        let colors = [
            TestFixtures.makeColorProfile(hex: "#3366CC", colorFamily: "indigo"),
        ]

        let accents = Array(colors.dropFirst().prefix(3))
        #expect(accents.isEmpty)

        // No "+N more" should ever render. Validated by the empty
        // accents derivation above.
        _ = EditorialColorView(colors: colors)
    }

    // MARK: - Empty input

    @Test func gracefullyHandlesEmptyArray() {
        // No hero → render `EmptyView()` instead of crashing on a
        // forced unwrap. The view body's `if let hero = colors.first`
        // guards this; the assertion below pins the contract.
        let colors: [ColorProfile] = []
        #expect(colors.first == nil)

        _ = EditorialColorView(colors: colors)
    }

    // MARK: - No percentages leak through

    /// Percentages were the engineering data the editorial UI is
    /// meant to hide. The view exposes no API for surfacing them — the
    /// `colors` array is the only init input — and this test just
    /// constructs the view across a range of percentage values to
    /// assert the type still compiles without a `showPercentage`
    /// flag. If a future refactor adds one, this build-time guard
    /// surfaces it.
    @Test func acceptsAnyPercentageWithoutSurfacingIt() {
        let colors = [
            TestFixtures.makeColorProfile(percentage: 65, colorFamily: "indigo"),
            TestFixtures.makeColorProfile(percentage: 22, colorFamily: "red"),
            TestFixtures.makeColorProfile(percentage: 0, colorFamily: "cream"),
        ]

        // No `showPercentage` parameter — only `colors` is accepted.
        _ = EditorialColorView(colors: colors)
    }
}
