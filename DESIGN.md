# Design System — Wardrobe Re-Do

## Visual Theme
Minimalist, editorial, refined. Think luxury magazine meets clean digital product. Every element should feel curated, not cluttered. Whitespace is a feature, not wasted space.

## Color Palette

> **Build 38 — "Mono + Burgundy".** Paper-warm neutrals carry the stage,
> burgundy is the single rich accent that carries every primary action
> and editorial moment. Gold and sage are kept declared but de-featured
> for seasonal use (year-in-review badges, "fits your vibe" ticks).
> The shift from a gold/ink primary to a burgundy hero is the headline
> change against Build 28's "Editorial Heritage" palette.

### Light Mode
| Token | Hex | Usage |
|-------|-----|-------|
| Background | #F7F5F0 | App background — paper-warm off-white |
| Surface | #FFFFFF | Cards, sheets, modals |
| Text Primary | #1A1A1A | Body text, headings |
| Text Secondary | #6B6B6B | Captions, metadata |
| Charcoal | #3A3A3A | Mid-tone hierarchy (filter labels, secondary nav icons) |
| **Brand Primary** | **#5C1A2A** | Buttons, links, selected states — the **burgundy hero** |
| Primary Light | #7A2535 | Hover/pressed states, subtle accents |
| Primary Muted | #F3E6E8 | Filter chip bg, badge fills, soft burgundy wash |
| Destructive | #9B1C30 | Delete, error states (red-leaning burgundy so it harmonises) |
| Muted | #EDEAE3 | Disabled states, dividers |
| Border | #E0DCD2 | Card borders, separators |
| Gold (rare) | #C99A3B | Seasonal accent — year-in-review, anniversaries only |
| Accent Sage | #7B8B6F | Success / "matched well" / capture-good frame |

### Dark Mode
| Token | Hex | Usage |
|-------|-----|-------|
| Background | #1A1714 | App background — warm near-black |
| Surface | #2A2622 | Cards, sheets, modals |
| Text Primary | #F5F0E7 | Body text, headings (warm paper) |
| Text Secondary | #9A958C | Captions, metadata |
| Charcoal | #B8B8B8 | Mid-tone hierarchy (filter labels, secondary nav icons) |
| **Brand Primary** | **#A8475A** | Buttons, links — lifted burgundy for dark-bg contrast |
| Primary Light | #C25A6D | Hover/pressed states |
| Primary Muted | #3D1F26 | Filter chip bg, badge fills |
| Destructive | #E85D75 | Delete, error states |
| Muted | #332E28 | Disabled states, dividers |
| Border | #3D3833 | Card borders, separators |
| Gold (rare) | #E0B65B | Seasonal accent only |
| Accent Sage | #A8B69E | Success / "matched well" |

### Implementation
- Use named color assets in `Assets.xcassets/Colors/` with light/dark variants
- Reference via `Color("Primary")` or typed `Theme.Colors.primary`
- System adaptive: respects `@Environment(\.colorScheme)`

## Typography

### Fonts
- **Headings:** Cormorant Garamond (serif) — elegant, editorial feel
  - Fallback: Georgia, Times New Roman
  - Weight: SemiBold for h1/h2, Medium for h3
  - Tracking: tight (-0.02em)
- **Body:** SF Pro (system font) — clean, native iOS feel
  - Weight: Regular for body, Medium for emphasis
  - No custom sans-serif needed — SF Pro is excellent

### Scale (iOS Points)
| Token | Size | Weight | Font | Line Height |
|-------|------|--------|------|-------------|
| Display | 34pt | SemiBold | Cormorant | 1.15 |
| H1 | 28pt | SemiBold | Cormorant | 1.2 |
| H2 | 22pt | Medium | Cormorant | 1.25 |
| H3 | 18pt | Medium | Cormorant | 1.3 |
| Body | 16pt | Regular | SF Pro | 1.5 |
| Body Small | 14pt | Regular | SF Pro | 1.5 |
| Caption | 12pt | Regular | SF Pro | 1.4 |
| Overline | 11pt | Medium | SF Pro | 1.2 |

