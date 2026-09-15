# StockSage — UI/UX critique and remediation plan

**Target:** `swonyu/StockSage-app` @ `main` `4a18b17` (identical to `origin/main`)
**Date:** 2026-09-15 · **Author:** Claude Opus 5 review session
**Audience:** the Codex session that will execute this.

---

## 0. Read this first

This review is different from the ones already in `docs/reviews/` and `agent-docs/`
in exactly one way: **the app was built and run, and the pixels were looked at.**

Every prior UI pass was source-only and says so:

> "Live pixel checks, VoiceOver interaction and physical iPhone layout remain unverified."
> "Full-workspace PNG capture still shows the pre-existing offscreen/mixed-appearance
> rendering defect. Those images are **not** visual signoff for whole-window geometry or contrast."
> — `docs/reviews/2026-09-13-ui-critique.md`

> "UI/navigation/accessibility/widget: source/caller review plus synthetic native
> interaction/render checks. No speculative navigation redesign in this batch."
> "Running app: Native UI connection failed before inspection."
> — `agent-docs/FULL_APP_REVIEW_2026-09-12.md`

That gap is the reason the defects below survived 2,381 passing tests and three
consecutive "full reviews". **A green suite has never once looked at this app.**

### How this review was produced

| | |
|---|---|
| macOS build | `xcodebuild -scheme StockSage -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build` → exit 0 |
| iOS build | same, `-destination 'generic/platform=iOS Simulator'` → exit 0 |
| Device | iPhone 17 Pro (gate) `3B0B0FE2-…`, iOS 26.5, 402×874 pt |
| Screens visited | Home, Research, Watchlist, Chat, More, Ideas, Portfolio, idea detail sheet |
| Stress tests run | Dynamic Type `accessibility-extra-large`; system appearance `light`; macOS window resize to minimum |
| Static measurement | contrast computed from `DesignSystem.swift` values; token/usage census by script |
| Cross-check | 13 independent source reviewers, each finding adversarially refuted by a second reviewer |

Findings are marked **MEASURED** (I ran it / computed it) or **SOURCE** (read the code).
Proposals are marked **PROPOSAL** and are separable from the facts.

### What is genuinely good — do not "fix" these

1. **The honesty engineering is real and rare.** `nil` means unknown everywhere;
   gross vs net is labelled; `PriceFlash.direction(from:to:)` refuses to render a
   direction at an equal-price straddle because "the price didn't move" and "we don't
   know" must not read as a fabricated tick. Keep all of it. Nothing in this plan
   removes a single caveat — §5 changes how they are *rendered*, never whether they exist.
2. **Deliberate decisions are documented at the call site.** The `More`-tab
   `NavigationStack` comment records a theory that was pixel-tested twice and found
   wrong. That is better engineering discipline than most production codebases.
3. **`DSSegmentPicker` is the one component built correctly** — `ViewThatFits`,
   an accessibility-size menu fallback, 44 pt targets, `matchedGeometryEffect`,
   reduce-motion transaction. It is the proof the team can do this. **Make it the template.**
4. **The Home bottom list** (`Watchlist / Find ideas / Ask Qwen` — icon, title,
   subtitle, chevron) is the best-composed thing in the app. It is also the model
   for what an idea row should look like.
5. **`dangerSoft` discipline holds**: 92 uses of the AA-safe red for text vs 16 of raw
   `danger`, and those 16 are icons. The palette's own rule was followed here. §4 is
   about the one place the same rule was *not* followed.

---

## 1. The thesis

The app is not suffering from a hundred unrelated UI bugs. It has **five root causes**,
and almost every visible defect is a symptom of one of them.

| # | Root cause | The measurement that proves it |
|---|---|---|
| **RC1** | **There is no component layer.** | `DesignSystem.swift` exports 5 usable pieces for a **16,722-line** view layer. Card chrome is re-implemented inline ~35× with 5 different insets and 2 different fills for one role. |
| **RC2** | **The type scale cannot express hierarchy.** | 16 numeric tokens `mvFont7…mvFont22`, **all anchored `relativeTo: .caption2`**. 7 semantic aliases exist; ~88% of call sites bypass them and use the raw numbers. `DS.Typography.titleM` is a **fixed-size** font that does not scale at all. |
| **RC3** | **There is no depth.** | `Bezel.cardFill` vs canvas = **1.13:1**. `surface` vs canvas = **1.21:1**. All four `DS.Elevation` shadow tokens have **zero consumers**; the entire view layer has **5** `.shadow(` calls. A card is separated from the page by a 13% luminance step and nothing else. |
| **RC4** | **There is no feedback loop.** | **Zero** `#Preview` across 26 view files. 4 of 167 test files touch a view. No Dynamic-Type, width, or contrast regression test exists. Nobody — human or agent — can see a component in isolation, so layout defects are invisible until someone runs the app, which per the quotes above had not happened. |
| **RC5** | **The honesty floor was implemented as chrome, not as design.** | On the iPhone Ideas screen, ~250 pt of orange caveat text renders **above** the first idea. The idea detail sheet opens with 10 lines of disclaimer before any content. At accessibility text size the sheet is **100% disclaimer, 0% product**. The caveats are correct; their visual weight is inverted. |

**The one-sentence version:** *the design system is a token file nobody uses, laid
over a 10,163-line view nobody can preview, rendering a product whose caveats are
louder than its content.*

### Scale of the monolith — context for every estimate below

| File | Lines | Note |
|---|---|---|
| `Views/MarketsView.swift` | **10,163** | 117 view builders, **6** top-level declarations, **105 state properties** (58 `@State`, 20 `@AppStorage`, 16 `@ScaledMetric`, 9 `@ObservedObject`, 1 `@StateObject`, 1 `@FocusState`) |
| `StockSage/StockSageStore.swift` | 3,454 | 72 `@Published`, observed by 12 views |
| `Views/` total | 16,722 | 26 files, 0 previews |

