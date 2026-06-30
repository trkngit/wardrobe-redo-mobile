# Architecture

How the code is organized, how the layers fit together, and **where new code goes**. Pairs with [`README.md`](README.md) (the *why* + overview) and [`CONTRIBUTING.md`](CONTRIBUTING.md) (the dev loop + conventions).

## Layers

```
View (SwiftUI)  →  ViewModel (@Observable)  →  Service  →  Repository  →  Supabase / SwiftData
   UI only          UI state + intent          domain logic   data access     network / local cache
```

Dependencies point **down** only; nothing reaches up or skips a layer. Protocols sit at the layer boundaries (`…ServiceProtocol`, `…RepositoryProtocol`) so tests inject fakes.

| Layer | Owns | Does **not** | Lives in |
|---|---|---|---|
| **View** | Layout, presentation, user input | Business logic, networking | `WardrobeReDo/Views/` (grouped by feature) |
| **ViewModel** | UI state (`@Observable`, `@MainActor`), translating user intent into Service calls | Heavy compute, direct DB/network | `WardrobeReDo/ViewModels/` |
| **Service** | Pure-ish domain logic — the style engine, image/extraction pipeline, telemetry | UI, persistence details | `WardrobeReDo/Services/` |
| **Repository** | Data access — Supabase PostgREST + Storage | Domain rules | `WardrobeReDo/Repositories/` |
| **Model** | Value types (`struct`/`enum`), `Codable` DTOs | Behavior beyond derivation | `WardrobeReDo/Models/` |

## Where new code goes — decision guide

- **A new screen / UI surface?** → a `Views/<Feature>/` SwiftUI view + a `ViewModels/<Feature>ViewModel.swift`. Name the VM `<Feature>ViewModel`.
- **Domain logic (scoring, a rule, a transformation, an ML/extraction step)?** → a `Service`. **Convention:** a *single-file* service lives flat in `Services/` (e.g. `AuthService.swift`); a *multi-file module* gets a subfolder (`Services/Extraction/`, `Services/StyleEngine/`, `Services/Telemetry/`). Put a new outfit scorer in `Services/StyleEngine/`.
- **Reading/writing persisted data?** → a `Repository` method (`Repositories/`). **Repository = remote data access (Supabase)**; local-cache plumbing lives under `Services/Persistence/`. If you're talking to Postgres/Storage, it's a Repository.
- **A new persisted field / model?** → the `struct` in `Models/` (+ a `supabase/migrations/000NN_*.sql`), and the insert/update DTOs in `Repositories/WardrobeRepository.swift`. New enums go in `Models/Enums/`.
- **Config / tuning (a flag, a theme token, a threshold)?** → `Config/` — and **only** that: feature flags (`FeatureFlags.swift`), theme tokens (`Theme.swift`), pre-fill thresholds (`AttributePrefill.swift`). Service singletons (e.g. `SupabaseManager`) and ML diagnostics live under `Services/`, not `Config/`.
- **A small reusable helper (image downsampling, orientation, a timeout race)?** → `Utilities/`.
- **A shared interface used across layers?** → `Protocols/`.

## Worked example — "add a feature"

Adding *"mark an item as a favorite"* touches one file per layer, top to bottom:

1. **View** — a heart button in `Views/Wardrobe/...` calls `viewModel.toggleFavorite(item)`.
2. **ViewModel** — `WardrobeViewModel.toggleFavorite` flips optimistic UI state, then `await wardrobeRepository.updateItem(id:updates:)`.
3. **Repository** — `WardrobeRepository.updateItem` sends a `WardrobeItemUpdate` to Supabase.
4. **Model + migration** — add `isFavorite` to `WardrobeItem` + a `supabase/migrations/000NN_item_favorite.sql`.
5. **Test** — pair tests under `WardrobeReDoTests/ViewModels/` and `WardrobeReDoTests/Repositories/` (mirror the source path).

## Folder map

```
WardrobeReDo/
├── App/            Entry point, AppState, ContentView (auth/onboarding gate)
├── Config/         Flags, theme tokens, pre-fill thresholds — configuration ONLY
├── Models/         Codable structs (top level) + Enums/
├── ViewModels/     @Observable, @MainActor UI state
├── Views/          SwiftUI, grouped by feature (Auth/ Camera/ Outfits/ Wardrobe/ …) + Components/
├── Services/       Domain logic — flat single-file services + module subfolders:
│   ├── Extraction/   multi-garment detection, masks, attribute classifier
│   ├── StyleEngine/  the 7 scorers + OutfitGenerator
│   ├── Telemetry/    ML/occasion/vibe telemetry + Sentry
│   ├── Persistence/  local cache / upload queue
│   └── (flat)        AuthService, ImageService, ColorExtractionService, …
├── Repositories/   Remote data access (Supabase)
├── Utilities/      Image/processing helpers
├── Protocols/      Cross-layer interfaces
└── Extensions/     Swift/SwiftUI extensions
```

## Concurrency & data

- `@MainActor` on ViewModels and anything touching UI; Services are `Sendable` and run heavy work off-main, hopping back to publish.
- Models are value types (`struct`/`enum`) → `Sendable` for free, predictable copy semantics, easy to test.
- Server data: explicit `CodingKeys` (never `.convertFromSnakeCase` alongside them); `decodeIfPresent` + defaults for columns added by later migrations.

## ML pipeline (on-device, by design)

Clothing photos never leave the device for inference. `Services/Extraction/` runs multi-garment detection (RF-DETR-Seg, Core ML) → per-garment cutouts → the attribute classifier + `ColorExtractionService`. Graceful degradation is mandatory: a missing/failed model is a handled fallback (Vision → manual entry), never a crash. Full reference: [`docs/ENGINE.md`](docs/ENGINE.md).

## Testing

`WardrobeReDoTests/` **mirrors** the source tree (find the test next to where the code lives). Three plans in [`Tests/Plans/`](Tests/Plans/README.md): **Fast** (dev loop), **All** (default), **Integration** (CI). Flag-mutating suites are `@Suite(.serialized)` and use `FeatureFlagTestIsolation`. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the run loop.

## Repo & branch model

- **Single public repo**, built in the open. **`main` is the latest development line** (always newest, not an old snapshot). Released TestFlight builds are tagged; "build N" / "TF52" in commits refers to the rolling build number.
- New work lands via short-lived `feat/*` / `fix/*` / `chore/*` branches → squash-merged PRs. CI (`.github/workflows/ios-tests.yml`) runs the suite on every PR.
- The Xcode project is generated from [`project.yml`](project.yml) via **XcodeGen** — regenerate (`xcodegen generate`) after adding/removing source files; the project globs the source dirs.
