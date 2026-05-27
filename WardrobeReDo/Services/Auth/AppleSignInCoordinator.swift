import AuthenticationServices
import CryptoKit
import Foundation

/// Build 32 — wraps `ASAuthorizationController` in an async API so
/// `AuthViewModel.signInWithApple()` can `await` a single call
/// instead of plumbing a delegate.
///
/// **Flow:**
///   1. Caller invokes `requestCredential()`.
///   2. We generate a random nonce, SHA-256 hash it, and include
///      the hash in the ASA request.
///   3. iOS shows the native "Sign in with Apple" sheet.
///   4. User authenticates via Face ID / Touch ID / passcode.
///   5. iOS returns an `ASAuthorizationAppleIDCredential` whose
///      `identityToken` is a signed JWT with the nonce hash as a
///      claim.
///   6. We hand the JWT + the RAW nonce back to the caller. The
///      caller (AuthService) forwards both to Supabase, which
///      verifies the JWT signature AND re-hashes the raw nonce to
///      match the JWT's claim. Without the raw nonce there's no
///      replay protection.
///
/// **Why a class, not a struct:** ASAuthorizationController requires
/// a delegate and a presentation-context provider, both of which
/// have to be retained for the entire lifetime of the modal sheet.
/// A continuation-bridge with a captured strong self is the
/// canonical way to do this in Swift Concurrency.
@MainActor
final class AppleSignInCoordinator: NSObject {

    /// Credential returned by Apple after a successful sign in.
    /// `fullName` is only present on the FIRST sign in for a given
    /// Apple ID; subsequent sign ins return nil. Persist it on
    /// first use if you want to keep the display name.
    struct AppleCredential: Sendable {
        let idToken: String
        let rawNonce: String
        let fullName: PersonNameComponents?
        let email: String?
    }

    private var continuation: CheckedContinuation<AppleCredential, Error>?
    private var currentNonce: String?

    /// Presents the Apple Sign In sheet and returns the credential
    /// (identity token + raw nonce + optional name/email).
    ///
    /// Throws `ASAuthorizationError.canceled` if the user
    /// dismisses without authenticating, or `AppleSignInError` for
    /// anything Apple returns that we can't proceed with.
    func requestCredential() async throws -> AppleCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let nonce = Self.randomNonce()
            self.currentNonce = nonce

            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = Self.sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - Nonce

    /// 32-character cryptographically random nonce. Per Apple's
    /// docs we want at least 32 chars from a set of URL-safe
    /// printable characters.
    private static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            precondition(status == errSecSuccess)
            randoms.forEach { byte in
                if remainingLength == 0 { return }
                if byte < charset.count {
                    result.append(charset[Int(byte)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    /// SHA-256 the raw nonce. Apple stores the HASH in the JWT and
    /// Supabase verifies that `SHA-256(rawNonce) == JWT.nonce`.
    private static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

enum AppleSignInError: LocalizedError {
    case missingIdentityToken
    case missingNonce
    case unexpectedCredentialType

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken: "Apple Sign In didn't return an identity token. Please try again."
        case .missingNonce: "Sign In session expired. Please try again."
        case .unexpectedCredentialType: "Unexpected credential type from Apple."
        }
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                resume(throwing: AppleSignInError.unexpectedCredentialType)
                return
            }
            guard let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                resume(throwing: AppleSignInError.missingIdentityToken)
                return
            }
            guard let nonce = currentNonce else {
                resume(throwing: AppleSignInError.missingNonce)
                return
            }
            resume(returning: AppleCredential(
                idToken: idToken,
                rawNonce: nonce,
                fullName: credential.fullName,
                email: credential.email
            ))
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            resume(throwing: error)
        }
    }

    private func resume(returning value: AppleCredential) {
        continuation?.resume(returning: value)
        continuation = nil
        currentNonce = nil
    }

    private func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
        currentNonce = nil
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        // Pick the first foreground active window. SwiftUI apps
        // can have multiple scenes; the foreground active one is
        // the one the user is interacting with. Fallback to an
        // empty anchor so we never crash — Apple still resolves
        // the presentation against the system if the anchor is
        // unattached, just less optimally.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes
            let activeWindow = scenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })?
                .windows.first(where: \.isKeyWindow)
            return activeWindow ?? ASPresentationAnchor()
        }
    }
}
