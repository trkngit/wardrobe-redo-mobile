import SwiftUI
import UIKit

/// Multi-garment proposal picker — **grid layout** + Build 52 approval gallery.
///
/// Replaces the earlier overlay-on-photo design (`MultiGarmentTapToSelectView`)
/// which stacked translucent tinted cutouts on top of the source photo and
/// became unreadable as soon as detected items overlapped on the body
/// (e.g. a suit + dress shirt + tie all sharing the torso region rendered
/// as a chaotic heatmap).
///
/// Grid layout rules:
/// - Two columns of square cards. Each card shows ONE proposal's
///   composited cutout (`maskedImage`) on a neutral background — the
///   user sees each detected garment individually instead of guessing
///   which colored blob is which.
/// - Cards scroll vertically — no overflow sheet, no "+N more" affordance.
/// - Tapping a card's image toggles selection (checkmark + tinted border).
///   Each card carries a compact **category menu** so a wrong best-guess is
///   corrected in one tap without leaving the gallery.
///
/// Build 52 — approval gallery: a single shared **Occasion** control sits
/// above the grid (the whole batch inherits it), and the bottom bar's
/// "Save N items" button commits every selected item in ONE pass via the
/// view model's Save-all loop — no per-item form. Per-card category
/// corrections and the shared occasion are applied to each item as it saves.
struct MultiGarmentGridView: View {
    let proposals: [MaskProposal]
    @Binding var selectedIDs: Set<MaskProposal.ID>

    /// Build 52 — per-card category corrections, keyed by proposal id.
    /// `MaskProposal` is immutable, so a card's 1-tap fix is recorded here
    /// and applied to that item when the batch saves.
    @Binding var categoryOverrides: [MaskProposal.ID: ClothingCategory]

    /// Build 52 — the single occasion the whole batch inherits (single-
    /// select: a tap replaces the set).
    @Binding var sharedOccasions: Set<Occasion>

    /// Commit every selected item in one pass. Async because it drives the
    /// view model's sequential save loop; the caller wraps it in a `Task`.
    var onSaveAll: () async -> Void
    var onUseFullPhoto: () -> Void
    var onCancel: () -> Void

