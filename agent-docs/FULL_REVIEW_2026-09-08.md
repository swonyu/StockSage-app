# StockSage app and model review — September 8, 2026

Source: `/Users/saleh/StockSage-wt/coverage`, `wt/coverage`, commit
`7e6e7aa251d82975311bd26269810eec45ba9d35`.

Three authorized sessions reviewed the app in parallel: this task covered app/UI,
lifecycle and integration; two read-only tasks covered model/chat/news and
portfolio/trading/data. The coordinator checked the important caller paths and
challenged findings before consolidation. This is a review and proposed sequence,
not an approved implementation specification. No app source or settings changed.

## Conclusion

StockSage has useful local research, market-data and paper/journal capabilities,
and the owner's configured Qwen server responds. It is not an implemented Derayah
trading client, and neither its AI validation nor its training loss establishes
a profitable trading strategy. The first work should repair data interpretation,
export readiness and credential handling, then add the four requested feature
areas incrementally. A new model or whole-app rewrite is not yet justified.

## Evidence and limits

| Area | Examined | Limit |
|---|---|---|
| App/UI | App entry, macOS/iOS settings, left navigation, relevant MarketsView lifecycle, list projection and export paths | Not every line of the large view; no fresh visual/VoiceOver acceptance |
| Data | Quote/provider routing, stream merges, source timestamps, caches, SEC/news/insider retrieval | No fresh entitlement test of every external endpoint |
| AI | Shared local client, assessment, Chat, Catalyst narration, briefing, research leads, targeted tests and evaluation notes | No complete current live contract or investment-quality benchmark |
| Portfolio | Sizing/gates, correlation caller/cache, plans, local portfolio/journal/paper/backup paths | Not a formal audit of every financial formula or persistence failure mode |
| Brokerage | Production call-site searches and current manual execution boundary | No Derayah sandbox, credentials, contract or live order test |

Fresh checks in this review:

- Git was clean at the source commit before this report; no other worktree edited.
- Saved app URL/model/backend are `http://127.0.0.1:8765`,
  `/Users/saleh/models/salehman-qwen38-27b-4bit`, and `localServerOnly`.
- `GET /v1/models` on that existing listener includes the exact configured ID.
- A synthetic, non-streaming JSON request using the app's OpenAI-compatible
  request fields returned `{"status":"ok"}`, `finish_reason: stop`, six completion
  tokens. This tests transport/basic generation, not stock reasoning.
- The existing model process has `--chat-template-args {"enable_thinking":false}`
  and decode/prompt concurrency 1. No second model loaded or settings changed.
- The model reviewer reproduced Form 4 array misalignment using Foundation's
  production regex patterns and equivalent indexing: four assertions passed.
  This was an isolated reproduction, not execution of the app test suite.
- The data reviewer independently demonstrated the correlation alignment issue;
  its numeric example is illustrative, not a recorded owner-portfolio result.

The previous sidebar change's 1,830 macOS and 1,827 iPhone tests are historical
evidence for this source baseline, not tests rerun by this review. Results live in
`/private/tmp/stocksage-left-sidebar-20260908.M4mAPS/`. Native UI automation's
helper previously crashed; no new visual pass is claimed. Broad web research,
fresh training, cloud services and actual orders were not performed.

## Prioritized findings

### R1 — P1: credential compiled into the app

[StockSageEODHD.swift:25](/Users/saleh/StockSage-wt/coverage/StockSage/Sources/StockSage/StockSageEODHD.swift:25)
contains a credential constant; its `apiKey` at line 30 uses that constant when
the runtime override is blank. The value is deliberately omitted here.
The fallback is still reachable through the calendar/catalyst path
(`StockSageStore.swift:2119`) and news fallback (`StockSageNewsService.swift:68`).
Private repository status does not prevent extraction from source or a binary.

Remove the compiled fallback and configure the provider through explicit runtime
credential storage, without logging the value. Coordinate replacement/rotation
so required routes do not silently lose access. Rotation and any repository-history
rewrite are separate owner/provider operations, not implicitly authorized here.
Validity, misuse and an active leak were not tested; this is not a P0 app outage.
Query-token authentication alone is not a finding. Calendar uses a shared session;
news already uses an ephemeral no-redirect session. No observed redirect/log/cache
disclosure was established.

Acceptance: no credential literal/fallback in source or build; absent key produces
an explicit unavailable state; runtime key works without echo; request tests cover
credential-bearing transport policy.

### R2 — P1: Form 4 fields can move between transactions

`StockSageInsider.swift:111–132` collects document-wide arrays for transaction
codes, shares, optional prices and dates, then indexes them by code position.
An omitted optional field removes an entry; later values shift to the wrong row.
The comment claiming shorter arrays are not misaligned is incorrect.

