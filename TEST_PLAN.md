# Wardrobe Re-Do — Code-Level UI/Logic Audit

## Method
For each screen: read the view + viewmodel code, trace every button action and data flow,
verify correctness. No simulator — pure code inspection.

---

## 1. Auth Flow

### 1A. LoginView + AuthViewModel
- [ ] `signIn()` — calls AuthService, error mapping, loading state
- [ ] `signUp()` — calls AuthService, validation gates (canSignIn/canSignUp)
- [ ] `toggleMode()` — switches sign-in ↔ sign-up form
- [ ] Validation computed props: emailValidationMessage, passwordValidationMessage, confirmPasswordMessage
- [ ] Error banner renders when errorMessage is set

### 1B. ContentView auth gate
- [ ] Shows LoginView when not authenticated
- [ ] Shows OnboardingView when onboardingCompleted == false
- [ ] Shows TabRootView when authenticated + onboarded

### 1C. AppState auth listener
- [ ] Auth state changes propagate to currentUser
- [ ] signOut() clears state

---

## 2. Onboarding Flow

### 2A. OnboardingView
- [ ] 4-step TabView paging (Welcome, Preferences, Upload, Done)
- [ ] Back/Next buttons increment/decrement step correctly
- [ ] Family chip toggle (add/remove from selectedFamilies)
- [ ] Occasion chip toggle (add/remove from selectedOccasions)
- [ ] "Get Started" calls completeOnboarding()
- [ ] completeOnboarding() saves preferences + marks onboarding complete + refreshes profile

---

## 3. Wardrobe Tab

### 3A. WardrobeGridView
- [ ] .task loads items + thumbnails on appear
- [ ] Category filter chips call selectCategory() correctly
- [ ] "+" toolbar button sets showAddItem = true
- [ ] "Add First Item" (empty state) sets showAddItem = true
- [ ] Sheet presents AddItemView with appState environment
- [ ] onChange(showAddItem) reloads when sheet dismissed
- [ ] NavigationLink pushes ItemDetailView for item UUID
- [ ] Pull-to-refresh reloads items
- [ ] Loading state shows WardrobeGridShimmer
- [ ] Empty state shows when isEmpty && items.isEmpty

### 3B. AddItemView + AddItemViewModel
- [ ] PhotosPicker binds to selectedPhoto
- [ ] onChange(selectedPhoto) calls onPhotoSelected()
- [ ] onPhotoSelected() loads image, processes, transitions to .details step
- [ ] Category picker onChange calls onCategoryChanged()
- [ ] Subcategory picker updates correctly
- [ ] Texture/Fit chip toggles work (nil ↔ value)
- [ ] Season chip toggles add/remove from set
- [ ] Occasion chip toggles add/remove from set
- [ ] "Save to Wardrobe" calls save(userId:)
- [ ] save() uploads images, then inserts NewWardrobeItem
- [ ] canSave checks processedImage != nil
- [ ] didSave triggers dismiss via onChange
- [ ] "Cancel" button calls dismiss()
- [ ] Error banner shows errorMessage
- [ ] Step indicator shows correct progress

### 3C. ItemDetailView
- [ ] .task loads signed image URL
- [ ] Archive button calls repo.archiveItem + dismiss
- [ ] Delete confirmation dialog shows
- [ ] Delete action calls deleteImages + deleteItem + dismiss
- [ ] Color swatches render from item.dominantColors
- [ ] Metadata (category, texture, fit, seasons, occasions) displays

### 3D. ItemCardView
- [ ] KFImage loads from thumbnailURL
- [ ] Color dots render
- [ ] Category label shows

---

## 4. Outfits Tab

### 4A. DailyOutfitsView + OutfitViewModel
- [ ] .task loads outfits for today
- [ ] Loading state shows OutfitCardShimmer
- [ ] Empty state shows with occasion picker + generate button
- [ ] "Generate Today's Outfits" calls generateDailyOutfits()
- [ ] generateDailyOutfits() fetches wardrobe + recent IDs, generates, saves, reloads
- [ ] Generating state shows progress spinner
- [ ] Paged TabView renders outfit cards
- [ ] NavigationLink pushes OutfitDetailView
- [ ] Occasion picker buttons update selectedOccasion
- [ ] Date header shows correct day/date
- [ ] Pull-to-refresh reloads outfits
- [ ] Widget data updates after loading outfits