    /// Two flexible columns. The grid stretches square cards to fill
    /// each column equally on every screen size — no per-device math.
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: Theme.Spacing.md),
        GridItem(.flexible(), spacing: Theme.Spacing.md),
    ]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color(Theme.Colors.background).ignoresSafeArea()

                VStack(spacing: 0) {
                    if shouldShowLayeredLookHint {
                        layeredLookHint
                    }
                    occasionHeader
                    grid
                    bottomBar
                }
            }
            .navigationTitle("Pick items to save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use full photo", action: onUseFullPhoto)
                }
            }
        }
    }

    // MARK: - Derived state (exposed for tests)

    /// Proposals laid out in detection-score order, descending. The grid
    /// surfaces the highest-confidence garments first so a user who
    /// only wants the obvious items can grab them in the first row.
    var sortedProposals: [MaskProposal] {
        proposals.sorted { $0.detectionScore > $1.detectionScore }
    }

    var selectionSummary: String {
        "\(selectedIDs.count) of \(proposals.count) selected"
    }

    /// Pluralized CTA text. "Save 1 item" vs "Save 3 items".
    ///
    /// Build 27 — return type changed to `LocalizedStringResource`
    /// after the PrimaryButton signature update. Catalog provides the
    /// translated singular + plural variants; the count slots into
    /// the format specifier.
    var confirmButtonTitle: LocalizedStringResource {
        let n = selectedIDs.count
        return n == 1
            ? LocalizedStringResource("Save 1 item")
            : LocalizedStringResource("Save \(n) items")
    }

    /// Heuristic for the layered-look help tip. The model often fuses a
    /// t-shirt + open overshirt into a single `.top` proposal because the
    /// pieces visually overlap on the torso. When at least one detected
    /// `.top` covers more than 30% of the frame we flag it as a likely
    /// layered look and surface a tip suggesting the user re-shoot each
    /// piece separately. A solitary, well-cropped t-shirt rarely crosses
    /// the threshold so the hint stays out of the way for the common
    /// single-piece case.
    var shouldShowLayeredLookHint: Bool {
        proposals.contains { proposal in
            proposal.predictedCategory == .top
                && proposal.boundingBox.area > Self.layeredLookAreaThreshold
        }
    }

    /// Threshold (normalized image area in [0, 1]) above which a `.top`
    /// proposal is considered large enough to suggest a layered look.
    /// Pulled out so the test suite can pin the exact boundary value.
    static let layeredLookAreaThreshold: CGFloat = 0.30

    // MARK: - Layered-look hint

    /// Inline help tip shown above the grid when the detector likely
    /// merged a t-shirt + overshirt (or any layered top) into a single
    /// proposal. We can't fix the segmentation post-hoc, so we nudge the
    /// user to re-shoot each piece separately for a cleaner result.
    private var layeredLookHint: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color(Theme.Colors.primary))
            Text("Wearing layers? Take a separate photo of each piece for the cleanest results.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Color(Theme.Colors.primary).opacity(0.08))
        )
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MultiGarmentGrid.LayeredLookHint")
    }

    // MARK: - Shared occasion (Build 52)

    /// One occasion control above the grid — the whole batch inherits it.
    /// Single-select (tap replaces the set), mirroring the Fast Confirm
    /// card's occasion quick-pick. Per-item occasion edits remain available
    /// in the full Edit screen after saving.
    private var occasionHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("When will you wear these?")
                .font(Theme.Fonts.h3)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
            FlowLayout(spacing: Theme.Spacing.sm) {
                ForEach(Occasion.allCases, id: \.self) { occasion in
                    Chip(occasion.localizedName, isSelected: sharedOccasions.contains(occasion)) {
                        sharedOccasions = [occasion]
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
        .accessibilityIdentifier("MultiGarmentGrid.OccasionHeader")
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                ForEach(sortedProposals) { proposal in
                    GridCard(
                        proposal: proposal,
                        isSelected: selectedIDs.contains(proposal.id),
                        categoryOverride: categoryOverrides[proposal.id],
                        onTap: { toggleSelection(proposal.id) },
                        onCategoryChange: { categoryOverrides[proposal.id] = $0 }
                    )
                }
            }
            .padding(Theme.Spacing.md)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(selectionSummary)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .accessibilityIdentifier("MultiGarmentGrid.SelectionSummary")
            Spacer()
            PrimaryButton(confirmButtonTitle) {
                Task { await onSaveAll() }
            }
            .frame(maxWidth: 220)
            .opacity(selectedIDs.isEmpty ? 0.5 : 1)
            .allowsHitTesting(!selectedIDs.isEmpty)
            .accessibilityIdentifier("MultiGarmentGrid.ConfirmButton")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
        .background(.ultraThinMaterial)
    }

    // MARK: - Logic helpers

    private func toggleSelection(_ id: MaskProposal.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

// MARK: - Grid card

private struct GridCard: View {
    let proposal: MaskProposal
    let isSelected: Bool
    /// Build 52 — the user's per-card category correction (nil = use the
    /// model's confident guess).
    let categoryOverride: ClothingCategory?
    let onTap: () -> Void
    let onCategoryChange: (ClothingCategory) -> Void

    /// The category the card displays + would save: a user correction wins
    /// over the model's confidence-gated guess.
    private var effectiveCategory: ClothingCategory? {
        categoryOverride ?? proposal.confidentCategory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Build 52 — selection toggle is the IMAGE (which carries the
            // checkmark badge); the category menu below is a SIBLING control,
            // so neither swallows the other's taps (the old whole-card Button
            // would have eaten the menu's tap). A plain Button keeps the
            // VoiceOver "selected/button" semantics.
            Button(action: onTap) {
                imageThumbnail
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(effectiveCategory?.displayName ?? "Item"), " +
                (isSelected ? "selected" : "not selected")
            )
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            label
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Color(Theme.Colors.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(
                    isSelected
                        ? Color(Theme.Colors.primary)
                        : Color(Theme.Colors.muted).opacity(0.3),
                    lineWidth: isSelected ? 2 : 1
                )
        )
    }

    private var imageThumbnail: some View {
        // The previous chain — `.scaledToFit()` then
        // `.aspectRatio(1, .fit)` — applied the square constraint AFTER
        // SwiftUI had already sized the image to its natural aspect
        // ratio, so cards rendered at different heights (a tall jeans
        // card next to a short shoe card on the same row).
        //
        // Wrapping a square `Color` placeholder via `.aspectRatio(1)`
        // FIRST forces a uniform square frame; the masked cutout then
        // renders inside via overlay + scaledToFit + padding so the
        // image is always centered, never cropped, and every card in
        // the grid has the same dimensions regardless of cutout
        // aspect ratio.
        Color(Theme.Colors.background)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                Image(uiImage: proposal.maskedImage)
                    .resizable()
                    .scaledToFit()
                    .padding(Theme.Spacing.sm)
            )
            .overlay(alignment: .topTrailing) {
                checkmarkBadge
                    .padding(Theme.Spacing.xs)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card - 4))
    }

    private var checkmarkBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(
                isSelected
                    ? Color(Theme.Colors.primary)
                    : Color.white.opacity(0.85)
            )
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 28, height: 28)
            )
    }

    private var label: some View {
        HStack(spacing: 4) {
            categoryMenu
            Spacer(minLength: 0)
            Text("\(Int(proposal.detectionScore * 100))%")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .monospacedDigit()
        }
    }

    /// Build 52 — compact 1-tap category correction. Tapping opens a menu of
    /// the six categories; the choice writes a per-proposal override that the
    /// batch save applies. A menu (vs a 6-chip row) keeps the 2-column grid
    /// scannable and gives the cutout room.
    private var categoryMenu: some View {
        Menu {
            ForEach(ClothingCategory.allCases, id: \.self) { cat in
                Button {
                    onCategoryChange(cat)
                } label: {
                    if effectiveCategory == cat {
                        Label(cat.localizedName, systemImage: "checkmark")
                    } else {
                        Text(cat.localizedName)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(effectiveCategory?.localizedName ?? LocalizedStringResource("Item"))
                    .font(Theme.Fonts.bodySmall.weight(.medium))
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }
        }
        .accessibilityLabel("Category: \(effectiveCategory?.displayName ?? "not set")")
        .accessibilityHint("Double-tap to change the category for this item")
    }
}

#if DEBUG
#Preview("3 proposals") {
    MultiGarmentGridViewPreviewHost(proposalCount: 3)
}

