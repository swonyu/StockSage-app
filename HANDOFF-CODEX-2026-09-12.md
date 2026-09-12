# Handoff — StockSage critique fix-plan, 25 of 26 findings landed

Written 2026-09-12 by the Claude Code session that did the work, for whoever picks this up next
(Codex or another agent). Everything below is verified, not assumed; where something is unproven
it says so.

## Where things stand

| | |
|---|---|
| Worktree | `/Users/saleh/StockSage-wt/opus-harness` (git worktree — do NOT `cd` to the main checkout) |
| Branch | `claude/model-harness-2026-09-10` |
| HEAD | `0453c31` — **pushed** to `origin` (`swonyu/StockSage-app`) |
| `origin/main` | `68664bf` — **12 commits behind**, merge deliberately NOT done yet |
| Gate at HEAD | 2174 tests / 215 suites pass (macOS), iOS Simulator build succeeds |
| Findings | 25 of 26 done. **D4 is the only one left.** |

## The one remaining task: D4

Full spec, with verbatim anchors, is in
`/Users/saleh/StockSage-harness-20260910.opus/specs/D4-portfolio-widget-currency.md`.

`StockSage/Sources/App/PortfolioWidget.swift` is ~340 lines of unreferenced code that nonetheless
compiles into the app target (a WidgetKit widget cannot render from there). It has a hardcoded-USD
portfolio sum — wrong for the owner's Saudi holdings — and a device-local "market hours" check.

**The owner chose "Keep and fix its currency", NOT delete.** Repair the sum to the app's real
convention (`StockSageCurrency` + an FX rate map — match what the shipped widget does, do not
invent a second convention), fix the market-hours check, and add an UNWIRED header note so nobody
wires it up believing it is maintained.

## Owner decisions made during this run — do not silently reverse any of these

| Decision | Chosen | Why it matters |
|---|---|---|
| 4b, cap-suppressed alerts | **Re-fire** | Reverses the 2026-07-28 anti-flood latching. A later agent reading only that older instruction would "restore" the latching and undo it. Also recorded in `~/.claude/projects/-Users-saleh/memory/stocksage-alert-refire-approved.md`. |
| 7.2, breadth | **60% coverage floor** | Below 9-of-14 names fetched, breadth abstains rather than printing a percentage from a partial sample. |
| 12.3, alert casing | **Engine-side lookup fix** | NOT the plan's restore-boundary normalization, which leaves on-disk alerts dead and inverts a purpose-built pinned test. |
| 5.1, weekly-R history | **Fix + mark old days** | Not a series reset. `VelocityMetricBasis` discriminator; old rows kept, excluded from comparison. |
| D4 | **Keep and fix currency** | Not delete. |

## The gate situation — read this before merging to main

**The full 2,244-test suite cannot run clean on this Mac right now, and it is not this branch's
fault.** Ten suites fail on wall-clock timing and NSWindow hosting regardless of the code:

```
StockSageCorrelationPresentationTests  DesignSystemAccentTests  DesignSystemMotionTests
MarketSectionNavigationTests           StockSageChatTests       StockSageNewsOutcomeTests
StockSageBenzingaClientTests           StockSageFeedIngressTests
IdeaDetailEvidenceTests                IdeaDetailLifecycleTests
```

Proven by control run, same machine, same load: unmodified `68664bf` failed with **109 issues**
where this branch failed with **9**, and two successive runs of the same binary failed in
*disjoint* suites. Representative signatures: `quarterSecondPublicationCoalescesWithoutAccumulating
Snapshots` asserting a 1.0s wall-clock budget and measuring 1.21s; `bitmapImageRepForCachingDisplay
(in: (0,0,0,0)) → nil`; `ready()` timing out at 49s. Load average held ~7.5 throughout (Chrome,
ChatGPT, Xcode, DeviceHub, a live-wallpaper Python host).

Every gate figure in the commit messages is the reduced run. **Before advancing main, re-run the
complete suite on a quiet machine** so main is not fast-forwarded on a partial gate.

Gate command actually used:

```bash
cd /Users/saleh/StockSage-wt/opus-harness && xcodebuild test \
  -project StockSage.xcodeproj -scheme StockSage -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stocksage-opus-dd \
  -skip-testing:StockSageTests/StockSageCorrelationPresentationTests \
  -skip-testing:StockSageTests/DesignSystemAccentTests \
  -skip-testing:StockSageTests/DesignSystemMotionTests \
  -skip-testing:StockSageTests/MarketSectionNavigationTests \
  -skip-testing:StockSageTests/StockSageChatTests \
  -skip-testing:StockSageTests/StockSageNewsOutcomeTests \
  -skip-testing:StockSageTests/StockSageBenzingaClientTests \
  -skip-testing:StockSageTests/StockSageFeedIngressTests \
  -skip-testing:StockSageTests/IdeaDetailEvidenceTests \
  -skip-testing:StockSageTests/IdeaDetailLifecycleTests
```

iOS build (6.2 is an iOS fix — this is its real gate):

```bash
cd /Users/saleh/StockSage-wt/opus-harness && xcodebuild build \
  -project StockSage.xcodeproj -scheme StockSage -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/stocksage-opus-ios
```

Use your own `derivedDataPath` — another agent shares this repo.

## Owner-visible behaviour changes shipped (the owner has been told each one)

- **5.1** "≈ +$N/week" moves in BOTH directions by up to ~20% depending on lane mix.
- **8.1** "Assumed (this book)" drops 30 → 15 bps/leg on a Saudi book, so fills read relatively
  *worse* than before. That is the correction, not a regression.
- **B3** a name that read "Diversifying" may now read "Concentrating"; the "you already own this
  bet" row can be absent.
- **9.1/9.2** the "index flow?" chip can fire on mega-caps for the first time; a stale volume item
  stops outranking a real earnings date.
- **5.2** new "Cap cut · N not funded" chip on the Deploy-capital card.
- **4a** new held-back-alerts line in the Signal-alerts panel.
- **B2** widget shows an honest age where it used to show "just now".

**Visual QA has NOT been done** for any of these. Tests are green; pixels are unverified.

## Method notes worth keeping

- Every finding was verified against current source and then **adversarially reviewed**. Six edit
  specs had blocking defects and four would have shipped NEW dishonesty (per-poll counter inflation,
  a corrupted trend series, "Scheduled / estimated" on undated rows, "prices less than a minute old"
  on a days-stale board). The adversarial pass is what caught them — keep it.
- Two of my own errors were caught by tests, not review: `Optional.map` turning `Some(nan)` into
  `Some(false)` (use `flatMap` when the closure contains a validity predicate), and a staleness
  assertion that contradicted the truncating arithmetic I had just documented.
- Full verified findings + their edit specs: `.../specs/findings-verified-2026-09-11.json`.
  Weekly-R design alternatives + judgements: `.../specs/weeklyr-designs-2026-09-12.json`.
- Source plan: `/Users/saleh/StockSage-harness-20260910.opus/FIX-PLAN-2026-09-11.md`. Note its line
  numbers are stale and several of its edit specs are wrong — the JSON above supersedes it.

## Still open from the earlier critique (never triaged into the plan)

Labelling the widget heat as **paper** on the widget face; a cached-vs-live flag on the widget
snapshot; the earnings race at `StockSageStore.swift:2146`; cached-board banner aging by file write
clock (`MarketsView.swift:799`); stale-row hover tooltip; AI assessment failing on WhatsApp-lead
symbols; Massive key in preferences rather than Keychain.
