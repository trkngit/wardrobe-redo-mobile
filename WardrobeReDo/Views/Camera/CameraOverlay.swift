import SwiftUI

/// HUD drawn on top of the live camera preview. Shows a traffic-light
/// pill with coaching copy, a cancel button, and the shutter button.
///
/// **The HUD is advisory, not gating.** Background quality drives the
/// pill color + coaching copy only — the shutter is tappable the moment
/// the user has granted camera permission, regardless of quality. We
/// coach, we don't gatekeep. Users who are shooting a garment worn on a
/// person, or who can't get to a plain wall, still need to be able to
/// capture.
struct CameraOverlay: View {
    let quality: BackgroundQuality
    let authorization: CameraAuthorizationState
    var onShutter: () -> Void
    var onCancel: () -> Void

    /// Whether the shutter is tappable for a given authorization state.
    /// Split out as a static function so unit tests can exercise the
    /// gate without constructing a SwiftUI view.
    static func shutterEnabled(for authorization: CameraAuthorizationState) -> Bool {
        authorization == .authorized
    }

    private var isShutterEnabled: Bool {
        Self.shutterEnabled(for: authorization)
    }

    var body: some View {
        ZStack {
            switch authorization {
            case .notDetermined, .authorized:
                authorizedOverlay
            case .denied:
                deniedOverlay
            case .notAvailable:
                notAvailableOverlay
            }
        }
        .animation(Theme.Animation.standard, value: quality)
        .animation(Theme.Animation.standard, value: authorization)
    }

    // MARK: - Authorized

    private var authorizedOverlay: some View {
        VStack {
            topBar
            Spacer()
            qualityPill
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
            Text(quality.coachingText)
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

    private var shutterRow: some View {
        // The shutter follows `isShutterEnabled` (camera authorization
        // only). We keep the `.disabled` binding so the button is inert
        // on the brief pre-authorization frame; we don't need a "Take
        // anyway" escape hatch any more because quality is advisory.
        Button(action: onShutter) {
            ZStack {
                Circle()
                    .fill(.white.opacity(isShutterEnabled ? 1.0 : 0.5))
                    .frame(width: 72, height: 72)
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 84, height: 84)
            }
        }
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
            authorization: .authorized,
            onShutter: {},
            onCancel: {}
        )
    }
}
