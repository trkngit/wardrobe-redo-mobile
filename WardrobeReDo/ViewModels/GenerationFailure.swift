import Foundation

/// Reason an outfit generation attempt failed, used to drive
/// reason-specific empty-state copy and the Try-Again button in
/// `DailyOutfitsView` and `MatchingView`.
///
/// Generic `errorMessage` is still set for backward compatibility with
/// existing tests, but views should prefer `lastFailure` when present.
enum GenerationFailure: Equatable, Sendable {
    /// Wardrobe has fewer than the minimum items needed (2 for daily,
    /// 2 for match: hero + at least one supporting piece).
    case wardrobeTooSmall(itemCount: Int)
    /// Generation ran but produced zero compatible candidates.
    case noCompatibleOutfits
    /// The 60s task-group timeout fired before generation finished.
    case networkTimeout
    /// Anything else — typically a thrown repository or service error.
    case unknown(String)

    /// User-facing copy shown in the empty-state of the Outfits and
    /// Match tabs.
    var userMessage: String {
        switch self {
        case .wardrobeTooSmall(let count) where count <= 0:
            return "Add a few items to start generating outfits."
        case .wardrobeTooSmall(let count) where count == 1:
            return "Add at least one more item — outfits need at least two pieces."
        case .wardrobeTooSmall:
            return "Add more variety to your wardrobe to generate outfits."
        case .noCompatibleOutfits:
            return "We couldn't build any outfits with your current wardrobe. Try a different occasion, or add more variety."
        case .networkTimeout:
            return "The connection is slow. Tap Try Again."
        case .unknown(let msg):
            return "Something went wrong: \(msg). Tap Try Again."
        }
    }

    /// Whether the empty state should also offer an "Add an Item" CTA
    /// (only meaningful for the wardrobe-too-small case).
    var suggestsAddingItems: Bool {
        if case .wardrobeTooSmall = self { return true }
        return false
    }
}

/// Internal outcome enum used by the ViewModel to disambiguate the
/// race between successful generation and timeout.
enum GenerationOutcome: Sendable {
    case success
    case empty
    case timeout
    case error(String)
}
