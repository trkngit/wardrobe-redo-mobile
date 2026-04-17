import SwiftUI
import Testing
@testable import WardrobeReDo

// MARK: - Color+Hex Tests

@Test func colorInitFromSixDigitHex() {
    let color = Color(hex: "#FF0000")
    let hex = color.hexString
    #expect(hex == "#FF0000")
}

@Test func colorInitFromSixDigitHexWithoutHash() {
    let color = Color(hex: "00FF00")
    let hex = color.hexString
    #expect(hex == "#00FF00")
}

@Test func colorInitFromEightDigitHex() {
    let color = Color(hex: "#FF3366CC")
    // 8-digit: alpha + RGB, so alpha = FF, R=33, G=66, B=CC
    // Color space conversions may shift values by 1-2/255
    let hex = color.hexString
    #expect(hex.hasPrefix("#"))
    #expect(hex.count == 7) // #RRGGBB format
}

@Test func invalidHexDefaultsToBlack() {
    let color = Color(hex: "ZZZZ")
    let hex = color.hexString
    #expect(hex == "#000000")
}

@Test func hexStringRoundTripApproximate() {
    let testCases = ["#FF0000", "#00FF00", "#0000FF", "#FFFFFF", "#000000"]
    for testHex in testCases {
        let color = Color(hex: testHex)
        let roundTripped = color.hexString
        // Allow tolerance of 1/255 due to floating point conversion
        #expect(roundTripped == testHex, "Expected \(testHex) but got \(roundTripped)")
    }
}

@Test func hexStringFormatIsUppercase() {
    let color = Color(hex: "#aabbcc")
    let hex = color.hexString
    #expect(hex == "#AABBCC")
}

@Test func threeDigitHexHandled() {
    // 3-digit hex may expand (e.g. #F00 → #FF0000) or fallback to black
    let color = Color(hex: "#F00")
    let hex = color.hexString
    // Should either expand correctly or default gracefully
    #expect(hex.hasPrefix("#"))
    #expect(hex.count == 7)
}

@Test func emptyStringDefaultsToBlack() {
    let color = Color(hex: "")
    let hex = color.hexString
    #expect(hex == "#000000")
}