### 4B. OutfitCardView
- [ ] Editorial name renders in serif font
- [ ] Score badge displays
- [ ] Item thumbnail strip renders with KFImage
- [ ] Role labels show (hero/supporting/completing)
- [ ] Reaction indicator shows if reaction set
- [ ] Worn indicator shows if isWorn

### 4C. OutfitDetailView
- [ ] Score breakdown shows 7 dimension bars
- [ ] Item gallery renders in adaptive grid
- [ ] Reaction buttons (love/like/skip) call react()
- [ ] react() toggles reaction (same reaction clears it)
- [ ] Haptic feedback fires on reaction tap
- [ ] "Mark as Worn" button calls toggleWorn()
- [ ] toggleWorn() flips isWorn state

---

## 5. Matching Tab

### 5A. MatchingView + MatchingViewModel
- [ ] .task loads wardrobe items + thumbnails
- [ ] Category filter chips filter hero picker
- [ ] Tapping hero item calls selectItem() which auto-triggers findMatches()
- [ ] findMatches() calls generationService.matchOutfits() with hero anchor
- [ ] Results render as MatchResultCard list
- [ ] Occasion selector re-triggers matching via changeOccasion()
- [ ] Empty wardrobe state shows
- [ ] No results state shows
- [ ] Loading/matching states show correctly

### 5B. MatchResultCard
- [ ] Editorial name + archetype label render
- [ ] Score badge shows
- [ ] Item thumbnails render with hero border
- [ ] Save button calls onSave closure
- [ ] saveAsOutfit() persists and tracks saved indices
- [ ] Saved state shows checkmark

---

## 6. Profile Tab

### 6A. ProfileView
- [ ] User info section shows name + tier
- [ ] Stats section loads from repositories (totalItems, outfitsGenerated, itemsWorn, mostWorn)
- [ ] Cache section shows disk size
- [ ] Clear cache button calls ImageCacheService.clearCache()
- [ ] Notification toggle calls NotificationService.toggle()
- [ ] "Edit Preferences" opens StylePreferencesEditor sheet
- [ ] Version row shows bundle version
- [ ] Sign out calls appState.signOut()

### 6B. StylePreferencesEditor
- [ ] Loads existing preferences on appear
- [ ] Family chips toggle correctly
- [ ] Occasion chips toggle correctly
- [ ] "Save" calls userRepository.updateStylePreferences + refreshProfile + dismiss
- [ ] "Cancel" calls dismiss

---

## 7. Services & Cross-Cutting

### 7A. ImageService
- [ ] loadImage(from:) handles PhotosPickerItem
- [ ] processImage() extracts colors, creates resized original + thumbnail
- [ ] upload() uploads both images to correct Storage paths
- [ ] signedURL() creates valid temporary URL
- [ ] deleteImages() removes both files

### 7B. ImageCacheService
- [ ] configure() sets memory + disk limits
- [ ] UIScreen.main.scale accessed safely on MainActor
- [ ] clearCache() clears both memory + disk
- [ ] formattedDiskCacheSize() returns "X.X MB" string

### 7C. HapticManager
- [ ] All methods are @MainActor (Swift 6 safe)
- [ ] Called from correct contexts (views are @MainActor)

### 7D. WidgetDataService
- [ ] updateWidget() writes to App Group UserDefaults
- [ ] clearWidget() removes data

### 7E. NotificationService
- [ ] requestPermission() handles UNUserNotificationCenter
- [ ] scheduleDailyReminder() sets repeating trigger
- [ ] toggle() handles permission + scheduling

---

## 8. Theme & Components

### 8A. Color assets
- [ ] All named colors resolve (no namespace prefix issue)
- [ ] Light + dark variants defined

### 8B. Fonts
- [ ] Cormorant Garamond font files present in Resources/Fonts
- [ ] UIAppFonts entries match filenames
- [ ] Theme.Fonts references correct font names

### 8C. Reusable components
- [ ] GoldButton action fires, disabled state works
- [ ] GhostButton action fires
- [ ] EditorialTextField binds correctly
- [ ] ShimmerPlaceholders render (ItemCardShimmer, OutfitCardShimmer, WardrobeGridShimmer)
- [ ] AnimationModifiers compile (staggeredFadeIn, scalePopIn, shimmer)
