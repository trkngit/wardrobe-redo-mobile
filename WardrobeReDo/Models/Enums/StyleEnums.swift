import Foundation

enum TextureType: String, Codable, CaseIterable, Sendable {
    case cotton, silk, denim, leather, suede
    case wool, linen, knit, synthetic, velvet
    case satin, chiffon, tweed, corduroy, nylon

    var displayName: String { rawValue.capitalized }

    /// Build 17 — localized form used by all SwiftUI surfaces.
    /// Keys equal the English `displayName` so the catalog stays
    /// canonical. Was reported as a coverage gap (leather → deri)
    /// after Build 16 — the displayName path was the only thing
    /// wired into ItemDetailView / ItemFormView pickers.
    var localizedName: LocalizedStringResource {
        switch self {
        case .cotton:    LocalizedStringResource("Cotton")
        case .silk:      LocalizedStringResource("Silk")
        case .denim:     LocalizedStringResource("Denim")
        case .leather:   LocalizedStringResource("Leather")
        case .suede:     LocalizedStringResource("Suede")
        case .wool:      LocalizedStringResource("Wool")
        case .linen:     LocalizedStringResource("Linen")
        case .knit:      LocalizedStringResource("Knit")
        case .synthetic: LocalizedStringResource("Synthetic")
        case .velvet:    LocalizedStringResource("Velvet")
        case .satin:     LocalizedStringResource("Satin")
        case .chiffon:   LocalizedStringResource("Chiffon")
        case .tweed:     LocalizedStringResource("Tweed")
        case .corduroy:  LocalizedStringResource("Corduroy")
        case .nylon:     LocalizedStringResource("Nylon")
        }
    }

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

    /// Build 17 — localized fit label for ItemForm picker.
    var localizedName: LocalizedStringResource {
        switch self {
        case .oversized:  LocalizedStringResource("Oversized")
        case .relaxed:    LocalizedStringResource("Relaxed")
        case .regular:    LocalizedStringResource("Regular")
        case .slim:       LocalizedStringResource("Slim")
        case .structured: LocalizedStringResource("Structured")
        case .cropped:    LocalizedStringResource("Cropped")
        }
    }
}

enum VisualWeight: String, Codable, Sendable {
    case light, medium, heavy
}

enum Season: String, Codable, CaseIterable, Sendable {
    case spring, summer, fall, winter

    var displayName: String { rawValue.capitalized }

    /// Build 17 — localized season label.
    var localizedName: LocalizedStringResource {
        switch self {
        case .spring: LocalizedStringResource("Spring")
        case .summer: LocalizedStringResource("Summer")
        case .fall:   LocalizedStringResource("Fall")
        case .winter: LocalizedStringResource("Winter")
        }
    }
}

enum Occasion: String, Codable, CaseIterable, Sendable {
    case casual, work, date, formal, athletic, lounge

    var displayName: String { rawValue.capitalized }

    /// Build 14 — localized chip label. Keys match the catalog
    /// entries created alongside this change so `Text(occasion.localizedName)`
    /// pulls the translated value. `LocalizedStringResource` is the
    /// system-native carrier that both `Text` and `String(localized:)`
    /// accept; previous attempts with `LocalizedStringKey` worked in
    /// views but not in plain-String contexts like `String(format:)`.
    var localizedName: LocalizedStringResource {
        switch self {
        case .casual:   LocalizedStringResource("Casual")
        case .work:     LocalizedStringResource("Work")
        case .date:     LocalizedStringResource("Date")
        case .formal:   LocalizedStringResource("Formal")
        case .athletic: LocalizedStringResource("Athletic")
        case .lounge:   LocalizedStringResource("Lounge")
        }
    }
}

enum ColorHarmonyType: String, Codable, Sendable {
    case complementary, analogous, triadic, monochromatic, neutral
}
