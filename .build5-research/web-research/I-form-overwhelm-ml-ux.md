# Form Overwhelm in ML-Prefilled Item Capture — UX Research

Research basis for redesigning Wardrobe Re-Do's add-item experience after multi-pick detection. Today: 6 detected items produce 6 sequential full forms (Category, Subcategory, 12 Texture chips, 6 Fit chips, 4 Season chips, 6+ Occasion chips, 5 color swatches with percentages, Notes). This document distills cross-industry patterns and authoritative UX research, then converts findings into 12 concrete recommendations with implementation priorities.

---

## Executive summary

Three insights drive the redesign:

1. **The form is conceptually wrong for ML-prefilled data.** When ML supplies the answer, the form's job is no longer "collect input" — it is "let me confirm or correct." That requires a fundamentally different layout: summary first, fields-on-demand, not all fields visible.
2. **6 sequential forms compound a Hick's-law / Miller's-law violation that a single grid review eliminates.** Apple Photos and PatternFly both ship the same shape: select-many → bulk-action bar → confirm-once. Native batch-edit on iOS sets the user expectation.
3. **Confidence percentages should mostly disappear.** Both Google PAIR and Microsoft's published ML-Kit guidance say raw numbers are dangerous defaults — they invite over-trust on ~80–90% scores and confusion at 95%+. Categorical labels (or just-show-result + low-confidence-only chrome) outperform on every measured trust metric.

The 12 recommendations at the bottom map directly to these three forces. They fall into three implementation tiers (Tier 1 = ship first, biggest leverage; Tier 3 = nice-to-have refinements).

---

## 1. Progressive disclosure for ML-prefilled forms

### The principle

Progressive disclosure "initially shows users only a few of the most important options" then "offers a larger set of specialized options upon request" — Nielsen Norman Group ([NN/G — Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)). Two critical requirements: (a) correctly split features between the initial and expanded layer based on **frequency of use** and **task sequence**, and (b) make the expansion control visible with strong information scent.

For ML-prefilled forms specifically, the "correct split" inverts the default. The high-frequency action is no longer "fill everything in" — it is "confirm." So the initial layer should be a confirmation summary, and the secondary layer is the field-by-field detail.

### Apple HIG: corrections, not collection

Apple's HIG explicitly addresses this. From the [Machine Learning > Corrections](https://developer.apple.com/design/human-interface-guidelines) section (paraphrasing the ML chapter):

- **"Don't rely on corrections to make up for low-quality results."** Corrections are insurance, not the primary affordance. Build confidence in the prediction first.
- **"Use guided corrections instead of freeform corrections when possible."** A list of alternative completions beats an empty text field.
- **"Give people familiar, easy ways to make corrections."** Apple Photos uses the same auto-crop controls for refining as for accepting — no separate "edit mode."
- **"Provide immediate value when people make a correction."** The interface updates instantly and persists the change without a separate save step.

This is the model Wardrobe Re-Do should adopt: the user is correcting, not filling out a form.

### Confirmation patterns from Material and AI products