#Preview("5 proposals") {
    MultiGarmentGridViewPreviewHost(proposalCount: 5)
}

#Preview("8 proposals (scrolls)") {
    MultiGarmentGridViewPreviewHost(proposalCount: 8)
}

private struct MultiGarmentGridViewPreviewHost: View {
    let proposalCount: Int
    @State private var selectedIDs: Set<UUID> = []
    @State private var categoryOverrides: [UUID: ClothingCategory] = [:]
    @State private var sharedOccasions: Set<Occasion> = [.casual]

    private var proposals: [MaskProposal] {
        (0..<proposalCount).map { makePreviewProposal(index: $0) }
    }

    private func makePreviewProposal(index i: Int) -> MaskProposal {
        let categories: [ClothingCategory] = [.outerwear, .top, .bottom, .shoe, .accessory, .dress, .top, .accessory]
        let bbox = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        return MaskProposal(
            id: UUID(),
            maskedImage: UIImage(systemName: "tshirt.fill") ?? UIImage(),
            mask: nil,
            confidence: .high,
            predictedCategory: categories[i % categories.count],
            boundingBox: bbox,
            detectionScore: Float(0.95 - Double(i) * 0.05),
            modelClassRaw: "class_\(i)"
        )
    }

    var body: some View {
        MultiGarmentGridView(
            proposals: proposals,
            selectedIDs: $selectedIDs,
            categoryOverrides: $categoryOverrides,
            sharedOccasions: $sharedOccasions,
            onSaveAll: {},
            onUseFullPhoto: {},
            onCancel: {}
        )
        .onAppear {
            selectedIDs = Set(proposals.map(\.id))
        }
    }
}
#endif
