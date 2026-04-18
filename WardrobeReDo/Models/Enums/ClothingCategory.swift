import Foundation

enum ClothingCategory: String, Codable, CaseIterable, Sendable {
    case top
    case bottom
    case shoe
    case dress
    case outerwear
    case accessory

    var displayName: String {
        switch self {
        case .top: "Tops"
        case .bottom: "Bottoms"
        case .shoe: "Shoes"
        case .dress: "Dresses"
        case .outerwear: "Outerwear"
        case .accessory: "Accessories"
        }
    }

    var iconName: String {
        switch self {
        case .top: "tshirt"
        case .bottom: "figure.walk"
        case .shoe: "shoe"
        case .dress: "figure.dress.line.vertical.figure"
        case .outerwear: "cloud.rain"
        case .accessory: "applewatch"
        }
    }

    // MARK: - Fashionpedia mapping

    /// Map a Fashionpedia main-class string (as emitted by the
    /// RF-DETR-Seg-Small model trained on Fashionpedia) to this app's
    /// existing 6-case enum. Returns `nil` for Fashionpedia classes we
    /// deliberately don't surface in v1 (e.g. `sock`, `leg_warmer`,
    /// `umbrella`) or classes the model doesn't know about.
    ///
    /// **Compromise for v1:** every accessory (glasses, hat, bag, belt,
    /// watch, jewellery, …) collapses to `.accessory` so we don't have
    /// to coordinate a Supabase `CHECK` migration in this cycle. v1.1
    /// splits `.accessory` into `.bag` / `.eyewear` / `.hat` / `.jewelry`.
    ///
    /// This helper is the **single source of truth** for Fashionpedia
    /// → enum mapping — tests assert every known Fashionpedia class is
    /// explicitly handled, so silent drops are impossible.
    static func fromFashionpediaClass(_ raw: String) -> ClothingCategory? {
        let normalized = raw.lowercased()
        switch normalized {
        // Tops / shirts / knits
        case "shirt", "blouse", "shirt_blouse",
             "top", "t-shirt", "sweatshirt", "top_t-shirt_sweatshirt",
             "sweater",
             "vest",
             "cardigan":
            return .top

        // Bottoms
        case "pants", "trousers",
             "shorts",
             "tights", "stockings", "tights_stockings",
             "skirt":
            return .bottom

        // Full-length garments
        case "dress", "gown",
             "jumpsuit", "romper":
            return .dress

        // Outerwear
        case "coat",
             "jacket", "blazer",
             "cape":
            return .outerwear

        // Footwear
        case "shoe",
             "boot",
             "sandal", "sandals":
            return .shoe

        // Accessories (intentionally folded; v1.1 splits these out)
        case "glasses", "sunglasses",
             "hat", "cap",
             "headband", "head_covering",
             "scarf",
             "tie", "bow_tie",
             "bag", "wallet", "bag_wallet", "purse",
             "belt",
             "glove",
             "watch",
             "ring",
             "bracelet",
             "earring", "earrings",
             "necklace":
            return .accessory

        // Explicit exclusions (not surfaced in v1)
        case "sock",
             "leg_warmer",
             "umbrella",
             "hood", "hood_head_covering":
            return nil

        default:
            return nil
        }
    }
}