Every one of those 105 properties invalidates a 10,163-line body.

---

## 2. What the app actually looks like right now

Screenshots referenced below are in the evidence directory accompanying this document.

### 2.1 The single worst visual defect — MEASURED

On the iPhone idea card, the AI-status chip **hyphenates across four lines**
("AI / un- / avail- / able"), inflating the card header to ~120 pt and pushing the
row's other chips into 2- and 3-line wraps ("At 63- / day high", "Rules: / Strong / Buy").
The next card down is unreadable. The **same string on the same device renders on one
line inside the detail sheet** — which isolates the cause to the card's chip layout,
not the string.

**Cause — `StockSage/Sources/Views/StockSageAIAssessmentView.swift:18`:**

```swift
Text(ai.label(for: idea, store: store))
    .font(.caption2.bold())
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(MarketsView.actionColorForTest(action), in: Capsule())
    .fixedSize(horizontal: false, vertical: true)   // <-- inverted
```

`horizontal: false` tells SwiftUI *"you may compress my width to anything"*;
`vertical: true` tells it *"and grow me as tall as you need"*. That is precisely the
instruction that produces a four-line capsule. The label can be up to 21 characters
(`"AI draft · unverified"`, `StockSageAIAssessment.swift:468-474`), and the header
`HStack` gives it no width priority.

This one line is visible on the app's headline surface, on every card, at default
text size, on the default device. **It is the strongest single piece of evidence that
nobody has run this app.**

### 2.2 The iPhone Ideas header stacks three buttons vertically — MEASURED

Above the fold on Ideas, before any idea: a `Copy CSV` pill, a `Cancel` pill, and a
`Loading 680/901…` pill, each on its own line, left-aligned, ragged, ~130 pt total.
`Copy CSV` — a power-user export — is the **first control the user sees**, above the
primary "Find ideas" action.

**Cause — `MarketsView.swift:4917-4922`:**

```swift
#if os(macOS)
let headerLayout = AnyLayout(HStackLayout(spacing: DS.Space.sm))
#else
let headerLayout = AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
#endif
headerLayout {
    Text("Research board")…
    Spacer()            // <-- meaningful in the HStack, pure slack in the VStack
    … Copy CSV … Cancel … Find ideas
}
```

This is not an accidental wrap — it is an explicit iOS branch that chose the wrong
container, and carried a horizontal `Spacer()` into a vertical layout.

### 2.3 Accessibility text size destroys the product — MEASURED

At `accessibility-extra-large` (three steps below the maximum iOS offers), on the
idea detail sheet:

- the ticker renders as **"PA"** — truncated mid-word;
- the "1 of 899" position counter breaks into a vertical stack of single characters
  (`1` / `c` / `f`);
- the pinned footer bar **covers the sheet header**;
- the only fully legible content on screen is the 6-line legal disclaimer.

**Cause — RC2.** Every font in the app is `@ScaledMetric(relativeTo: .caption2)`.
`.caption2` has the *steepest* accessibility ramp of any text style, because small
styles scale proportionally hardest. Anchoring a 20 pt sheet title to `.caption2`
makes the title grow like an 11 pt caption — so hierarchy does not merely compress,
the whole ladder inflates uniformly and blows every fixed container.

Compounding it (SOURCE, confirmed by reviewers): the heatmap tile has a hard
`66 pt` (iOS) / `92 pt` (macOS) height while its text is `@ScaledMetric`
(`MarketsView.swift:4038`), and 27 of 28 fixed-width text columns in `Views/` carry
no `minimumScaleFactor`.

### 2.4 Navigation buries the product — MEASURED

`MarketSection` has **11 routes**. On iPhone they go into a `TabView`, so iOS shows
4 + **More**. What lives behind More: **Catalysts, Ideas, Markets, Heatmap, Portfolio,
Alerts, Legacy paper history**.

**"Ideas" is behind More.** The README's first line calls this app "the ranked-ideas
board… `MarketsView` is the entire product." The entire product is two taps deep,
under a generic system list, below "Catalysts", in alphabetical-ish order it does not control.

It compounds: the More tab retains its pushed stack (standard `UINavigationController`
behaviour). After visiting Ideas, tapping **More** returns to **Ideas**, not the list.
Reaching Portfolio from Ideas is More → Back → Portfolio = **3 taps**, and the first
one looks like it did nothing.

### 2.5 Light mode does not exist — MEASURED

With the simulator set to `appearance light`, the app renders identically dark.
`preferredColorScheme(.dark)` is applied app-wide (`StockSageApp.swift:118, 177`) and
then **six more times redundantly** in views that are already inside it.

Forcing dark is a legitimate product choice and I am not asking to reverse it. Two
consequences are still defects:

- the system **More** list renders pure black `#000` while the app canvas is charcoal
  `#181819` — two different "darks" adjacent in the same app (visible in the screenshot);
- **SOURCE, confirmed:** the iOS bundle never declares a dark appearance, so the
  generated launch screen is **white** on a light-mode phone — a white flash into a
  black app on every cold start.

### 2.6 macOS wastes the width it demands — MEASURED

`StockSageApp.swift:111` sets `.frame(minWidth: 900, minHeight: 700)` with
`.windowResizability(.contentMinSize)`. I confirmed the floor: requesting a 500×600
window yields 900×740.

