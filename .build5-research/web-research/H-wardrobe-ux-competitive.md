# H — Wardrobe UX Competitive Landscape Research

**Date:** 2026-04-26
**Author:** Research agent (Build 5 redesign)
**Scope:** Competitive teardown of 10+ wardrobe / closet apps + UX patterns for ML-prefilled forms, item display, multi-pick capture, and worn-outfit entities. Ends with 10 actionable recommendations.

---

## Executive Summary

The wardrobe app market splits into three tiers:

1. **AI-first, polished UX** — Whering, Acloset, Indyx. Auto-bg-removal, auto-tagging, AI outfit gen. *This is our competitive set.*
2. **Manual but reliable** — Stylebook (the OG), Smart Closet, Closet+. Older, paid one-time, deeper feature trees.
3. **Specialty / niche** — Save Your Wardrobe (sustainability), Combyne (social/collage), Pureple (virtual try-on), Cladwell (capsule/ChatGPT), OpenWardrobe (open-source).

**Key takeaways for our redesign:**
- **Whering's mass-tagging** (long-press → multi-select → bulk edit) is the gold-standard pattern for solving our 6-form fatigue problem. We must adopt it.
- **All competitive apps use light/white/transparent backgrounds for items** — none use dark gray. Industry standard is white or off-white with the cutout filling 70-85% of frame, *consistent aspect ratio*.
- **Confidence-based UI is rare** in wardrobe apps but well-established in ML-design literature (Google PAIR, Apple HIG). The pattern: show *N-best alternatives* not a percentage; allow easy override.
- **"Worn outfits" as a calendar entity** is universal — Stylebook, Whering, Acloset, Indyx, Cladwell all have it. Source-photo-as-look is *not* the dominant pattern; users compose looks from item cutouts. Our build-4 source-photo backdrop bug is actually worth keeping as an *additional* surface (Whering does this for "real outfit" photos), but should never replace the cutout-based composition.

---

## 1. App-by-App Teardown

### 1.1 Whering (UK) — *the closest competitor and the model we should benchmark against*

