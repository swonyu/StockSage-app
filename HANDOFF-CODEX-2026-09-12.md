# Handoff — StockSage critique fix-plan, 25 of 26 findings landed

**Current Codex continuation:** D4, the reliability review and date-relevant research
selection were previously published at `e576d70c6fd3d4cc3f5a94d47cb3f61635bb91fa`.
The owner's subsequent missing-model recovery, normal-quit model unloading and Research
screenshot fixes are now implemented, verified and reversibly installed. The owner then
requested commit and push of this continuation on `claude/model-harness-2026-09-10` to
`swonyu/StockSage-app`; no new merge to main is part of that request. Worktree:
`/Users/saleh/StockSage-wt/opus-harness`; preserve sole writer/tester/installer ownership.
Use current Git history and the remote branch to verify publication, not an older receipt.
Read `agent-docs/MODEL_DOWNLOAD_2026-09-12.md` for the current receipt and explicit limits:
Mac **2,381 tests / 227 suites**, iPhone simulator **2,300 / 223**, both passed after the
final source change. `/Applications/StockSageX.app` now matches the final Mac-tested bundle;
the blank Research toolbar strip was checked in the running app and both horizons exercised.
Protected preferences, paper records and chat history were unchanged across replacement.
Rollback copies and the installation receipt are in
`/Users/saleh/Codex-Backups/stocksage-model-update-20260912.pes0mT`.
The earlier "D4 open", installed-app-unchanged and reduced-gate sections below are preserved
as history, not current release status. Do not repeat an earlier push or restore old data
over the current app state by inference.

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

## Codex D4 continuation — 2026-09-12

Starting state verified: clean worktree `/Users/saleh/StockSage-wt/opus-harness`, branch
`claude/model-harness-2026-09-10`, HEAD `ccee332` (the handoff commit after `0453c31`).
This task owns the local D4 edits and its isolated tests. No other findings were reopened.

The newer owner decision **KEEP and repair** overrides the deletion instructions in the
older D4 spec. The file is retained and remains outside the shipping widget extension.

Changes:

- `StockSage/Sources/App/PortfolioWidget.swift`: its real entry builder is now testable on
  both platforms. Convert each signed P&L using `conversionCurrencyForSymbol`,
  `majorUnitValue`, and the store's `fxConversionToUSD` rates. USD is the app's portfolio
  base, not a label applied to a sum of raw currencies. All three layouts render estimated
  USD explicitly, including cents. Missing/invalid marks or FX (and numeric overflow)
  withhold the total instead of substituting entry price, zero, or a partial sum.
- R rankings remain dimensionless and side-aware; missing/undefined marks are not 0R.
  A single measured position is no longer also listed as worst performer.
- Refresh scheduling reuses `StockSageStore.marketIsTrading`: held venues, US pre/after-hours,
  DST, and the existing holiday/early-close calendar. No device-local hour heuristic remains.
- An **UNWIRED** header names the shipping extension and explicitly defers snapshot transport,
  age/source labels and navigation before activation. `agent-docs/STATUS.md` now says the same.
- `StockSageTests/PortfolioWidgetTests.swift`: six regression tests with 22 input cases covering
  USD/SAR/GBP-pence/ZAR-cents/FX quote legs, shorts, missing/invalid/overflowing rates and marks,
  empty/one/two-position books, and session boundaries. No owner journal data is used.

Executed validation (Xcode 26.6, build 17F113):

- RED: the original arithmetic/timing was mechanically extracted without fixing it; the
  regression suite failed with **28 issues**. Mixed book: **1,647.50 instead of 126.75 USD**.
- GREEN macOS arm64: **62 tests in 5 suites passed** (0.054 s test execution).
- GREEN iPhone 17 Pro (gate), iOS 26.5 simulator: app + widget extension built, and
  **62 tests in 5 suites passed** (0.071 s test execution).
- Full macOS, **no skips**: **2,326 tests in 226 suites, 3 issues** (76.911 s).
  `MarketSectionNavigationTests.testHostDoesNotPresentAnApplicationWindow` found an NSWindow;
  `IdeaDetailEvidenceTests.benzingaLateCompletionRequiresCurrentOwnershipAndReceipt`
  failed `probe.allStarted(1)` for cancellation;
  `DesignSystemMotionTests.luxPressOnlyScalesWhenReduceMotionIsOff` measured identical
  resting/pressed pixels. These are in the UI/timing families identified above; this is
  **not a clean release gate**. No test was skipped or weakened to hide them.
