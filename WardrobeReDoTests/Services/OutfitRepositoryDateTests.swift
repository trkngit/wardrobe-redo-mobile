import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - OutfitRepository Date Helper Tests

@Test func todayDateStringMatchesExpectedFormat() {
    let dateString = OutfitRepository.todayDateString()
    // Should match yyyy-MM-dd format
    let regex = /^\d{4}-\d{2}-\d{2}$/
    #expect(dateString.wholeMatch(of: regex) != nil, "Expected yyyy-MM-dd format, got: \(dateString)")
}

@Test func todayDateStringParsesBackToToday() {
    let dateString = OutfitRepository.todayDateString()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"

    let parsed = formatter.date(from: dateString)
    #expect(parsed != nil)

    if let parsed {
        let calendar = Calendar.current
        #expect(calendar.isDateInToday(parsed))
    }
}