**Tagline:** "The Social Wardrobe & Styling App"
**Pricing:** Free up to 100 items; £30/yr basic; £120/yr expert (unlimited items + advanced features). [Source](https://stylewithingrace.com/whering-wardrobe-app-review/)
**Users:** Unspecified, but featured by Apple as App of the Day.

**Capture flow:**
- Three paths: take a photo, upload from camera roll, or import from a 100M+ retailer database. [Whering FAQ](https://whering.co.uk/faq/how-do-i-add-my-own-clothes)
- **Auto-background-removal runs server-side after upload.** Items appear in the wardrobe immediately while AI processes attributes "in the background." [Style With Grace review](https://stylewithingrace.com/whering-wardrobe-app-review/)
- AI auto-suggests category, color, sometimes brand. User can edit before/after.
- **Limitation:** "Background remover sometimes picks up little things from the background, though it's understood it can't be perfect." (App Store review excerpt) — *same problem we have*.

**Grid presentation:**
- Light/white background (matches the "slick, polished" aesthetic praised in reviews).
- Items appear as clean cutouts. Grid is sortable by date added (a frequent complaint — "Canvas organization arranged by when items were added rather than by category"). [Style With Grace](https://stylewithingrace.com/whering-wardrobe-app-review/)
- Cards show item only — no labels in default grid view (info revealed on tap).

**Attribute editing:**
- Form fields: category (auto), color (auto), price, size, material, brand, season, occasion, tags. Most are optional and revealed progressively.
- Smart defaults: category and color are filled by AI. User can override by tapping to expand.

**Mass-tagging (the killer feature for us):** [Whering blog post](https://whering.co.uk/thoughts/mass-tagging-is-finally-here)
- **Long-press an item in the wardrobe grid → enters selection mode.**
- User taps additional items to multi-select. Selection count shown in header.
- Bottom action bar: "More > Add tags" → bulk-edit Season, Brand, Occasion, Tags.
- Quote from Whering team: "You asked and we delivered– mass tagging is FINALLY here! Uploading items and editing tags just got a whole lot faster."

**Outfit generation:**
- Three modes: (a) **W-Pick** — a Tinder-style swipe-yay/nay, only 3 outfits/session ("frequent complaint"); (b) **Dress Me** — random shuffle through a per-category slider (top, bottom, shoes); (c) AI-generated outfits based on weather + style profile.
- Pain point per multiple reviews: "Dress Me occasionally pairs two tops or outerwear pieces together" (no semantic constraints).
- Outfit cards show items as a vertical stack of cutouts, not a 2x2 grid.

**Outfits / "worn looks" entity:**
- **"Outfits" tab is separate from items.** Users can save an outfit as a "look" with optional photo of self wearing it, date worn, occasion.
- Calendar surfacing on premium tier.

**Innovations to steal:**
- ✅ **Long-press → multi-select → bulk-edit pattern** for items grid. Solves our 6-form fatigue.
- ✅ **Async background processing**: items appear immediately, AI fills in attributes after — user is never blocked waiting.
- ✅ **Beta features in-app** with explicit "this is beta, send feedback" labels. Builds trust during ML errors.
- ⚠ **AI suggestion confusion** — tags get duplicated. Lesson: when ML suggests a tag the user already has, dedupe.

---

### 1.2 Acloset (Korea, by Looko) — *7M+ users, "AI-powered closet" tagline*

**Tagline:** "Your AI-Powered Smart Closet"
**Pricing:** Free up to 100 items; subscription tiers above.
**Users:** 7M+ globally. [KoreaTechDesk](https://koreatechdesk.com/korean-startup-lookos-ai-digital-wardrobe-app-acloset-gets-over-800000-global-users)

**Capture flow:**
- Photo upload + AI auto-bg-removal + auto-tag (category, season, material, color, sometimes pattern). [Style With Grace Acloset review](https://stylewithingrace.com/acloset-review/)
- Manual edit available for misidentified attributes.
- "Photo upload can be glitchy" (per Indyx comparison). [Indyx blog](https://www.myindyx.com/blog/the-best-wardrobe-apps)

**Grid presentation:**
- "Best interface among popular wardrobe apps" — described as *"like Instagram for your wardrobe"*. [Indyx blog](https://www.myindyx.com/blog/the-best-wardrobe-apps)
- Light background, transparent-bg cutouts.
- Multiple "closets" supported (capsule wardrobes, seasonal, work vs. casual).

**Attribute editing:**
- Auto-filled: category, season, material, color, pattern.
- User-added: occasion, brand, price, size.
- Optional multiple images per item ("if you can wear it different ways").

**Outfit generation:**
- Four AI modes: occasion-based, color-pop, featured-piece pairing, weather-appropriate.
- Refinement via three-dot menu: user can flag "mismatched categories" or temperature issues — *a feedback loop that informs future suggestions*.
- Reviews: "AI outfit generator is clever, but the suggestions often feel disjointed from your personal style — more novelty than an everyday tool." [Clueless Clothing 2026 review](https://clueless.clothing/blog/best-wardrobe-apps-2026/)

**Innovations to steal:**
- ✅ **Personal Color analysis + Fit Diagnosis** — auto-derived from uploaded selfies, builds onboarding stickiness.
- ✅ **Multiple closet contexts** (work / casual / season). Reduces grid overload.
- ✅ **3-dot flag-and-correct on AI suggestions** — captures structured feedback.

---

### 1.3 Indyx — *high-fidelity, premium positioning*

**Tagline:** "Catalog, Style, Resell Your Closet"
**Pricing:** Free tier; Insider $9/mo (analytics, customization, expert outfits from $150).
**Rating:** 4.8/5 with 250k+ downloads.

**Capture flow:**
- Photo upload + AI bg-removal + auto-tag (category + colors). [App Store listing](https://apps.apple.com/us/app/indyx-wardrobe-outfit-app/id1599179405)
- **"Forward your shopping receipts"** auto-creates items from purchase emails. *Unique pattern we may consider for v2.*
- Premium "Catalog" service: Indyx sends a human Archivist to digitize your closet for a fee.

**Grid presentation:**
- Praised for "fresh, modern UI with neutral colors and minimal serif fonts" — editorial aesthetic. [Out of Office Mode review](https://outofofficemode.com/indyx-closet-tracking-app-review/) — *very similar to our DESIGN.md Cormorant Garamond direction!*
- "Birds-eye closet view" is a paid feature (lots of items per screen).
- Standard grid = scrolling through screens of cards.

**Attribute editing:**
- AI auto-tag category and colors. Manual fields for customizable tags.
- Less detail revealed in reviews — appears to be relatively minimalist.

**Outfit generation:**
- Customizable drag-and-drop outfit boards.
- Insider tier: outfit ideas from professional stylists.
- **Social: explore other users' closets** — discovery surface beyond your own wardrobe.

**Innovations to steal:**
- ✅ **Editorial, serif-fonts, neutral-color UI** matches our DESIGN.md vision — Indyx is the closest aesthetic competitor.
- ✅ **Drag-and-drop outfit canvas** is more flexible than fixed-slot outfits.
- ✅ **Cost-per-wear analytics** displayed prominently — gives users a reason to keep logging.

---

### 1.4 Stylebook — *the OG, $4.99 one-time, 15 years old, iOS-only*

**Tagline:** "Catalog your real wardrobe."
**Pricing:** $4.99 one-time. No subscription.
**Platform:** iOS only.

**Capture flow:**
- Multiple paths: built-in camera, photo library, copy/paste, **drag-and-drop**, **AI text-to-image generation** ("leather motorcycle jacket"), **clipping from web**, **multiple-import from album**, built-in clothing catalog. [Stylebook features page](https://www.stylebookapp.com/features.html)
- AI background removal (introduced 2023) + manual eraser tools (slider, eraser, tap-to-clear) for fine corrections.
- **"Continuous Import mode"** — sequential additions without menu navigation. *Pattern to steal for our multi-pick.*

**Grid presentation:**
- Bare-bones, dated visual design — but functional. [Indyx comparison](https://www.myindyx.com/versus/stylebook-vs-whering)
- Items shown on white background, organized by category.

**Attribute editing:**
- Manual tagging required. No auto-categorize.
- Many fields available: notes, season, tags, status (clean/laundry/at cleaners/lent out — *unique feature*).

**Outfit generation:**
- **"Outfit Shuffle™"** — randomized combinations within selected categories.
- Free-form canvas: pinch and drag clothing items to compose looks like a magazine collage.

**Looks (worn outfit) entity — gold standard:**
- Looks are persistent, magazine-style collages.
- **Calendar tracks every wear** — multiple outfits per day, individual items, searchable notes, wear-history logs.
- "Each clothing and outfit entry has a list of dates it was worn, most recent first." [Stylebook FAQ](https://www.stylebookapp.com/faq.html)
- Wear count drives **cost-per-wear** calculation.

**Innovations to steal:**
- ✅ **Drag-and-drop outfit canvas** (used by Stylebook + Indyx) — no fixed slots.
- ✅ **Multiple outfits per calendar day** + per-item wear log.
- ✅ **Status tracking** (clean / laundry / lent out) — utility feature beyond styling.
- ✅ **AI text-to-image item generation** — for items lost to laundry / not photographable.
- ⚠ **Don't copy** the dated visual design.

---

### 1.5 Cladwell — *capsule wardrobe / minimalist / ChatGPT-integrated*

**Tagline:** "Smaller wardrobe, bigger life."
**Pricing:** Free (1 outfit/day, 1 capsule); $7.99/mo unlimited; $49/mo includes human stylist via text/email.

**Philosophy:** Capsule wardrobe (e.g., 33 items / 3 months). Outfits are auto-generated from a curated set.

**Capture flow:**
- **Pre-populated capsule templates** — user picks a template, then *replaces* template items with their own photos. *Very different from competitor "scan everything" approach.*
- Background removal "spotty."

**Outfit generation:**
- One AI outfit per day (free), unlimited (paid). Weather-aware.
- "Ask Cladwell" ChatGPT integration for styling questions.
- Reviews: "Most outfits don't quite go together; app seems to ignore some clothes." [Skywork review](https://skywork.ai/skypage/en/Cladwell-App-Your-AI-Stylist-or-Just-a-Digital-Closet-An-In-Depth-2024-Review/1975254383916150784)

**Innovations to steal:**
- ⚠ Capsule template flow is too prescriptive for our use case.
- ✅ **"Ask the stylist" chat affordance** — could be repurposed as "What should I wear?" command.

---

### 1.6 Save Your Wardrobe — *sustainability angle, London-based*

**Tagline:** "Pack, plan, and save your wardrobe."
**Pricing:** Free.
**Featured:** Apple App of the Day.

**Distinctive features:**
- **Care services marketplace** — connects users to local cleaning, repairs, alterations, upcycling (currently London-only).
- "Good On You" sustainability ratings on brands.
- "Remove background feature is highly accurate, even on light colors against light backgrounds." [App Store reviews]
- 2024 update added **multi-edit (add/edit multiple items at once)** and zoom on item images.

**UX:**
- "Clean, fast, generally easy to use, but only basic self-serve organizing." [Indyx blog](https://www.myindyx.com/blog/the-best-wardrobe-apps)
- No category for underwear (a feature gap mentioned in reviews).

**Innovations to steal:**
- ✅ **Multi-item edit** (recent feature) — same direction as Whering's mass-tag.
- ✅ **Zoom on item image** — no other app reviewed mentions this.

---

### 1.7 Smart Closet — *clean utility app*

**Tagline:** "Smart Closet — Your Stylist"
**Pricing:** Free; Pro $0.99/mo or $9.99/yr.

**Features:**
- One-click bg-removal.
- Edit category, color, brand, price, season.
- "Random looks by your custom rules."
- **Packing list feature** for travel — "absolutely essential for travelers; lets you make outfits and asks if you want to add items to your packing list." [App Store reviews]
- Calendar planning + daily notifications.

**UX:** Simple, dated, "developers don't actively maintain." [fits-app review](https://www.fits-app.com/posts/top-8-closet-outfit-planning-apps-reviewed)

**Innovations to steal:**
- ✅ **Packing list flow** — ask "add to packing list?" when building an outfit.

---

### 1.8 Pureple — *AI outfit planner with virtual try-on*

**Pricing:** Free (ad-supported); Premium tier.
**Users:** 3M+

**Distinctive:**
- **Virtual Try-On (AI)**: see outfit on a model.
- Auto-categorization on upload.
- **Batch-edit items** (recent feature).
- Free tier interrupts with ads.

**Reviews:**
- "Algorithm doesn't seem to take swipe feedback into account; same suggestions repeated." [App Store review excerpt]
- "No back button after going through outfit suggestions." (UX bug)

**Innovations to steal:**
- ⚠ Virtual try-on is heavy; not v1 territory.
- ✅ **Batch-edit** is consistent across the polished apps — yet another signal we must adopt it.

---

### 1.9 Combyne — *social outfit creator, 8M users*

**Tagline:** "Your perfect outfit"
**Avg session:** 12 minutes (high engagement).
**Distinctive:**
- **Catalog of 1000+ brands and items** — users compose outfits from a *library*, not their own closet.
- Social: chat, follow influencers, daily outfit challenges.
- **Drag-and-drop "combyner" tool** = canvas where you arrange items into a look.
- Direct shopping integration.

**Innovations to steal:**
- ⚠ Library-first is a different product. Not for v1.
- ✅ **Outfit challenges** as engagement / content surface (could be "outfit of the week" community feature later).

---

### 1.10 OpenWardrobe (open source) + AI Closet (GitHub)

- **OpenWardrobe** — Flutter + Supabase, web/iOS/Android. Open-source, basic feature set. [GitHub](https://github.com/OpenWardrobe)
- **AI Closet** — React Native + Expo, "AI-native" closet with virtual try-on. [GitHub](https://github.com/zebangeth/ai-closet)
- **ClosetArchive** — React Native, focuses on "preventing wearing the same clothes for specific events." [GitHub](https://github.com/bahaaTuffaha/Project-ClosetArchive)

These give us a useful free-for-all comparison, but none match our SwiftUI native + on-device Vision pipeline. *Worth checking their data models for inspiration but not their UX.*

---

## 2. Avoiding Form Overwhelm — UX Patterns

### 2.1 Progressive Disclosure (Nielsen Norman, IxDF)

**Definition:** Defer advanced features and information to secondary UI components, keeping essential content in the primary UI. Coined by Nielsen 1995. [NN/g](https://www.nngroup.com/articles/progressive-disclosure/)

**For ML-prefilled forms, the pattern becomes:**
1. Primary surface = AI's best guess + confirm button (the "happy path" 80% case).
2. Secondary surface = "Edit details" disclosure that reveals all fields.
3. Tertiary = advanced fields (custom tags, notes) only shown on second tap.

**Quote (Lollypop, 2025):** "Designers must know what information is necessary at the outset and what information can wait." [Lollypop](https://lollypop.design/blog/2025/may/progressive-disclosure/)

### 2.2 Smart Defaults + "Edit if Wrong" (vs. "Fill Everything")

**Apple HIG ML guidance (paraphrased + Google PAIR):**
- *Make the AI's prediction the default value.* User accepts by doing nothing.
- *If the user changes one field, suggest re-checking related fields* (e.g., change category → re-suggest subcategory).
- *Never lock prediction*: always allow override.

**Quote (LinkedIn — Sangam Singh):** "There should be a way for users to easily override ML's predictions."

### 2.3 Confidence-Based UI (Google PAIR — Explainability + Trust chapter)

[Google PAIR Explainability + Trust](https://pair.withgoogle.com/chapter/explainability-trust/)

Patterns:

| Confidence level | Action | UI pattern |
|---|---|---|
| **High** (>85%) | Silent accept | Show as filled-in default, no annotation. User can still edit. |
| **Medium** (60-85%) | Confirm-with-alternatives | Show prediction + "or" → tap reveals top-3 alternatives. |
| **Low** (<60%) | Prompt user | Show prediction with subtle warning ("Best guess: T-shirt — please confirm") + alternatives. |
| **Unknown** | Explicit ask | Empty field, no default. |

**Critical Google PAIR principle:** "Show confidence ONLY if research confirms it meaningfully impacts user decisions. Avoid percentages — they create mistrust." Use **categorical buckets (High/Medium/Low) or N-best alternatives** instead of raw numbers.

**For our app this means:**
- Don't show "92% sneakers" — show silently if confident, OR show "Sneakers" with subtle "↓" hint if not.
- For low confidence, surface top-3 ("Sneakers / Boots / Oxford") as a chip-row picker.

### 2.4 Bulk-Edit vs. Per-Item Review

[Eleken bulk-actions UX article](https://www.eleken.co/blog-posts/bulk-actions-ux)

**Decision tree:**
- If detected items have **same predicted category, similar confidence** → bulk-confirm UI.
- If items have **mixed confidence** → split into "high-confidence batch (silent save)" vs. "needs review batch (per-item form)".
- **Wizard flow** for complex multi-step bulk edits (Jira example).

**Whering's pattern (the gold standard for our case):**
1. After detection, show a **2-column grid of detected items**, all checked by default.
2. User unchecks unwanted items (e.g., the duplicate sneaker).
3. Bottom action bar: "Save 5 items" (count updates as user toggles).
4. **Skip the per-item form** for high-confidence items — only deep-dive into low-confidence ones via a "Review" badge on the card.

### 2.5 Skip-and-Review-Later

**Pattern:** Save all detected items with the AI's best-guess attributes immediately. Surface a "Review (3)" badge on the wardrobe tab indicating items pending confirmation. User can batch-confirm later when they have time.

**Source:** This is the Whering "async background processing" model — items appear in wardrobe immediately, attribute corrections happen at user's leisure.

### 2.6 Apple HIG on ML

[Apple HIG — Machine learning](https://developer.apple.com/design/human-interface-guidelines/machine-learning) (page summary):
- **Build trust by showing what you predicted and why** (e.g., "We thought this was a T-shirt because of the round neck and short sleeves").
- **Always allow override** — predictions should never be locked.
- **Fail gracefully** — if the model can't predict, ask, don't guess.
- **Privacy** — process on-device when possible (we do, via CoreML + Vision).

---

## 3. Display Conventions for Clothing Items

### 3.1 Background Color

| App | Background | Aesthetic |
|---|---|---|
| Whering | White | Clean, slick |
| Acloset | Light gray / white | "Instagram for your wardrobe" |
| Indyx | Off-white / neutral | Editorial, magazine |
| Stylebook | White | Bare-bones |
| Save Your Wardrobe | White | Minimalist |
| Smart Closet | White | Utility |
| Pureple | White | Studio |
| **None reviewed use dark gray.** | | |

**Recommendation: white or off-white (#FAFAFA — already our app background) with the cutout floating on it.**

Our build-4 sample (IMG_2519 in `screenshots-analysis/findings.md`) shows a "dark gray" target — this *contradicts* industry standard. Reconsider: was the dark-gray choice deliberate or a leftover? Most reviewed apps go with white because the cutouts already have varied dark + light items, and a white surface doesn't compete.

### 3.2 Aspect Ratio

E-commerce best practice for clothing: [Clipping Path Experts 2025](https://www.clippingpathexperts.com/blog/image-aspect-ratio-for-ecommerce/)
- **3:4 portrait** for full-length garments (dresses, pants, full-body).
- **1:1 square** for tops, accessories, shoes — better for grid consistency.
- **Consistency across catalog** > picking the "best" ratio for each item.

**Recommendation: 1:1 square for grid view (consistency), 3:4 portrait for item detail view (room to breathe).**

### 3.3 Item Sizing Within Card

Industry research (e-commerce + reviewed wardrobe apps): **70-85% of frame**, with consistent margin/padding around the cutout. Specifically:
- Whering: ~75% (item floats centered with whitespace).
- Indyx: ~80% (slightly larger fill, more editorial).
- Stylebook: ~70% (more whitespace).

**Recommendation: 75-80% fill, 10-12% margin on each side. Use largest-axis fit: tall items (jeans) fit by height, wide items (sneakers) fit by width.**

### 3.4 Icon Styling: Drop Shadow / No Shadow / Glow

- **No shadow / minimal shadow** is dominant. Whering, Indyx, Acloset all use clean cutouts with no drop shadow.
- Stylebook uses an extremely subtle outer glow on dark items to lift them off white.
- **Heavy drop shadows look dated** (Smart Closet, Closet+).

**Recommendation: no shadow by default. Use a 2-3% opacity outer glow to give the card subtle definition without looking skeuomorphic.**

### 3.5 Multi-Item Outfit Card Presentation

Three patterns observed:

1. **2x2 grid** — Acloset, Indyx (when 4 items). Compact, comparable. *Most common.*
2. **Vertical stack** — Whering, Cladwell. Mimics how an outfit lays on a body (top → bottom → shoes). *Most "human-readable."*
3. **Layered "stack"** (like overlapping cards) — Combyne. Looks fashion-magazine-y, harder to parse at a glance.
4. **Free-form canvas** — Stylebook, Indyx outfit builder. Magazine-style, used in *outfit detail* view, not grid thumbnail.

**Recommendation: 2x2 grid for outfit cards in match/grid view (compact, scannable). Vertical stack for outfit detail view (mimics body layout). Free-form canvas only if we add an "outfit builder" feature later.**

---

## 4. ML Correction UX

### 4.1 Inline Picker Defaulting to Top-3 Predictions

**Source:** Google PAIR + Material Design ML guidance.

**Pattern:**
- Subcategory field shows current prediction as default.
- Tap to expand → reveal **top-3 model predictions as chips**, then a "More..." link to the full list.
- Selecting an alternative *immediately re-evaluates* dependent fields (e.g., category → subcategory → texture).

**Concrete UI:**
```
Subcategory: [ Boots ▼ ]              ← AI's guess
↓ tap
[ Boots ] [ Sneakers ] [ Loafers ]    ← top-3 alternatives
[ See all 12 options... ]              ← full list disclosure
```

This solves our "Sneakers → Boots" problem because Sneakers is right there as alternative #2, one tap away.

### 4.2 "Looks Wrong?" Tap to Surface Alternatives

**Source:** Apple Photos people-naming pattern. [Apple Support](https://support.apple.com/guide/iphone/find-and-name-people-and-pets-iph9c7ee918c/ios)

**Pattern:** Subtle "Not [X]?" link near the prediction. Tap reveals:
1. "Rename to..." (free-text).
2. "Try another suggestion" (top-3 alternatives).
3. "Train me" (capture user correction as feedback for future).

**Adapt for us:** Below each AI-filled chip, show a small "Wrong?" caption. Single tap = swap to top-2 alternative. Long press = full picker.

### 4.3 Smart Cascading Corrections

**Source:** Google PAIR + Apple HIG.

**Pattern:** When user changes a high-level attribute, re-suggest dependent attributes.

Example:
- User changes "Boots" → "Sneakers".
- Texture re-suggests: from "Leather" (boot default) → "Knit/Mesh" (sneaker default).
- Fit options re-suggest: from "Tall shaft" → "Low-cut, ankle, mid".

For our app, the cascade is:
- Category → Subcategory → Texture, Fit options.
- Color extraction is independent (always run).

### 4.4 Examples from Major Apps

| App | Pattern | Quote / source |
|---|---|---|
| **Apple Photos** | "Not [name]?" → rename or pick from suggested. Trains future recognition. | [Apple Support](https://support.apple.com/guide/iphone/find-and-name-people-and-pets-iph9c7ee918c/ios) |
| **Google Lens** | Shows top-N possibilities ranked; only collapses to single answer when confidence is high (>95%). User can scroll for alternatives. | [Wikipedia](https://en.wikipedia.org/wiki/Google_Lens) |
| **Pinterest visual search** | Multiple visually similar results in horizontal scroller; user picks. | (referenced in Codecospirators article) |
| **Gmail Smart Reply** | Three short reply suggestions, low-friction dismiss. Failure = type your own, no penalty. | [Google PAIR pattern](https://pair.withgoogle.com/guidebook/patterns) |

---

## 5. Worn-Outfit / "Look" Entity

### 5.1 Industry Standard

**ALL the polished apps have a "looks" entity separate from items.** Patterns:

| App | Worn-outfit feature | Surface |
|---|---|---|
| **Stylebook** | "Looks" (collages) + Calendar (one or many per day, with notes) | Calendar view, item history, shuffle |
| **Whering** | "Outfits" tab; can attach photo of self wearing it; date worn | Calendar + analytics |
| **Acloset** | Outfits with multiple item slots; can be saved + scheduled | Calendar |
| **Indyx** | Drag-drop outfit boards; pin to calendar date | Calendar + cost-per-wear analytics |
| **Cladwell** | Daily AI-suggested outfit; user logs accept/reject + custom outfit | Calendar / "Today" |
| **Pureple** | Outfit collages; can preview on AI model | Calendar |
| **Smart Closet** | Looks + daily calendar planning + notifications | Calendar |

### 5.2 What the User Wants for Our App

User said: *"source photos saved as 'worn outfits' separate from individual items."*

This is a **hybrid of two patterns**:
1. **Composed outfit** (Whering/Stylebook): user assembles 4-5 items into a saved look. *This is the dominant pattern.*
2. **Captured outfit** (closer to what the user is asking for): the source photo *itself* is a "look" — record of "I wore this on [date]."

**Recommendation: support both.** Source photo of a multi-pick session can become a "Look entry" with date, with the auto-detected items linked to it. This:
- Preserves the full-context photo (matches user's request).
- Avoids the build-4 bug of source-photo-as-item-thumbnail (cleanup of grid).
- Adds calendar surface for "what did I wear last Tuesday?"
- Drives wear count → cost-per-wear (Stylebook + Indyx pattern).

### 5.3 How to Surface Looks Later

Three surfaces, all observed in Whering/Stylebook/Indyx:
1. **Calendar view** — month grid with the day's look as a thumbnail (tap to see items).
2. **Looks gallery** — chronological grid like Photos.app, can scroll back through worn outfits.
3. **Per-item history** — on item detail, show "Worn on: 4/12, 4/18, 4/26" linking to the looks.

**Recommendation: start with #2 (looks gallery — easiest to ship). Add #1 (calendar) in v1.1. #3 (per-item history) is unlocked for free once data model is in place.**

---

## 6. Multi-Item Batch Capture Flow

### 6.1 The Problem (recap)

After detecting N items in one photo (our scenario: 6 items from a mirror selfie), showing 6 sequential forms is fatiguing. Source photo backdrop pollutes the grid. AI confidence varies (sneakers vs. boots, jeans vs. shorts, sunglasses misclassified as hat).

### 6.2 Whering's Batch Flow (closest analog to ours)

Whering doesn't actually do *N items from one photo* in the polished AI-detection way we do — they upload one item at a time. **However, their post-upload mass-tagging is the operative pattern.** The flow:

1. Upload all items (1 by 1, or by selecting multiple from camera roll).
2. Items appear in wardrobe with auto-tagged attributes.
3. User long-presses → multi-selects items needing correction.
4. Bulk-edit fields that are wrong (Season, Brand, Occasion, Tags).

### 6.3 Acloset's Batch Flow

Similar to Whering. No N-from-1 detection. Upload, AI fills, user corrects.

### 6.4 Bulk-Confirm With Override (the recommended hybrid for us)

**Flow:**

```
Step 1: User takes 1 photo (mirror selfie or flatlay).
Step 2: AI detects N items + extracts cutouts + predicts attributes.
Step 3: 2-COL GRID OF DETECTED ITEMS shown:
        [Cutout]  Jeans, Blue, Denim       ✓
        [Cutout]  Sneakers, Tan, Leather   ⚠ low confidence
        [Cutout]  Sunglasses, Brown        ⚠ low confidence
        [Cutout]  Belt, Brown              ✓
        [Cutout]  T-shirt, Cream           ✓

        Each card: tappable cutout, predicted attrs as chips, ✓ or ⚠ badge.
Step 4: User unchecks any unwanted (e.g., duplicate sneaker).
Step 5: User taps high-confidence ✓ items? → No, they auto-save.
Step 6: User taps low-confidence ⚠ items → opens MINI form (only the
        uncertain fields shown — others stay hidden).
Step 7: Bottom: [Save 5 items] (with skip-review-later option).
```

**Smart per-item form for low-confidence:**
- Show ONLY fields where AI confidence is below threshold.
- E.g., for sneakers misclassified as boots, show subcategory picker (with top-3 chip row: Sneakers / Boots / Loafers).
- Hide texture, fit, color (those were high confidence) behind "Edit details" disclosure.

This brings the user from **6 forms × ~10 fields each = 60 decisions** down to:
- 6 cards to scan ≈ 6 glances.
- ~2-3 cards needing tap-to-correct ≈ 2-3 chip selections.
- **Total: ~10 decisions instead of 60.**

### 6.5 Source Photo as a "Look" Entity (preserves user's data + cleans grid)

The 1 source photo from this session = **a "Look" entry** linked to the 5 detected items. Surfaces in calendar / looks gallery. Item grid shows only clean cutouts.

---

## 7. Recommendations for Our Redesign

Listed in priority order. Each cites specific competitive evidence and the build-4 pain point it addresses.

---

### Recommendation 1: Adopt Whering's long-press → multi-select → bulk-edit pattern in the wardrobe grid

**Rationale:** Whering, Save Your Wardrobe, and Pureple all have this. Solves bulk-correction needs for misdetected items.

**UX:**
- Long-press any item card → enters selection mode (haptic).
- Selection count appears in nav bar ("3 selected").
- Bottom action sheet: Edit Tags / Edit Season / Edit Occasion / Delete.
- "Done" exits mode.

**Solves:** Pain point #2 (form overwhelm) + provides a corrective UI for the misdetections.

**Source:** [Whering mass-tagging announcement](https://whering.co.uk/thoughts/mass-tagging-is-finally-here)

---

### Recommendation 2: Replace per-item sequential forms with a 2-column grid bulk-confirm screen after multi-detection

**Rationale:** This is the single biggest UX win. Reduces 6 forms × 10 fields to 1 screen × glance-and-tap.

**UX:**
- After detection, show all N detected items as cutout cards in a 2-col grid.
- Each card: cutout + 2-3 predicted chips + ✓ (high conf) or ⚠ (low conf) badge.
- All checked by default; user unchecks rejects.
- Tap a ⚠ card → mini-form revealing only low-confidence fields.
- Tap ✓ card → optional "Edit details" disclosure (full form), but not required.
- Save All at bottom.

**Solves:** Pain points #2 (overwhelm), #3 (wrong attributes), #4 (multi-pick fatigue).

**Source:** Whering pattern + Google PAIR confidence-based UI guidance.

---

### Recommendation 3: Confidence-driven UI — silent accept high-confidence; surface top-3 for low-confidence

**Rationale:** Google PAIR + Apple HIG converge on: don't show percentages, show *categorical confidence* via UI behavior. Top-3 alternatives chip row is the dominant pattern.

**UX:**
- High confidence (>85%): default fills the field silently. No badge.
- Medium (60-85%): default fills, with a subtle "↓" hint indicating tap to see alternatives. Top-3 chip row on tap.
- Low (<60%): default fills with a ⚠ badge ("Best guess"). Top-3 chip row visible by default.
- Always allow free-text or full-list override.

**Solves:** Pain point #3 (wrong attributes) — sneakers becomes a tap away from boots, instead of buried in a 12-item alphabetical list.

**Source:** [Google PAIR Explainability + Trust](https://pair.withgoogle.com/chapter/explainability-trust/), [hanjing AI Product Design Guidelines](https://hanjing.medium.com/ai-product-design-guidelines-42c482e4fe70)

---

### Recommendation 4: Drastically simplify default form — collapse 5 colors to 1 dominant + 1 accent; hide texture/fit/season/occasion behind disclosure

**Rationale:** All polished apps (Whering, Acloset, Indyx) show only category + color in primary. Other fields revealed via "Edit details."

**UX (default item form):**
```
[ Cutout ]
Category: T-shirt ▼
Color:    [●●] Cream + Brown        ← 1 dominant + 1 accent
─────────
[ + Edit details ]  ← discloses texture, fit, season, occasion, brand, price, notes
```

**Color simplification:**
- Show 1 dominant color + 1 accent color (max 2 swatches).
- Drop percentages from primary view (they confuse users — 26% vs 23% blue is meaningless).
- "Show all colors" link reveals the 5-color palette for power users.

**Solves:** Pain point #2 (overwhelm), #1 (form bloat).

**Source:** All polished competitor apps, NN/g progressive disclosure, our own findings (5 near-identical blues per `findings.md`).

---

### Recommendation 5: Item card design — 1:1 square, white/off-white background (#FAFAFA), 75-80% cutout fill, no drop shadow, consistent margin

**Rationale:** Matches industry standard (Whering, Indyx, Acloset, Stylebook all use white). Our build-4 dark-gray choice contradicts the field. Consistency matters more than ratio choice.

**UX:**
- 1:1 square cards in main wardrobe grid.
- White/off-white background (`Surface` token = #FFFFFF, or `Background` = #FAFAFA).
- Cutout floats centered, fits to 75-80% of frame on largest axis.
- No drop shadow. Optional 2% outer glow for definition.
- Optional 1pt border in `Border` token (#E8E6E3) for card edge.
- 3:4 portrait card on item detail view (room to breathe + bounding box overlay from PR #21).

**Solves:** Pain point #1 (inconsistent grid).

**Source:** [Clipping Path Experts e-commerce best practices](https://www.clippingpathexperts.com/blog/image-aspect-ratio-for-ecommerce/), Indyx + Whering reviews.

---

### Recommendation 6: Add a "Look" entity that wraps the source photo + detected items

**Rationale:** All polished apps have a Looks/Outfits entity separate from items. Solves user's request to preserve source photo while keeping item grid clean. Drives long-term value (calendar, cost-per-wear).

**Data model:**
```
Look {
  id, source_photo_path, captured_at, occasion (optional),
  worn_dates: [...], notes, tags
}
LookItem { look_id, item_id, bbox }  // many-to-many
```

**Surfaces:**
- v1: Looks gallery (chronological grid, like Photos.app).
- v1.1: Calendar view (Stylebook pattern).
- v1.x: Per-item wear log (Indyx pattern).

**Solves:** User's explicit ask + pain point #1 (cleans up grid).

**Source:** Stylebook Looks + Whering Outfits + Indyx outfit boards.

---

### Recommendation 7: Save items immediately with best-guess attrs; add a "Review (N)" badge on low-confidence pending items

**Rationale:** Whering's async processing model. User isn't blocked at upload time. "Review later" badge surfaces uncertain items at the user's leisure.

**UX:**
- After multi-detection bulk-confirm, items save immediately.
- Items with ⚠ low-confidence get a small badge in the grid corner.
- Wardrobe tab shows "Review (3)" indicator.
- Tap badge → batch review screen.

**Solves:** Pain point #4 (multi-pick fatigue) without losing detection data.

**Source:** Whering async processing model.

---

### Recommendation 8: Smart cascading corrections — when category changes, re-suggest dependent fields

**Rationale:** Apple HIG + Google PAIR both call this out. Reduces cognitive load when a single fix needs to ripple.

**UX:**
- If user changes Category from "Footwear" → "Shoes" or subcategory from "Boots" → "Sneakers":
  - Texture re-suggests with sneaker-appropriate options (mesh, knit, leather).
  - Fit options refresh (low-cut, mid, high — instead of boot-shaft).
- Show an inline hint: "Updated suggestions for Sneakers."

**Solves:** Pain point #3 — one correction shouldn't require 3 more corrections.

**Source:** Apple HIG, Google PAIR.

---

### Recommendation 9: Detail view = full source photo + bounding-box overlay (PR #21 direction is correct, expand it)

**Rationale:** PR #21 already implements this for items. Extend the pattern: in the **Look detail view**, show the full source photo with all bounding boxes overlaid; tap a box to navigate to that item.

**UX (item detail):**
- Tab/segment: "Cutout" | "Source"
- Cutout view: clean 3:4 portrait of the cutout on white.
- Source view: original photo with bounding box highlighted around the item, dimmed background.

**UX (look detail):**
- Source photo as hero, all detected boxes overlaid with item labels.
- Below: thumbnail strip of the 5 cutout items in this look.

**Solves:** Build-4 source-photo-thumbs polluting the item grid (move source photo to detail view + look entity, not grid).

**Source:** Existing PR #21 + Stylebook + Whering "outfit detail" patterns.

---

### Recommendation 10: Add explicit feedback affordance — "This is wrong" link captures correction events for future model improvements

**Rationale:** Apple Photos "Not [name]?" pattern. Closes the loop between user correction and model improvement (server-side dataset for retraining). Builds trust.

**UX:**
- On any AI-suggested chip in the item form, a small "Not right?" link below.
- Tap → "What is it actually?" picker.
- Logs an event server-side: `{user_id, item_id, predicted_subcategory, corrected_subcategory, source_photo_id}`.
- Used to retrain the subcategory rescue mapping.

**Solves:** Pain point #3 long-term — instead of just patching mappings, capture user corrections as training data.

**Source:** [Apple Photos people identification](https://support.apple.com/guide/iphone/find-and-name-people-and-pets-iph9c7ee918c/ios), Google PAIR feedback patterns.

---

## Appendix A — Sources

### Wardrobe app reviews
- [Indyx blog: Best Wardrobe Apps 2026](https://www.myindyx.com/blog/the-best-wardrobe-apps)
- [fits-app: Top 8 closet & outfit planner apps reviewed](https://www.fits-app.com/posts/top-8-closet-outfit-planning-apps-reviewed)
- [Style With Grace: Whering review](https://stylewithingrace.com/whering-wardrobe-app-review/)
- [Style With Grace: Acloset review](https://stylewithingrace.com/acloset-review/)
- [Out of Office Mode: Indyx review](https://outofofficemode.com/indyx-closet-tracking-app-review/)
- [Conscious by Chloe: Indyx review](https://consciousbychloe.com/2025/11/19/indyx-app-review/)
- [Stylebook official features](https://www.stylebookapp.com/features.html)
- [Cotton Cashmere Cat Hair: Stylebook review 2025](https://www.cottoncashmerecathair.com/blog/2020/4/10/how-i-catalog-my-closet-and-track-what-i-wear-with-the-stylebook-app-review)
- [Indyx versus pages: Stylebook vs Whering, Acloset vs Save Your Wardrobe, etc.](https://www.myindyx.com/versus/stylebook-vs-whering)
- [Skywork: Cladwell review](https://skywork.ai/skypage/en/Cladwell-App-Your-AI-Stylist-or-Just-a-Digital-Closet-An-In-Depth-2024-Review/1975254383916150784)
- [Hannah Fürstenberg / Medium: Whering UX masterclass](https://medium.com/@HannahFberg/whering-a-masterclass-in-ux-understanding-the-5-elements-of-ux-through-this-digital-closet-app-3a1fb6663bd2)
- [Clueless Clothing: Best Wardrobe Apps 2026](https://clueless.clothing/blog/best-wardrobe-apps-2026/)
- [Kat Sturges: Whering / Indyx / Style DNA comparison](http://www.kathrynsturges.com/home/2025/4/8/comparison-between-wardrobe-apps)

### App Store / official pages
- [Whering: App Store](https://apps.apple.com/us/app/whering-your-digital-closet/id1519461680)
- [Whering: How it Works](https://whering.co.uk/how-it-works)
- [Whering: Mass Tagging announcement](https://whering.co.uk/thoughts/mass-tagging-is-finally-here)
- [Acloset: official site](https://www.acloset.app/)
- [Indyx: App Store](https://apps.apple.com/us/app/indyx-wardrobe-outfit-app/id1599179405)
- [Stylebook: App Store](https://apps.apple.com/us/app/stylebook/id335709058)
- [Save Your Wardrobe: App Store](https://apps.apple.com/gb/app/save-your-wardrobe-organiser/id1485757044)
- [Smart Closet: App Store](https://apps.apple.com/us/app/smart-closet-your-stylist/id1198057728)
- [Pureple: App Store](https://apps.apple.com/us/app/pureple-ai-outfit-planner/id628106373)
- [Combyne: App Store](https://apps.apple.com/us/app/combyne-your-perfect-outfit/id989727742)
- [Cladwell: official site](https://cladwell.com/app)
- [OpenWardrobe (open source)](https://github.com/OpenWardrobe)
- [AI Closet (open source)](https://github.com/zebangeth/ai-closet)

### UX / ML design references
- [Apple HIG: Machine Learning](https://developer.apple.com/design/human-interface-guidelines/machine-learning)
- [Google PAIR: Explainability + Trust](https://pair.withgoogle.com/chapter/explainability-trust/)
- [Google PAIR: People + AI Guidebook](https://pair.withgoogle.com/guidebook/)
- [Google Design: Predictably Smart (ML for UX)](https://design.google/library/predictably-smart)
- [hanjing on Medium: Google AI Product Design Guidelines](https://hanjing.medium.com/ai-product-design-guidelines-42c482e4fe70)
- [Nielsen Norman: Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)
- [IxDF: What is Progressive Disclosure](https://ixdf.org/literature/topics/progressive-disclosure)
- [Eleken: Bulk action UX guidelines](https://www.eleken.co/blog-posts/bulk-actions-ux)
- [Material Design: Confirmation & Acknowledgement](https://m1.material.io/patterns/confirmation-acknowledgement.html)
- [Sangam Singh / LinkedIn: UI/UX implications for ML applications](https://www.linkedin.com/pulse/uiux-design-implications-machine-learning-sangam-singh)
- [Pencil & Paper: Error Message UX](https://www.pencilandpaper.io/articles/ux-pattern-analysis-error-feedback)
- [Apple: Find and name people in Photos](https://support.apple.com/guide/iphone/find-and-name-people-and-pets-iph9c7ee918c/ios)
- [Apple: Visual Look Up](https://support.apple.com/guide/iphone/identify-objects-in-your-photos-and-videos-iph21c29a1cf/ios)
- [Wikipedia: Google Lens](https://en.wikipedia.org/wiki/Google_Lens)
- [Lens.google: How Lens Works](https://lens.google/howlensworks/)
- [Clipping Path Experts: Image aspect ratio for e-commerce 2025](https://www.clippingpathexperts.com/blog/image-aspect-ratio-for-ecommerce/)
- [Squareshot: E-commerce Product Image Size Guide 2026](https://www.squareshot.com/post/e-commerce-product-image-size-guide)
- [MDPI Sustainability: Wardrobe Management Apps and Sustainability](https://www.mdpi.com/2071-1050/17/9/4159)

---

## Appendix B — Quick Reference: What to Steal

| Pattern | Source app | Priority |
|---|---|---|
| Long-press multi-select + bulk-edit bar | Whering, Save Your Wardrobe | **P0** |
| 2-col grid bulk-confirm after detection | Whering (adapted) | **P0** |
| Top-3 chip-row picker for low-confidence ML | Google Lens, Apple Photos | **P0** |
| White/off-white grid background, 1:1, 75% fill | Whering, Indyx, Acloset | **P0** |
| Async processing — items save immediately | Whering | **P0** |
| Looks/Outfits entity + calendar | Stylebook, Whering, Indyx | **P0** |
| Cascading attribute corrections | Apple HIG | P1 |
| Drag-and-drop outfit canvas | Stylebook, Indyx, Combyne | P1 |
| Cost-per-wear + wear log | Stylebook, Indyx | P1 |
| AI text-to-image item generation | Stylebook | P2 |
| Receipt forwarding for auto-add | Indyx | P2 |
| Personal Color analysis from selfie | Acloset | P2 |
| Care services marketplace | Save Your Wardrobe | P3 |
| Virtual try-on | Pureple | P3 |
| Status tracking (clean / laundry / lent) | Stylebook | P3 |
| Outfit challenges (community) | Combyne | P3 |
| Social closet sharing | Indyx, Combyne | P3 |

---

## Appendix C — Open Questions for Tarkan

1. **White vs. dark gray grid background** — build-4 sample screenshot uses dark gray. Is that a deliberate brand choice or a leftover? Industry standard is white. Confirm before implementing Recommendation #5.
2. **Looks entity scope for v1** — start with looks gallery only (ship fast) or include calendar in v1 (more complete)?
3. **Server-side ML correction logging** — do we have infrastructure to capture {predicted, corrected} events for future model retraining? (Recommendation #10 depends on this.)
4. **Bulk-confirm decision threshold** — what confidence cutoff defines high (silent accept) vs. medium (chip row) vs. low (mini-form)? Suggest 85% / 60% as starting points; tune from telemetry.
5. **Worn date defaulting** — when user creates a Look from a multi-pick session, default worn_date to *today* or leave blank (user must opt in to logging)?
