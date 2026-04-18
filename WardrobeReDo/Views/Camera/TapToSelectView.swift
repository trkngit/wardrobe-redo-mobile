import SwiftUI
import UIKit

/// Manual tap-to-select UX for the Phase 3 SAM2 fallback. Shown from
/// `MaskTouchupView` when the user taps "Trouble cropping?".
///
/// The user taps directly on the clothing item to place a positive
/// point; long-pressing (or using the − button then tapping) places a
/// negative point on background/skin. SAM2 re-runs on every change, so
/// the mask preview updates live. When they're happy, "Use this crop"
/// commits and the edited mask flows back into the view model.
struct TapToSelectView: View {
    let sourceImage: UIImage
    /// Pre-populated extraction result from the upstream auto-pipeline
    /// (Vision or SAM2-auto). When non-nil, the view opens with this mask
    /// already shown so the user can hit "Use this crop" without tapping
    /// — the happy-path single-item flow is now a one-button confirm.
    /// Tapping anywhere overrides the auto-mask with a fresh SAM2 pass.
    var initialResult: ExtractionResult?
    /// Extractor used to re-segment after every tap. Parent supplies the
    /// same instance the rest of the pipeline uses so prewarmed models
    /// aren't re-loaded here.
    let extractor: any ClothingExtracting
    var onDone: (ExtractionResult) -> Void
    var onCancel: () -> Void
    /// "Refine with brush" detour — when non-nil, a toolbar button
    /// surfaces it as the escape hatch into `MaskTouchupView` for users
    /// who want pixel-level control. Optional so legacy entry points
    /// (e.g. the `MaskTouchupView` "Trouble cropping?" back-detour) can
    /// hide the button to avoid a brush ↔ tap loop.
    var onRefineWithBrush: (() -> Void)?

    @State private var points: [SAM2TapPoint] = []
    @State private var mode: PointMode = .positive
    @State private var preview: UIImage?
    @State private var lastResult: ExtractionResult?
    @State private var isProcessing = false
    @State private var hasRunInitial = false
    /// Latest in-flight SAM2 inference. Cancelled before each new tap /
    /// undo / reset so fast user input doesn't stack 2-3 concurrent
    /// predictions (each ~100 MB working set). See "bound heap" plan
    /// in `unified-mapping-honey.md`.
    @State private var segmentTask: Task<Void, Never>?

    enum PointMode: String, CaseIterable, Identifiable {
        case positive, negative
        var id: String { rawValue }
        var displayName: String { self == .positive ? "Clothing" : "Background" }
        var systemImage: String { self == .positive ? "plus.circle.fill" : "minus.circle.fill" }
        var tint: Color { self == .positive ? .green : .red }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(Theme.Colors.background).ignoresSafeArea()

