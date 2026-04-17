import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - AppState Tests
// Note: AppState has hard Supabase dependencies. These tests cover
// observable state behavior that doesn't require network calls.

@Test @MainActor func appStateInitialValues() {
    let state = AppState()
    #expect(state.isLoading == true)
    #expect(state.isAuthenticated == false)
    #expect(state.currentUser == nil)
    #expect(state.profileLoadFailed == false)
}

@Test @MainActor func appStateProfileLoadFailedDefaultsFalse() {
    let state = AppState()
    #expect(state.profileLoadFailed == false)
}

@Test @MainActor func appStateIsLoadingStartsTrue() {
    // isLoading starts true until initialize() completes
    let state = AppState()
    #expect(state.isLoading == true)
}

@Test @MainActor func appStateCurrentUserStartsNil() {
    let state = AppState()
    #expect(state.currentUser == nil)
}
