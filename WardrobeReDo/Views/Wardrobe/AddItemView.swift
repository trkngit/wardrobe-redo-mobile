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
                        case .photo:
                            photoStep
                        case .analysis:
                            analysisStep
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
            }
            .onChange(of: viewModel.selectedPhoto) {
                Task { await viewModel.onPhotoSelected() }
            }
            .onChange(of: viewModel.didSave) {
                if viewModel.didSave { dismiss() }
            }
        }
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
                Text("Choose a photo")
                    .font(Theme.Fonts.h2)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                Text("Photograph your item against a clean background for best color extraction.")
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.center)
            }

            PhotosPicker(
                selection: $viewModel.selectedPhoto,
                matching: .images,
                photoLibrary: .shared()
            ) {
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "camera")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color(Theme.Colors.primary))
                    Text("Select Photo")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(Theme.Colors.primary))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(Color(Theme.Colors.surface))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .stroke(Color(Theme.Colors.border), style: StrokeStyle(lineWidth: 1, dash: [8]))
                )
            }

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
        }
    }

    // MARK: - Step 2: Analysis (Loading)

    private var analysisStep: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if let image = viewModel.selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            }

            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                    .tint(Color(Theme.Colors.primary))
                    .scaleEffect(1.2)
                Text("Analyzing colors...")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
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

            // Category + Subcategory
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Category")
                    .font(Theme.Fonts.h3)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                Picker("Category", selection: $viewModel.category) {
                    ForEach(ClothingCategory.allCases, id: \.self) { cat in
                        Text(cat.displayName).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.category) {
                    viewModel.onCategoryChanged()
                }

                Picker("Subcategory", selection: $viewModel.subcategory) {
                    ForEach(viewModel.availableSubcategories, id: \.self) { sub in
                        Text(sub.displayName).tag(sub)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color(Theme.Colors.primary))
            }

            // Texture
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Texture")
                    .font(Theme.Fonts.h3)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: Theme.Spacing.sm) {
                    ForEach(TextureType.allCases, id: \.self) { tex in
                        chipButton(
                            tex.displayName,
                            isSelected: viewModel.texture == tex
                        ) {
                            viewModel.texture = viewModel.texture == tex ? nil : tex
                        }
                    }
                }
            }

            // Fit
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Fit")
                    .font(Theme.Fonts.h3)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(FitAttribute.allCases, id: \.self) { fit in
                        chipButton(
                            fit.displayName,
                            isSelected: viewModel.fitAttribute == fit
                        ) {
                            viewModel.fitAttribute = viewModel.fitAttribute == fit ? nil : fit
                        }
                    }
                }
            }

            // Seasons
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Seasons")
                    .font(Theme.Fonts.h3)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(Season.allCases, id: \.self) { season in
                        chipButton(
                            season.displayName,
                            isSelected: viewModel.selectedSeasons.contains(season)
                        ) {
                            if viewModel.selectedSeasons.contains(season) {
                                viewModel.selectedSeasons.remove(season)
                            } else {
                                viewModel.selectedSeasons.insert(season)
                            }
                        }
                    }
                }
            }

            // Occasions
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Occasions")
                    .font(Theme.Fonts.h3)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: Theme.Spacing.sm) {
                    ForEach(Occasion.allCases, id: \.self) { occasion in
                        chipButton(
                            occasion.displayName,
                            isSelected: viewModel.selectedOccasions.contains(occasion)
                        ) {
                            if viewModel.selectedOccasions.contains(occasion) {
                                viewModel.selectedOccasions.remove(occasion)
                            } else {
                                viewModel.selectedOccasions.insert(occasion)
                            }
                        }
                    }
                }
            }

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            // Save button
            GoldButton("Save to Wardrobe", isLoading: viewModel.isSaving) {
                guard let userId = appState.currentUser?.id else { return }
                Task { await viewModel.save(userId: userId) }
            }
            .disabled(!viewModel.canSave)
            .padding(.top, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.xl)
        }
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

    // MARK: - Helpers

    private func chipButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.caption)
                .foregroundStyle(isSelected ? .white : Color(Theme.Colors.textPrimary))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(isSelected ? Color(Theme.Colors.primary) : Color(Theme.Colors.surface))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .stroke(isSelected ? Color.clear : Color(Theme.Colors.border), lineWidth: 1)
                )
        }
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

#Preview {
    AddItemView()
        .environment(AppState())
}