Synthetic example: purchase of 100 shares with no price, followed by sale of
200 shares at 20. Current indexing assigns 20 to the purchase and nil to the sale.
The known-priced subtotal becomes +2,000 instead of −4,000 from the sale; total
net value remains unknown because the purchase is unpriced. Missing dates shift
the same way. The results reach `MarketsView.swift:6700` and Explain citations
at `CatalystsSection.swift:677`.

Parse fields inside each transaction's XML element, preserving absent values in
that row. Existing multi-row tests exclude mechanical transactions; the value
assertions use single-row fixtures, so they miss this case. Add multi-row missing
price/date and mechanical-before-discretionary regressions. Also label any partial
known-value subtotal honestly rather than presenting it as a complete net.

### R3 — P1: copied plans do not establish quote freshness

`StockSageTodayPlan.swift:81–89` and `MarketsView.swift:8374` omit the price warning
when the market timestamp is nil; their day-key check also allows an arbitrarily
old same-day price. `StockSageTodayPlanTests.swift:81` explicitly pins nil producing
no warning. Meanwhile the quote freshness helper treats nil as stale
(`StockSageModels.swift:118`). The trading gate itself receives no timestamp.

A copied artifact can consequently contain entry, stop, size and a clear checklist
without establishing quote age. These remain manual plans, not submitted orders,
but that distinction does not establish readiness for broker entry.

Use one explicit readiness decision at the shared plan/snapshot interface and
consume it in detail, Today and ranked exports. Unknown/future/stale inputs should
produce a non-ticket status with a re-price/reconfirm action; keep research and
model drafts readable. Specify order-readiness freshness independently of the
general off-hours quote badge, whose 48-hour tolerance is not execution freshness.
Test every export route and boundary, including missing, future and same-day-old
timestamps. Do not replace a real source timestamp with retrieval time.

### R4 — P1: correlation evidence is misaligned and indefinitely cached

`StockSageStore.refreshPrecheck` (`StockSageStore.swift:1854–1885`) discards history
dates and passes numeric returns to `StockSageCorrelationPrecheck.assess`
(`StockSageCorrelationPrecheck.swift:61`). It pairs shorter tails, so missing or
different final sessions can pair different return intervals. The cache checks
only holding-symbol membership: no age/history expiry, and no membership or
cancellation check after asynchronous completion. Missing holding histories can
be cached as `.noHoldings`, despite a real unchecked portfolio.

The snapshot currently passes `maxCorrelation: nil` to the gate
(`StockSageDecisionSnapshot.swift:242`). **Do not fix that by forwarding the current
precheck blindly.** Its sentinel zero could become “adds diversification.”

First establish matching return intervals, usable/partial/unavailable coverage,
bounded cache freshness and publication against the same portfolio/request.
Reuse the Pearson calculation and the close-date alignment pattern already in
`StockSageHistoryCache.panel` (line 177). Merely matching return end dates is not
enough when one return spans a missing session. Gate integration comes after this
prerequisite. Average correlation at 0.60 and maximum-pair correlation at 0.80
are different measures and need not have identical verdicts.

Tests: missing-middle/latest sessions; all or some holding fetches fail; unchanged
holdings across expiry; portfolio changes during a request; unavailable is never
zero/low correlation. Until then, explicitly describe the check as unverified.

### R5 — P2: Explain evidence has inconsistent temporal meaning

`CatalystsSection.citedSources` (lines 654–679) fetches the latest 8-K and dated
Form 4 transactions without an elapsed-age limit. News has a seven-day bound.
The 8-K source uses `filingDate`, not `acceptedAt`, even though the disclosure
model distinguishes filing day from the instant it became public. Form 4 uses
transaction date, which is also not publication time.

`StockSageCatalystNarrator.facts` (line 151) and `checkedResponse` (line 256) do
not remove old evidence. Old SEC records can enter and pass structural validation;
this review did not observe a current response falsely calling one recent.
Preserve and label the different dates, and separate current evidence from
historical background under an explicit source-age policy. Do not fabricate a
publication time when missing. The rules-engine company-event window is a
separate path and does not protect these Explain citations.

### R6 — P2: settings contain dead or unreachable controls

- `StockSageSettings.swift:46` exposes “Show menu-bar ticker,” but the
  `MenuBarExtra` scene is parked (`StockSageApp.swift:104`). Remove/disable that
  control with truthful availability; restoring the previously wedging scene is
  separate work.
- `ToolPolicy.swift:58` tells users web access is off in Settings. The policy
  keys exist in `AppSettings`, but no production settings binding was found on
  either platform. Provide reachable privacy controls or correct the recovery
  path; do not tell users to operate a nonexistent switch.
- `IOSSettingsSheet.swift:32` still promises a 4.75-minute timer. The implementation
  at `MarketsView.swift:326` uses 30-second stream-gap and 900-second full refresh
  intervals, doubled under thermal stress. Derive copy from the existing cadence
  policy or use accurate nonnumeric wording. Polling frequency is not feed latency.

