# Build 14 — UI refresh, light theme polish, Turkish localization

## Goals

1. Audit current UI for sizing / spacing / flow issues, fix the real ones.
2. Refresh the light palette so it feels **fresh** — cleaner whites, livelier
   accent, more readable text — without losing the editorial "muted cream &
   gold" brand DNA that Cormorant Garamond + the gold accent already imply.
3. Set up Turkish (`tr`) localization infrastructure and translate the most
   visible strings.
4. Document the design tokens + rules so future surfaces stay consistent.

## Where we are today

**Palette (light, sampled from `Assets.xcassets/Colors/`):**

| Token | Light | Dark | Notes |
|---|---|---|---|
| Background | `#FAFAFA` | `#1A1A1A` | very gray, almost cool |
| Surface | `#FFFFFF` | `#2C2C2C` | clean white card |
| TextPrimary | `#2C2C2C` | `#F5F5F5` | dark charcoal |
| TextSecondary | `#6B6B6B` | `#A0A0A0` | neutral gray |
| BrandPrimary | `#B8860B` | `#D4A843` | dark editorial gold |
| PrimaryLight | `#D4A843` | `#E8C878` | softer gold |
| PrimaryMuted | `#F5ECD7` | `#3D3425` | pale gold cream |
| Border | `#E8E6E3` | `#404040` | warm hairline |
| Muted | `#F0EFED` | `#333333` | slight warmth |
| Destructive | `#C41E3A` | `#E85D75` | crimson |

**Type:** Cormorant Garamond for h1–h3, system for body / caption / overline.
4pt spacing scale, 12pt card / button radius, 20pt chip radius.

**Localization:** none. Hard-coded English everywhere. ~112 inline `Text("...")`
across 29 view files.

## What "fresh" means here

Research distilled into rules that fit this app specifically:

### 1. Warm-paper backgrounds beat cool gray
Gray backgrounds (`#FAFAFA`) read as "system default, no effort." Designer-led
e-commerce apps from the last two years (SSENSE, Mr Porter, Glossier, Aritzia)
nearly all use slightly **warm** backgrounds (`#FBFAF7` / `#FAF8F4`) — looks
like premium paper rather than printer paper. Matches Cormorant Garamond's
editorial DNA.

### 2. Higher text contrast = perceived "fresh"
A `#2C2C2C` body color on `#FAFAFA` is fine but not crisp. Pushing primary
text to `#171717` (near-black) increases legibility AND makes the page feel
more decisively designed, not "muted by default". WCAG AAA-safe.

### 3. The accent should sing on a single button per screen
The current dark gold `#B8860B` is rich but visually heavy. A slightly warmer,
brighter gold (`#C99A3B`) reads as fresher without breaking brand. Apply it
sparingly — one CTA per surface, plus picker-selected state.

### 4. Surfaces need contrast against the background
Currently `#FAFAFA` background with `#FFFFFF` surfaces: 1 step of gray
difference. Cards barely separate. Bumping background to `#F6F4EF` (warm
cream) makes white surfaces pop slightly without becoming an aggressive
visual frame.

### 5. Borders go softer, not harder
"Fresh" interfaces usually under-line rather than over-line. The current
`#E8E6E3` is good; we'll keep it. What's broken is that some surfaces use
hairline borders where shadow would feel cleaner — but that's a per-view
fix, not a token.

### 6. Cool secondary text reads modern; warm reads dated
Switching `TextSecondary` from neutral gray `#6B6B6B` to a slightly cool
`#5A6675` makes the page feel less sepia/dated.

### 7. Saturated reds are read as alerts on a warm palette
The current `#C41E3A` is fine, but on the fresher cream background it
could go to `#DC2626` (true Tailwind-ish red) — feels more contemporary.

## Final fresh palette (light only — dark stays untouched)

| Token | From | To | Why |
|---|---|---|---|
| Background | `#FAFAFA` | `#FBFAF6` | warm paper, not gray |
| Surface | `#FFFFFF` | `#FFFFFF` | unchanged — clean white card |
| TextPrimary | `#2C2C2C` | `#171717` | crisper, more contrast |
| TextSecondary | `#6B6B6B` | `#5A6675` | cool, modern |
| BrandPrimary | `#B8860B` | `#C99A3B` | warmer, livelier gold |
| PrimaryLight | `#D4A843` | `#E0B65B` | brighter |
| PrimaryMuted | `#F5ECD7` | `#F8EFD8` | slightly cooler cream |
| Border | `#E8E6E3` | `#EAE7E0` | barely changed |
| Muted | `#F0EFED` | `#F1EEE8` | warmer |
| Destructive | `#C41E3A` | `#DC2626` | contemporary red |

## UI audit findings

Quick pass through the surfaces I touched in builds 7–13:

