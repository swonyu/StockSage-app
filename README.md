# StockSage

A native macOS/iPhone workspace for market research, local-model explanations,
portfolio journaling and simulated trading. Research opinions are not execution
permission or evidence of a profitable strategy.

Originally extracted from Salehman AI's Markets tab. The macOS app now has a left
sidebar: Home, Watchlist, Ideas, Markets, Catalysts, Heatmap, Portfolio, Alerts and
Chat, plus native Settings. iPhone retains its platform-specific navigation.

## What it is

- **Market data:** Massive US snapshots, trade/quote streaming and adjusted daily
  history, with supported Yahoo fallbacks. Benzinga products use the existing
  Massive integration. SEC filings, earnings and news retain source/coverage states.
  Endpoint access, freshness and licensing rights are separate questions.
- **Research:** rules-based indicators and sizing, company catalysts, evidence-bound
  AI opinions, local Qwen Chat, and manual 1–7 / 7–14 trading-day scans. Each manual
  horizon scans at most 500 validated active US names; it does not open positions.
- **Native paper automation:** Day mode checks up to 101 symbols including holdings,
  with four research workers, a 15-minute research cadence and independent position
  polling. The poll sleeps 30 seconds after completion; this is not a maximum delay
  guarantee. Scheduled pre-market, regular and after-hours sessions are supported.
- **Records:** holdings, journal, legacy paper results and the separate native Qwen
  paper account. Normal backup covers journal/portfolio/watchlist; the separate
  paper research export includes committed account data and referenced audit chunks.
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
type-checks the whole test target. It proves the code compiles; it does NOT run the tests.

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
