# Qwen primary badges — design and implementation plan

> Execute inline using executing-plans; owner forbids other tasks/subagents and
> routine design reconfirmation (AGENTS.md). All changes remain on wt/coverage.

**Goal:** the configured local Qwen model chooses the primary idea assessment,
including Buy/Strong Buy, from dated app evidence rather than copying the rules verdict.

**Architecture:** keep immutable AI assessment records outside TradeAdvice.
One bounded serial coordinator reuses StockSageLocalModelServer. Shared native
badge/detail components consume that record; mathematical consumers retain
TradeAdvice with explicit Rules labeling. No new dependency or persistence.

**Tech stack:** existing SwiftUI, Combine, Foundation and Swift Testing; macOS
and iOS26.5 builds. Current server is already running on loopback8765.

## Design / authority

Owner02:19 requested Qwen set the badge, and confirmed ORCL earnings September10.
Compared three approaches: narrator-only does not meet that request; rewriting
TradeAdvice would also change risk, direction, sizing and execution without a
validated mapping; a separate primary AI badge meets the request without those
unrequested money changes. Choose the third. Existing approved autonomous
implementation authority covers this scoped feature; no orders are authorized.

The primary caption is AI plus the model-selected action and snapshot time.
The rules action remains a secondary caption. No AI record means AI not assessed,
not a secretly rules-generated AI verdict. Busy, unavailable and stale records
are distinct. Detail shows reason, counter-case, exact model identity, quote
clock/source, the offered facts, and the cited fact IDs. It explicitly says
unvalidated, can misstate, not a probability, and not execution permission.

## Global constraints

- Action whitelist: Strong Buy, Buy, Hold, Avoid, Reduce, Sell. No forced ORCL rating.
- Horizon: next trading week, an assessment rather than a promised weekly return.
- Facts: quote/source/market time, dated rules rationale and volatility, earnings
  confirmed/estimated/projected/unchecked with source/check time, each company
  feed's real coverage and selected observation. Unknown is not a negative event.
- No account identifiers, balances, credentials or journal notes sent to the model.
- Strict JSON with exactly action/reason/risk/evidence; evidence is1–3 existing
  F-prefixed fact IDs. Reject malformed/oversize/foreign-number replies; never
  extract a Buy word out of arbitrary prose or silently fall back to rules.
- Number and reference checks are mechanical, not proof the reasoning is true.
- No new news/API sweep: reuse already-loaded paid company-event and earnings
  observations. Additional on-demand news retrieval remains the Explain feature.
- Loopback local server only for this slice. Respect Off/on-device-only; no
  remote inference, new model loading, second server, training or downloads.
- One AI request at a time. Assess the first3 displayed ideas after a completed
  scan, plus the opened detail; explicit Reassess retries. No per-tick generation,
  unbounded queue, automatic retry storm or per-card timer. Missing ideas say so.
- Records live in memory, maximum100; show snapshot time, expire on read after
 15minutes or changed analysis/catalyst/company evidence/configuration. A price
  tick does not rewrite an old snapshot or trigger inference; its original quote
  clock/price stay visible. These are not live entry prices.
- Recheck cancellation/configuration before publication. No stale async result
  may acquire another symbol or model label.
- Technical filters/counts/ranking/alerts, copy plans, widget and execution CTAs
  remain rules-based and must say Rules; neither AI confidence nor action feeds
  EV, stop/target, sizing, journaling direction, paper trading or broker code.
- No pushes, main-worktree edits, real orders or credential bypasses.

## Task1 — assessment contract and serial state

Files: create `StockSage/Sources/StockSage/StockSageAIAssessment.swift` and
`StockSageTests/StockSageAIAssessmentTests.swift`.

Interfaces: `StockSageAIAssessment.Context` contains an immutable idea, optional
earnings record and company observations; `facts` is the bounded string array.
`parse(_:facts:) -> Verdict?` validates the JSON. `Record.current(...) -> Bool`
checks model/config, analysis/evidence identity and age, not a new live-price tick.
`StockSageAIAssessments.assess(_:store:force:) async` snapshots the app context,
checks local settings/sample data, serializes one call and publishes the record.

- [ ] Add focused tests before implementation. Core assertions include:
  ```swift
  #expect(A.parse(goodBuyJSON, facts: facts)?.action == .buy)
  #expect(A.parse(unknownActionJSON, facts: facts) == nil)
  #expect(A.parse(foreignNumberJSON, facts: facts) == nil)
  #expect(A.parse(forgedFactIDJSON, facts: facts) == nil)
  #expect(!record.current(idea: idea, earnings: changed, company: [:], config: config, now: now))
  ```
- [ ] Run focused xcodebuild with only StockSageAIAssessmentTests; record whether
  the red is compilation or executed assertion failure, never conflate the two.
- [ ] Implement using JSONSerialization strict-key validation, the existing
  numeric fence, immutable captured model/config and fixed safe error messages.
  One MainActor active-symbol guard is the intentional throughput ceiling.
- [ ] Re-run focused tests; add cancellation/concurrency checks using an injected
  completion closure at the same production coordinator seam, no live singleton.

## Task2 — one primary badge, consistent native consumers

Files: create `StockSage/Sources/Views/StockSageAIAssessmentView.swift`; modify
`StockSage/Sources/Views/MarketsView.swift` and `CatalystsSection.swift`.

- [ ] Shared `StockSageAIBadge(idea:store:)` renders the AI label, snapshot time
  and secondary Rules action. Shared `StockSageAIAssessmentPanel` shows the
  rationale, risk, captured evidence and Reassess action. Reuse existing AA
  action fill/ink helpers and Dynamic Type, avoid a new design system.
- [ ] Replace primary idea/detail/catalyst/best-opportunity capsules. Explicit
  card VoiceOver labels must include the same AI status; retained execution CTA,
  widget, summary filters/counts and journal plan copy identify Rules.
- [ ] Add one scan-completion task capped at3, and the selected-detail assessment
  after its existing earnings refresh; guard QA/sample/cancellation. No per-row
  request task or provider refresh duplication.
- [ ] Review all action.rawValue callers; verify engine/projection/money files
  have no behavior edits. The AI record is never inserted into TradeAdvice.

## Task3 — release evidence

- [ ] Focused assessment/narrator/local-server tests, then serial canonical
  macOS and iPhone17Pro(gate) tests, same3 opt-in exclusions as HANDOFF.
  Use unique result bundles under /private/tmp and shared isolated DerivedData.
- [ ] Exercise the real loopback model with a dated ORCL snapshot. Record actual
  action or validation failure, without tuning the validator to force acceptance.
- [ ] Install only after passing gates and a normal app quit; preserve previous
  bundle in Trash and user data. Verify native badge + rationale + provenance.
- [ ] Update HANDOFF with exact tests and remaining limits. Stage explicit
  paths and commit with the required heredoc/co-author trailer; do not push.

Self-review: no AI-to-money route, no duplicated quote service or provider sweep,
bounded RAM/request count, refusal and stale states visible, both platforms and
VoiceOver included. Remote iPhone inference and learned investment performance
remain separate work; neither is claimed by this feature.
