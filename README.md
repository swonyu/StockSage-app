# StockSage

A native macOS/iPhone workspace focused on **1–7 and 7–14 trading-day research**,
local-model explanations and portfolio journaling. Research opinions are not execution
permission or evidence of a profitable strategy.

Originally extracted from Salehman AI's Markets tab. The macOS app now has a left
sidebar led by Home, Research, Watchlist and Chat. Home summarizes the latest saved
picks for each horizon and predictions ready for review, with dates and direct links.
iPhone uses the same charcoal/magenta design and Home-first native tabs.
Legacy same-day paper records remain on Mac; new runs and automatic resumption are retired.

## What it is

- **Market data:** Massive US snapshots, trade/quote streaming and adjusted daily
  history, with supported Yahoo fallbacks. Benzinga products use the existing
  Massive integration. SEC filings, earnings and news retain source/coverage states.
  Endpoint access, freshness and licensing rights are separate questions.
- **Research:** rules-based indicators and sizing, company catalysts, evidence-bound
  AI opinions, local Qwen Chat, and manual 1–7 / 7–14 trading-day scans. Each manual
  horizon scans at most 500 validated active US names and displays at most five
  accepted Buy / Strong Buy results. Strong Buy precedes Buy; ties retain the dated
  activity order. The rank is not a validated return forecast. No positions are opened.
- **Saved research:** completed runs preserve original ordered picks, opinions,
  evidence, model and reference prices in `Application Support/StockSage/ResearchHistory/runs.json`.
  Saved research → Check due results reviews the seventh or fourteenth future Nasdaq
  regular-session target date, once that New York date has ended. The benchmark uses the
  next trading date’s daily open after completion and the target date’s daily close from
  one verified split-adjusted history; missing dates/calendar/data stay unavailable. Flat is distinct from rose/fell.
  Active or cancelled scans are not durable completed runs. Review is manual while
  the app is open, not a background execution service.
- **Legacy paper:** retained account/history/export remain readable. No new same-day
  runs start from the app or resume on launch. Open legacy positions are not monitored
  after relaunch; existing records are not reinterpreted as 7/14-day research.
- **Records:** holdings, journal, legacy paper results and the separate native Qwen
  paper account. Normal backup covers journal/portfolio/watchlist/price alerts; the separate
  paper research export includes committed account data and referenced audit chunks.
  Saved research is a separate local file and is not yet part of that normal backup.
- **Code:** financial/data logic in `StockSage/Sources/StockSage/`; views in
  `StockSage/Sources/Views/`; shared refresh/lifecycle ownership in `MarketsView`.
  `AppSettings` and `ToolPolicy` enforce web-access/offline controls.

## Honesty floor (inherited, non-negotiable)

Preserve gross/net, assumed/measured, snapshot/live and unavailable/empty distinctions.
An evidence validator checks format/references, not the truth of model reasoning.
Retrospective and synthetic checks do not establish future returns or a weekly target.
Native paper fills use qualified later trades with an assumed adverse cost, not
verified broker fills or an executable bid/ask queue simulation. The IBKR relay is
separate and held; normal app operation does not enable broker submission.

## Universe

Curated watch/idea lists, the provider's active-US directory and wildcard feed
receipt are different populations. Displayed/observed/eligible counts must not be
confused with complete market coverage. Tadawul/index support uses its applicable
provider path; infrastructure FX pairs are not tradable recommendations.
Up-to-60-second Massive observations are permitted for research only; native paper
fills/marks and LIVE labels retain stricter gates. Quiet symbols may have older
last trades even when the connection is healthy.

## Build & run

```bash
xcodebuild -project StockSage.xcodeproj -scheme StockSage \
  -destination 'platform=macOS,arch=arm64' -configuration Debug build
xcodebuild -project StockSage.xcodeproj -scheme StockSage \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -parallel-testing-enabled NO \
  -skip-testing:StockSageTests/CalibrationPersistRunTests \
  -skip-testing:StockSageTests/LiveUniverseVerificationTests \
  -skip-testing:StockSageTests/StrategyBaselineMeasurementTests test
```

Run the same test gate serially for the available iPhone 17 Pro (gate) simulator
using its verified destination ID. Keep live/opt-in diagnostics disabled. Use
isolated DerivedData and unique result bundles; see the latest [HANDOFF.md](HANDOFF.md)
for exact receipts, exclusions, toolchain and installed-build identity. Opening
Xcode or passing a build is not equivalent to executing either platform's tests.

Fallback while `xcodebuild` is unavailable (e.g. an unaccepted Xcode licence after an update):
`tools/gate.sh` emits the app module for macOS and iOS with the project's Swift 6 flags and
type-checks macOS test code. It does not check iOS-only test code or the widget target,
and it does **not** execute tests. Invalid modes fail; each invocation keeps separate artifacts.

`tools/runtests.sh` runs the Mac gate above using Xcode's actual app test host and
unique artifacts. It preserves the native failure status and rejects successful
zero-test runs. The retired standalone dylib runner did not activate XCTest-based
startup isolation and could resolve its supposed temporary home to the owner's data.
Use `--filter StockSagePortfolioTests` for an exact suite (no regex), `--build-only`
for `build-for-testing`, or no options for the full Mac gate. `--no-parallel` remains
accepted; all runs are serial. Live diagnostics remain excluded as above.

Editor configuration is checkout-local. If using the already installed
`xcode-build-server`, generate it from the checkout you are editing:
`xcode-build-server config -project StockSage.xcodeproj -scheme StockSage`.
The generated `buildServer.json`, temporary source archives and browser review
captures are ignored; do not commit another checkout's absolute paths or captured pages.

Requires full Xcode (macOS 26.5 deploy target, Swift 6, MainActor default isolation). New `.swift` files under `StockSage/Sources/` auto-compile (synchronized file groups — no `project.pbxproj` edits). Live quote/history fetches need network access.

## Intraday research (separate from the app)

The bounded minute-data collector and offline baseline/LightGBM benchmark are
documented in [tools/intraday_research.md](tools/intraday_research.md). This is an
engineering research lane, not an intraday predictor wired into badges or orders.
Raw feeds, fitted models and reports remain private in ignored `.research/`.
The separate walk-forward CLI adds calendar-complete multi-archive checks and
continuous-capital rolling tests; research results never automatically change app decisions.
The frozen prospective recorder preserves missed/late events and forecast-error
denominators; it does not calculate executed portfolio returns. Do not edit its
frozen source/recipe, backfill events or start collection merely to run tests.
Offline regression checks: `python3 -m unittest discover -s tools -p 'test_intraday*.py' -v`.
Two tests need the existing isolated LightGBM environment; a skipped optional test
is not a full-fit verification. No production model files are needed by timing tests.

## Provenance

Extracted from the `Salehman AI` repo at commit `fc8f383` (2026-07-16). The extraction is source-clean: the engine and Markets views depend only on the DesignSystem, `ToolPolicy`, and the `AppSettings` shim — verified by dependency trace before the copy. This repo is a copy-out (not a submodule/package), so future engine fixes made in the parent app are **not** automatically reflected here.