A 900 pt floor means the app **cannot be tiled in macOS Split View** on any laptop
whose half-screen is narrower than 900 pt (a 13" MacBook Air half-screen is 735 pt).
For a tool meant to sit beside a broker window, that is a real workflow cost.

And the width it insists on is not used: the ideas board is one full-width column up
to ~1152 pt (`MarketsView.swift:4721`), so on a 1380 pt window each idea row is ~250 pt
tall with its five metrics crushed into the left 35% and a 1 px sparkline stretched
across the remaining 800 pt. Meanwhile the detail sheet caps itself at 680 pt
*"for readability"* — the codebase knows the rule and applies it to one surface only.

---

## 3. The design system, measured

I ran a usage census of every token in `DesignSystem.swift` against all of
`StockSage/Sources` excluding the definition file. **23 of 56 tokens (41%) have zero
consumers.**

### 3.1 Dead tokens — MEASURED

```
Space.xxl 0   Radius.field 0   Radius.icon 0   Palette.accent2 0   Palette.bgBottom 0
Palette.hairline 0   Palette.warning 0 (!)   Typography — n/a
Motion.spring 0   Motion.snappy 0   Motion.fade 0   Motion.cinematic 0
Motion.magnetic 0  Motion.stagger 0   Motion.entrance 0
Elevation.shadow1 0  shadow2 0  shadow3 0  accentGlow 0        <-- ALL FOUR
Bezel.outerRadius 0  innerRadius 0  shellPadding 0  shellStroke 0  coreFill 0
Gradient.brand 0
```

Three of these matter beyond tidiness:

- **All four elevation tokens are dead.** Combined with `cardFill` sitting at 1.13:1
  against the canvas, the app has *no depth cue whatsoever*. This is the measured
  explanation for why every screenshot looks like flat text on a black field.
- **`DS.Palette.warning` has 0 consumers** — 236 sites use `warningSoft` instead. The
  token is a trap for the next author.
- **`DS.Gradient.brand` is not a gradient.** `Palette.accent` resolves from
  `AccentColor.colorset` to `(0.773, 0.153, 0.678)`. `Palette.accent2` is
  `(197/255, 39/255, 173/255)` = `(0.773, 0.153, 0.678)`. **They are the same colour**,
  so `LinearGradient(colors: [accent, accent2])` renders a flat fill. It currently has
  zero consumers, so nothing is broken today — but it is a loaded gun for whoever
  reaches for "the brand gradient".

### 3.2 Contrast — MEASURED (WCAG 2.1 relative luminance, computed from the source values)

Backgrounds: `bgTop` `#181A1A`-ish (0.094/0.094/0.102), `Bezel.cardFill`
(0.137/0.137/0.149), `Palette.surface` (white @ 7% over `bgTop`).

| Foreground | on `bgTop` | on `cardFill` | on `surface` | Verdict |
|---|---|---|---|---|
| pure white | 17.74 | 15.68 | 14.69 | fine |
| `warningSoft` | 10.32 | 9.13 | 8.55 | fine |
| `successSoft` | 10.14 | 8.97 | 8.40 | fine |
| `textSecondary` (white 66%) | 8.22 | 7.59 | 7.24 | fine |
| `accentText` | 7.38 | 6.52 | 6.11 | fine |
| `dangerSoft` | 7.28 | 6.44 | 6.03 | fine |
| system `red` (`Palette.danger`) | 5.00 | 4.42 | 4.14 | **fails AA below 18 pt** — and the palette already says so, and is obeyed (16 uses, all icons) |
| **`Palette.accent` / `accent2`** | **3.60** | **3.19** | **2.98** | **fails AA text everywhere; fails even the 3:1 non-text bar on `surface`** |

**The accent finding is the important one, and the codebase already knows the rule.**
`DesignSystem.swift:36-38` says verbatim:

> "Keep white-label fills dark enough for AA; **use the lighter sibling for text/icons
> on dark surfaces.**"

The lighter sibling is `accentText` (7.38:1 — passes comfortably). Actual usage:

| | count |
|---|---|
| `foregroundStyle(DS.Palette.accent)` in `Views/` | **115** |
| `foregroundStyle(DS.Palette.accentText)` in `Views/` | **2** |

**The design system documents the rule and the code violates it 115 : 2.**

This is not a request to change the brand colour — the magenta was explicitly retained
as an owner design choice in `docs/reviews/2026-09-13-ui-critique.md` and it stays.
It is a request to use *the token the palette already provides for this exact purpose*.
Everything visibly magenta-on-dark in the screenshots is affected: the tab bar label,
sidebar selection, "Saved research (0)", "Research 1–7 days", "Browse all 901 tickers",
"Rules sort: EV / day", "Holdings ⌄", and — worst — **"Base size 20.0%"**, a position-sizing
percentage rendered in the control-accent colour (`MarketsView.swift:3862`), which both
fails contrast and collides semantically with "this is an interactive control".

### 3.3 Spacing — MEASURED

`DS.Space` has 7 steps: 4 / 8 / 10 / 14 / 18 / 24 / 32.

| | count |
|---|---|
| hardcoded numeric spacing/padding in `Views/` | **527** |
| `DS.Space.*` spacing/padding in `Views/` | **178** |

**75% of spacing decisions bypass the ladder.** 20 distinct literal values are in use
(0,1,2,3,4,5,6,7,8,9,10,11,12,14,16,18,20,22,24,28). The **single most common spacing
value in the app is `6`, used 128 times — and `6` is not on the ladder at all.**

That is the measured reason the vertical rhythm reads as arbitrary in every screenshot.

### 3.4 Motion and accessibility — MEASURED

| | count |
|---|---|
| `withAnimation` / `.animation(` sites in `Views/` | **39** |
| `reduceMotion` / `accessibilityReduceMotion` references in `Views/` | **2** |
| `DS.Motion` curves defined | 11 |
| `DS.Motion` curves actually used | **3** (`smooth` 31, `press` 2, `lux` 1) |

Reduce Motion is a system accessibility setting for users who get motion sickness or
vestibular symptoms. It is honoured in `DesignSystem.swift`'s own components and
essentially nowhere else in the product.

| a11y annotation in `Views/` | count | denominator |
|---|---|---|
| `accessibilityLabel` | 157 | 135 `Button(` sites |
| `accessibilityValue` | **7** | 986 `Text(` sites |
| `accessibilityHidden` | 24 | — |
| `accessibilityIdentifier` | 19 | — |

`accessibilityValue` — the API for "this control/element has a current value" — is used
**7 times in a financial app whose every screen is numbers.**

---

## 4. The plan

Eight workstreams. **The order is not negotiable: W0 exists so that W1–W5 can be
verified at all.** Each is independently shippable and independently revertible.

### Ground rules for every workstream

1. **The honesty floor is untouchable.** No caveat is deleted, weakened, or made
   unreachable. §W5 changes *typographic weight and disclosure*, never presence.
   If a change would make a caveat harder to *find*, it is wrong.
2. **No engine semantics.** Nothing here alters ranking, conviction, EV, calibration,
   sizing, fills, or fees. If a diff touches `StockSage/Sources/StockSage/*` beyond a
   pure formatting helper, stop and re-scope.
3. **Do not reverse a recorded owner decision.** See `HANDOFF-CODEX-2026-09-12.md`
   — alert re-fire, the 60% breadth floor, engine-side alert casing, the weekly-R
   `VelocityMetricBasis` discriminator, and "keep and fix" for `PortfolioWidget`.
   Also retained by owner choice: the magenta accent, the native left sidebar, grouped
   destinations, and the existing keyboard assignments.
4. **Ship in small commits with the gate green each time.** Canonical gate:
   ```
   xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug \
     -parallel-testing-enabled NO -destination 'platform=macOS,arch=arm64'
   xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug \
     -parallel-testing-enabled NO \
     -destination 'platform=iOS Simulator,id=3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA'
   ```
   Canonical exclusions: `CalibrationPersistRunTests`, `LiveUniverseVerificationTests`,
   `StrategyBaselineMeasurementTests`.
5. **Every UI-visible change is verified in pixels, not in tests.** That is the entire
   point of this document.

---

### W0 — Make UI regressions visible *(do this first; nothing else is verifiable without it)*

**Why:** RC4. Zero previews, 4 of 167 test files touch a view. The four-line
hyphenated chip shipped and survived three "full reviews" because there is no way to
look at a component.

**The blocker to fix first (SOURCE, confirmed):** a `#Preview` of any Markets surface
currently fires a live refresh and a whole-universe scan (`MarketsView.swift:578`).
That is *why* there are no previews. So:

1. **W0.1 — Add a preview-safe seam.** A `StockSageStore.preview` (or an injected
   `ScanPolicy.none`) that constructs the store with fixture data and performs no
   network work and no scan. This is the keystone change; everything else in W0
   depends on it.
2. **W0.2 — Extract and preview the five worst offenders.** Pull these out of
   `MarketsView.swift` into their own files, each with `#Preview`s at
   *default / xxxLarge / accessibility3* text sizes and at *375 pt / 1400 pt* widths:
   - the idea card header row (the chip cluster),
   - the idea metric row,
   - `ideasHeader`,
   - the filter/sort bar,
   - the detail-sheet header + pinned footer.
3. **W0.3 — A width/Dynamic-Type smoke test.** For each extracted component, render at
   {375, 402, 744, 1400} pt × {`.large`, `.accessibility3`} and assert **no truncation
   of a required label and no intrinsic height above a stated bound**. This is the test
   that would have caught §2.1, §2.3 and §3.4 automatically.
4. **W0.4 — A contrast unit test.** Port the luminance function from §3.2 into a test
   that asserts every `DS.Palette` foreground/background pairing the app actually uses
   clears its bar (4.5:1 text, 3:1 non-text). Seed it with the §3.2 table so it starts
   **red on `accent`** and goes green when W3 lands.

**Acceptance:** a `#Preview` renders for all five components without a network call;
W0.3 and W0.4 run in the normal gate; W0.4 currently fails on `accent` by design.

**Effort:** L. **This is the highest-leverage work in the document.**

---

### W1 — Fix the visible breakages *(small diffs, immediate payoff)*

Each of these is independently verifiable in a simulator screenshot.

| ID | Defect | Anchor | Fix | Effort |
|---|---|---|---|---|
| **W1.1** | AI chip hyphenates 4 deep (§2.1) | `Views/StockSageAIAssessmentView.swift:18` | `.fixedSize(horizontal: true, vertical: true)` + `.lineLimit(1)`; give the chip layout priority over the flexible siblings in the header `HStack`. Verify with the longest label, `"AI draft · unverified"`. | **S** |
| **W1.2** | iOS Ideas header stacks 3 buttons vertically (§2.2) | `Views/MarketsView.swift:4917-4922` | Move `Copy CSV` / `Cancel` to the iOS navigation toolbar (they are secondary); keep **one** primary "Find ideas" action inline. Delete the `Spacer()` from the vertical branch. | **M** |
| **W1.3** | Filter/sort/search bar clips horizontally at 402 pt — "Search" renders as "Searc" | `Views/MarketsView.swift:4639` — plain `HStack` of three `.fixedSize()` menus plus a search field, no wrap and no scroll | Wrap in a horizontal `ScrollView` with a scroll indicator, **or** collapse sort+filter into a single menu on compact width. Do not leave a silently clipped control. | **S** |
| **W1.4** | Heatmap tiles overflow at large text | `Views/MarketsView.swift:4038` — hard 66 pt / 92 pt tile height with `@ScaledMetric` text | Make the tile height scale with the metric, or clamp the text | **S** |
| **W1.5** | Detail-sheet pinned footer covers the sheet at accessibility sizes (§2.3) | `Views/MarketsView.swift:9219` `safeAreaInset(edge:.bottom)` | Let the footer wrap/scroll, or drop to a compact bar above `.accessibility1`. The sheet must never be 100% disclaimer. | **M** |
| **W1.6** | 27 of 28 fixed-width text columns lack `minimumScaleFactor` | `Views/MarketsView.swift:2369` et al | Add `minimumScaleFactor(0.8)` + `lineLimit(1)` to fixed-width numeric columns | **M** |
| **W1.7** | iOS launch screen is white on a light-mode phone | `StockSage.xcodeproj/project.pbxproj:356` | Declare the dark appearance / a dark launch background in the bundle | **S** |
| **W1.8** | Widget renders system blue, not app magenta | `StockSageWidget/` has no `AccentColor` asset | Add the asset to the widget target | **S** |

**Note on one thing I checked and it is NOT a bug:** content rendering under the
floating iOS 26 tab bar mid-scroll. I scrolled Home to the bottom and the last row
(`Market context ›`) clears the bar correctly. That is normal translucency, not
clipping. **Do not "fix" it.** The detail-sheet footer (W1.5) is a different surface
and is genuinely broken.

---

### W2 — Rebuild the type scale *(fixes RC2)*

**W2.1 — Re-anchor the ladder.** Replace the 16 `relativeTo: .caption2` metrics with
role-anchored ones: titles → `.title3`/`.headline`, body/metrics → `.body`/`.callout`,
chips/captions → `.caption`/`.caption2`. This is what stops §2.3.

**W2.2 — Make the semantic aliases the only public API.** ~88% of call sites use the
raw `mvFontNN` numbers. Make the numeric tokens `private`, expose only roles, and add
the roles the app actually needs (the current 7 collapse three distinct jobs onto one
value — `fontCardTitle`, `fontSectionHeader` and `fontMetricValue` are all `mvFont15`,
which is a measured reason section headers and metric values are indistinguishable).

**W2.3 — Fix `DS.Typography.titleM`.** It is a fixed-size `Font.system(size: 17)`
used at 9 panel headings, so those headings **stop scaling while their own body copy
keeps scaling** — hierarchy inverts as text grows. Make it relative.

**W2.4 — Raise the caveat floor.** Honesty caveats render at 8 pt at
`MarketsView.swift:6974` — below the 11 pt floor this codebase itself ratified, and
smaller than the figure they disqualify. Nothing that qualifies a number may be
smaller than the number.

**W2.5 — `monospacedDigit()` on every changing figure.** `ideaMetric`
(`MarketsView.swift:9592`) — the renderer for every money figure on the ideas surface —
has none, while its own siblings do, so columns jitter on each tick. Same for the
iPhone symbol row (`:4451`).

**Acceptance:** W0.3 passes at `.accessibility3` on all five extracted components;
a screenshot at accessibility-extra-large shows a legible ticker and a readable sheet.

**Effort:** L, but almost entirely mechanical once W2.1/W2.2 land.

---

### W3 — Fix colour and depth *(fixes RC3 + the §3.2 contrast failure)*

**W3.1 — Honour the palette's own rule.** Replace `foregroundStyle(DS.Palette.accent)`
with `accentText` at the 115 text/icon sites. Keep `accent` for **fills, tints and
control chrome** — which is what the comment at `DesignSystem.swift:36` already says.
Brand hue unchanged. This alone moves the app from 3.19:1 to 6.52:1 on cards.

**W3.2 — Stop using the control accent for financial values.** "Base size 20.0%"
(`MarketsView.swift:3862`) must not be the same colour as an interactive control.

**W3.3 — Give surfaces real separation.** `cardFill` at 1.13:1 against the canvas is
below perceptual threshold. Either raise the card fill, or re-enable elevation — the
four `DS.Elevation` tokens exist, are tuned for this canvas, and have **zero**
consumers. Pick one and apply it consistently; do not do both.

**W3.4 — Delete the traps.** Remove `Palette.warning` (0 consumers, 236 uses of
`warningSoft` instead), `Palette.accent2` (identical to `accent`), and
`Gradient.brand` (a "gradient" between a colour and itself). Or, if the gradient is
wanted, give `accent2` a genuinely different value.

**W3.5 — Fix the signal meter.** The 5-block strength meter is 1.51:1
filled-vs-unfilled (`MarketsView.swift:9747`) — the bar visible in every screenshot
conveys nothing. Needs ≥3:1.

**W3.6 — Reconcile the two "darks".** The system `More` list renders `#000` against
the app's `#181819` canvas. Either theme the list or accept it explicitly in a comment.

---

### W4 — Build the component layer *(fixes RC1)*

**W4.1 — One `SectionCard`.** ~35 inline re-implementations with 5 insets and 2 fills
for one visual role. `DesignSystem.swift` already ships a `Card` type — with **zero
consumers**. Make one canonical card, migrate the 35 sites, delete the drift.

**W4.2 — One `Chip`.** The card header is 6+ ad-hoc chips. One component, one set of
states (neutral / caveat / positive / negative), correct intrinsic sizing (W1.1's fix
belongs here permanently), one accessibility treatment.

**W4.3 — One `Metric`.** label + value + optional unit + optional info affordance,
`monospacedDigit`, fixed column behaviour, `accessibilityValue` wired.

**W4.4 — Fix `LuxPressStyle`.** It never reads `\.isEnabled`, so 5 disabled custom
CTAs render identically to live ones (`DesignSystem.swift:166`). I saw this on the
Portfolio screen: a grey "Add holding" button with no indication of why it is inert.

**W4.5 — Adopt the two good precedents.** `DSSegmentPicker` for compact choices;
the Home `icon / title / subtitle / chevron` row as the base for list rows.

**Effort:** L. **Do this after W2 and W3** — migrating 35 cards is far cheaper once
the type and colour tokens underneath are already correct.

---

### W5 — Rebalance honesty against content *(fixes RC5 — the design problem, not the honesty)*

This is the highest-judgement workstream and the one to get owner sign-off on before
building. **Nothing here removes information.**

The current state, measured: on iPhone Ideas, ~250 pt of orange caveat renders above
the first idea; the detail sheet opens on ~10 lines of disclaimer; at accessibility
sizes the sheet is entirely disclaimer. Caveats are rendered at the *same or greater*
visual weight than the data they qualify, in the app's alarm colour, permanently expanded.

**PROPOSAL — a three-tier caveat model:**

- **Tier 1 — inline, always visible, subordinate.** One short qualifier bound to the
  number it qualifies (`+0.56R gross · net ≈ +0.52R`, `win% assumed`). Smaller weight
  than the figure but never below the 11 pt floor, and never in alarm orange unless it
  is genuinely an alarm.
- **Tier 2 — one persistent, collapsed affordance per surface.** A single "How this
  board is built" row (which already exists) that owns the methodology paragraphs.
  Expanded state persists per user.
- **Tier 3 — the legal/blanket disclaimer.** Once per surface, at the bottom, or in a
  footer that does not occupy the primary reading position.

Then reclaim the space for the decision: on the card, the **rules verdict** and the
**net R:R** should be the two loudest things. Today (§2.4 screenshot) the loudest
element is an `AI unavailable` chip and the actual verdict — `Rules: Strong Buy` — is
grey caption text underneath it. **The unvalidated signal outranks the validated one.**

Also in scope here (SOURCE, confirmed): ~135 honesty caveats are hover-only `.help`
(`Views/ExecutionQualityPanel.swift:66` et al) and are therefore **invisible to every
iPhone user**. That is an honesty-floor gap, not a polish item — a caveat a touch user
can never see is not a caveat. Fixing it belongs here.

**Owner decision required before building W5.** Do not implement on your own judgement.

---

### W6 — Navigation and IA

**W6.1 — Promote the product.** "Ideas" must not be behind **More** (§2.4).
**PROPOSAL** for the four iPhone tabs: **Ideas · Research · Watchlist · Chat**, with
Home either merged into Ideas' top block or taking Research's slot. Owner decision.

**W6.2 — Reduce 11 routes.** `watchlist`, `all`, `ideas`, `briefing` and `research`
are five top-level routes over one job: *find something worth trading*. Merging even
two would empty the More list. Owner decision.

**W6.3 — Fix the keyboard map.** `⌘1…9` follow `MarketSection.allCases` order while the
sidebar shows a different order, so the **first sidebar item is ⌘9**, the **second
(Research) has no shortcut at all**, and neither does Legacy paper history. The code
comment concedes the tooltip is "the only discovery path". Assign shortcuts in sidebar
order and surface them in the menu bar, where macOS users look.

**W6.4 — Name things once.** `MarketSection.title` says "Briefing" and "All";
`workspaceTitle` overrides to "Home" and "Markets". Two names per route in one file.
Pick one each.

**W6.5 — The build is `StockSageX.app`** with display name "StockSageX", while every
document and in-app string says "StockSage" (`project.pbxproj:468`). Decide and align.

**W6.6 — macOS minimum width.** Reconsider `minWidth: 900` (§2.6) so the app can be
tiled; and give the ideas board a max content width like the detail sheet's 680 pt.

---

### W7 — Rendering cost and state *(independent of W1–W6; can run in parallel)*

Confirmed by multiple independent reviewers:

- `StockSageLiveStream.swift:330` fires `objectWillChange` **4×/s unconditionally**,
  re-rendering all of `MarketsView` — whose 105 state properties share one invalidation
  scope (`MarketsView.swift:493`).
- `displayedIdeas` — a full-board EV re-rank — is recomputed inside `ideasHeader`
  **only to decide whether to show a button** (`MarketsView.swift:4927`).
- `.task(id:)` rebuilds and sorts the whole 901-symbol tracked union on **every body
  evaluation** (`MarketsView.swift:512`).
- Collapsed `DisclosureGroup`s still pay full engine cost per render (`:4728`).
- Price text animates for 450 ms while the feed republishes every 250 ms, so digits
  never settle (`:4432`).

The W0.2 extractions are the same work as fixing this: pulling a component out of the
monolith gives it its own invalidation scope. **Sequence W7 to ride along with W0.2.**

---

### W8 — Repo hygiene *(do this before anything else if Codex is the executor)*

**W8.1 — `agent-docs/STATUS.md` is actively misleading and will waste an agent's time.**
Verified: it instructs the next agent to add four files to the Xcode project —
`HapticFeedback.swift`, `PullToRefresh.swift`, `iPadLayout.swift`, `TradePnLTests.swift`.
**Three of the four do not exist anywhere in the repo.** It also describes a "black
screen fallback" as current work. The file's mtime is 2026-09-12, so it reads as fresh.
Delete it or stamp it `HISTORICAL — DO NOT ACT ON`. Same treatment for
`URGENT_FIX.md`, `BUILD_FIX.md`, `QUICK_START.md`, `IMPLEMENTATION_SUMMARY.md`,
`CLAUDE_HANDOFF.md` (all 2026-09-08 or older, all written as current).

**W8.2 — Add a documentation index.** 27 files in `agent-docs/`, three of which claim
to be "status", plus two competing HANDOFFs, and README's only pointer is a 6,193-line
append log. State in README which **two** documents are authoritative.

**W8.3 — Correct README.** It says "a standalone **macOS** app" and "84 files";
the repo ships macOS **and** iOS (`TARGETED_DEVICE_FAMILY = "1,2"`), a widget
extension, Chat, paper automation, research modes and a local model server, across 122
source files. Its code map omits `App/`, `DesignSystem/` and `StockSageWidget/`.

**W8.4 — State the product gap plainly.** `AGENTS.md` sets the objective as placing
real BUY/SELL orders via Derayah with cancel/modify and order tracking. The 2026-09-12
audit found **no executable broker adapter or submission client in the checkout**, and
onboarding says the app prepares orders but never places them. That is a coherent and
defensible position — but it appears in no entry-point document, so every new agent
rediscovers it. Say it in README.

---

## 5. Suggested sequencing

| Phase | Contents | Rationale |
|---|---|---|
| **0** | W8.1, W8.2 | 30 minutes; stops the executor being actively misled |
| **1** | **W0** | Everything downstream is unverifiable without it |
| **2** | W1 (all), W3.1, W3.2, W3.4 | Small diffs, largest visible payoff, already-proven anchors |
| **3** | W2, W3.3, W3.5, W3.6 | System-level; mechanical once W2.1/W2.2 land |
| **4** | W4, W7 | Component layer + invalidation scope; same extractions |
| **5** | W5, W6 | **Owner decisions first.** Judgement, not defects. |

Phases 0–2 are pure defect repair and need no design sign-off. **Phase 5 must not be
started without the owner.**

---

## 6. What I did not check

Stated plainly so nobody reads this as broader than it is.

- **VoiceOver was not run.** The a11y section is a source census plus contrast maths,
  not a screen-reader session. The `accessibilityValue`=7 figure is a count, not a
  transcript.
- **No physical device.** iPhone 17 Pro simulator only; no iPad, no other size class.
  `TARGETED_DEVICE_FAMILY = "1,2"` claims iPad support that I did not exercise.
- **No live-data screens.** The feed showed "Feed stopped"/"not live" throughout, so
  fully-populated Catalysts, Heatmap, Chat and Alerts were not seen with real data.
  The Ideas board was mid-scan (680/901) in most captures.
- **Engine, money maths, provider correctness, security: not my scope here.** The
  reviewers surfaced items (a 2026-hardcoded US session calendar at
  `StockSageMarketHours.swift:109`; credentialed Massive requests on
  `URLSession.shared` with no redirect/host check at `StockSageMassive.swift:227`) that
  survived adversarial refutation at P2. **They are listed for triage, not diagnosed
  by me.** Confirm independently before acting.
- **I did not run the test suite.** Test counts quoted are from the repo's own handoffs.
- **macOS light appearance was not tested** (changing it affects the owner's machine).
  iOS light-mode was, and the app force-overrides to dark on both.

---

## Appendix A — Why "read the source" was not enough (calibration data)

Alongside the live session, 13 independent reviewers each audited one dimension of
the source, and a **second** reviewer then tried to refute every finding by opening the
cited line. Results:

| | |
|---|---|
| Findings filed | **85** |
| CONFIRMED (survived adversarial refutation) | **19** |
| WEAKENED (real, but narrower or less severe) | 56 |
| REFUTED (wrong, or a documented deliberate choice) | 10 |
| Surviving at **P1** | **2** — both rendering-cost, both in Appendix B |

**The finding that matters most about this table is what is not in it.**

The four-line hyphenated chip (§2.1) — the most visible defect in the app, on its
headline screen, at default text size — **was not filed by any of the 13 reviewers.**
One reviewer opened `StockSageAIAssessmentView.swift:13` and filed a *semantic*
issue (the AI badge outranking the rules verdict — a real finding, kept in Appendix B).
It read the `.fixedSize(horizontal: false, vertical: true)` on line 18 and did not see
what it does on a 402 pt screen.

Likewise, one reviewer opened `ideasHeader` at line **4927** and filed a performance
finding — walking past the `VStackLayout` on line **4919** that stacks three buttons
down the page (§2.2).

Neither the accessibility-size collapse (§2.3) nor the navigation burial (§2.4) appears
in any of the 85.

**Reading Swift tells you what the code says. Only running it tells you what the user
sees.** That is the whole case for W0, and it is why W0 is sequenced first.

Conversely, the source review found things pixels never could — the dead
`bestOpportunityCTA`, the 4×/s invalidation storm, the 2026-hardcoded calendar. **The
two methods are complements, and this repo has only ever used one of them.**

---

## Appendix B — Triage list (source findings that survived refutation)

Verdicts are the adversarial reviewer's, not the finder's. Severities are post-refutation.
**Confirm each independently before acting** — I did not personally verify these.

### Rendering cost — the only surviving P1s

| Verdict | Finding | Anchor |
|---|---|---|
| CONFIRMED **P1** | Live-feed publisher fires `objectWillChange` 4×/s unconditionally, re-rendering all of `MarketsView` | `StockSageLiveStream.swift:330` |
| CONFIRMED **P1** | `displayedIdeas` (a full-board EV re-rank) is recomputed in `ideasHeader` **only to decide whether to show a button** | `MarketsView.swift:4927` |
| CONFIRMED P2 | `applyLiveNBBO` rebuilds and deep-compares the entire ideas array every 250 ms | `StockSageStore.swift:2703` |
| WEAKENED P2 | `StockSageStore` is a 72-`@Published` singleton mixing scan orchestration, persistence, derivation and presentation; any field invalidates all 12 observing views | `StockSageStore.swift:116` |
| WEAKENED P2 | `.task(id:)` rebuilds and sorts the whole 901-symbol tracked union on every body evaluation | `MarketsView.swift:512` |
| WEAKENED P2 | Collapsed `DisclosureGroup`s still pay full engine cost per render | `MarketsView.swift:4728` |

### UI / design (feeds W1–W5)

| Verdict | Finding | Anchor |
|---|---|---|
| CONFIRMED P2 | `bestOpportunityCTA` — 143 lines of unreachable view. `11d63c9` deleted the one render site; four live comments still claim it renders | `MarketsView.swift:7115` |
| CONFIRMED P2 | `ideaMetric`, the renderer for every money figure on the ideas surface, has no `monospacedDigit` while its siblings do | `MarketsView.swift:9592` |
| CONFIRMED P2 | Signal meter is 1.51:1 filled-vs-unfilled — strength invisible | `MarketsView.swift:9747` |
| CONFIRMED P2 | iPhone-only controls miss the 44 pt touch floor that the repo's own `touchHitArea()` shim exists to enforce | `MarketsView.swift:8970` |
| CONFIRMED P3 | `touchHitArea()` documents "≥44pt on iOS" but delivers ~35–38 pt at caption sizes | `PlatformShims.swift:36` |
| CONFIRMED P3 | Three typography roles alias one token — section headers and metric values are indistinguishable | `MarketsView.swift:106` |
| CONFIRMED P3 | `Card` and `Eyebrow` are dead, directly under a comment claiming the dead-component sweep was verified | `DesignSystem.swift:147` |
| CONFIRMED P3 | Dead `Eyebrow` ships a contrast-failing accent-on-accent recipe (2.71:1) for a future author to copy | `DesignSystem.swift:177` |
| WEAKENED P2 | `DS.Typography.titleM` is fixed-size — 9 panel headings stop scaling while their body copy keeps scaling | `DesignSystem.swift:68` |
| WEAKENED P2 | Honesty caveats render at 8 pt — below the 11 pt floor this file ratified | `MarketsView.swift:6974` |
| WEAKENED P2 | ~135 honesty caveats are hover-only `.help`, invisible to every iPhone user | `ExecutionQualityPanel.swift:66` |
| WEAKENED P2 | Live-feed toolbar button's `accessibilityLabel` is a ~120-word diagnostic dump, spoken twice | `MarketsView.swift:1146` |
| WEAKENED P2 | Reduce Motion honoured at 1 of 40 animated sites (independently measured: 39 vs 2) | `MarketsView.swift:398` |
| WEAKENED P2 | No canonical card: chrome re-implemented ~35× with 5 insets and 2 fills | `DesignSystem.swift:147` |
| WEAKENED P2 | `LuxPressStyle` never reads `\.isEnabled` — 5 disabled CTAs look live | `DesignSystem.swift:166` |
| WEAKENED P2 | `PriceFlash` encodes tick direction in hue alone — 1.10:1 luminance between up and down | `DesignSystem.swift:226` |
| WEAKENED P2 | Ideas board is one full-width column to ~1152 pt while the detail sheet caps at 680 pt "for readability" | `MarketsView.swift:4721` |
| WEAKENED P3 | `DS.Space` governs ~28% of spacing; most-used value (6 pt, 128 sites) is not on the ladder (independently measured: 25%) | `DesignSystem.swift:7` |

### Data / provider / security — **not my scope; verify before acting**

| Verdict | Finding | Anchor |
|---|---|---|
| WEAKENED P2 | US session calendar hard-coded to year 2026; on 2027-01-01 every US symbol loses its % change and its signal | `StockSageMarketHours.swift:109` |
| CONFIRMED P2 | `approxAmount`/`signedAmount` print a raw exchange suffix as a currency code, contradicting the contract stated in the same file | `StockSageCurrency.swift:160` |
| WEAKENED P2 | Credentialed Massive requests use `URLSession.shared` — redirects followed, response host never checked | `StockSageMassive.swift:227` |
| WEAKENED P3 | A failed Massive snapshot chunk fans out into up to 250 keyless Yahoo requests with no Massive-side backoff | `StockSageMassive.swift:228` |
| WEAKENED P2 | Catalysts explanation backend accepts any public https host; the only guard is worded as a LAN caveat | `StockSageLocalModelServer.swift:295` |
| WEAKENED P2 | Idea alert notification body prints the exact share count — readable on a locked Lock Screen | `StockSageMonitor.swift:523` |

### Testing

| Verdict | Finding | Anchor |
|---|---|---|
| WEAKENED P2 | Honesty-floor guards pass on any prose containing `"not "` — including an over-promise | `StockSageGlossaryTests.swift:27` |
| WEAKENED P2 | Two of eleven routes (`heatmap`, `paper`) are never mounted by any test; both audits hard-code their route lists | `StockSageChatTests.swift:193` |
| WEAKENED P3 | The macOS whole-page render audit writes a PNG per route and asserts nothing about it | `StockSageChatTests.swift:1495` |
| WEAKENED P3 | 23 derivation scripts backing hand-derived financial fixtures live in `/tmp`, not in the repo | `StockSageRankScoreTests.swift:9` |
| WEAKENED P2 | The ideas-board perf guard models a render graph that no longer exists, with a bound ~200× too loose to catch a regression | `StockSagePerfProbeTests.swift:165` |

The 10 REFUTED findings and the remaining P3s are in the run journal:
`~/.claude/projects/-Users-saleh/…/workflows/wf_b519c54d-317/journal.jsonl`

---

## Appendix C — Reproducing the visual evidence

```bash
# 1. build for the simulator
xcodebuild -scheme StockSage -destination 'generic/platform=iOS Simulator' \
  -configuration Debug -derivedDataPath /tmp/ss-dd CODE_SIGNING_ALLOWED=NO build

# 2. boot, install, launch
xcrun simctl boot 3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA
xcrun simctl install booted /tmp/ss-dd/Build/Products/Debug-iphonesimulator/StockSageX.app
xcrun simctl launch booted SA.StockSageX

# 3. §2.1 / §2.2 — More > Ideas, scroll one screen
xcrun simctl io booted screenshot ideas.png

# 4. §2.3 — the accessibility collapse
xcrun simctl ui booted content_size accessibility-extra-large
xcrun simctl io booted screenshot ax.png
xcrun simctl ui booted content_size large

# 5. §2.5 — light mode is ignored
xcrun simctl ui booted appearance light
xcrun simctl io booted screenshot light.png
xcrun simctl ui booted appearance dark
```

macOS minimum-width check (§2.6):

```bash
osascript -e 'tell application "System Events" to tell application process "StockSageX" \
  to tell window 1 to set size to {500, 600}'
osascript -e 'tell application "System Events" to tell application process "StockSageX" \
  to get size of window 1'   # -> 900, 740
```

Contrast figures in §3.2 are WCAG 2.1 relative luminance computed directly from the
literal values in `DesignSystem.swift`; the token census in §3.1/§3.3/§3.4 is a
`grep -F` count over `StockSage/Sources` excluding `DesignSystem.swift`.
