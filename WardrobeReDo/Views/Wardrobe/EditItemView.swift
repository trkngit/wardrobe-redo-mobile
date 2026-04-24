import SwiftUI
import Kingfisher

/// Screen for editing an existing wardrobe item's user-editable
/// attributes (category, subcategory, texture, fit, seasons, occasions).
///
/// Reuses `ItemFormView` for the form body so the Add and Edit surfaces
/// stay visually consistent. The only Edit-specific chrome is:
///   * A read-only hero image at the top (Kingfisher remote URL, unlike
///     Add's in-memory `UIImage`).
///   * Navigation toolbar with Cancel + Save buttons.
///   * An error banner pinned under the form.
///
/// Presentation is push-navigation from `ItemDetailView`'s toolbar —
/// not a modal sheet — because users typically arrive here from tapping
/// the item tile and the Back affordance is already in the expected
/// place.
struct EditItemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: EditItemViewModel
    @State private var imageURL: URL?

    private let imageService = ImageService()

    init(item: WardrobeItem) {
        _viewModel = State(initialValue: EditItemViewModel(item: item))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                heroImage

                ItemFormView(
                    category: $viewModel.category,
                    subcategory: $viewModel.subcategory,
                    texture: $viewModel.texture,
                    fitAttribute: $viewModel.fitAttribute,
                    selectedSeasons: $viewModel.selectedSeasons,
                    selectedOccasions: $viewModel.selectedOccasions,
                    availableSubcategories: viewModel.availableSubcategories,
                    onCategoryChanged: viewModel.onCategoryChanged
                )

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Color(Theme.Colors.background))
        .navigationTitle("Edit Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(viewModel.isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .tint(Color(Theme.Colors.primary))
                    } else {
                        Text("Save")
                            .fontWeight(.semibold)
                    }
                }
                .disabled(viewModel.isSaving || !viewModel.hasChanges)
            }
        }
        .task {
            imageURL = try? await imageService.signedURL(for: viewModel.original.imagePath)
        }
    }

    // MARK: - Actions

    private func save() async {
        await viewModel.save()
        if viewModel.didSave {
            // The edit affects both the grid (category/sub/etc. all show
            // in the tile) and this screen's source-of-truth — post the
            // same `.wardrobeDidChange` that `ItemDetailView`'s archive
            // + delete paths post so the Wardrobe list refreshes.
            NotificationCenter.default.post(name: .wardrobeDidChange, object: nil)
            dismiss()
        }
    }

    // MARK: - Subviews

    private var heroImage: some View {
        KFImage(imageURL)
            .placeholder {
                Rectangle()
                    .fill(Color(Theme.Colors.muted).opacity(0.3))
                    .overlay {
                        ProgressView()
                            .tint(Color(Theme.Colors.primary))
                    }
            }
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .cardShadow()
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
