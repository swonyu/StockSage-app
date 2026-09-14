# Native workspace polish implementation plan

**Goal:** Continue the owner's approved polished native Mac direction with substantially clearer data-heavy screens and calmer shared chrome.

**Architecture:** Reuse the current sidebar, lazy quote-list rows, existing status/price renderers, native controls and page lifecycle. No new data model, dependency, scrolling container, inference path or persistence change.

**Tech stack:** Existing SwiftUI/AppKit, Xcode 26.6, Mac and iPhone simulator gates.

## Constraints

- Original shutdown constraint was superseded by the owner during final verification: "load stocksage model" and "enable it". Only StockSage Qwen3.5-9B-6bit is now authorized to run, with its local loopback server. Keep all automatic loading/startup disabled and other models unloaded. No live generation is needed for UI checks.
- Preserve all current dirty changes, existing financial calculations, source/freshness distinctions, optional plan legs, user records, and iPhone navigation/financial behavior. Small shared spacing changes are covered by the iPhone gate.
- Lead owns integration, gates and reversible installation. A bounded Paper writer owns only its view while active; reviewers are read-only.
- Use the same three README test exclusions, disable existing opt-in diagnostics, and keep build artifacts under `/private/tmp`. Preserve the exact Mac-tested app before the iPhone gate.

## Implementation

- [x] `StockSageDesktopNavigation.swift`: secondary unselected symbols, accent selected symbol, neutral Settings, existing native selection/shortcuts unchanged.
- [x] `MarketsView.swift`: put the page-top identifier on the complete padded content rather than a spacer child; use semibold page titles and consistent insets. Improve Home briefing rhythm without changing its content or generation handler.
- [x] `MarketsView.swift`: keep the lazy Watchlist/Markets list and original sorting/advisor lookup; replace per-row rounded borders with divided, aligned rows. Give quotes/recommendations stable columns, strengthen the price/ticker hierarchy, retain complete source/reason/optional-plan information and existing removal actions.
- [x] `MarketsView.swift`: give Ideas a full-width introduction/status band, increase control readability, and place optional planning/backtest disclosures after the ranked list. Keep all freshness, calibration, failure, missing-coverage and model-provenance warnings visible and preserve handlers. Reuse the existing horizontal strip on compact Mac windows so interactive summary labels stay intact.
- [x] `MarketsView.swift`: larger Heatmap type/tiles and a compact loss/neutral/gain legend; reuse Tadawul name lookup; keep the original universe/order/color thresholds/stale/new/basis branches.
- [x] `StockSagePaperAutomationPanel.swift`: consolidate visible mode/status/monitoring information, retain full warnings, and align position metrics to expose account/activity sooner.
- [x] `StockSageChatSection.swift` and `StockSageResearchModesPanel.swift`: align title weight and quiet secondary controls, retaining composer/selection/inspector lifecycle.
- [x] Correct the existing Heatmap/quote-row VoiceOver missing-basis mismatch through one shared formatter; add focused checks to the existing ordinal-strength test suite. Extend native render coverage only for layout branches needing executable checks.
- [x] Freeze source, source-review, execute canonical Mac then iPhone gates, install the exact candidate reversibly, inspect installed normal/narrow screens and safe interactions, verify records and model-off state, and update HANDOFF/receipt.

Design review: no new market classification or changed financial thresholds; no decorative animation or additional glass effects. Existing list composition avoids introducing another scroll container. Source references: Apple HIG lists/tables, sidebars, layout, and designing for macOS, refreshed 14 September 2026.