- Independent Astra source review: **no material findings**; review was read-only.
- Final `tools/gate.sh . all`: **`GATE repo=. macos=OK ios=OK tests=OK`**, exit 0.
  macOS emit 98 s, iOS emit 84 s, test-source typecheck 155 s. This is compile/typecheck
  evidence; it does not turn the full executed macOS suite's three failures into passes.

Evidence directory: `/private/tmp/stocksage-d4-codex-KfDey5/` — `red.log`,
`red-missing.log`, `green.log`, `full-mac.log`, `ios.log`, corresponding `.xcresult` bundles,
and `compile-gate.log`. Each Xcode invocation used its own `mac`/`ios` derived-data directory
inside this directory, never another session's build products. Focused suites selected with
`-only-testing:StockSageTests/` followed by `PortfolioWidgetTests`, `StockSageCurrencyTests`,
`StockSageMarketHoursTests`, `StockSageWidgetSnapshotTests`, and `TradePnLTests`.

Changes are local and uncommitted. No merge, push, installed-app replacement, project-file
edit, widget registration, or historical-record edit. The running installed app was preserved.
No live widget-gallery/pixel QA was claimed: this component intentionally remains unwired.
The complete release gate and the earlier shipped changes' visual QA remain open as above.

## Full-app review continuation — Codex, 2026-09-12

Owner requested a full critique, a plan, and implementation of verified findings.
The same worktree/branch remains in use, with HEAD `ccee3329b92e90b7e1029f37d56e838878fef720`.
Preserved D4; the lead remained sole writer/tester, with three read-only Astra reviewers.
Good-spender remains removed. No new commits, pushes, merges, broker/relay activation,
paid services, live probes, model weight/risk changes, or historical-record edits.

- Plan: `docs/superpowers/plans/2026-09-12-stocksage-full-review.md`.
- Critique, all 22 findings, implementation/evidence/policy limits:
  `agent-docs/FULL_APP_REVIEW_2026-09-12.md`.
- Highest-priority fixes: previous-close provenance and independent REST repair; closure
  conflicts and cross-process record ownership; retained exit-history coverage; correct
  minor-currency fees and explicit severe-gap paper costs; Qwen deadline/cancellation/
  settings ownership; source/date-aware research caches; verified Keychain migration;
  honest widget/briefing/cache status and test-window isolation.
- Existing research-only horizons, extended-session behavior, strategy/risk parameters
  and native paper-account boundaries remain intact. No new trading capability added.

Final native tests (not cumulative):

| Gate | Result | Evidence stem |
|---|---|---|
| macOS arm64 | **2,356 tests / 225 suites passed**, 91.066 s test execution, exit 0 | `full-mac-final2` |
| iPhone 17 Pro (gate), iOS 26.5 | **2,281 tests / 221 suites passed**, 71.264 s, exit 0 | `full-ios-final` |
| `tools/gate.sh . all` | **macos=OK ios=OK tests=OK**, exit 0; 84 s / 75 s / 140 s | `compile-gate-final.log` |
| Python offline research | **17 passed, one optional LightGBM test skipped** out of 18, exit 0 | `python-research.log` |

Evidence root: `/private/tmp/stocksage-full-review-20260912-6Oi5VM/`. Native artifacts
include both `.log` and `.xcresult`; compile logs are under its isolated `compile/` tree.
Xcode 26.6 (17F113), host macOS 27.0. No iOS 27 runtime or physical-device gate claimed.
Both native commands used `xcodebuild test -project StockSage.xcodeproj -scheme StockSage
-parallel-testing-enabled NO`; Mac destination `platform=macOS,arch=arm64`, iPhone
`platform=iOS Simulator,id=3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA`.
Only README opt-in diagnostics were excluded: `CalibrationPersistRunTests`,
`LiveUniverseVerificationTests`, `StrategyBaselineMeasurementTests`. DerivedData remained
lead-owned `/private/tmp/stocksage-d4-codex-KfDey5/mac` and `/ios`; no concurrent heavy gates.

Source, existing fixture and final bounded data/model/persistence reviews are complete.
Installed/native live pixels are **not** signed off: the supported app connection repeatedly
closed its native pipe. Synthetic narrow controls are readable, but an offscreen split-view
capture has an unresolved mixed-appearance artifact. No speculative production color fix
was made to hide that uncertainty. Actual owner Keychain migration, live entitlements/model
performance and widget gallery were not exercised. See the critique's explicit limits.