### Implementation
- Register Cormorant Garamond via Info.plist (`UIAppFonts`)
- Create `Theme.Fonts` enum with static methods returning `Font`
- Support Dynamic Type: use `.relativeTo(.body)` for accessibility scaling

## Spacing

### Base Unit: 4pt
| Token | Value | Usage |
|-------|-------|-------|
| xs | 4pt | Inline spacing, icon gaps |
| sm | 8pt | Tight padding, chip gaps |
| md | 16pt | Standard padding, section gaps |
| lg | 24pt | Card padding, group spacing |
| xl | 32pt | Section dividers |
| 2xl | 48pt | Page-level spacing |

### Implementation
- Define in `Theme.Spacing` enum as `CGFloat` constants
- Use consistently — no magic numbers in views

## Components

### Cards
- Corner radius: 12pt
- Shadow: `shadow(color: .black.opacity(0.06), radius: 4, y: 2)`
- Padding: `lg` (24pt) internal
- Background: Surface color
- Border: 1pt Border color (optional, used for emphasis)

### Buttons
- **Primary:** filled with Primary color, white text, 12pt radius, 48pt height min
- **Secondary:** ghost with Primary color border and text, 12pt radius
- **Destructive:** ghost with Destructive color
- Touch target: minimum 44x44pt (iOS HIG)
- Haptic: light impact on tap

### Text Fields
- 48pt height, 12pt radius
- 1pt Border color border, Surface fill
- Focus state: Primary color border
- Error state: Destructive color border + error message below

### Tags/Chips
- Small rounded pill: Primary Muted background, Primary text
- 8pt vertical padding, 12pt horizontal
- 20pt radius

### Color Swatches
- Circular, 24pt diameter (grid), 32pt (detail view)
- 2pt white border with subtle shadow for visibility on any background
- Grouped in horizontal row with `sm` (8pt) spacing

## Layout

### Navigation
- `TabView` with 4 tabs: Wardrobe, Outfits, Matching, Profile
- Tab icons: SF Symbols (tshirt, sparkles, arrow.triangle.branch, person)
- Tab tint: Primary color
- `NavigationStack` per tab for drill-down

### Grid
- `LazyVGrid` with `GridItem(.adaptive(minimum: 160))`
- 2 columns on standard iPhone, 3 on Pro Max / landscape
- Grid spacing: `md` (16pt)

### Safe Areas
- Respect all safe areas — no content under notch or home indicator
- Content insets: `md` (16pt) horizontal

## Animations

### Principles
- Every animation has a purpose — don't animate for decoration
- Duration: 150-250ms (fast enough to feel instant, slow enough to be perceived)
- Easing: `.easeOut` for entrances, `.easeIn` for exits, `.spring(response: 0.35)` for interactive

### Specific Animations
| Element | Animation | Duration |
|---------|-----------|----------|
| View transitions | Cross-fade + slide up | 200ms |
| Card entrance | Staggered fade-in from bottom | 150ms per card, 50ms stagger |
| Color swatch reveal | Sequential scale-in | 100ms per swatch, 30ms stagger |
| Reaction button | Scale bounce (1.0 → 1.2 → 1.0) | 200ms spring |
| Tab switch | Cross-fade | 150ms |
| Pull to refresh | Native iOS | System default |
| Sheet presentation | System sheet | System default |

## Haptics
| Action | Feedback |
|--------|----------|
| Tab switch | Light impact |
| Filter selection | Light impact |
| Reaction (love/like) | Medium impact |
| Skip/dismiss | Soft impact |
| Item saved | Success notification |
| Delete confirm | Warning notification |
| Error | Error notification |

## Do's
- Generous padding, clean lines, editorial-style copy
- Subtle micro-interactions (fade, slide, scale)
- Hero imagery as focal point (outfit photos, item photos)
- Restrained color — let content lead, gold as accent only
- Serif headings to establish luxury editorial voice
- Empty states with personality (editorial copy, not generic messages)

## Don'ts
- No heavy shadows or gradients
- No bright/neon colors
- No cluttered layouts — if it feels busy, remove something
- No generic stock UI patterns
- No rounded/playful fonts — keep it editorial
- No more than 3 non-neutral colors on any single screen