### R7 — P2: current model quality lacks a repeatable app-contract evaluation

The historical fine-tune loss improvement and today's tiny JSON smoke do not test
citation relevance, multi-company news interpretation, stale-context reasoning,
assessment F/W references or current Chat contracts. The project's own
`agent-docs/QWEN_RESEARCH_2026-09-07.md:107` records a semantically misleading
APP/news interpretation that passed mechanical validation.

Add a small fixed, sanitized contract set across assessment, Catalyst and Chat.
Check factual attribution/relevance and expected accepted/draft outcomes, latency,
truncation and cancellation—not just JSON syntax. Preserve failed outputs as
unverified drafts. A higher acceptance rate obtained by weakening validation is
not a quality improvement. Compare alternatives only after this baseline exists.

### Usability gaps and unconfirmed risks

- Generic defaults remain Ollama at port 11434 / `qwen3.8`. The owner is correctly
  configured for MLX at 8765. This is onboarding friction after reset, not today's
  outage; do not hardcode an owner's absolute model path as a portable default.
- `MarketsView` observes multiple broad stores and recomputes expensive projections.
  Existing performance tests measure render-equivalent calculations, not actual
  UI frame time. Profile invalidations before extracting/caching more logic.
- Per-window lifecycle tasks may duplicate sequential refresh work across multiple
  windows. Store re-entry guards protect several writes; a duplicate polling/crash
  incident was not reproduced. Audit task ownership before changing it.
- Exchange holiday/early-close handling is incomplete and disclosed. This affects
  polling usefulness; no evidence it executes trades or restamps stale prices.
- README and older comments describe the pre-Chat/pre-Massive app. Update docs after
  accepted changes; do not treat historical descriptions as current architecture.

## Existing strengths to preserve

Massive-to-Yahoo routing preserves source and market timestamps. Stream/poll merges
reject older quotes. Missing FX blocks sizing rather than assuming parity. Core
sizing/fees/stops remain deterministic and separate from AI badges. AI results are
snapshot-bound; unsupported replies remain labelled drafts. Chat has bounded local
history and explicitly untrusted research leads. News uses bounded retrieval and
no-redirect transport. Current left navigation retains keyboard shortcuts,
accessibility labels, selected traits, reduced motion and reduced transparency.

## The four requested improvement areas

| Area | Small first feature | Acceptance |
|---|---|---|
| App usability | One Connections & Health panel using existing provider state and model probe | Shows configured/missing/unavailable/not-tested accurately; reaches actual settings; no new polling daemon or model launch |
| Stock/news explanations | Evidence timeline and coverage summary | Ticker, source, retrieval/market/publication dates and historical scope remain distinct; absent news is not “nothing happened” |
| Chat/proactive briefing | A compact “what changed” briefing with follow-up Chat | Grounded in captured app snapshots; offline deterministic fallback; stale snapshots labelled; no repeated notifications or claimed live WhatsApp subscription |
| Portfolio/trading | Readiness receipt plus broker-import preview | Unknown quote/FX/correlation inputs remain unverified; imports preview diffs and require confirmation; no broker order submission |

Derayah buy/sell/cancel/modify is not implemented in this tree. Broker connectivity
is a separate contract/sandbox project: verify personal US/NASDAQ access, scopes,
idempotency, order replacement/cancellation and account/data entitlements before
designing a live route. This review does not approve credentials, legal status,
paid services or real orders.

## Proposed sequence — awaiting focused design approval

1. **Recommended: evidence/readiness repairs, then all four areas in slices.**
   Start with R1–R4 and focused regressions, expose the resulting health/readiness
   state, then evidence/briefing improvements and model-contract evaluation.
   Reuse current modules and avoid a full rewrite.
2. **UI-first:** quicker visible polish, but interpretation/export issues remain
   underneath. Not recommended as the first slice.
3. **Model-first:** establish the evaluation set and compare models before app
   changes. Useful research, but cannot repair wrong input fields or absent broker
   connectivity. Not a substitute for the safety/data work.

Each approved slice needs its own small design, implementation and relevant
regressions; Swift changes then run the canonical macOS and iPhone gates. Broad
strategy/model/vendor research follows the local review, with independent
out-of-sample, latency and net-cost evidence—not promises of weekly returns.

## Experiment and repository preservation

The frozen prospective recipe and recorder source were not edited. Its scheduled
18:10 UTC batch completed with all six candidates eligible at both entry delays;
at that point the private record had six captured batches and seven missed slots.
Missing/late observations remain recorded, never backfilled or counted as on-time.
No forecast-error results, trading P&L or model promotion are inferred from capture.

Qwen and StockSage were left running. No new build installed, key rotated, repository
history rewritten, merge performed or push sent during this review. The review
produced this report and a documentation-only HANDOFF entry; app/research source
is unchanged. Documentation commits do not change the reviewed source baseline.
