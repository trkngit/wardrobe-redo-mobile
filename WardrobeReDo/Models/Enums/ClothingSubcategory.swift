import Foundation

enum ClothingSubcategory: String, Codable, CaseIterable, Sendable {
    // Tops
    case tshirt, buttonDown, polo, blazer, hoodie
    case sweater, tankTop, henley, cropTop, blouse
    case turtleneck, vneck, graphicTee

    // Bottoms
    case jeans, chinos, dressPants, shorts, cargo
    case joggers, skirt, miniSkirt, midiSkirt, wideLeg
    case straightLeg, slimFit

    // Shoes
    case sneakers, dressShoes, boots, sandals
    case loafers, highTops, heels, flats
    case designerSneakers, chelseaBoots

    // Dresses
    case casualDress, cocktailDress, maxiDress
    case miniDress, shirtDress, wrapDress

    // Outerwear
    case winterCoat, leatherJacket, denimJacket
    case windbreaker, cardigan, varsityJacket
    case trench, parka, bomber, puffer

    // Accessories
    case baseballCap, beanie, scarf, belt
    case watch, sunglasses, necklace, bracelet
    case bag, backpack, fedoraHat, earrings

    var displayName: String {
        switch self {
        case .tshirt: "T-Shirt"
        case .buttonDown: "Button-Down"
        case .polo: "Polo"
        case .blazer: "Blazer"
        case .hoodie: "Hoodie"
        case .sweater: "Sweater"
        case .tankTop: "Tank Top"
        case .henley: "Henley"
        case .cropTop: "Crop Top"
        case .blouse: "Blouse"
        case .turtleneck: "Turtleneck"
        case .vneck: "V-Neck"
        case .graphicTee: "Graphic Tee"
        case .jeans: "Jeans"
        case .chinos: "Chinos"
        case .dressPants: "Dress Pants"
        case .shorts: "Shorts"
        case .cargo: "Cargo"
        case .joggers: "Joggers"
        case .skirt: "Skirt"
        case .miniSkirt: "Mini Skirt"
        case .midiSkirt: "Midi Skirt"
        case .wideLeg: "Wide Leg"
        case .straightLeg: "Straight Leg"
        case .slimFit: "Slim Fit"
        case .sneakers: "Sneakers"
        case .dressShoes: "Dress Shoes"
        case .boots: "Boots"
        case .sandals: "Sandals"
        case .loafers: "Loafers"
        case .highTops: "High Tops"
        case .heels: "Heels"
        case .flats: "Flats"
        case .designerSneakers: "Designer Sneakers"
        case .chelseaBoots: "Chelsea Boots"
        case .casualDress: "Casual Dress"
        case .cocktailDress: "Cocktail Dress"
        case .maxiDress: "Maxi Dress"
        case .miniDress: "Mini Dress"
        case .shirtDress: "Shirt Dress"
        case .wrapDress: "Wrap Dress"
        case .winterCoat: "Winter Coat"
        case .leatherJacket: "Leather Jacket"
        case .denimJacket: "Denim Jacket"
        case .windbreaker: "Windbreaker"
        case .cardigan: "Cardigan"
        case .varsityJacket: "Varsity Jacket"
        case .trench: "Trench"
        case .parka: "Parka"
        case .bomber: "Bomber"
        case .puffer: "Puffer"
        case .baseballCap: "Baseball Cap"
        case .beanie: "Beanie"
        case .scarf: "Scarf"
        case .belt: "Belt"
        case .watch: "Watch"
        case .sunglasses: "Sunglasses"
        case .necklace: "Necklace"
        case .bracelet: "Bracelet"
        case .bag: "Bag"
        case .backpack: "Backpack"
        case .fedoraHat: "Fedora Hat"
        case .earrings: "Earrings"
        }
    }

    var category: ClothingCategory {
        switch self {
        case .tshirt, .buttonDown, .polo, .blazer, .hoodie,
             .sweater, .tankTop, .henley, .cropTop, .blouse,
             .turtleneck, .vneck, .graphicTee:
            .top
        case .jeans, .chinos, .dressPants, .shorts, .cargo,
             .joggers, .skirt, .miniSkirt, .midiSkirt, .wideLeg,
             .straightLeg, .slimFit:
            .bottom
        case .sneakers, .dressShoes, .boots, .sandals,
             .loafers, .highTops, .heels, .flats,
             .designerSneakers, .chelseaBoots:
            .shoe
        case .casualDress, .cocktailDress, .maxiDress,
             .miniDress, .shirtDress, .wrapDress:
            .dress
        case .winterCoat, .leatherJacket, .denimJacket,
             .windbreaker, .cardigan, .varsityJacket,
             .trench, .parka, .bomber, .puffer:
            .outerwear
        case .baseballCap, .beanie, .scarf, .belt,
             .watch, .sunglasses, .necklace, .bracelet,
             .bag, .backpack, .fedoraHat, .earrings:
            .accessory
        }
    }

    static func subcategories(for category: ClothingCategory) -> [ClothingSubcategory] {
        allCases.filter { $0.category == category }
    }
}
