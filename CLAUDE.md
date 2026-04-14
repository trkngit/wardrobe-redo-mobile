# Wardrobe Re-Do

iOS-native wardrobe decision engine — generates daily styled outfit suggestions from uploaded clothing using a 7-dimension style engine grounded in professional fashion theory.

## Config Inheritance
@~/.claude/configs/types/mobile/conventions.md
@~/.claude/configs/types/mobile/stacks/swiftui-supabase/conventions.md

## Stack
- Frontend: SwiftUI (iOS 17+, @Observable)
- Backend: Supabase (PostgreSQL, Auth, Storage, Edge Functions)
- Image Analysis: CoreImage + Vision (on-device)
- Image Loading: Kingfisher
- Local Cache: SwiftData
- Dependencies: Swift Package Manager

## Commands
- Dev: Open `WardrobeReDo.xcodeproj` in Xcode, Cmd+R
- Build: `xcodebuild -scheme WardrobeReDo -sdk iphonesimulator build`
- Test: `xcodebuild test -scheme WardrobeReDo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`

## Architecture
MVVM + Repository + Service

```
View (SwiftUI) → ViewModel (@Observable) → Service → Repository → Supabase / SwiftData
```

- ViewModels own UI state, call Services
- Services encapsulate domain logic (style engine, image processing)
- Repositories handle data access (Supabase PostgREST, Storage, local cache)

## Key Directories
| Directory | Purpose |
|-----------|---------|
| `WardrobeReDo/App/` | Entry point, AppState, ContentView |
| `WardrobeReDo/Config/` | Constants (Supabase config), Theme (design tokens) |
| `WardrobeReDo/Models/` | Codable structs, enums |
| `WardrobeReDo/Services/StyleEngine/` | 7 scoring dimensions + OutfitGenerator |
| `WardrobeReDo/Repositories/` | Supabase data access layer |
| `WardrobeReDo/Views/` | SwiftUI views by feature domain |
| `supabase/migrations/` | Database schema migrations |
| `supabase/functions/` | Edge Functions (outfit generation) |

## Style Engine — 7 Scoring Dimensions
1. Proportion Balance (0.15) — silhouette pairing
2. Color Harmony (0.25) — 3-color max, 60-30-10, value contrast
3. Texture Mix (0.10) — 2-3 textures, visual weight balance
4. Formality Coherence (0.15) — multi-dimensional formality
5. Outfit Formula (0.15) — hero piece, 2-of-3 matching, third piece rule
6. Versatility (0.10) — item frequency, novel combinations
7. Occasion Context (0.10) — season, occasion, weather

## Data Model (Supabase Tables)
- `profiles` — user profile (extends auth.users)
- `wardrobe_items` — clothing with colors, texture, fit, formality
- `style_archetypes` — 50 archetypes across 8 families (seed data)
- `style_rules` — 200+ outfit combination rules (seed data)
- `outfits` — generated outfits with score breakdowns
- `outfit_slots` — item-to-outfit assignment
- `item_style_tags` — auto/user-applied style tags

## Secrets
- Supabase URL and anon key: stored in `Secrets.plist` (gitignored)
- Never hardcode credentials in Swift files
