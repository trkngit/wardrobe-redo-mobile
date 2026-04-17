import Testing
@testable import WardrobeReDo

// MARK: - ColorExtractionService Math Tests

private let service = ColorExtractionService()

// MARK: - rgbToHSL

@Test func rgbToHSLPureRed() {
    let result = service.rgbToHSL(r: 1.0, g: 0.0, b: 0.0)
    #expect(abs(result.h - 0.0) < 1.0)
    #expect(abs(result.s - 1.0) < 0.01)
    #expect(abs(result.l - 0.5) < 0.01)
}

@Test func rgbToHSLPureGreen() {
    let result = service.rgbToHSL(r: 0.0, g: 1.0, b: 0.0)
    #expect(abs(result.h - 120.0) < 1.0)
    #expect(abs(result.s - 1.0) < 0.01)
    #expect(abs(result.l - 0.5) < 0.01)
}

@Test func rgbToHSLPureBlue() {
    let result = service.rgbToHSL(r: 0.0, g: 0.0, b: 1.0)
    #expect(abs(result.h - 240.0) < 1.0)
    #expect(abs(result.s - 1.0) < 0.01)
    #expect(abs(result.l - 0.5) < 0.01)
}

@Test func rgbToHSLWhite() {
    let result = service.rgbToHSL(r: 1.0, g: 1.0, b: 1.0)
    #expect(result.s == 0.0)
    #expect(result.l == 1.0)
}

@Test func rgbToHSLBlack() {
    let result = service.rgbToHSL(r: 0.0, g: 0.0, b: 0.0)
    #expect(result.s == 0.0)
    #expect(result.l == 0.0)
}

// MARK: - colorDistance

@Test func colorDistanceIdenticalIsZero() {
    let color = (r: 0.5, g: 0.3, b: 0.7)
    let distance = service.colorDistance(color, color)
    #expect(distance == 0.0)
}

@Test func colorDistanceKnownValues() {
    let black = (r: 0.0, g: 0.0, b: 0.0)
    let white = (r: 1.0, g: 1.0, b: 1.0)
    let distance = service.colorDistance(black, white)
    // sqrt(1^2 + 1^2 + 1^2) = sqrt(3) but distance uses squared distance
    #expect(abs(distance - 3.0) < 0.001)
}

// MARK: - colorFamily

@Test func colorFamilyRedHue() {
    let family = service.colorFamily(hue: 0, saturation: 0.7, lightness: 0.5)
    #expect(family == "red")
}

@Test func colorFamilyBlueHue() {
    let family = service.colorFamily(hue: 220, saturation: 0.7, lightness: 0.5)
    #expect(family == "blue")
}

@Test func colorFamilyLowSaturationGray() {
    let family = service.colorFamily(hue: 100, saturation: 0.05, lightness: 0.5)
    #expect(family == "gray")
}

@Test func colorFamilyNavyDarkBlue() {
    let family = service.colorFamily(hue: 220, saturation: 0.7, lightness: 0.2)
    #expect(family == "navy")
}

// MARK: - isNeutral

@Test func isNeutralLowSaturation() {
    #expect(service.isNeutral(saturation: 0.1, lightness: 0.5) == true)
}

@Test func isNeutralVeryDark() {
    #expect(service.isNeutral(saturation: 0.5, lightness: 0.1) == true)
}

@Test func isNeutralVeryLight() {
    #expect(service.isNeutral(saturation: 0.5, lightness: 0.95) == true)
}

@Test func isNeutralFalseForSaturatedMidtone() {
    #expect(service.isNeutral(saturation: 0.5, lightness: 0.5) == false)
}

// MARK: - rgbToHex

@Test func rgbToHexPureRed() {
    let hex = service.rgbToHex(r: 1.0, g: 0.0, b: 0.0)
    #expect(hex == "#FF0000")
}

@Test func rgbToHexBlack() {
    let hex = service.rgbToHex(r: 0.0, g: 0.0, b: 0.0)
    #expect(hex == "#000000")
}
