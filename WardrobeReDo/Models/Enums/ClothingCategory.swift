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

    /// Build 17 — localized form for SwiftUI surfaces. Keys match
    /// the English `displayName` (plural-form noun: "Tops" not
    /// "Top") so the wardrobe chip + form pickers display the
    /// translated plural in Turkish.
    var localizedName: LocalizedStringResource {
        switch self {
        case .top:       LocalizedStringResource("Tops")
        case .bottom:    LocalizedStringResource("Bottoms")
        case .shoe:      LocalizedStringResource("Shoes")
        case .dress:     LocalizedStringResource("Dresses")
        case .outerwear: LocalizedStringResource("Outerwear")
        case .accessory: LocalizedStringResource("Accessories")
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

    /// Build 6 Phase 8 — typical fraction of a head-to-toe outfit
    /// silhouette this category occupies. Used by
    /// `ColorHarmonyScorer` to weight per-item color percentages
    /// by visual area rather than item count. A black top + white
    /// pants read closer to 47/53 (or 60/40 against a dress)
    /// instead of the item-count-driven 50/50.
    ///
    /// Defaults are intentionally hand-picked sensible starting
    /// points — they roughly match how much of a typical
    /// head-to-toe outfit silhouette each category occupies, not
    /// research-backed values. Future builds can fit them from
    /// engagement data or modulate via the persisted
    /// `WardrobeItem.silhouetteArea` (Phase 8B).
    var defaultSilhouetteFraction: Double {
        switch self {
        case .top:       0.28
        case .bottom:    0.32
        case .outerwear: 0.20  // layered over tops; partial overlap
        case .dress:     0.55  // covers top + bottom buckets in one piece
        case .shoe:      0.06
        case .accessory: 0.04
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
        // Combo classes `shirt_blouse` and `top_t-shirt_sweatshirt` are
        // what RFDETRSegFashion actually emits — Fashionpedia merges
        // shirts/blouses into one trained class and tops/t-shirts/
        // sweatshirts into another. The singular aliases the previous
        // version handled (`shirt`, `blouse`, `top`, `t-shirt`,
        // `sweatshirt`) are dead code because the model never produces
        // them.
        case "shirt_blouse",
             "top_t-shirt_sweatshirt",
             "sweater",
             "vest",
             "cardigan":
            return .top

        // Bottoms — `tights_stockings` is the model's combo class; the
        // singular `tights` / `stockings` aliases never fire. `pants`
        // is the canonical Fashionpedia label (NOT `trousers`).
        case "pants",
             "shorts",
             "tights_stockings",
             "skirt":
            return .bottom

        // Full-length garments — `dress` and `jumpsuit` are the only
        // canonical labels; `gown` and `romper` are dead aliases.
        case "dress",
             "jumpsuit":
            return .dress

        // Outerwear — `jacket` covers blazer/bomber/leather/etc. as a
        // single Fashionpedia class. `blazer` alias is dead code.
        case "coat",
             "jacket",
             "cape":
            return .outerwear

        // Footwear — model emits `shoe`, `boot`, `sandal` (singular)
        // only; subcategory rescue distinguishes them downstream.
        case "shoe",
             "boot",
             "sandal":
            return .shoe

        // Accessories (intentionally folded; v1.1 splits these out).
        // Combo class `bag_wallet` is what the model emits — singular
        // `bag` / `wallet` / `purse` are dead aliases. `glasses` is
        // canonical (NOT `sunglasses`); `hat` covers caps/fedoras/
        // beanies as one class. `earring` is singular per Fashionpedia.
        case "glasses",
             "hat",
             "headband",
             "scarf",
             "tie",
             "bag_wallet",
             "belt",
             "glove",
             "watch",
             "ring",
             "bracelet",
             "earring",
             "necklace":
            return .accessory

        // Explicit exclusions (not surfaced in v1) — must stay in sync
        // with `MultiGarmentProposalService.fashionpediaExcludedLabels`.
        case "sock",
             "leg_warmer",
             "umbrella":
            return nil

        default:
            return nil
        }
    }
}
