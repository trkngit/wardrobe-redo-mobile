import Foundation

struct ItemStyleTag: Codable, Identifiable, Sendable {
    let id: UUID
    let wardrobeItemId: UUID
    var tag: String
    var confidence: Double
    var source: String

    enum CodingKeys: String, CodingKey {
        case id
        case wardrobeItemId = "wardrobe_item_id"
        case tag, confidence, source
    }
}