[Material Design — Confirmation & Acknowledgement](https://m1.material.io/patterns/confirmation-acknowledgement.html) distinguishes the two:

- **Confirmation** — explicitly asks "are you sure?" before proceeding. Reserve for destructive or irreversible actions.
- **Acknowledgement** — the system did something; here is an undo affordance. Use this for ML-supplied defaults that the user implicitly accepts.

Concrete cross-product patterns:

| Product | Pattern | Why it works for ML-prefilled |
|---|---|---|
| Gmail Smart Compose | Grey ghost text, Tab-to-accept, ignore-by-typing | Zero-friction acceptance. The default is "discard suggestion" — the user has to actively pull it in. |
| Notion AI suggested edits | Hover → ✔ accept / ✕ reject inline | Inline preview means the user evaluates against context, not in the abstract. |
| Apple Photos auto-crop | Shows the suggested crop applied, with the same handles used for refining | One control set for "accept as-is" and "tweak." No mode switch. |
| Apple Photos "Don't Feature a Person" | Less / Never / Reset | Three-tier dismiss with a recovery path — users feel safer rejecting. |
| Google Lens labels | Shows only the top-confidence label, not the ranked list | Hides the probability distribution. The user gets an answer, not a vote tally. |

### "Confirmed by default, override if wrong" — the optimistic pattern

The right pattern for Wardrobe Re-Do's case is what GitLab's [Pajamas design system](https://design.gitlab.com/product-foundations/saving-and-feedback/) calls **automatic saving with implicit acknowledgement**. The system commits the ML prediction; the user sees a summary; the user only opens the detail view if something looks wrong.

This is the same pattern Gmail uses for "Undo Send": the action proceeds optimistically, with a brief affordance to reverse. The cognitive math is asymmetric — saving 6 items × 7 attributes × 100% taps is much more user effort than the rare correction of one wrong subcategory.

**Practical translation: show one summary line per item — `"Sneakers, Black, Casual"` — that the user taps to expand only when they want to change something.**

### Show only the diff

If the ML predicted (Bottom, Jeans, Denim, Casual), the form is mostly noise — the user is only there to fix the Texture if it's wrong. The "diff" pattern is well-explored in code review tooling (git inline diff, Notion suggested edits) but maps directly here: present a compact card showing the prediction, with each attribute tappable for change. Don't draw the whole field structure.

**Sources for this section:**
- [NN/G — Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)
- [NN/G — 4 Principles to Reduce Cognitive Load in Forms](https://www.nngroup.com/articles/4-principles-reduce-cognitive-load/)
- [Apple HIG — Machine Learning](https://developer.apple.com/design/human-interface-guidelines/machine-learning)
- [Apple HIG — Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
- [Material Design — Confirmation & Acknowledgement](https://m1.material.io/patterns/confirmation-acknowledgement.html)
- [Material Design — Understanding ML Patterns](https://m2.material.io/design/machine-learning/understanding-ml-patterns.html)
- [The Shape of AI — UX Patterns](https://www.shapeof.ai/)
- [Notion — Suggested edits](https://www.notion.com/help/suggested-edits)
- [Gmail Smart Compose — Tab to accept](https://support.google.com/mail/answer/9116836)

---

## 2. Multi-item bulk review UX

### The native iOS expectation

iOS users already know what bulk-edit looks like: Photos lets you Select → tap many → action bar at bottom with Share/Add to Album/Delete. Apple's [Hide people, memories, and holidays](https://support.apple.com/en-al/guide/iphone/iph10a9dd2a1/ios) flow uses the same shape for taxonomy ("Feature less / Never feature"). When the user has just multi-selected 6 items in our app, they have already been primed for a batch UI by everything else they do on iOS.

[PatternFly's Bulk Selection pattern](https://www.patternfly.org/patterns/bulk-selection/) and [eBay's Bulk Editing pattern](https://playbook.ebay.com/design-system/patterns/bulk-editing) both prescribe:

- A header takeover when bulk mode begins (tray nav hidden, focused mode)
- A persistent bulk-action bar that expands/contracts with selection state
- Inline editable properties on each card (no drill-into-each-item required)
- Single Save All commit at the end

### The single-grid review screen

The strongest pattern for Wardrobe Re-Do's case is what eBay calls "inline bulk edits for routine changes" and Eleken calls Notion's pattern: **a 2-column grid of all 6 detected items with editable category/subcategory chips directly on each card.** No drill-down for the routine 80% case.

Sources:
- [Eleken — Bulk Action UX: 8 design guidelines](https://www.eleken.co/blog-posts/bulk-actions-ux) — recommends inline quick actions on cards for routine changes; reserve wizard flows for actions with dependencies.
- [eBay Playbook — Bulk Editing](https://playbook.ebay.com/design-system/patterns/bulk-editing) — header takeover, sticky bottom bar, batch undo.
- [PatternFly — Bulk selection](https://www.patternfly.org/patterns/bulk-selection/) — split-button selection control, contextual action surface.

### Skip-by-default with later-review CTA

A second valid model: pre-fill all attributes silently, save all 6 items, and surface a passive "Review attributes?" notification (a yellow chip on the wardrobe item, or a top-of-screen "3 items need review" toast). This is how Apple Photos handles auto-applied location and face suggestions — they appear as accepted, with a quiet path back if something looks wrong.

Trade-off:
- **Pro:** zero friction at capture time. The user shoots 6 items and is done.
- **Con:** users must trust the prediction more. If ML accuracy is < ~85% on subcategory, this creates "wrong items in my wardrobe" frustration.

Recommended for v2 once the model has confidence calibration data; not for first launch.

### Drill-down only on uncertainty

The hybrid model that Google PAIR endorses ([Mental Models chapter](https://pair.withgoogle.com/chapter/mental-models/)): high-confidence items save silently, low-confidence items surface as "Tap to confirm" cards. This is **confidence-driven progressive disclosure** — the surface area scales with system uncertainty, not with the number of items.

The threshold question is empirical (more on this in §6), but published ML Kit guidance (per [Microsoft Document Intelligence accuracy/confidence](https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/concept/accuracy-confidence)) and the [Mindee confidence-score guide](https://www.mindee.com/blog/how-use-confidence-scores-ml-models) converge on **0.7 as the auto-accept floor and below 0.5 as "must review."**

### Comparable: fashion-app patterns

[Whering's upload flow](https://whering.co.uk/thoughts/upload-items-fast) auto-tags then shows a "Styling" tab for tag review — review is a secondary action, not blocking. Indyx auto-removes background, auto-tags category/subcategory/color, then lets brand/season/location be added asynchronously. **No fashion app in the surveyed set forces a 7-attribute form on ingest.** Whering's own help docs say: "the technology is usually quite good but doesn't get it right every time" — they expose tags for review post-hoc, not as a gate.

**Sources for this section:**
- [Eleken — 8 Bulk Action Guidelines](https://www.eleken.co/blog-posts/bulk-actions-ux)
- [eBay Playbook — Bulk Editing](https://playbook.ebay.com/design-system/patterns/bulk-editing)
- [PatternFly — Bulk selection](https://www.patternfly.org/patterns/bulk-selection/)
- [Apple Support — Hide people, memories, and holidays in Photos](https://support.apple.com/en-al/guide/iphone/iph10a9dd2a1/ios)
- [Whering — Upload Items Fast](https://whering.co.uk/thoughts/upload-items-fast)
- [Indyx — How It Works](https://www.myindyx.com/how-it-works)
- [Bound State Software — Multi-Select on Mobile](https://boundstatesoftware.com/articles/mobile-ux-design-exploring-multi-select-solutions)

---

## 3. Smart defaults and Hick's law

### The math

**Hick's Law:** decision time is logarithmic in the number of options. From [Laws of UX — Hick's Law](https://lawsofux.com/hicks-law/) and [IxDF — Hick's Law](https://ixdf.org/literature/topics/hick-s-law): "the time it takes to make a decision increases with the number and complexity of choices." 12 texture chips puts a real cognitive cost on every item — and that cost is paid even when the user is just confirming.

**Choice Overload** ([Laws of UX — Choice Overload](https://lawsofux.com/choice-overload/)) extends this: beyond a threshold, more options make decision *quality* worse, not just slower. Users default to skipping or guessing.

### The Hick's-law countermove for ML-prefilled chips

The right answer is not "fewer options" — it is "predicted options shown first, the rest one tap away." Three patterns:

**a) Top-3 predicted + "More" disclosure**
Material Design's [Filter chips guideline](https://m3.material.io/components/chips/guidelines) explicitly endorses this: chip sets "should be placed in a horizontally scrollable row" with overflow. For Wardrobe Re-Do: show the 3 top-ML-predicted Texture chips inline, plus an "More" pill that expands the full 12. ML's prediction is the smart default, and Hick's-law cost drops from 12 → 3.

**b) Hierarchical chunking — Miller's chunks first, full set inside**
The 12 textures collapse cleanly into 3 chunks:
- Smooth (silk, satin, chiffon, velvet)
- Sturdy weaves (denim, canvas, twill, cotton)
- Knit (jersey, cable knit, ribbed, fleece)

[Laws of UX — Chunking](https://lawsofux.com/chunking/) and [NN/G — How Chunking Helps Content Processing](https://www.nngroup.com/articles/chunking/): "the size of the chunk typically ranges from two to six items." 3 chunks of 4 items hits the sweet spot. For users who don't know what "twill" means, the chunk label is a learning ramp.

**c) Collapse 6 fits to 3 with "See more"**
6 fit options is right at Miller's 7±2 boundary, and the long tail (Tailored, Boxy, Cropped) is rarely the answer. Loose / Regular / Slim covers ~80% of items per analytics on most fashion apps. Hide the others behind "See more." Same pattern, smaller blast radius.

### Smart defaults are mandatory, not optional

[NN/G — Cognitive Load](https://www.nngroup.com/articles/minimize-cognitive-load/) and the [Shopify smart-defaults guide](https://www.shopify.com/partners/blog/cognitive-load) converge on a strict rule: **set the default to the choice the vast majority of users (~95%) would pick.** For ML-prefilled forms, "the prediction" *is* that default — we just need to not undermine it by showing 11 unselected alternatives next to it.

**Sources for this section:**
- [Laws of UX — Hick's Law](https://lawsofux.com/hicks-law/)
- [Laws of UX — Choice Overload](https://lawsofux.com/choice-overload/)
- [Laws of UX — Chunking](https://lawsofux.com/chunking/)
- [NN/G — Chunking](https://www.nngroup.com/articles/chunking/)
- [Material Design 3 — Chips](https://m3.material.io/components/chips/guidelines)
- [Shopify — Smart Defaults Reduce Cognitive Load](https://www.shopify.com/partners/blog/cognitive-load)
- [Zuko — Smart Defaults to Optimize Form UX](https://www.zuko.io/blog/how-to-use-defaults-to-optimize-your-form-ux)
- [UI Patterns — Good Defaults](https://ui-patterns.com/patterns/GoodDefaults)

---

## 4. Color display — overload vs. essential

### What other apps actually show

| App | Color UI on item card |
|---|---|
| Apple Photos color search | One tag (the dominant color) |
| Google Lens | Hidden — only used for search ranking |
| Indyx | One auto-tagged color, editable |
| Whering | One color tag, editable |
| Acloset | One color, auto-tagged |
| Pinterest fashion | Single dominant color swatch on saved pins |

**No surveyed wardrobe / fashion / photo app shows percentages on color extraction.** The 5-swatches-with-% is a mismatch: it surfaces engineering data (the k-means cluster output) instead of user-facing meaning.

### The Baymard finding

Baymard's research on color swatches in fashion e-commerce ([Make All Color Swatches Available in Mobile List Items](https://baymard.com/blog/mobile-interactive-color-swatches)) is about product discoverability — it covers *variants*, not *attributes of one item*. The lesson transfers though: the minimum hit area is 7mm × 7mm with 2mm spacing. Five swatches in a row at typical iPhone widths puts each one well below this, suggesting our current layout is below tappable threshold even if the user *wanted* to interact.

### Three viable layouts

Listed in order of recommended preference for our case:

**Option A — Single dominant swatch + name (recommended)**
`[●] Black`
Mirrors Apple Photos and the entire wardrobe app category. Item search and outfit-generation use the dominant color anyway; secondary colors are rarely user-facing.

**Option B — Three swatches, no percentages**
`[●][●][●]`
Dominant + 2 accents. Useful only if pattern items (stripes, plaids) are common in the wardrobe. Skip the labels too — colors are self-evident.

**Option C — Two-row hierarchy**
Dominant large + 4 small below, no percentages.
This is closest to current behavior but removes the cognitive load of interpreting "47% / 23% / 18% / 8% / 4%."

### What percentages cost

Two NN/G principles fire here:
- "Eliminate visual clutter — remove unnecessary typography flourishes that don't serve a purpose" ([NN/G — Minimize Cognitive Load](https://www.nngroup.com/articles/minimize-cognitive-load/)).
- The Smart Defaults guide ([Reform.app](https://www.reform.app/blog/how-smart-defaults-reduce-form-errors)) explicitly notes that displaying derived data like extraction confidence "carries the cognitive overhead of explaining what it means."

Percentages presume the user understands what 47% color means. They don't. **Drop them.**

**Sources for this section:**
- [Baymard — Mobile Interactive Color Swatches](https://baymard.com/blog/mobile-interactive-color-swatches)
- [Indyx — Best Wardrobe Apps](https://www.myindyx.com/blog/the-best-wardrobe-apps)
- [Whering — Adding Clothes](https://whering.co.uk/faq/how-do-i-add-my-own-clothes)
- [NN/G — Minimize Cognitive Load](https://www.nngroup.com/articles/minimize-cognitive-load/)
- [Image color extraction — algorithm context](https://imageonline.io/dominant-colors/)

---

## 5. Reducing form fatigue

### The four NN/G principles

[NN/G — Few Guesses, More Success](https://www.nngroup.com/articles/4-principles-reduce-cognitive-load/) defines four principles. Mapped to our case:

| Principle | Today's form | Recommended |
|---|---|---|
| **Structure** | Single long form, all attributes flat | Group into 2-3 chunks: Identity (category/subcategory), Style (texture/fit), Context (season/occasion). Visually distinct sections. Single column. |
| **Transparency** | No progress indicator across 6 items | Show "Item 2 of 6" if sequential, or a 6-card grid for parallel review |
| **Clarity** | Text labels only | Plain language, examples in placeholders ("e.g., dark wash"). Required vs. optional made explicit. Notes is optional — mark it. |
| **Support** | Validation appears at save | Inline acknowledgement on every change (no submit gate). Help text outside the field, not in a placeholder. |

### Multi-step → single-screen with defaults

The reform.app guide ([7 Tips for Reducing Cognitive Load in Forms](https://www.reform.app/blog/7-tips-for-reducing-cognitive-load-in-forms)) and the [LinkedIn — questionnaire fatigue advice](https://www.linkedin.com/advice/1/what-best-way-sequence-questionnaire-minimize-fatigue-jqruc) both recommend **collapsing multi-step into a single screen when defaults are reliable.** With ML pre-filling everything, the default reliability is high — so the case for "6 long forms in sequence" collapses to "6 cards on one screen."

### Bulk apply for shared attributes

Season and Occasion are the highest-leverage candidates. If a user just photographed a single drawer of 6 sweaters, all 6 are likely "winter/fall" and "casual." A "Apply 'Winter, Casual' to all 6" mass-action eliminates 6 × 2 = 12 chip taps in a single action.

This is the [Eleken bulk-action pattern](https://www.eleken.co/blog-posts/bulk-actions-ux): "use inline quick actions on cards for routine bulk tasks without requiring confirmation dialogs." Surface the bulk-apply at the top of the grid review screen.

### Skip mode and edit later

The Whering pattern: auto-tag everything, save immediately, expose review as a non-blocking secondary task. Combined with a "3 items need review" passive nudge in the wardrobe view, this preserves the option for thorough taggers without forcing it on speed-focused users.

The [GitLab Pajamas saving-and-feedback](https://design.gitlab.com/product-foundations/saving-and-feedback/) guidance applies: "introduce automatic saving of changes if it will improve the user's experience." With ML-supplied data, it does.

### Smart sequencing — but easy first, not hardest first

A counter-intuitive finding: the educational research on task sequencing ([HBS — Task Selection and Workload](https://www.hbs.edu/ris/Publication%20Files/17-112_54fdf950-a08d-4ba8-a718-1150dc8916cb.pdf), [questionnaire-fatigue research summaries](https://www.linkedin.com/advice/1/what-best-way-sequence-questionnaire-minimize-fatigue-jqruc)) consistently shows that **easy tasks first** beats "hardest first." Easy tasks build momentum and reduce drop-off. Phase 1 should be the high-confidence quick confirmations; Phase 2 the genuinely ambiguous items requiring user judgment.

This contradicts the original brief's "smart sequencing — hardest first." The research goes the other way. Sequence by confidence: high-confidence items appear in a "Quick approve" row at top, low-confidence items in a "Needs review" row below. The user gets a sense of progress before tackling the hard cases.

### Auto-save without submit button

The [Pajamas — Saving and Feedback](https://design.gitlab.com/product-foundations/saving-and-feedback/) and [Primer — Saving](https://primer.style/ui-patterns/saving/) systems both endorse auto-save for low-stakes per-field edits. For ML-prefilled forms, every chip change is low stakes — the data isn't financial or security-critical. Save on change, toast confirmation only when the user navigates away from the screen.

**Caveat from NN/G — Don't Prioritize Efficiency Over Expectations** ([NN/G article](https://www.nngroup.com/articles/efficiency-vs-expectations/)): users "are more used to the pattern of having a Save or Submit button at the end." Solution: keep a "Done" button for the screen as a whole (which dismisses the bulk grid), but the per-attribute saves happen continuously underneath. Best of both worlds.

**Sources for this section:**
- [NN/G — 4 Principles to Reduce Cognitive Load](https://www.nngroup.com/articles/4-principles-reduce-cognitive-load/)
- [NN/G — Don't Prioritize Efficiency Over Expectations](https://www.nngroup.com/articles/efficiency-vs-expectations/)
- [Reform.app — 7 Tips for Reducing Cognitive Load](https://www.reform.app/blog/7-tips-for-reducing-cognitive-load-in-forms)
- [Pajamas — Saving and Feedback](https://design.gitlab.com/product-foundations/saving-and-feedback/)
- [Primer — Saving](https://primer.style/ui-patterns/saving/)
- [HBS — Task Selection and Workload](https://www.hbs.edu/ris/Publication%20Files/17-112_54fdf950-a08d-4ba8-a718-1150dc8916cb.pdf)

---

## 6. Confidence display

### Users don't know what 92% means

The strongest finding in the research, supported by three independent sources:

> "Numeric confidence indicators are risky because they presume your users have a good baseline understanding of probability." — [Google PAIR — Explainability + Trust](https://pair.withgoogle.com/chapter/explainability-trust/)

> "Mapping confidence scores to descriptive categories like 'Likely Match,' 'Possible Match,' or 'Low Confidence' proves more actionable and understandable for users." — [Medium — ML Kit Confidence and User Perception](https://medium.com/@root_36416/optimizing-user-experience-with-ml-kit-a-guide-to-confidence-scores-and-user-perception-aef30653cf90)

> "Switching to labels ('likely,' 'uncertain') improved trust scores in surveys." — [AI UX Design Guide — Confidence Visualization](https://www.aiuxdesign.guide/patterns/confidence-visualization)

The pathology of percentages: 92% reads as "wrong 8% of the time" (correct interpretation) but most users either treat it as binary (≥90 = right, <90 = wrong) or anchor on the gap from 100% as "this thing is broken." Microsoft's QnA Maker explicitly maps to "high confidence" (>0.7), "medium confidence" (0.5–0.7), "low confidence" (<0.5). This bucketing is almost universal across production ML UIs.

### Apple Vision / Core ML conventions

Apple's sample apps (per [Vision + Core ML real-time detection tutorials](https://medium.com/@authfy/real-time-object-detection-in-ios-using-vision-framework-and-swiftui-e77b1523b5fe)) typically display confidence only in *developer-facing* views (during model debug), and filter results above a threshold (often 0.3 or 0.5) before presenting to users. End-user UI shows the *label*, not the score. This matches our internal ML diagnostics view (which keeps percentages — correct location) versus the user-facing item form (where percentages should disappear).

### When to surface low-confidence

Google PAIR's rule (and a recommendation in the Mindee guide): **only surface confidence if it changes user action.** Translated for our case:

- **High confidence (>0.85)** — show the prediction as fact. No chrome. Save silently. The user can still tap to override.
- **Medium confidence (0.6–0.85)** — show the prediction but with a subtle "Tap to confirm" hint. No percentage.
- **Low confidence (<0.6)** — show the prediction with a yellow/amber outline + "Looks uncertain — tap to choose." Optionally an N-best list (top 3 alternatives) inline.

This is **confidence-driven progressive disclosure** — the UI progressively becomes more demanding only when the system itself is uncertain. The user's burden scales with system uncertainty, not arbitrarily.

### What to do with the multi-pick grid's existing 92% / 91% / 60% labels

Replace with category icons:
- ≥85% — green checkmark or no decoration
- 60–85% — a subtle question-mark dot
- <60% — amber triangle + "Looks uncertain"

[Whering's documentation](https://whering.co.uk/thoughts/upload-items-fast) takes the same line: "the technology is usually quite good but doesn't get it right every time" — said in plain language, no percentages.

**Sources for this section:**
- [Google PAIR — Explainability + Trust](https://pair.withgoogle.com/chapter/explainability-trust/)
- [Google PAIR — Mental Models](https://pair.withgoogle.com/chapter/mental-models/)
- [AI UX Design Guide — Confidence Visualization](https://www.aiuxdesign.guide/patterns/confidence-visualization)
- [Medium — ML Kit Confidence and User Perception](https://medium.com/@root_36416/optimizing-user-experience-with-ml-kit-a-guide-to-confidence-scores-and-user-perception-aef30653cf90)
- [Mindee — Confidence Scores Practical Guide](https://www.mindee.com/blog/how-use-confidence-scores-ml-models)
- [Microsoft — Document Intelligence accuracy and confidence](https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/concept/accuracy-confidence)
- [Apple Vision + SwiftUI tutorial](https://medium.com/@authfy/real-time-object-detection-in-ios-using-vision-framework-and-swiftui-e77b1523b5fe)

---

## 7. Avoiding cognitive load — Miller's 7±2

### The misapplication risk

[Laws of UX — Miller's Law](https://lawsofux.com/millers-law/) and [NN/G — Working Memory](https://www.nngroup.com/articles/working-memory-external-memory/) caution that Miller's 7±2 is *not* "menus must have ≤7 items." The original research is about **working memory** — what users hold in their head while making a decision. Visible-but-not-memorized items don't count.

The relevant application is: **how many options must the user actively compare in working memory at once?** When 12 texture chips are visible at once and the user is trying to match against the photo, they *are* loading them into working memory.

### Concrete remedies

**12 textures → 3 chunks of 4** (as proposed in §3). Each chunk is a single working-memory item until the user opens it.

**6 occasions → 3 chunks of 2** (or accept 6 since users don't need to compare all of them — they're picking one or a few). 6 is at Miller's boundary, not over it. Reasonable to keep flat, but use icons + labels (per Material Design's [icon guidance](https://m3.material.io/components/chips/guidelines)) for faster visual scanning.

**4 seasons** — leave alone. 4 is well within working memory. But: with ML pre-filling, even 4 is unnecessary. Default to the predicted season(s) and only expand if the user disagrees.

### Icons + labels for faster scan

Material Design 3's chip guidance explicitly endorses leading icons on chips: a leading icon + label can be parsed in a single saccade, especially when the iconography is conventional (sun for summer, snowflake for winter). Wardrobe Re-Do's chips today are text-only; adding icons reduces scan time per chip without changing the option count.

**Sources for this section:**
- [Laws of UX — Miller's Law](https://lawsofux.com/millers-law/)
- [NN/G — Working Memory and External Memory](https://www.nngroup.com/articles/working-memory-external-memory/)
- [O'Reilly — Laws of UX, Chapter 4: Miller's Law](https://www.oreilly.com/library/view/laws-of-ux/9781492055303/ch04.html)
- [Userbrain — Miller's Law: The Most Important Rule](https://www.userbrain.com/blog/millers-law-important-rule-ux-design-everyone-breaks/)
- [Material Design 3 — Chips](https://m3.material.io/components/chips/guidelines)

---

## 8. Recommendations for Wardrobe Re-Do

12 specific recommendations, in implementation tiers. Each cites the principle and the source.

### Tier 1 — Ship first (highest leverage, lowest risk)

**R1. Replace the 6-form sequence with a single grid review screen.**
After multi-pick, present a 2-column grid where each detected item is a card showing thumbnail + summary line ("Sneakers, Black, Casual"). Tap a card to expand its details inline. Save All button at bottom. Header takeover during this mode (hide tabs).
*Source: [eBay Bulk Editing Playbook](https://playbook.ebay.com/design-system/patterns/bulk-editing), [Eleken Bulk Action UX](https://www.eleken.co/blog-posts/bulk-actions-ux), [PatternFly Bulk Selection](https://www.patternfly.org/patterns/bulk-selection/).*
*Removes 5 navigation transitions and replaces them with one screen.*

**R2. Reduce color display to 1 dominant swatch + name; drop percentages.**
Replace `[●]47% [●]23% [●]18% [●]8% [●]4%` with `[●] Black`. Pattern items (stripes/plaid) can show 2 swatches max. No percentages anywhere in the user-facing form.
*Source: Apple Photos, Indyx, Whering, Acloset, Pinterest all do this. [Baymard mobile-color-swatches](https://baymard.com/blog/mobile-interactive-color-swatches) on hit-area, [NN/G clutter elimination](https://www.nngroup.com/articles/minimize-cognitive-load/).*

**R3. Replace confidence percentages with categorical chrome.**
The 92% / 91% / 60% labels on multi-pick become: no decoration (high), subtle dot (medium), amber triangle + "Looks uncertain" (low). Same in the form view.
*Source: [Google PAIR Explainability + Trust](https://pair.withgoogle.com/chapter/explainability-trust/), [AI UX Design Guide](https://www.aiuxdesign.guide/patterns/confidence-visualization), [Mindee confidence guide](https://www.mindee.com/blog/how-use-confidence-scores-ml-models). Microsoft's QnA Maker uses the same buckets.*

**R4. Show a summary line on the card; expand on tap.**
The card's first state is `Sneakers · Black · Casual` plus the thumbnail. The full attribute set is in an inline expansion or a sheet — only loaded if the user taps. This is the "confirmed by default, override if wrong" pattern.
*Source: [NN/G Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/), [Apple HIG Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls).*

### Tier 2 — Ship second (real reduction, moderate complexity)

**R5. Texture chips: top-3 ML-predicted + "More" expansion.**
Default surface is 3 chips (the ML's top predictions). "More" pill expands to the chunked full list (Smooth, Sturdy, Knit). The user only sees the long list when they actively need to override.
*Source: [Laws of UX Hick's Law](https://lawsofux.com/hicks-law/), [Material Design 3 chip guidelines](https://m3.material.io/components/chips/guidelines), [NN/G chunking](https://www.nngroup.com/articles/chunking/).*

**R6. Group the 12 textures into 3 chunks (when expanded).**
- Smooth: silk, satin, chiffon, velvet
- Sturdy: denim, canvas, twill, cotton
- Knit: jersey, cable knit, ribbed, fleece
*Source: [Laws of UX Chunking](https://lawsofux.com/chunking/), [Userbrain Miller's Law](https://www.userbrain.com/blog/millers-law-important-rule-ux-design-everyone-breaks/).*

**R7. Reduce visible Fit chips from 6 → 3 with "See more."**
Loose / Regular / Slim covers ~80% of items per cross-app analytics. The other 3 (Tailored, Boxy, Cropped) live behind a "See more" link.
*Source: [Hick's Law](https://lawsofux.com/hicks-law/), Smart Defaults [Shopify guide](https://www.shopify.com/partners/blog/cognitive-load).*

**R8. Bulk-apply for Season and Occasion.**
At top of grid review: "Apply [Winter] [Casual] to all 6" pills. Pre-selected based on the most common ML prediction across the batch. One tap commits to all.
*Source: [Eleken bulk-action UX](https://www.eleken.co/blog-posts/bulk-actions-ux), [PatternFly Bulk selection](https://www.patternfly.org/patterns/bulk-selection/).*

**R9. Auto-save on change; remove the per-form Save button.**
Each chip tap commits immediately. Toast confirmation only on screen exit. Keep a single "Done" button on the grid that closes the bulk mode.
*Source: [Pajamas saving-and-feedback](https://design.gitlab.com/product-foundations/saving-and-feedback/), [Primer Saving](https://primer.style/ui-patterns/saving/), with a hat-tip to [NN/G expectations](https://www.nngroup.com/articles/efficiency-vs-expectations/) for keeping the Done button.*

### Tier 3 — Refinement (polish, can defer)

**R10. Confidence-driven progressive disclosure: silent save above 0.85, prompt review below 0.6.**
High-confidence items save without expanded chrome. Medium shows a subtle "Tap to confirm" hint. Low surfaces inline as an "amber" card requiring confirmation. This is a per-attribute decision — Category might be high-confidence while Texture is low.
*Source: [Google PAIR Mental Models](https://pair.withgoogle.com/chapter/mental-models/), [Mindee thresholds 0.5/0.7](https://www.mindee.com/blog/how-use-confidence-scores-ml-models), [Microsoft confidence buckets](https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/concept/accuracy-confidence).*

**R11. Add icons to chips (seasons, occasions, fits).**
Sun/leaf/snowflake/flower for seasons. Coffee/briefcase/champagne/dumbbell for occasions. Reduces scan time per chip. Material 3 default style.
*Source: [Material Design 3 chips](https://m3.material.io/components/chips/guidelines).*

**R12. "Skip details — I'll review later" CTA.**
Bottom of grid: a tertiary "Skip review" link that saves all 6 with ML defaults intact. Surface a passive "3 items need review" badge in the wardrobe later. This is the Whering / Indyx model.
*Source: [Whering upload patterns](https://whering.co.uk/thoughts/upload-items-fast), [Indyx tagging flow](https://www.myindyx.com/how-it-works), [Apple Photos auto-tag pattern](https://support.apple.com/en-al/guide/iphone/iph10a9dd2a1/ios).*

---

## Implementation note: the user's expected mental model

The biggest shift is psychological: today's flow says "you must label this item." The new flow says "we labeled it; check our work." Every micro-decision in the redesign should reinforce that the user is **correcting**, not **filling in**.

This matters for copy too:
- "Save" → "Done" (the work is the review, not the save)
- "Add tags" → "Looks right?" or just no prompt (silent acceptance)
- "Required" → mostly absent (the ML supplied it; nothing is missing)

Apple's HIG calls this "respect people's agency and time by choosing outputs that are easy to understand and effortlessly helpful." The current form respects neither — every attribute demands a decision. The redesign should demand decisions only where the system is genuinely uncertain.

---

## Source list (consolidated)

### Authoritative UX research
- [NN/G — 4 Principles to Reduce Cognitive Load in Forms](https://www.nngroup.com/articles/4-principles-reduce-cognitive-load/)
- [NN/G — Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)
- [NN/G — Minimize Cognitive Load](https://www.nngroup.com/articles/minimize-cognitive-load/)
- [NN/G — Chunking Helps Content Processing](https://www.nngroup.com/articles/chunking/)
- [NN/G — Working Memory and External Memory](https://www.nngroup.com/articles/working-memory-external-memory/)
- [NN/G — Don't Prioritize Efficiency Over Expectations](https://www.nngroup.com/articles/efficiency-vs-expectations/)
- [NN/G — Design Guidelines for Selling Products with Multiple Variants](https://www.nngroup.com/articles/products-with-multiple-variants/)

### Laws of UX
- [Laws of UX — Hick's Law](https://lawsofux.com/hicks-law/)
- [Laws of UX — Choice Overload](https://lawsofux.com/choice-overload/)
- [Laws of UX — Chunking](https://lawsofux.com/chunking/)
- [Laws of UX — Miller's Law](https://lawsofux.com/millers-law/)

### Apple HIG and platform
- [Apple HIG — Machine Learning](https://developer.apple.com/design/human-interface-guidelines/machine-learning)
- [Apple HIG — Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
- [Apple HIG — Inputs](https://developer.apple.com/design/human-interface-guidelines/inputs)
- [Apple HIG — Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)
- [Apple Support — Hide people, memories, and holidays in Photos](https://support.apple.com/en-al/guide/iphone/iph10a9dd2a1/ios)
- [Apple Support — Feature certain people and content less often (Mac)](https://support.apple.com/guide/photos/feature-certain-people-and-content-less-pht165ab8150/mac)
- [WWDC19 — Designing Great ML Experiences](https://developer.apple.com/videos/play/wwdc2019/803/)
- [Vision + Core ML object detection in SwiftUI](https://medium.com/@authfy/real-time-object-detection-in-ios-using-vision-framework-and-swiftui-e77b1523b5fe)

### Material Design and design systems
- [Material Design 1 — Confirmation & Acknowledgement](https://m1.material.io/patterns/confirmation-acknowledgement.html)
- [Material Design 2 — Understanding ML Patterns](https://m2.material.io/design/machine-learning/understanding-ml-patterns.html)
- [Material Design 3 — Chips](https://m3.material.io/components/chips/guidelines)
- [Material Design 1 — Selection](https://m1.material.io/patterns/selection.html)
- [eBay Playbook — Bulk Editing](https://playbook.ebay.com/design-system/patterns/bulk-editing)
- [PatternFly — Bulk selection](https://www.patternfly.org/patterns/bulk-selection/)
- [Pajamas (GitLab) — Saving and Feedback](https://design.gitlab.com/product-foundations/saving-and-feedback/)
- [Primer (GitHub) — Saving UI Pattern](https://primer.style/ui-patterns/saving/)

### AI / ML UX guidance
- [Google PAIR — People + AI Guidebook home](https://pair.withgoogle.com/guidebook/)
- [Google PAIR — Mental Models](https://pair.withgoogle.com/chapter/mental-models/)
- [Google PAIR — Explainability + Trust](https://pair.withgoogle.com/chapter/explainability-trust/)
- [The Shape of AI — UX Patterns for AI](https://www.shapeof.ai/)
- [AI UX Design Guide — Confidence Visualization](https://www.aiuxdesign.guide/patterns/confidence-visualization)
- [Smashing Magazine — Designing for Agentic AI](https://www.smashingmagazine.com/2026/02/designing-agentic-ai-practical-ux-patterns/)
- [Notion — Suggested edits](https://www.notion.com/help/suggested-edits)
- [Gmail — Smart Compose](https://support.google.com/mail/answer/9116836)

### Confidence display
- [Mindee — How to use confidence scores in ML models](https://www.mindee.com/blog/how-use-confidence-scores-ml-models)
- [Microsoft — Document Intelligence accuracy and confidence](https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/concept/accuracy-confidence)
- [Medium — Optimizing UX with ML Kit confidence scores](https://medium.com/@root_36416/optimizing-user-experience-with-ml-kit-a-guide-to-confidence-scores-and-user-perception-aef30653cf90)
- [Ultralytics — Confidence Score](https://www.ultralytics.com/glossary/confidence)

### Smart defaults and form fatigue
- [Reform.app — How Smart Defaults Reduce Form Errors](https://www.reform.app/blog/how-smart-defaults-reduce-form-errors)
- [Reform.app — 7 Tips for Reducing Cognitive Load](https://www.reform.app/blog/7-tips-for-reducing-cognitive-load-in-forms)
- [Shopify — Smart Defaults Reduce Cognitive Load](https://www.shopify.com/partners/blog/cognitive-load)
- [Zuko — Smart Defaults to Optimize Form UX](https://www.zuko.io/blog/how-to-use-defaults-to-optimize-your-form-ux)
- [UI Patterns — Good Defaults](https://ui-patterns.com/patterns/GoodDefaults)
- [Yellowball — Zero-Decision UX](https://weareyellowball.com/guides/designing-for-zero-decision-ux/)
- [Eleken — Bulk Action UX 8 Guidelines](https://www.eleken.co/blog-posts/bulk-actions-ux)
- [Bound State — Multi-Select on Mobile](https://boundstatesoftware.com/articles/mobile-ux-design-exploring-multi-select-solutions)

### Wardrobe app comparables
- [Indyx — How It Works](https://www.myindyx.com/how-it-works)
- [Whering — Adding clothes](https://whering.co.uk/faq/how-do-i-add-my-own-clothes)
- [Whering — Upload Items Fast](https://whering.co.uk/thoughts/upload-items-fast)
- [Whering — Why are tags important](https://whering.co.uk/thoughts/whering-hacks-why-we-use-tags)
- [Acloset vs Whering comparison](https://www.myindyx.com/versus/acloset-vs-whering)
- [Best wardrobe apps 2026](https://www.myindyx.com/blog/the-best-wardrobe-apps)
- [Baymard — Mobile Interactive Color Swatches](https://baymard.com/blog/mobile-interactive-color-swatches)

### Sequencing and fatigue research
- [HBS — Task Selection and Workload (PDF)](https://www.hbs.edu/ris/Publication%20Files/17-112_54fdf950-a08d-4ba8-a718-1150dc8916cb.pdf)
- [LinkedIn — Sequencing a questionnaire to minimize fatigue](https://www.linkedin.com/advice/1/what-best-way-sequence-questionnaire-minimize-fatigue-jqruc)
