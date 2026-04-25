import SwiftUI
import UIKit

/// Multi-garment proposal picker — **grid layout**.
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
/// - The card's whole surface is the tap target. A checkmark + tinted
///   border indicate selection. Category label sits below the image.
///
/// Interaction rules (unchanged from the old view, so the ViewModel
/// surface stays identical):
/// - All proposals start selected.
/// - "Use full photo" remains the escape hatch back to the single-item
///   flow.
/// - "Save N items" confirms the selection and pops the queue.
struct MultiGarmentGridView: View {
    let proposals: [MaskProposal]
    @Binding var selectedIDs: Set<MaskProposal.ID>

    var onConfirmed: () -> Void
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
    var confirmButtonTitle: String {
        let n = selectedIDs.count
        return n == 1 ? "Save 1 item" : "Save \(n) items"
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                ForEach(sortedProposals) { proposal in
                    GridCard(
                        proposal: proposal,
                        isSelected: selectedIDs.contains(proposal.id),
                        onTap: { toggleSelection(proposal.id) }
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
            GoldButton(confirmButtonTitle) {
                onConfirmed()
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
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                imageThumbnail
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
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(proposal.predictedCategory?.displayName ?? "Item"), " +
            (isSelected ? "selected" : "not selected")
        )
        .accessibilityAddTraits(.isButton)
    }

    private var imageThumbnail: some View {
        ZStack(alignment: .topTrailing) {
            // Square image area. The proposal's masked cutout has
            // transparency outside the garment so it renders cleanly
            // on the surface color — no tint, no opacity tricks.
            Image(uiImage: proposal.maskedImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card - 4))

            // Selection indicator overlaid in the corner.
            checkmarkBadge
                .padding(Theme.Spacing.xs)
        }
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
            Text(proposal.predictedCategory?.displayName ?? "Item")
                .font(Theme.Fonts.bodySmall.weight(.medium))
                .foregroundStyle(Color(Theme.Colors.textPrimary))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(Int(proposal.detectionScore * 100))%")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .monospacedDigit()
        }
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
            onConfirmed: {},
            onUseFullPhoto: {},
            onCancel: {}
        )
        .onAppear {
            selectedIDs = Set(proposals.map(\.id))
        }
    }
}
#endif
