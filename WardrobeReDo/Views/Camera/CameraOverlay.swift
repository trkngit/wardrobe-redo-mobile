import SwiftUI
import UIKit

/// HUD drawn on top of the live camera preview. Shows a traffic-light
/// pill with coaching copy, a cancel button, the shutter button, and
/// (when the live frame is favorable) a thin green stroke around the
/// preview rect.
///
/// **The HUD is advisory, not gating.** Background quality, sharpness,
/// and subject-coverage drive the pill color, coaching copy, and green
/// stroke — the shutter is tappable the moment camera permission is
/// granted AND the session has emitted at least one frame, regardless
/// of quality. We coach, we don't gatekeep. Users who shoot garments
/// worn on a person, or who can't reach a plain wall, still need to
/// be able to capture.
struct CameraOverlay: View {
    let quality: BackgroundQuality
    let sharpness: Float
    let coverage: Float
    let authorization: CameraAuthorizationState
    let sessionState: CameraSessionState
    var onShutter: () -> Void
    var onCancel: () -> Void

    /// Combines authorization × session lifecycle into a single
    /// user-visible state. Pure function for unit tests; the view body
    /// just dispatches on the result.
    static func overlayPhase(
        authorization: CameraAuthorizationState,
        sessionState: CameraSessionState
    ) -> OverlayPhase {
        switch authorization {
        case .denied: return .denied
        case .notAvailable: return .notAvailable
        case .notDetermined: return .starting
        case .authorized:
            switch sessionState {
            case .running: return .live
            case .configuring, .failed, .stopped: return .preparing
            }
        }
    }

    /// Backward-compat shutter gate keyed on authorization only. The
    /// pre-build-6 tests assert this exact contract: shutter is
    /// enabled iff the user has explicitly granted permission. Kept
    /// intact so existing call sites and `CameraOverlayTests` continue
    /// to compile.
    static func shutterEnabled(for authorization: CameraAuthorizationState) -> Bool {
        authorization == .authorized
    }

    /// New gate used by the live overlay — shutter is enabled only in
    /// the `.live` phase. `.starting` and `.preparing` hide the
    /// button; `.denied` / `.notAvailable` swap in their own copy.
    ///
    /// Uses the `in:` label rather than `for:` so the compiler can
    /// disambiguate from the legacy `shutterEnabled(for:)`
    /// authorization-based overload without forcing callers (or the
    /// pre-build-6 tests) to qualify enum cases.
    static func shutterEnabled(in phase: OverlayPhase) -> Bool {
        phase == .live
    }

    /// Capture-ready composite. Drives the advisory green border and
    /// the quality pill's "Looks great" copy. Does NOT gate the
    /// shutter — see class docstring.
    static func isCapturable(
        quality: BackgroundQuality,
        sharpness: Float,
        coverage: Float
    ) -> Bool {
        quality == .good
            && sharpness >= minSharpness
            && coverage >= minCoverage
            && coverage <= maxCoverage
    }

    /// Minimum normalized Laplacian-variance value for the frame to
    /// be considered sharp. Tuned via `SharpnessMetric` constants.
    static let minSharpness: Float = 0.6
    /// Lower bound of subject coverage — below this the garment is too
    /// small to extract reliably.
    static let minCoverage: Float = 0.15
    /// Upper bound of subject coverage — above this the user is too
    /// close and the frame likely cuts off the silhouette.
    static let maxCoverage: Float = 0.80

    private var phase: OverlayPhase {
        Self.overlayPhase(authorization: authorization, sessionState: sessionState)
    }

    private var isShutterEnabled: Bool { Self.shutterEnabled(in: phase) }
    private var isCapturable: Bool {
        Self.isCapturable(quality: quality, sharpness: sharpness, coverage: coverage)
    }