`/Applications/StockSageX.app` was neither replaced nor restarted; its observed PID remains
18128. Executable SHA-256: `003d801f764e80412731877e9a69b6e846f8cfa8bf2d37614d611a191302ea31`.
This running binary is not claimed to contain the new fixes. Installation requires a separate
normal-quit, protected-data/compatibility check and verified handover; never run cooperating
new and uncooperative old builds against the same records. The new legacy-paper cost field
is not understood by older binaries, and multi-key backup restore is not crash-atomic.

Before continuing: recheck branch/dirty paths/process ownership and current receipts; do not
reapply old findings, launch duplicate writers, overwrite owner state or treat old pushed
commits as these changes. D4 is still deliberately unwired, not a newly activated widget.

## Research-selection and release continuation — 2026-09-12

Both **1–7** and **7–14 trading-day** modes now select up to 500 confirmed-USD active US
listings by observed traded dollar volume (volume × VWAP), descending, before the cap.
Alphabetical order only breaks equal-activity ties. This is a transparent activity proxy,
not a social-popularity score or an investment recommendation. Existing per-stock
news/Benzinga/Qwen research runs afterward. The day-paper scanner is unchanged.

Every manual Run fetches the active directory and a dated Massive grouped market summary.
NY trading dates, 04:00 boundaries, holidays, DST and bounded prior-session fallback use
the existing calendar. If current-day coverage is under 500, a preceding session is used
only when its verified eligible count is greater. No mixed-session ranking or alphabetical
padding. The current published calendar supports 2026; unsupported dates fail closed.

The scan and detail preserve the selected session, request time, coverage and activity
basis. Invalid/empty source data cannot replace a prior run. Cancellation and settings
revision checks prevent stale requests from publishing. Research-only, one-shot behavior,
completed-history checks, price levels and model/risk parameters remain unchanged.

Design and implementation receipt:
`docs/superpowers/specs/2026-09-12-relevant-research-universe-design.md` and
`docs/superpowers/plans/2026-09-12-relevant-research-universe.md`.

Final source SHA-256 (sorted per-file hashes for Swift/Python/gate sources in
`StockSage/Sources`, `StockSageTests`, `StockSageWidget`, `tools`):
`37e28663854f5e16144f1b9fe5231378635828de8027a47840d2ba2727eaeb11`.

Latest native gates supersede the earlier counts for release verification:

| Gate | Result | Evidence stem |
|---|---|---|
| macOS arm64 | **2,365 tests / 226 suites passed**, 86.004 s, exit 0 | `relevance-full-mac` |
| iPhone 17 Pro (gate), iOS 26.5 | **2,290 tests / 222 suites passed**, 70.306 s, exit 0 | `relevance-full-ios` |
| Focused universe/horizon/chat | **71 tests / 3 suites passed**, 8.464 s, exit 0 | `relevance-focused3` |
| Strict compile/typecheck | **macos=OK ios=OK tests=OK**, exit 0; 78 s / 71 s / 135 s | `relevance-compile-gate.log` |
| Python offline research | **17 passed, one optional LightGBM skip**, 0.162 s, exit 0 | `relevance-python-tools.log` |

Same evidence root, native destinations, isolated DerivedData and three README opt-in
exclusions as above. Final native source hash matches the pre-gate hash. No source change
is permitted after these gates without revalidation; documentation is updated separately.
Strict/deep codesign verification of the Mac-tested bundle succeeded. Its launcher SHA-256
is `d3976c7461f5c7d950d101045f3adc5ae87c5422a98372f1df075b0b5acf1c71`.
It remains under the lead's Mac DerivedData, not `/Applications`.

Independent read-only selection review found no remaining material issue. Native synthetic
workspace inspection shows the new activity detail but still has the earlier documented
mixed-appearance capture issue. No live provider/model/Keychain/installed-pixel signoff
is claimed; no owner historical records, credentials, model weights or real orders changed.

Owner subsequently requested **commit, merge, push everything** for this StockSage work.
The verified destination is `origin` = `https://github.com/swonyu/StockSage-app.git`.
The working branch is `claude/model-harness-2026-09-10`. The existing `main` worktree is
`/Users/saleh/StockSage-wt/main-integration.yPdibq`, initially clean, and both local and
remote main are ancestors of this branch. Use a non-destructive fast-forward, verify the
same tested tree/source hash, and push both branch refs; never force-push. The unrelated
dirty main app checkout is on `review-followups-2026-09-06` and must remain untouched.
