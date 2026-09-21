# Scanner news implementation plan

**Goal:** Give the Mac screener an explicitly loaded news feed for its complete matching set. This is the first milestone in the approved news, briefing and live-filter order.

**Architecture:** Reuse StockSageNewsService and its bounded, credential-aware provider path. A small view model owns one cancellable batch; native SwiftUI displays both headlines and complete per-symbol coverage. No new provider, model, polling, persistence, or trade action.

**Tech stack:** Swift 6, SwiftUI, existing Swift Testing / XCTest gates.

## Constraints

- Mac only. Preserve saved research and existing qualification rules.
- Never truncate eligible symbols to a page or the former 24-stock limit.
- Five selected excerpts per symbol over seven days, with actual provider outcomes and dates; this is not a live or complete news census.
- Four rolling symbol workers share the existing provider client's three-request limit.
- Cancel obsolete filter/snapshot loads; never mix credential or policy generations.
- Morning/event and live filter additions may use only observed, validated data. Unavailable data stays unavailable.
- PDF remains at most 20 pages. Rebuild and test a candidate; a running installed app needs action-time restart approval when memory-only data would be cleared.

## Work

- [x] Add `StockSageScreenerNewsTests.swift`: executed failing checks for complete membership, outcomes, bounded concurrency, cancellation and access invalidation.
- [x] Add `StockSageScreenerNews.swift`: `matchingRows(_:filters:search:)`, `load(rows:)`, `cancel()`, `clear()`; observable rows, observations, status, start time and loading state.
- [x] Connect `StockSageStockScreenerView.swift` and a small news view, preserving financial filters and per-symbol failures.
- [x] Review source and exercise focused offline tests, Mac UI fixtures and full Mac gate.
- [x] Build and verify the signed Mac Release and ZIP.
- [x] Update living guides and verify/publish the concise 12-page PDF, preserving the previous edition. Candidate, installed and live-provider status remain distinct.

Reviewed changes are committed and pushed to main; the original candidate receipt is `work/scanner-news/push-receipt.json`. The owner then authorized reopening. Runtime `f578733` was installed on 21 September at 19:50 Asia/Riyadh, reopened, and verified against the signed candidate. All 20 saved runs and 3,068 compared files were unchanged before tracking resumed. Daily ratios were reloaded, both cap trackers restored, and the prior record-lock warning was absent. The installed Matched news sheet was inspected; live headline loading remains unverified. Installation and UI receipts are `work/scanner-news/installation.json` and `work/scanner-news/installed-ui-verification.json`.

## Following milestones

Morning briefing and richer live filters follow this independently reviewable news milestone. Inventory found reusable quote/NBBO clocks and selected-symbol earnings/analyst evidence, but no macroeconomic event feed or broad cumulative day-volume field. They are not represented as implemented here. Paid Pro AI, squawk and community chat are outside this milestone.
