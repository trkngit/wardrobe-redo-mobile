import Foundation

enum TextureType: String, Codable, CaseIterable, Sendable {
    case cotton, silk, denim, leather, suede
    case wool, linen, knit, synthetic, velvet
    case satin, chiffon, tweed, corduroy, nylon

    var displayName: String { rawValue.capitalized }

    var visualWeight: VisualWeight {
        switch self {
        case .silk, .chiffon, .satin, .nylon: .light
        case .cotton, .linen, .synthetic: .medium
        case .denim, .leather, .suede, .wool, .knit, .velvet, .tweed, .corduroy: .heavy
        }
    }

    var formalitySmoothness: Double {
        switch self {
        case .silk, .satin: 9.0
        case .chiffon: 8.0
        case .wool, .tweed: 7.0
        case .cotton, .linen: 5.0
        case .leather, .suede: 6.0
        case .knit, .velvet: 4.0
        case .denim, .corduroy: 3.0
        case .nylon, .synthetic: 4.0
        }
    }
}

enum FitAttribute: String, Codable, CaseIterable, Sendable {
    case oversized, relaxed, regular, slim, structured, cropped

    var displayName: String { rawValue.capitalized }
}

enum VisualWeight: String, Codable, Sendable {
    case light, medium, heavy
}

enum Season: String, Codable, CaseIterable, Sendable {
    case spring, summer, fall, winter

    var displayName: String { rawValue.capitalized }
}

enum Occasion: String, Codable, CaseIterable, Sendable {
    case casual, work, date, formal, athletic, lounge

    var displayName: String { rawValue.capitalized }
}

enum ColorHarmonyType: String, Codable, Sendable {
    case complementary, analogous, triadic, monochromatic, neutral
}
