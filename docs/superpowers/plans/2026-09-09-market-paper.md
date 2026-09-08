# Market-wide Paper Autopilot Implementation Plan

> **For agentic workers:** Use executing-plans inline in this session; owner explicitly
> requires one task/writer. No new agents. Steps use checkboxes for tracking.

**Goal:** Discover US market-wide candidates and automatically buy/sell in the existing
native paper account rather than repeatedly reviewing a one-stock watchlist.

**Architecture:** Add an explicit full-market request alongside the existing filtered
Massive API. Reuse its trade parser, select a bounded rotating shortlist plus holdings,
and run the existing Qwen-to-paper pipeline with market-scoped eligibility.

**Tech Stack:** Swift/Foundation/SwiftUI, existing Swift Testing, existing MLX server.

## Global Constraints

All money, freshness, cancellation, no-broker and rollout contracts in the approved
spec remain unchanged. The current branch is codex/qwen-chat-context. No push/merge.

### Task1: Full-market discovery and order path

Files: StockSage/Sources/StockSage/StockSageMassive.swift,
StockSage/Sources/StockSage/StockSagePaperAutomation.swift,
StockSage/Sources/Views/StockSagePaperAutomationPanel.swift,
StockSageTests/StockSagePaperAutomationTests.swift.

Interfaces: `StockSageMassive.marketRequest(key:) -> URLRequest?`,
`parseMarketSnapshot(_:) -> MarketSnapshot?`, `fetchMarketSnapshot() async -> MarketSnapshot?`.
Snapshot contains returnedCount and rows of parsed LiveQuote plus optional daily dollar volume.
`StockSagePaperAutomation.researchTargets(market:book:at:) -> [String]` is the production
selection seam. `mayResearch(_:marketSymbols:heldSymbols:) -> Bool` gates both before
inference and immediately before an order. Unknown board symbols receive a local
`StockSageSymbol(symbol: symbol, market: "US · Massive")` definition.

- [ ] Add tests with a full-market snapshot fixture and no ORCL/watchlist dependency.
  Assert HTTP request has no ticker filter and include_otc=false. Assert `status=ERROR`
  and malformed rows cannot become a complete market scan. Select thirteen synthetic
  supported symbols; twelve must be selected; record their attempts and assert the
  previously unreviewed thirteenth wins the next cycle. Add all five held names first.
- [ ] Run the entire StockSagePaperAutomationTests suite before implementation;
  record the missing production seams as the initial red result.
- [ ] Implement the explicit snapshot methods without changing existing empty-list
  no-op semantics. Reuse parseTicker/finite and enforce finite valid timestamps.
- [ ] Replace all watchlist-only research guards, synthesize off-board definitions,
  retain buy/sell proposal and settlement, add held/cash facts to Qwen, and expose
  truthful coverage/last-decision/next-cycle UI. Discovery failure still checks holdings.
- [ ] Run focused paper and Massive suites and inspect every changed caller.

### Task2: Verification, installation and durable evidence

Files: agent-docs/QWEN_RESEARCH_PAPER_2026-09-08.md, HANDOFF.md, this plan.

- [ ] Run final macOS tests using xcodebuild test, projectStockSage.xcodeproj,
  schemeStockSage, Debug, platform=macOS,arch=arm64, jobs2, parallel-testing-enabledNO,
  DerivedData/private/tmp/stocksage-qwen-context-20260908/DerivedData. Preserve canonical
  exclusions CalibrationPersistRunTests,LiveUniverseVerificationTests,
  StrategyBaselineMeasurementTests. Repeat serially for iOS Simulator
  3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA. Expect test suites passed and exit0.
- [ ] Confirm no IBKR/frozen/global-policy changes; update operation docs with actual
  counts and scope limitations. Verify signed tested app, normally quit current app,
  preserve old bundle recoverably, install/open, verify process/hash/lease and ledger.
- [ ] Record real discovery/decision evidence, not inferred trades. Stage explicit paths
  and commit with required heredoc Co-Authored-By line. No push.
