# Contributing

Conventions and the day-to-day loop. For *where* code goes and how the layers fit, read [`ARCHITECTURE.md`](ARCHITECTURE.md) first.

## Setup

1. macOS + Xcode 16.2+, iOS 17+ simulator/device, a Supabase project.
2. Create a git-ignored `Secrets.plist` in the `WardrobeReDo` target with `SUPABASE_URL` + `SUPABASE_ANON_KEY` (see [`README.md`](README.md#build--run)).
3. The Xcode project is **generated** — run `xcodegen generate` after any add/remove of source files (don't hand-edit `WardrobeReDo.xcodeproj`).

## Dev loop

```bash
xcodegen generate                      # after adding/removing files
# fast inner loop (excludes slow model-inference + large-image stress tests):
xcodebuild test -scheme WardrobeReDo -testPlan Fast \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Test plans live in [`Tests/Plans/`](Tests/Plans/README.md): **Fast** (inner loop), **All** (default/full), **Integration** (CI). Run **Fast green before every commit**; CI runs the full suite on the PR.

## Conventions

- **Naming:** `<Feature>View.swift`, `<Feature>ViewModel.swift`, `<Name>Service.swift`, `<Name>Repository.swift`. Tests mirror the source path under `WardrobeReDoTests/` and pair with the file they cover.
- **Where code goes:** follow the decision guide in [`ARCHITECTURE.md`](ARCHITECTURE.md#where-new-code-goes--decision-guide). In short: UI → `Views/` + `ViewModels/`; domain logic → `Services/` (flat for single-file, subfolder for a module); data access → `Repositories/`; config-only → `Config/`; helpers → `Utilities/`.
- **File size:** keep Views ~50–150 lines and ViewModels focused; when a file grows past a few hundred lines, extract a collaborator (a `Service`, a child VM, or a `Components/` view) rather than letting one file own everything.
- **Value types by default:** `struct`/`enum` for data; `class` only for shared mutable/identity state (ViewModels, caches, singletons). `@MainActor` on ViewModels.
- **Codable:** explicit `CodingKeys`; `decodeIfPresent` + defaults for migrated columns. Never combine `CodingKeys` with `.convertFromSnakeCase`.
- **Feature flags:** ship risky/unfinished work behind a flag in `Config/FeatureFlags.swift` (default off, or on for dogfooding) — the flag is the kill-switch.
- **Accessibility & theming:** semantic SwiftUI controls, VoiceOver labels, and the `Theme` tokens / `Chip` / `PrimaryButton` components — don't introduce a second styling system. Follow [`DESIGN.md`](DESIGN.md).

## Database

- Schema changes are **migrations** in `supabase/migrations/000NN_descriptive.sql` (sequential, timestamp/number-prefixed). **Never edit a migration that has shipped** — add a new one.
- Index foreign keys + filter/sort columns; RLS on every user-owned table.

## Commits & PRs

- **Conventional commits:** `feat: / fix: / docs: / refactor: / test: / chore:`, imperative mood, first line < 72 chars; the body explains *why*.
- **Branches:** short-lived `feat/*` / `fix/*` / `chore/*` off `main`; one logical change per PR; **squash-merge**. Delete the branch after merge.
- `main` stays green and is the latest dev line; tag released TestFlight builds.

## Tests

- Write a failing test first for a bug fix. Test behavior, not implementation.
- Highest-value tests are the pure-logic ones (scorers, formulas) and the ViewModel state machines — protocols make the fakes fast.
- Flag-mutating suites: `@Suite(.serialized)` + `FeatureFlagTestIsolation` + `FeatureFlags.resetAll()` in a `defer` (see existing `AddItemViewModel*Tests`).
- iOS reality check: dogfood UI/camera/ML on a **real device** — the Simulator hides OOM, camera, and watchdog issues.