    var body: some View {
        ZStack {
            // Live preview rect indicator — a thin advisory stroke
            // that turns green when capture conditions are favorable.
            // Wrapped in a ZStack so we can animate the color
            // independently of the rest of the HUD.
            if phase == .live {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(isCapturable ? Color.green : Color.clear, lineWidth: 3)
                    .padding(1.5)
                    .ignoresSafeArea()
                    .animation(Theme.Animation.standard, value: isCapturable)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            switch phase {
            case .starting:
                startingOverlay
            case .preparing, .live:
                authorizedOverlay
            case .denied:
                deniedOverlay
            case .notAvailable:
                notAvailableOverlay
            }
        }
        .animation(Theme.Animation.standard, value: quality)
        .animation(Theme.Animation.standard, value: phase)
    }

    // MARK: - Starting (permission decision in flight)

    private var startingOverlay: some View {
        VStack(spacing: Theme.Spacing.md) {
            topBar
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text("Starting camera…")
                .font(Theme.Fonts.body.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
    }

    // MARK: - Authorized (preparing + live)

    private var authorizedOverlay: some View {
        VStack {
            topBar
            Spacer()
            qualityPill
                .padding(.bottom, Theme.Spacing.sm)
            coachingText
                .padding(.bottom, Theme.Spacing.lg)
            shutterRow
                .padding(.bottom, Theme.Spacing.xl)
        }
    }

    private var topBar: some View {
        HStack {
            overlayButton(systemImage: "xmark", accessibilityLabel: "Cancel", action: onCancel)
            Spacer()
        }
        .padding(Theme.Spacing.md)
    }

    private var qualityPill: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.25), lineWidth: 1)
                )
            Text(phase == .preparing ? "Framing up…" : quality.coachingText)
                .font(Theme.Fonts.bodySmall.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            Capsule()
                .fill(.black.opacity(0.55))
        )
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var coachingText: some View {
        Text("Place clothing on a clean, flat surface")
            .font(Theme.Fonts.bodySmall)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Spacing.lg)
    }

    private var shutterRow: some View {
        Button {
            // Synchronous haptic on tap. UIImpactFeedbackGenerator
            // dispatches before the SwiftUI re-render cycle, so the
            // user feels the bump *before* the photo flash — that
            // immediacy is what makes the shutter feel reliable.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onShutter()
        } label: {
            Color.clear.frame(width: 84, height: 84)
        }
        .buttonStyle(ShutterButtonStyle(isEnabled: isShutterEnabled))
        .disabled(!isShutterEnabled)
        .accessibilityLabel("Capture photo")
    }

    // MARK: - Denied / not available

    private var deniedOverlay: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "camera.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white)
            Text("Camera access needed")
                .font(Theme.Fonts.h3)
                .foregroundStyle(.white)
            Text("Enable camera access in Settings to take photos in-app. You can still choose photos from your library.")
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.lg)
            HStack(spacing: Theme.Spacing.md) {
                Button("Close", action: onCancel)
                    .buttonStyle(.bordered)
                    .tint(.white)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                        .font(Theme.Fonts.body.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
            }
            .padding(.top, Theme.Spacing.sm)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.75))
    }

    private var notAvailableOverlay: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white)
            Text("Camera not available")
                .font(Theme.Fonts.h3)
                .foregroundStyle(.white)
            Text("This device or environment doesn't have a usable camera. Try choosing a photo from your library instead.")
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.lg)
            Button("Close", action: onCancel)
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.top, Theme.Spacing.sm)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }

    // MARK: - Helpers

    private var dotColor: Color {
        switch quality.semanticColor {
        case .positive: return .green
        case .warning:  return .yellow
        case .neutral:  return .gray
        }
    }

    private func overlayButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.black.opacity(0.45)))
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Overlay phase

/// Composite state surfaced to the SwiftUI body. Maps onto
/// `authorization × sessionState` so the view can switch on a single
/// enum rather than nest conditions.
enum OverlayPhase: Sendable, Equatable {
    case starting       // permission decision in flight
    case preparing      // .authorized but no frames yet
    case live           // ready to capture
    case denied
    case notAvailable
}

// MARK: - Shutter button style

private struct ShutterButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle()
                .fill(.white.opacity(isEnabled ? 1.0 : 0.5))
                .frame(width: 72, height: 72)
            Circle()
                .stroke(.white.opacity(0.9), lineWidth: 4)
                .frame(width: 84, height: 84)
        }
        .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

#Preview {
    ZStack {
        LinearGradient(
            colors: [.blue.opacity(0.6), .indigo.opacity(0.8)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        CameraOverlay(
            quality: .good,
            sharpness: 0.8,
            coverage: 0.4,
            authorization: .authorized,
            sessionState: .running,
            onShutter: {},
            onCancel: {}
        )
    }
}