                VStack(spacing: Theme.Spacing.md) {
                    if showAutoDetectedHint {
                        autoDetectedHint
                    }

                    GeometryReader { geo in
                        tappableCanvas(in: geo.size)
                    }
                    .frame(maxHeight: .infinity)

                    modePicker
                    actionRow
                }
                .padding(Theme.Spacing.md)
            }
            .navigationTitle("Tap the clothing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", action: onCancel)
                }
                if let onRefineWithBrush {
                    // Power-user escape hatch — most users finish in
                    // tap-to-select alone. Lives in the trailing
                    // toolbar (not the action row) to keep visual
                    // weight low; "Use this crop" stays the primary
                    // CTA per the tap-to-select-first redesign.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onRefineWithBrush()
                        } label: {
                            Label("Refine with brush", systemImage: "paintbrush")
                        }
                        .accessibilityLabel("Refine selection with brush")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Use this crop") { commit() }
                        .disabled(lastResult == nil && preview == nil)
                }
            }
            .task {
                guard !hasRunInitial else { return }
                hasRunInitial = true
                if let initial = initialResult {
                    // Tap-to-select-first flow: parent already ran the
                    // auto-pipeline (Vision or SAM2-auto), so paint that
                    // mask immediately and let the user commit with one
                    // button. Skip the initial center-point SAM2 pass —
                    // we already have a higher-quality starting point.
                    lastResult = initial
                    preview = initial.maskedImage
                } else {
                    // Legacy entry point (e.g. the brush-detour back into
                    // tap-to-select with no upstream result). Kick off a
                    // center-point segmentation so the user has something
                    // to refine instead of an empty canvas.
                    scheduleSegment(with: [SAM2TapPoint.positive(CGPoint(x: 0.5, y: 0.5))])
                }
            }
            .onDisappear { segmentTask?.cancel() }
        }
    }

    // MARK: - Hint

    /// Show the "Auto-detected — tap to refine" callout while the
    /// pre-populated mask is still untouched. As soon as the user taps
    /// even once the hint disappears (they've engaged with the tool, no
    /// more nudge needed). Also hidden if upstream extraction failed
    /// (`.none`) so we don't claim to have detected something we didn't.
    private var showAutoDetectedHint: Bool {
        guard points.isEmpty, let result = lastResult else { return false }
        switch result.method {
        case .vision, .sam2Auto:
            return true
        case .sam2Manual, .none:
            return false
        }
    }

    private var autoDetectedHint: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color(Theme.Colors.primary))
            Text("Auto-detected — tap to refine if needed")
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

    // MARK: - Canvas

    private func tappableCanvas(in container: CGSize) -> some View {
        let rect = aspectFitRect(imageSize: sourceImage.size, in: container)
        return ZStack {
            CheckerboardBackground()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

            if let preview = preview ?? (lastResult?.maskedImage) {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.opacity)
            } else {
                Image(uiImage: sourceImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .opacity(0.35)
            }

            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                let absolute = CGPoint(
                    x: rect.origin.x + point.normalized.x * rect.width,
                    y: rect.origin.y + point.normalized.y * rect.height
                )
                pointMarker(for: point)
                    .position(absolute)
            }

            if isProcessing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(Theme.Spacing.md)
                    .background(
                        Capsule().fill(.black.opacity(0.5))
                    )
                    .position(x: rect.midX, y: rect.origin.y + Theme.Spacing.xl)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    guard rect.contains(value.location) else { return }
                    let normalized = CGPoint(
                        x: (value.location.x - rect.origin.x) / rect.width,
                        y: (value.location.y - rect.origin.y) / rect.height
                    )
                    let tap = SAM2TapPoint(
                        normalized: normalized,
                        isPositive: mode == .positive
                    )
                    let next = points + [tap]
                    points = next
                    scheduleSegment(with: next)
                }
        )
    }

    private func pointMarker(for point: SAM2TapPoint) -> some View {
        Image(systemName: point.isPositive ? "plus.circle.fill" : "minus.circle.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(point.isPositive ? Color.green : Color.red)
            .background(
                Circle()
                    .fill(.white)
                    .padding(4)
            )
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
    }

    // MARK: - Controls

    private var modePicker: some View {
        Picker("Tap mode", selection: $mode) {
            ForEach(PointMode.allCases) { option in
                Label(option.displayName, systemImage: option.systemImage).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                guard !points.isEmpty else { return }
                let next = points.dropLast()
                points = Array(next)
                scheduleSegment(with: Array(next))
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(Theme.Fonts.bodySmall.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.sm)
            }
            .buttonStyle(.bordered)
            .tint(Color(Theme.Colors.textSecondary))
            .disabled(points.isEmpty || isProcessing)

            Button {
                points = []
                preview = nil
                lastResult = nil
                scheduleSegment(with: [SAM2TapPoint.positive(CGPoint(x: 0.5, y: 0.5))])
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(Theme.Fonts.bodySmall.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.sm)
            }
            .buttonStyle(.bordered)
            .tint(Color(Theme.Colors.primary))
            .disabled(isProcessing)
        }
    }

    // MARK: - Segmentation

    /// Cancel any in-flight SAM2 inference and schedule a fresh one.
    /// The previous Task continues to run until its current `await`
    /// suspension point, but its result is dropped via the
    /// `Task.isCancelled` check inside `segment(with:)`. Net effect:
    /// fast successive taps no longer stack 2-3 concurrent SAM2
    /// predictions in working memory — only the most recent one ever
    /// commits to the UI state.
    private func scheduleSegment(with taps: [SAM2TapPoint]) {
        segmentTask?.cancel()
        segmentTask = Task { await segment(with: taps) }
    }

    private func segment(with taps: [SAM2TapPoint]) async {
        isProcessing = true
        let result = await extractor.extract(sourceImage, tapPoints: taps)
        // If a fresh tap superseded this one mid-inference, the new
        // task already flipped `isProcessing` back to true, so we must
        // not commit `false` here (would clear the spinner during the
        // newer prediction). The new task will own the eventual
        // `isProcessing = false` flip when it finishes.
        guard !Task.isCancelled else { return }
        lastResult = result
        preview = result.maskedImage
        isProcessing = false
    }

    private func commit() {
        if let result = lastResult {
            onDone(result)
            return
        }
        // User tapped commit before any segmentation finished — build a
        // synthetic result from the source image so the flow still
        // advances gracefully.
        onDone(ExtractionResult(
            originalImage: sourceImage,
            maskedImage: preview ?? sourceImage,
            mask: nil,
            confidence: .low,
            method: .sam2Manual
        ))
    }

    // MARK: - Layout

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let widthRatio = container.width / imageSize.width
        let heightRatio = container.height / imageSize.height
        let ratio = min(widthRatio, heightRatio)
        let fittedSize = CGSize(
            width: imageSize.width * ratio,
            height: imageSize.height * ratio
        )
        let origin = CGPoint(
            x: (container.width - fittedSize.width) / 2,
            y: (container.height - fittedSize.height) / 2
        )
        return CGRect(origin: origin, size: fittedSize)
    }
}

#Preview {
    if let placeholder = UIImage(systemName: "tshirt.fill")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal) {
        TapToSelectView(
            sourceImage: placeholder,
            initialResult: ExtractionResult(
                originalImage: placeholder,
                maskedImage: placeholder,
                mask: nil,
                confidence: .high,
                method: .sam2Auto
            ),
            extractor: ClothingExtractionService(),
            onDone: { _ in },
            onCancel: {}
        )
    }
}
