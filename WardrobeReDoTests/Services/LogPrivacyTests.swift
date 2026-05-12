import Foundation
import Testing
import os
@testable import WardrobeReDo

// MARK: - LogPrivacy (build 20)
//
// `LogPrivacy` is a thin wrapper over `os.Logger` whose value is in
// the convention, not the implementation. Testing it directly is
// limited — `Logger` doesn't surface what it wrote, and the privacy
// attributes are interpreted at the os_log level which the test
// process doesn't intercept.
//
// What we CAN test is the call-site contract: the helpers compile,
// don't crash on valid inputs, and accept all three logger
// signatures from the codebase (error/warning/info). That's enough
// to catch a refactor that breaks the API; the actual masking
// behavior is Apple's responsibility.

@Test @MainActor
func logPrivacyAcceptsErrorWithReason() {
    let logger = Logger(subsystem: "com.wardroberedo.tests", category: "LogPrivacyTests")
    struct StubError: Error { let detail: String }
    LogPrivacy.error(logger, category: "signIn", reason: StubError(detail: "test"))
}

@Test @MainActor
func logPrivacyAcceptsWarningWithReason() {
    let logger = Logger(subsystem: "com.wardroberedo.tests", category: "LogPrivacyTests")
    LogPrivacy.warning(logger, category: "loadProfile", reason: "stub reason")
}

@Test @MainActor
func logPrivacyAcceptsInfoWithUserId() {
    let logger = Logger(subsystem: "com.wardroberedo.tests", category: "LogPrivacyTests")
    LogPrivacy.info(logger, category: "initialize.sessionFound", userId: UUID())
}
