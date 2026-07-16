# StockSage

A standalone macOS app for the **StockSage money engine** and its **Markets / ideas** surface — the ranked-ideas board, best-opportunity card, fast lane, idea detail sheet, trade journal, and strategy backtest.

This is the Markets tab of the "Salehman AI" app, extracted into its own app. `MarketsView` is the entire product — there is no tab bar and none of the parent app's brain / agents / knowledge / voice / media code.

## What it is

- **The engine** (`StockSage/Sources/StockSage/`, 84 files): the advisor, expected-value / velocity math, conviction→win-probability calibration selector, half-Kelly position sizing, the trade journal, the walk-forward backtester with Deflated-Sharpe honesty gating, the live Yahoo quote/history service, and the Tadawul + NASDAQ universe.
- **The views** (`StockSage/Sources/Views/`): `MarketsView` (the board + detail sheet + journal), `MarketsTodayActionsCard`, `MarketsRiskAllocationSection`, `BrowseMarketsView`.
- **Support**: `DesignSystem.swift` (the `DS.*` design tokens + `LuxPressStyle`), `ToolPolicy.swift` (the web-access gate), and a 3-member `AppSettings` shim (`App/AppSettings.swift`) that provides only the web-access / offline-only flags `ToolPolicy` needs — the parent app's full settings object did not come along.

## Honesty floor (inherited, non-negotiable)

Every number on every surface is labeled: gross vs. net, assumed vs. measured win-probability, `nil` = unknown (never fabricated). No surface implies a proven edge — the engine's own measured Deflated Sharpe is ≈ 0, and its value is **risk discipline, not alpha**. See the engine source comments; this was the guiding constraint of the parent project and it carries over intact.

## Universe

Tadawul (`.SR`, 29 names incl. `^TASI.SR`) + NASDAQ-listed (872 names). The SAR→USD rate the `.SR` currency-correct displays need is fetched as infrastructure (`USDSAR=X`), not as a tradable row.

## Build & run

```bash
xcodebuild -scheme StockSage -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme StockSage -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

Requires full Xcode (macOS 26.5 deploy target, Swift 6, MainActor default isolation). New `.swift` files under `StockSage/Sources/` auto-compile (synchronized file groups — no `project.pbxproj` edits). Live quote/history fetches need network access.

## Provenance

Extracted from the `Salehman AI` repo at commit `fc8f383` (2026-07-16). The extraction is source-clean: the engine and Markets views depend only on the DesignSystem, `ToolPolicy`, and the `AppSettings` shim — verified by dependency trace before the copy. This repo is a copy-out (not a submodule/package), so future engine fixes made in the parent app are **not** automatically reflected here.
