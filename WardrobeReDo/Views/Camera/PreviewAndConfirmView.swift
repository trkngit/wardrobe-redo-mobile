import SwiftUI
import UIKit

/// Build 45 — primary post-processing surface. Replaces
/// `TapToSelectView` as the default landing after auto-extraction.
///
/// User journey:
///   1. Auto-pipeline produces a cutout (RFDETR proposal, Vision, or
///      SAM2 auto).
///   2. This view shows that cutout centered on a checkerboard, with
///      a small confidence/method hint underneath.
///   3. Three actions:
///        * **Use this** — commits the cutout, routes to details.
///        * **Refine if needed** — opens the existing `TapToSelectView`
///          for users who want pixel-level control.
///        * **Retake** — drops back to the photo step.
///
/// The "Refine if needed" path keeps the TF43/TF44 cached-session +
/// serialized tap pipeline alive for the rare bad-detection case.
/// Most users will tap "Use this" on the happy path; that turns the
/// post-process step into a single tap instead of a tap-to-select
/// session that's slow on cold sessions and crash-prone under rapid
/// input.
struct PreviewAndConfirmView: View {
    /// Cutout the auto-pipeline produced (transparent background,
    /// clothing only). When the pipeline emitted no mask, callers can
    /// pass the original image and the view still renders a sensible
    /// preview — just without the "background removed" effect.
    let cutoutImage: UIImage
    /// Which path generated the cutout. Drives the hint text below
    /// the image — "Auto-detected (Wardrobe)" for RF-DETR, "Photo
    /// background removed" for Vision, etc.
    let method: ExtractionMethod
    /// Confidence band — used in the hint copy. `.high` / `.medium`
    /// → "auto-detected, looks good"; `.low` / `.failed` → "auto-
    /// detected, you may want to refine".
    let confidence: ExtractionConfidence?

    var onUseThis: () -> Void
    var onRefine: () -> Void
    var onRetake: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color(Theme.Colors.background).ignoresSafeArea()

                VStack(spacing: Theme.Spacing.lg) {
                    headerText
                    cutoutCanvas
                    detectionHint
                    actionStack
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .navigationTitle(LocalizedStringResource("Looks good?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("Retake"), action: onRetake)
                }
            }
        }
    }

    // MARK: - Sections

    private var headerText: some View {
        // The navigation bar already shows "Looks good?", so the
        // section below the canvas focuses on what's actually visible
        // — the cutout and the actions.
        EmptyView()
    }

    private var cutoutCanvas: some View {
        ZStack {
            CheckerboardBackground()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

            Image(uiImage: cutoutImage)
                .resizable()
                .scaledToFit()
                .padding(Theme.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detectionHint: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: hintSystemImage)
                .foregroundStyle(Color(Theme.Colors.primary))
            Text(hintCopy)
                .font(Theme.Fonts.caption.weight(.medium))
                .foregroundStyle(Color(Theme.Colors.textSecondary))
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button)
                .fill(Color(Theme.Colors.primary).opacity(0.08))
        )
    }

    private var actionStack: some View {
        VStack(spacing: Theme.Spacing.md) {
            PrimaryButton(LocalizedStringResource("Use this"), action: onUseThis)
            GhostButton(LocalizedStringResource("Refine if needed"), action: onRefine)
        }
    }

    // MARK: - Hint copy

    private var hintSystemImage: String {
        switch method {
        case .multiGarmentRFDETR, .vision, .sam2Auto:
            return "sparkles"
        case .sam2Manual:
            return "hand.tap"
        case .none:
            return "exclamationmark.circle"
        }
    }

    private var hintCopy: LocalizedStringResource {
        switch (method, confidence) {
        case (.multiGarmentRFDETR, _),
             (.vision, .high),
             (.vision, .medium),
             (.sam2Auto, .high),
             (.sam2Auto, .medium):
            return LocalizedStringResource("Auto-detected — tap to refine if needed")
        case (.vision, .low), (.sam2Auto, .low):
            return LocalizedStringResource("Auto-cropped — double-check the outline")
        default:
            return LocalizedStringResource("Auto-detected — tap to refine if needed")
        }
    }
}

#Preview {
    if let placeholder = UIImage(systemName: "tshirt.fill")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal) {
        PreviewAndConfirmView(
            cutoutImage: placeholder,
            method: .multiGarmentRFDETR,
            confidence: .high,
            onUseThis: {},
            onRefine: {},
            onRetake: {}
        )
    }
}
