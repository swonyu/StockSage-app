# All matching momentum implementation plan

**Goal:** Detect momentum for every dated, eligible Micro cap and Large cap symbol while the Mac app is awake in the approved weekday Riyadh window.

**Architecture:** Reuse the existing Massive socket and off-main ingress for provisional AM minute histories. Detect across the complete eligible universe independently of the display cache. Confirm prospective events using the existing adjusted-minute parser before Telegram or Astra; retain pending events while fresh and disclose expiration.

**Tech stack:** Swift 6, Foundation actors and URLSession, existing SwiftUI views and Swift Testing suites. No dependencies or additional sockets.

## Constraints

- macOS only; preserve iOS, saved research, pairing, other worktrees and all existing strict qualification gates.
- Monday–Friday 11:00–23:00 Asia/Riyadh; no synthetic or Sunday live assessment.
- Twenty consecutive completed positive-volume minutes; unchanged return/volume thresholds and three-minute event age.
- Streaming aggregates nominate only. They cannot assert split adjustment or finality. REST must independently confirm a current heavy event.
- No secrets in files/output, extra Telegram test without the pending approval, paid compute or orders.

## Work and verification

- [x] Feed: add AM decode and bounded per-symbol correction-aware history in `StockSageMomentumStream.swift`, `StockSageFeedIngress.swift`, and `StockSageLiveStream.swift`. Test events beyond 24 and 4,096; corrections, malformed/current bars, gaps, reconnect and stale clocks.
- [x] Monitor: replace first-24 selection with complete eligible membership and provisional-event confirmation. Keep requests bounded, capture each batch at its real clock, reject feed/access changes, retain Astra events with visible expiry. Test old prefix behavior RED, all-symbol intake, confirmation disagreement and cancellation.
- [x] UI: coverage counts, warming/missing data, dated confirmed details and honest review queue status in `StockSageMicrocapActivityView.swift`; review native layouts.
- [ ] Review complete diff, execute focused Mac tests then canonical full Mac gate against unchanged source, commit and build signed release.
- [ ] Preserve saved records and disclose in-memory screener loss before restart; install/reopen if native control is available or obtain owner assistance.
- [ ] Update living guide and owner's exact PDF, verify text/links/pages, fast-forward reviewed work to main and push. Preserve other dirty worktrees.

Live market/event delivery remains separate from deterministic tests; Sunday does not establish weekday performance.

Focused validation: 181 definitions / 403 executions / zero failures and skips; all four native activity renders inspected. Full combined validation and release remain pending. A separate owner-created concurrency task is being reviewed for combined integration.
