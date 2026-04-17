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
}
