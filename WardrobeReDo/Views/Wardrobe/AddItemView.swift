import SwiftUI
import PhotosUI

struct AddItemView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = AddItemViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(Theme.Colors.background)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        // Progress indicator
                        progressBar

                        switch viewModel.currentStep {
                        case .photo, .analysis:
                            // The `.analysis` step no longer renders its
                            // own surface — `AnalyzingPopup` sits on top
                            // of the (stable) photo step while processing
                            // runs, so the popup smoothly dismisses back
                            // to the picker if the user cancels. The
                            // enum case is kept for source-compat with
                            // existing tests + future surfaces.
                            photoStep
                        case .details:
                            detailsStep
                        case .saving:
                            savingStep
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.md)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // "Skip this item" is visible only while a multi-pick
                // batch is mid-flight — i.e. the user has confirmed
                // proposals and is walking through the sequential
                // details step. Single-item flows never see it.
                if viewModel.currentProposal != nil, viewModel.currentStep == .details {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Skip this item") {
                            viewModel.onSkipCurrentProposal()
                        }
                        .accessibilityHint("Skips this garment without saving and moves to the next detected item.")
                    }
                }
            }
            .onChange(of: viewModel.selectedPhoto) {
                Task { await viewModel.onPhotoSelected() }
            }
            .onChange(of: viewModel.didSave) {
                if viewModel.didSave { dismiss() }
            }
            .fullScreenCover(isPresented: $viewModel.isShowingCamera) {
                cameraCover
            }
            .fullScreenCover(isPresented: $viewModel.isShowingTouchup) {
                touchupCover
            }
            .fullScreenCover(isPresented: $viewModel.isShowingTapToSelect) {
                tapToSelectCover
            }
            .fullScreenCover(isPresented: $viewModel.isShowingMultiPick) {
                multiPickCover
            }
            .sheet(isPresented: $viewModel.isShowingTutorial) {
                FirstRunTutorialView {
                    viewModel.onTutorialDismissed()
                }
                .interactiveDismissDisabled()
            }
            .task {
                // Pre-warm SAM2 so the first tap doesn't eat a model-load
                // hit. The extractor guards against redundant work.
                await viewModel.clothingExtractor.prewarm()
            }
            .overlay {
                // Centered analyzing-popup overlay. Replaces the inline
                // `.analysis` step's role as the "processing" surface —
                // the underlying view stays mounted (so the popup
                // smoothly dismisses back to whichever step the user
                // came from) and a 40% black backdrop blocks input on
                // the rest of the UI while the user decides whether to
                // wait or cancel.
                if viewModel.isProcessing {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        AnalyzingPopup(onCancel: { viewModel.cancelProcessing() })
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .overlay(alignment: .bottom) {
                // Brief "Cancelled" pill confirms the cancel landed —
                // the analyzing popup disappears at the same instant
                // the underlying step reverts to `.photo`, which would
                // otherwise look identical to a slow processing run
                // that hadn't started yet. The pill auto-dismisses
                // ~1.8s later via the VM's `cancellationDismissTask`.
                if viewModel.cancellationToastVisible {
                    cancellationToast
                        .padding(.bottom, Theme.Spacing.xl)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isProcessing)
            .animation(.spring(duration: 0.3), value: viewModel.cancellationToastVisible)
        }
    }

    // MARK: - Camera fullscreen cover

    @ViewBuilder
    private var cameraCover: some View {
        let monitor = BackgroundQualityMonitor()
        let controller = CameraController()
        ZStack {
            Color.black.ignoresSafeArea()
            CameraCaptureView(
                monitor: monitor,
                controller: controller,
                onPhotoCaptured: { image in
                    Task { await viewModel.onCameraPhotoCaptured(image) }
                },
                onAuthorizationChanged: { _ in }
            )
            .ignoresSafeArea()
            CameraOverlay(
                quality: monitor.quality,
                authorization: .authorized,
                onShutter: controller.capture,
                onCancel: viewModel.onCameraCancelled
            )
        }
    }

    // MARK: - Touch-up fullscreen cover

    @ViewBuilder
    private var touchupCover: some View {
        if let source = viewModel.selectedImage,
           let maskedData = viewModel.processedImage?.maskedData,
           let masked = UIImage(data: maskedData) {
            MaskTouchupView(
                sourceImage: source,
                initialMaskedImage: masked,
                isAutoCropped: viewModel.isAutoCropped,
                onDone: { edited in
                    Task { await viewModel.onTouchupDone(edited) }
                },
                onSmartRecrop: {
                    Task { await viewModel.onTouchupSmartRecrop() }
                },
                onTapToSelect: { viewModel.onTroubleCropping() },
                onCancel: viewModel.onTouchupCancelled
            )
        } else {
            // Fallback: no masked data yet; skip touchup.
            Color.clear
                .onAppear { viewModel.onTouchupCancelled() }
        }
    }

    // MARK: - Tap-to-select fullscreen cover (Phase 3)

    @ViewBuilder
    private var tapToSelectCover: some View {
        if let source = viewModel.selectedImage {
            // Build an `ExtractionResult` from the processed metadata so
            // tap-to-select opens already showing the auto-pipeline's
            // best guess. One-button "Use this crop" commits straight
            // through; tapping anywhere overrides with a fresh SAM2 pass.
            // Falls back to a `.none` result when no upstream mask is
            // available (e.g. the brush detour re-enters with no fresh
            // processing run behind it).
            let initialResult = viewModel.processedImage.map { processed -> ExtractionResult in
                let maskedImage = processed.maskedData
                    .flatMap { UIImage(data: $0) } ?? source
                return ExtractionResult(
                    originalImage: source,
                    maskedImage: maskedImage,
                    mask: nil,
                    confidence: processed.extractionConfidence ?? .low,
                    method: processed.extractionMethod ?? .none
                )
            }
            TapToSelectView(
                sourceImage: source,
                initialResult: initialResult,
                extractor: viewModel.clothingExtractor,
                onDone: { result in
                    Task { await viewModel.onTapToSelectDone(result) }
                },
                onCancel: viewModel.onTapToSelectCancelled,
                onRefineWithBrush: viewModel.onTapToSelectRequestTouchup
            )
        } else {
            Color.clear
                .onAppear { viewModel.onTapToSelectCancelled() }
        }
    }

    // MARK: - Multi-pick fullscreen cover (Phase 5)

    @ViewBuilder
    private var multiPickCover: some View {
        if let proposals = viewModel.proposals {
            // 2-column grid of detected garments — each card shows ONE
            // proposal cleanly on a neutral surface. Replaces the old
            // overlay-on-photo design (`MultiGarmentTapToSelectView`)
            // which became unreadable when items overlapped on the body.
            MultiGarmentGridView(
                proposals: proposals,
                selectedIDs: Binding(
                    get: { viewModel.selectedProposalIDs },
                    set: { viewModel.selectedProposalIDs = $0 }
                ),
                onConfirmed: { viewModel.onMultiPickConfirmed() },
                onUseFullPhoto: { viewModel.onMultiPickUseFullPhoto() },
                onCancel: { viewModel.onMultiPickCancelled() }
            )
        } else {
            // Defensive fallback — the cover shouldn't open without
            // proposals, but closing it rather than showing a blank
            // screen recovers gracefully if state ever diverges.
            Color.clear
                .onAppear { viewModel.onMultiPickCancelled() }
        }
    }

    // MARK: - Cancellation Toast

    private var cancellationToast: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(Theme.Colors.primary))
            Text("Cancelled")
                .font(Theme.Fonts.bodySmall.weight(.medium))
                .foregroundStyle(Color(Theme.Colors.textPrimary))
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            Capsule()
                .fill(Color(Theme.Colors.surface))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 2)
        )
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(AddItemViewModel.Step.allCases, id: \.rawValue) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(step.rawValue <= viewModel.currentStep.rawValue
                          ? Color(Theme.Colors.primary)
                          : Color(Theme.Colors.muted))
                    .frame(height: 3)
            }
        }
    }

    // MARK: - Step 1: Photo Selection

    private var photoStep: some View {
        VStack(spacing: Theme.Spacing.lg) {
            VStack(spacing: Theme.Spacing.sm) {
                Text("Add a photo")
                    .font(Theme.Fonts.h2)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                Text("Photograph your item against a clean background, or choose from your library.")
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.center)
            }

            Button {
                viewModel.beginCameraCapture()
            } label: {
                SourceOptionLabel(
                    systemImage: "camera.fill",
                    title: "Take Photo",
                    subtitle: "Live background check + smart crop",
                    isPrimary: true
                )
            }
            .accessibilityLabel("Take a new photo")

            PhotosPicker(
                selection: $viewModel.selectedPhoto,
                matching: .images,
                photoLibrary: .shared()
            ) {
                SourceOptionLabel(
                    systemImage: "photo.on.rectangle",
                    title: "Choose from Library",
                    subtitle: "Pick an existing photo",
                    isPrimary: false
                )
            }

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
        }
    }

    // MARK: - Step 3: Details

    private var detailsStep: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Image preview with extracted colors
            if let image = viewModel.selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 250)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            }

            // Extracted colors
            if !viewModel.extractedColors.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Extracted Colors")
                        .font(Theme.Fonts.h3)
                        .foregroundStyle(Color(Theme.Colors.textPrimary))
                    ColorSwatchView(colors: viewModel.extractedColors, size: 28, showPercentage: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Shared form body. Same fields the Edit screen renders — the
            // only Add-specific wiring is the sparkle badge, which lights
            // up for sections the attribute classifier pre-filled while
            // the live value still matches the snapshot.
            ItemFormView(
                category: $viewModel.category,
                subcategory: $viewModel.subcategory,
                texture: $viewModel.texture,
                fitAttribute: $viewModel.fitAttribute,
                selectedSeasons: $viewModel.selectedSeasons,
                selectedOccasions: $viewModel.selectedOccasions,
                availableSubcategories: viewModel.availableSubcategories,
                onCategoryChanged: viewModel.onCategoryChanged,
                isSectionAutoDetected: { section in
                    switch section {
                    case .category:
                        return isAutoDetected("category", matching: viewModel.category.rawValue)
                            || isAutoDetected("subcategory", matching: viewModel.subcategory.rawValue)
                    case .texture:
                        return isAutoDetected("texture", matching: viewModel.texture?.rawValue)
                    case .fit:
                        return isAutoDetected("fit", matching: viewModel.fitAttribute?.rawValue)
                    case .seasons:
                        return isAutoDetected(
                            "seasons",
                            matchingSortedJoined: viewModel.selectedSeasons.map { $0.rawValue }
                        )
                    case .occasions:
                        return isAutoDetected(
                            "occasions",
                            matchingSortedJoined: viewModel.selectedOccasions.map { $0.rawValue }
                        )
                    }
                }
            )

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            // Multi-garment loop affordances. The "Save & add another"
            // button loops back into tap-to-select on the same capture
            // instead of dismissing the sheet, and the small pill above
            // tells the user how many garments have landed from this
            // photo so they know they're in a repeat flow.
            saveActions
                .padding(.top, Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xl)
        }
    }

    // MARK: - Save action buttons

    /// Primary + optional secondary save buttons plus the "Garment N
    /// saved from this photo" pill. The secondary button ("Save & add
    /// another garment") is only rendered when we have a live capture
    /// AND SAM2 is available — without SAM2 the next tap-to-select
    /// pass would fail, so we hide the affordance rather than producing
    /// a dead button.
    @ViewBuilder
    private var saveActions: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if viewModel.savedItemsFromSource > 0 {
                savedFromSourceBadge
            }
            GoldButton("Save to Wardrobe", isLoading: viewModel.isSaving) {
                guard let userId = appState.currentUser?.id else {
                    viewModel.errorMessage = "Not signed in. Please restart the app and try again."
                    return
                }
                Task { await viewModel.save(userId: userId) }
            }
            .disabled(!viewModel.canSave)

            if canShowAddAnother {
                Button {
                    guard let userId = appState.currentUser?.id else {
                        viewModel.errorMessage = "Not signed in. Please restart the app and try again."
                        return
                    }
                    Task { await viewModel.onSaveAndAddAnother(userId: userId) }
                } label: {
                    Label("Save & add another garment", systemImage: "square.stack.3d.up")
                        .font(Theme.Fonts.bodySmall.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.sm)
                }
                .buttonStyle(.bordered)
                .tint(Color(Theme.Colors.primary))
                .disabled(!viewModel.canSave)
                .accessibilityHint("Saves this garment and re-opens tap-to-select on the same photo for the next garment.")
            }
        }
    }

    /// Whether the secondary "Save & add another garment" button is
    /// rendered. Hidden when no capture has started yet OR when SAM2 is
    /// unavailable — in that second case tap-to-select wouldn't work,
    /// and the user shouldn't be offered a dead loop. Also hidden during
    /// a multi-pick batch (queue-driven progression owns the loop
    /// semantics; stacking the two affordances would confuse users).
    private var canShowAddAnother: Bool {
        viewModel.selectedImage != nil
            && viewModel.sam2Session != nil
            && viewModel.currentProposal == nil
    }

    /// Small pill above the save buttons that surfaces how many garment
    /// rows have been saved from the current capture so far. Only shows
    /// during the multi-garment loop (savedItemsFromSource >= 1);
    /// single-item flows never see it.
    private var savedFromSourceBadge: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(Theme.Colors.primary))
            Text(savedFromSourceLabel)
                .font(Theme.Fonts.caption.weight(.medium))
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            Capsule().fill(Color(Theme.Colors.surface))
        )
        .overlay(
            Capsule().stroke(Color(Theme.Colors.border), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var savedFromSourceLabel: String {
        let count = viewModel.savedItemsFromSource
        let noun = count == 1 ? "garment" : "garments"
        return "\(count) \(noun) saved from this photo"
    }

    // MARK: - Step 4: Saving

    private var savingStep: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ProgressView()
                .tint(Color(Theme.Colors.primary))
                .scaleEffect(1.2)
            Text("Saving to your wardrobe...")
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Auto-detected indicator (Phase 8)
    //
    // Snapshot comparison for fields the attribute classifier pre-filled.
    // The live `ItemFormView` lights up a sparkle badge via its
    // `isSectionAutoDetected` hook only while the form value still
    // matches the snapshot — any user edit drops the match and the badge
    // vanishes. No explicit toggle state needed; SwiftUI re-derives the
    // check on every render.

    /// Scalar-field match: category, subcategory, texture, fit.
    private func isAutoDetected(_ field: String, matching currentValue: String?) -> Bool {
        guard let snap = viewModel.detectedAttributes[field], let currentValue else {
            return false
        }
        return snap == currentValue
    }

    /// Multi-select match. The snapshot joins rawValues sorted + comma-
    /// delimited, so we rebuild the same string from the live set.
    private func isAutoDetected(_ field: String, matchingSortedJoined values: [String]) -> Bool {
        guard let snap = viewModel.detectedAttributes[field] else { return false }
        return snap == values.sorted().joined(separator: ",")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.circle")
            Text(message)
                .font(Theme.Fonts.bodySmall)
        }
        .foregroundStyle(Color(Theme.Colors.destructive))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Color(Theme.Colors.destructive).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

// MARK: - Source Option Label
//
// Extracted into its own View so it can be used inside the PhotosPicker
// label closure, which Swift 6 requires to be Sendable / non-isolated.
// Instance methods on `AddItemView` can't return `some View` into that
// context, but a standalone View struct can.

private struct SourceOptionLabel: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let isPrimary: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isPrimary ? .white : Color(Theme.Colors.primary))
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(isPrimary
                              ? Color(Theme.Colors.primary)
                              : Color(Theme.Colors.primary).opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                Text(subtitle)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(Color(Theme.Colors.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Color(Theme.Colors.border), lineWidth: 1)
        )
    }
}

#Preview {
    AddItemView()
        .environment(AppState())
}