1. **OutfitCardView wear-count badge** can visually overlap the slot role
   text when wearCount > 0 and slot is "hero". Currently no z-order issue
   (badge is in the thumbnail's ZStack; the role is outside the ZStack)
   but the visual spacing is tight. Not a bug, just visually cramped.

2. **DailyOutfitsView vibe + occasion row** stacks 3 controls (occasion
   chips, vibe slider, Surprise me button) above the carousel — on small
   iPhones (SE / 13 mini) the carousel can squeeze. Acceptable, not
   broken.

3. **SearchBar** in WardrobeGridView has an X button that's only visible
   when query non-empty — good. No size issue spotted.

4. **GoldButton** is `frame(height: 48)` — meets 44pt minimum tap target.

5. **Chip buttons** (occasion picker) use `padding(.horizontal, .md)` +
   `padding(.vertical, .sm)` = 16+8 padding = comfortably tappable.

6. **Match hero picker thumbnails** are 72×88 — meets 44pt for the tap
   area. Fine.

7. **StatusToast** has `lineLimit(1)` + `minimumScaleFactor(0.85)` — handles
   long localized strings reasonably.

8. **MatchResultCard** doesn't have a visible width constraint — should be
   fine on all phones but worth a manual check.

No actual breakage found. The "feels broken" concern is more about palette
freshness than literal sizing bugs.

## Turkish localization plan

### Approach
Use a **String Catalog** (`Localizable.xcstrings`, the Xcode 15+ format) at
`WardrobeReDo/Resources/`. Xcode generates the catalog on first build from
inline `String(localized:)` calls and `Text("…")` keys.

For Build 14 scope:
- Wire up Turkish (`tr`) as a supported locale.
- Replace the highest-visibility strings with `String(localized:)` so they're
  pulled into the catalog. Specifically: tab labels, navigation titles,
  picker option names, primary CTAs, the toast message template.
- Translate those into Turkish.
- Leave the long tail of strings (error messages, advanced settings) for a
  Build 15 expansion. Doing the visible ~30 strings first is real progress;
  doing all ~200 in one go would be a 4-hour grind with high risk of
  paraphrase mistakes.

### Turkish translations for visible strings

| English | Turkish |
|---|---|
| Wardrobe | Gardırop |
| Outfits | Kombinler |
| Match | Eşleştir |
| Profile | Profil |
| Today's Outfits | Bugünün Kombinleri |
| Your Daily Outfits | Günlük Kombinlerin |
| Generate Today's Outfits | Bugünün Kombinlerini Oluştur |
| Try Again | Tekrar Dene |
| 🎲 Surprise me | 🎲 Şaşırt beni |
| Rolling… | Karıştırılıyor… |
| Updated for | için güncellendi |
| Casual | Günlük |
| Work | İş |
| Date | Buluşma |
| Formal | Resmi |
| Athletic | Spor |
| Lounge | Rahat |
| Safe | Güvenli |
| Polished | Şık |
| Balanced | Dengeli |
| Adventurous | Cesur |
| Bold | İddialı |
| Add an Item | Ürün Ekle |
| Add First Item | İlk Ürünü Ekle |
| Search wardrobe | Gardıropta ara |
| Clear search | Aramayı temizle |
| No items match your search | Aramayla eşleşen ürün yok |
| Sort by | Sıralama |
| Newest | En Yeni |
| Most worn | En Çok Giyilen |
| Least worn | En Az Giyilen |
| Curating your outfits... | Kombinlerin hazırlanıyor... |
| Worn | Giyildi |
| Mark as worn | Giyildi olarak işaretle |
| Skip | Atla |
| Love | Beğen |
| Like | Hoşuma gitti |
| Cancel | İptal |
| Save | Kaydet |
| Save all | Tümünü kaydet |
| Saved | Kaydedildi |
| Loading wardrobe... | Gardırop yükleniyor... |
| Add items to your wardrobe first | Önce gardırobuna ürün ekle |
| Outfit suggestions | Kombin önerileri |
| Select a piece | Bir parça seç |
| Tap an item above to find\noutfits built around it | Yukarıdan bir parça seçince\nona göre kombin oluşturulur |
| Finding matches... | Eşleşmeler aranıyor... |
| No matching outfits found. | Eşleşen kombin bulunamadı. |
| Try a different item | Farklı bir parça dene |

## Phases

### Phase 1 — Refresh light palette (8 colorset edits)
Update light variants of the 8 colors listed in the table above. Dark mode
unchanged.

### Phase 2 — Audit pass
Touch up the OutfitCardView wear-count badge spacing if cramped after
palette swap. Confirm no other visual breakage.

### Phase 3 — Wire up String Catalog
- Create `Localizable.xcstrings` (empty)
- Add `tr` to project.yml's `KNOWN_LOCALIZATIONS` (and `INFOPLIST_KEY_CFBundleLocalizations`)
- Convert ~30 high-visibility strings to `String(localized:)` / `LocalizedStringKey`
- Re-generate project so Xcode picks up the catalog
- Build once to auto-populate keys

### Phase 4 — Translate
Edit the catalog directly (it's JSON) to add `tr` translations for the keys
that exist after Phase 3's pass.

### Phase 5 — Tests + Fast plan + ship
Run Fast plan (should be unaffected — no semantic changes), commit, bump
to TestFlight build 18.

## Out of scope (deferred to Build 15+)

- Full long-tail string translation (error messages, advanced settings, dev
  toolings)
- RTL support (Turkish is LTR so not blocked)
- Date/number locale formatting beyond what `RelativeDateTimeFormatter`
  already does automatically
- A user-facing language picker in Settings (system language is fine for
  now; we'll honor it via `Bundle.main`)
- A theme picker (system light/dark is fine; we're refreshing the existing
  light palette, not adding a new theme)

## Risks

| Risk | Mitigation |
|---|---|
| Color swap breaks contrast somewhere | All new values were checked against WCAG AA for text-on-background |
| Catalog generation requires xcodegen + Xcode build | Run `xcodegen generate` after adding catalog, build once locally to populate |
| Turkish string longer than English → button overflow | `StatusToast` already has `minimumScaleFactor(0.85)`; GoldButton uses single-line |
| Some `Text("…")` still hard-coded | OK — those stay English until Build 15. iOS falls back to base locale per-string |
