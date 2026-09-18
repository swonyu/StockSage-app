# StockSage V3 — Massive data, AI assistance, Derayah execution

Date: 2026-09-06. Status: corrected design and implementation acceptance plan;
**not a claim that Chat, brokerage, or a profitable strategy has shipped.**

**18:24 review update:** the owner reaffirmed the original goal. Review supports
delivery; it does not replace it. Unattended own-account trading is an explicit
product requirement (Claude session `d1ce9e6b`, source line 2750, 13:17:02 UTC).
Both manual and policy-authorized automated execution belong in the design.
All123 application/widget Swift source files and all167 test/support files have
now been read in the frozen5bb544d snapshot. The exported top-level Claude text
and historical agent-documents review is complete, with raw-tool/image/child-log
limits explicitly recorded. Saved model-readiness evidence is separate. See the
[consolidated review](FULL_REVIEW_2026-09-06.md). Review has not changed the live
Claude session's application code or submitted live trades. At18:43 the owner
assigned pipelines4/5 to a separate Codex takeover task; avoid duplicate writers.

## 1. The owner's actual objective

Build a fast, useful trading application that can BUY and SELL through Derayah,
cancel/modify orders, track fills and holdings, proactively explain relevant
changes, and answer specific questions. Include unattended trading on the owner's
account within explicitly enabled, versioned limits. Start verification with mock
and sandbox execution; per-order confirmation is a supported mode, not a permanent
restriction on the requested product. Do not substitute a read-only chatbot or
copy-ticket workflow for genuine execution. We do not execute real trades during
this development/review work.

Massive Advanced is **already purchased**. History identifies Benzinga Earnings
as selected, and Analyst Ratings plus Corporate Guidance as explicitly purchased
(session `d1ce9e6b`, source lines 1873, 2440 and 2456). Use these subscriptions;
do not budget duplicate purchases. Owner statements establish purchase intent/
confirmation, not a current authenticated entitlement check.

The owner wants profitable short-horizon opportunities. That is a research
objective, not a demonstrated property of the current app or a particular LLM.
Measure net returns, uncertainty, drawdowns and execution costs. Neither a
disclaimer nor a large fine-tuned model establishes a trading edge.

At18:33 +03 the owner specified **5% per week on the total portfolio** as an
additional target. Retain that aspiration in research reporting, not as an
assumption in sizing or a quota that forces trades. At a constant5% compounded
for52weeks, equity would multiply by1.05^52 =12.6428 (+1164.28%); a few successful
weeks do not establish a repeatable rate. Report cash-flow-adjusted total equity
(including cash and marked-to-market open positions), net trading costs,
drawdowns, losing weeks and uncertainty at a declared base currency/week cutoff.
Count deposits separately from profit. No new leverage or increased risk is
authorized by the return target. Prefer no trade over violating an active limit.
Frequent trading can create substantial loss/cost risk; see
[FINRA's risk discussion](https://www.finra.org/investors/insights/frequent-intraday-trading).

## 2. What was compared and verified

- Attached **Architecture Design Document, Version 2**, read in full. Its
  inspection target was a July binary, not the September working source.
- Claude Code's `stocksage-chat-trading-design.md` (17:15) and
  `stocksage-design-reconciliation.md` (17:28), both read in full from the
  prior session's scratchpad. These are drafts, not implementation evidence.
- The full historical `agent-docs/AUTOTRADER_2026-07-28.md` proposal. It predates
  the current Derayah plan and confirms automation was part of the goal; its
  Alpaca code blocks are not shipped broker code or safe reusable execution code.
- Gemini's architecture pasted in the conversation. The additional Gemini share
  URL could not be retrieved; no claim is made about its unseen content.
- Current repo: `/Users/saleh/StockSage-app`, branch
  `review-followups-2026-09-06`, HEAD `5bb544d` at inspection. The existing dirty
  `StockSage.xcodeproj/project.pbxproj` is unrelated and was not changed.
- Source examined: `StockSageLocalModelServer`, `StockSageCatalystNarrator`,
  `StockSageTradeGate`, `StockSageLossLimit`, `StockSageTickSize`,
  `StockSagePaperTrader`, `ToolPolicy`, and `MarketsView.MarketSection`.

Agreement between generated designs is not independent verification. Source,
tests, broker contracts and primary documentation override repeated assertions.

### Comparison and corrections

| Topic | Claude Code | Attached V2 | V3 decision |
|---|---|---|---|
| Current AI code | Correctly identifies existing client/narrator | Says no AI exists, based on old binary | Reuse the existing client and narrator; build conversation and grounding extensions, not a second stack |
| Execution scope | Mostly placement, later portfolio | Explicit BUY/SELL/CANCEL/MODIFY and brackets | Keep all four operations, holdings and fill tracking; brackets are contract-gated |
| Paid data | Underuses the new subscription | Still centered on EODHD/Yahoo | Massive-first US data; extras individually verified; Saudi broker data remains separate |
| Trade gate | Mostly descriptive | Makes every order require GREEN | Server-authoritative, operation-specific controls; do not apply entry criteria to closing a position or cancelling an entry |
| AI honesty | Reuses numeric fence | Treats numeric fence as a truth guarantee | Typed facts and deterministic financial rendering; regex is only supplementary |
| Phone networking | Incorrectly claims Tailscale HTTP already allowed | Complex ATS exceptions | Private HTTPS through Tailscale Serve; keep Ollama loopback-bound; no blanket ATS exception |
| Authorization | Later draft requires every trade confirmed, contradicting earlier owner automation request | App Attest purportedly proves confirmation screen | Manual: transaction-bound confirmation. Automated: explicitly enabled, bounded account policy checked per order. Attestation is separate integrity evidence |
| Paper evidence | Keeps existing simulator | Replaces it with broker sandbox | Keep historical simulation, forward paper and sandbox records distinct; sandbox success tests plumbing, not alpha |
| Risk lockout | Underspecified | Blocks staging during loss lockout, including SELL | Block added exposure; preserve authenticated risk-reduction and appropriate cancellation |
| Regulations/hosting | Reconciliation accepts several unsupported absolutes | More detail, still assumes applicability and future region facts | Confirm personal-use vs commercial scope, contract and applicable controls before production; no automatic compliance claim |
| Model selection | Assumes fine-tuned 27B | Adds a small model without a benchmark | Benchmark existing candidates first; no second resident model or new purchase by default |

### Current code details that change implementation

`StockSageLocalModelServer` already implements Ollama and OpenAI-compatible
requests, probes, and URL/model settings. It currently sends one system/user
pair with `stream: false` and no authentication header. Its configuration accepts
HTTP/HTTPS hosts; `isLoopback` is a warning predicate, **not an allowlist**.
Do not claim ATS alone enforces our intended network policy.

`StockSageCatalystNarrator.numericTokens` collects ASCII numeric strings and
discards signs/units. If facts include “AAPL USD 100” and “MSFT USD 200”, a reply
saying “AAPL USD 200” can pass. So can changing -3% to +3%; Arabic numerals are
not covered. Conversely, an otherwise useful explanation with numbered steps
can be withheld. This fence does not prove truth, attribution, or safe advice.

`StockSageTradeGate.evaluate` is a pure discipline check. R:R from 1 to below 2
is currently a warning, not a hard failure. Loss lockout is a different module;
liquidity and live broker balances are not inputs to this gate. A new execution
policy must explicitly version its differences rather than claiming parity.

`MarketSection` already supplies navigation, icons and swipe order. Add Chat
there; retain the existing Briefing surface and reuse its information. Do not
replace the application's navigation with a separate framework.

The full-source review adds implementation prerequisites, not a replacement goal:

- Normalize and merge observations at one shared boundary. Preserve market time
  separately from receipt time; nil is not now. Older polls/ticks/scan snapshots
  must not rewind the current quote, and tracked holdings must not require a
  preexisting visible board row to receive data. Propagate actual provider/delay,
  event identity, source range and unavailable/malformed status to every consumer.
- Currency, size and costs must form one coherent final decision. Missing foreign
  FX is not1:1 conversion; minimum fees must update gate/EV as well as reason text;
  every final allocation must satisfy both individual and aggregate constraints.
  Net/gross rankings must use the same holding horizon. Existing tests encode
  some compatibility fallbacks that are unsuitable for broker-ready sizing.
- Thin fallback calibration needs its prior ceiling at the actual query, not just
  bin midpoints. Validation must purge outcome windows unknown at prediction time;
  open/censored records cannot masquerade as realized labels. Preserve validated
  versus assumed provenance rather than clamping all maps indiscriminately.
- Require corporate-action evidence and an actual entry basis for paper rebasing,
  and persist legitimate still-open updates. A large price gap alone is not a split.
  Paper marks, realized simulated trades and broker fills remain separate books.
- Key asynchronous detail/narration results by instrument and immutable fact
  version. Card rendering cannot open a sheet, and an old paragraph cannot
  silently describe new facts. Persist desired monitoring state independently of
  foreground/running state and gate remote work at transport boundaries.

These are source-supported failure cases and regression requirements. They have
not all been reproduced through the complete app or fixed. Do not turn source
reading, arithmetic witnesses or this design into a claimed passing release.

## 3. Three distinct paths

```text
Massive / approved Saudi feeds -> normalized observations -> research + app facts
                                                         -> briefing/feed/Chat
                                                              | explanations
Manual ticket --------> authoritative broker validation -> signed confirmation
Versioned strategy ---> authoritative broker validation -> enabled account policy
                                                       -> durable order state
                                                       -> Derayah -> reconciliation
```

The chat model has no broker token or permission to authorize an order. Manual
tickets start from a user action and deterministic instrument lookup. Automated
strategies produce recorded proposals that a separate execution policy validates;
model analysis can be a versioned input, never an authority to change limits.
Never trust model-generated URLs, prices, quantities or account IDs as executable
terms. News or conversation text cannot enable automation or override a breaker.

One modest backend deployment plus PostgreSQL and managed key protection is the
starting point for broker integration. Logical isolation and least privilege are
required; EKS, Redis, multiple microservices and migration between cloud vendors
are not requirements without measured need. No cloud resources are purchased or
provisioned by this document.

## 4. Make the Massive subscription useful

Use real-time US trade and NBBO quote subscriptions for the tracked universe,
REST snapshots/history, and bounded tick retrieval for research. Advanced
includes real-time stock quotes according to [Massive's quote documentation](https://massive.com/docs/websocket/stocks/quotes).
Keep entitlement, connection health and timestamp freshness as separate states:
paying for a plan does not make a cached quote current.

For every observation retain instrument/venue, currency, event time, receipt
time, provider, delay status and available condition/sequence metadata. Quote
sequence gaps alone are not proof of lost packets; documented sequences need
not be contiguous. Preserve corrections/cancellations and use an intentional
policy for anomalous/crossed quotes before computing spread or execution costs.

Use the exchange-reference mapping for Nasdaq attribution; do not hardcode a
numeric exchange ID. A Nasdaq listing/tape is different from a trade executed
at Nasdaq, and filtered consolidated NBBO is **not** a complete Nasdaq order
book. [Exchange reference](https://massive.com/docs/rest/stocks/market-operations/exchanges).

Maintain a small capability record: product name, owner-reported purchase,
verified access status, last check and a non-secret failure reason. This covers
news/Benzinga, earnings, ratings, guidance, financials, splits, dividends, insider
data and other purchased extras without inventing subscriptions. A permission
error disables that feature with a clear label, not a fabricated data fallback.
Obey provider terms for storage, model training and multi-user redistribution.

Massive US access does not establish Tadawul coverage or Derayah execution
entitlements. Earlier owner cancellation of EODHD and the dropped Tadawul live
tracking task must not be silently reversed. Saudi order validation still needs
the broker's authoritative security, account and current tradability data.

## 5. Chat and model selection

Chat opens with a deterministic briefing and a deduplicated feed of material
changes, not an empty prompt. Reuse app monitoring events; do not regenerate on
every tick or unload/reload a 27B model for every row. Show source, as-of,
staleness, missed-update state and whether a statement is analysis or observed.
General explanations and ordinary questions should not be reflexively refused.
An answer to “should I buy?” can explain evidence, alternatives, costs and risks
without fabricating certainty or representing an unvalidated signal as proven.

Fact records carry stable ID, subject, field, signed value, unit/currency,
event/as-of time, provider and provenance. The model selects relevant fact IDs;
compiled code renders financial values and computes supported derived values
(with operands/formula provenance). Reject unknown IDs and stale inputs for
current-price claims. Keep free prose labelled as interpretation: valid JSON or
valid IDs alone do not prove that the prose follows from the facts. Test subject
swaps, wrong signs/currencies, old facts, Arabic digits, unsupported conclusions
and malicious instructions embedded in news. Never render an unvalidated raw
financial stream and retract it afterwards; buffer it or stream validated blocks.

Conversation history is bounded, stored locally with a delete control, and does
not become fresh market evidence. New questions retrieve a new fact snapshot.
Do not send secrets or raw account identifiers to a model. External inference
requires explicit destination/data policy; a model timeout gives a labelled
template fallback, never a silent upload to another provider.

Keep inference on the Mac when enabled; for the phone use private HTTPS
[Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve) with device
access controls, not public Funnel or an assumed CGNAT ATS exemption. Mac sleep
means unavailable inference. Foreground updates are implementable now; continuous
background iPhone monitoring/push needs a separately operated scheduler and
notification permission. Do not promise 24/7 behavior from a sleeping Mac.

**Choose the best measured model, not the largest model by label.** Compare the
existing base and fine-tuned candidate on the same frozen held-out English/Arabic
questions and fact packs: fact/claim accuracy, retrieval quality, arithmetic,
hallucination and false-refusal rates, correct uncertainty, latency and memory.
Pin model revision, quantization, prompt, decoding and eval set. Training loss
or knowing StockSage's source code does not establish a profitable forecast.

## 6. Derayah execution, not merely an external ticket

[Derayah publicly advertises](https://web.derayah.com/en/open-api/) order placement,
edit/cancel, buying power, portfolio data, OAuth, webhooks and sandbox onboarding.
The page also displays example routes. These are evidence of advertised scope,
not an approved integration contract, granted account access, or guaranteed
idempotency/latency. Obtain schemas, credentials and acceptance criteria before
binding production behavior. Confirm US/Global versus Saudi access separately.

### Order intent and authorization

Stage an immutable intent containing account/connection, canonical broker
instrument, side, order type, exact decimal price/quantity, currency, time-in-force,
order version, fee estimate/version, data freshness, policy version and expiry.
Resolve account holdings, available shares, pending orders/reservations and buying
power server-side. Never trust the client's GREEN flag or raw journal as the
authoritative account state. Use decimal/integer money units, not binary floating
point. Unknown rules fail clearly; they are not silently filled with defaults.

An invalid tick or price band produces a proposed correction for review, not a
silent snap/clamp. Any change to terms invalidates prior confirmation. Recheck
account/session/tradability and expiry at submit, not just at stage. A quote is
not a guaranteed fill. Present estimated versus actual costs separately, using
the contracted fee/tax schedule rather than a universal 15.5-bps assumption.

In manual mode, the backend issues a single-use challenge bound to the intent hash, user,
device, session and expiry. User-presence-protected signing authorizes those
exact terms; backend verifies identity, signature, challenge consumption and
replay protection. A client `biometricSucceeded = true` flag or keyboard shortcut
alone is insufficient. App Attest supplements app integrity; it does not attest
which screen was viewed or whether the user understood an order.

[Apple documents macOS App Attest from macOS 27](https://developer.apple.com/videos/play/wwdc2026/201/).
The current 26.5 target therefore needs an explicitly reviewed alternative or
broker-hosted confirmation path; no silent downgrade based on a client-provided
unsupported flag. Development/simulator bypasses must never authorize production.

### Unattended execution is a first-class mode

Keep manual, sandbox automation and live automation visibly separate. Automation
is disabled until the owner enables a specific account policy, authenticating
that change rather than every subsequent trade. Record account, environment,
strategy/model/data versions, instrument/session allowlist, maximum order/risk/
portfolio exposure, loss limits, order-rate limit, freshness limits and the policy
version. Changing permissions or raising limits requires renewed authorization;
the model cannot do it. Evaluate the active policy on every proposed order and
again before dispatch; retain the decision and its evidence with the order.

The engine must halt new exposure when data, holdings, clock/session state or
reconciliation are uncertain. Bounded reservations prevent multiple acceptable
orders from jointly exceeding a limit. The kill switch revokes new dispatch,
reconciles in-flight orders and requests cancellation of eligible entry orders;
it must not blindly remove protective exits or claim that cancellation succeeded
before broker acknowledgement. Liquidation is a distinct policy/action.

Persist and recover the same state machine used by manual execution; do not add
a second ad-hoc order client. Restart never silently reenables a disabled policy.
Use an appropriately available execution host; a sleeping Mac or suspended phone
cannot guarantee timely synthetic stops. Approved broker-native protection is
preferable when supported. Contract/market support and production activation
remain prerequisites, not reasons to erase the automation feature.

Report research evidence honestly. An owner decision to use an unvalidated
strategy must not relabel it validated or bypass operational security/risk caps.
No draft-defined DSR shortcut or unreviewed Settings override is a substitute for
an explicit, tested activation policy.

### Operation-specific controls

| Operation | Authoritative checks |
|---|---|
| BUY / added exposure | Capability, account/session, instrument rules, costs, buying power and pending-order reserves, per-trade/portfolio risk and loss lockout |
| SELL to reduce a long | Current available shares minus other orders; no accidental short; tradability, identity and manual/policy authorization. No demand for a new trade's profit target/R:R or positive research score |
| CANCEL | Ownership, live broker state and cancellability; do not let entry loss lockout prevent cancellation of an entry. Warn if cancelling protection increases risk |
| MODIFY | Fresh intent/version/authorization; classify net exposure and changed protection, account for fills during modification; do not assume cancel-and-replace is atomic |

An account-security freeze may block every write; a trading-loss breaker is
different. Do not conflate the two. Unknown holdings prevent an unsafe SELL;
provide clear broker escalation, not an invented “close everything” success.

### Durable submission and reconciliation

Keep short database transactions around local state; do not hold a row lock
across a slow broker HTTP request. A durable dispatch claim prevents concurrent
workers from submitting the same intent. Reuse a stable broker client-order ID
only where its semantics are verified. Idempotency is scoped to account,
operation and request hash, not merely a UUID header.

```text
STAGED -> AUTHORIZED -> SUBMITTING -> SUBMITTED -> PARTIAL -> FILLED
                            |          |          |
                            v          +----------+--> CANCEL_PENDING -> CANCELLED
                    UNKNOWN / RECONCILING
                            -> resolved broker state, or manual investigation
```

Timeout after dispatch is UNKNOWN, not rejected and not permission to resubmit.
Reconcile via documented broker identifiers/history. Without upstream dedup or
conclusive non-acceptance, stop automatic retries. Include EXPIRED and REJECTED
terminal outcomes; a cancel request can race a fill. Deduplicate executions by
broker/account execution ID, handle out-of-order events and broker corrections,
and restore state from snapshots after reconnect/restart. Verify webhook
signatures using the actual contract, plus replay protection; HMAC header names
and a 300-second drift limit are not established facts. Poll when necessary.

Bracket/OCO support is a capability, not a promise. A manually staged stop is
not protection while the app sleeps. Prefer broker-native linked orders when
approved; otherwise disclose that no stop is active. Never synthesize an
unattended bracket executor under the guise of human-confirmed trading: if such
execution is supported, it must be part of the explicit automation policy.

## 7. Security and operating prerequisites

Use broker-approved OAuth flow with anti-CSRF state, PKCE where supported, exact
redirect/issuer validation and a defined verifier handoff. Backend-owned linking
can retain its own verifier; a native-owned flow must transmit it only through
the authenticated channel. The Secure Enclave does not store arbitrary OAuth
strings. The app holds its own short-lived session credential in Keychain, not
upstream broker tokens. Keep token rotation serialized and recover ambiguous
refresh-token rotation failures; never log tokens, request authorization or codes.

Envelope encryption binds ciphertext to tenant/connection and separates keys
from stored data. Managed runtimes do not guarantee wiping every copy of a token
with `buffer.fill(0)`. Minimize plaintext lifetime and logging instead of making
an absolute zeroization claim. Retain a redacted append-only audit with protected
exports/backups and tested restore/revocation, not sensitive raw webhooks forever.

Personal trading software and a service for other investors can have different
regulatory obligations. Have Derayah and qualified Saudi counsel establish the
app's operating scope, permissions, data licensing, residency/transfers, retention
and required approvals. Disclaimers and biometrics do not establish compliance.
[SDAIA guidance](https://dgp.sdaia.gov.sa/wps/portal/pdp/knowledgecenter/details/PDPLCP/%21ut/p/z0/04_Sj9CPykssy0xPLMnMz0vMAfIjo8ziPR1dzTwMgw2MDMOcTA3MjH39TE29jY0MQsz1g1Pz9L30o_ArAppiVOTr7JuuH1WQWJKhm5mXlq8fEeAS4OMcoF-Q7R4OAFcDiug%21/)
distinguishes personal/family use; do not presume the exception covers cloud
sharing or commercial operation. No blanket five-year or all-KSA rule is certified
by this document. Prefer an appropriate in-Kingdom host if required; verify GA,
service availability and residency of backups/logs/support before provisioning.
[AWS me-central-1 is UAE, not Riyadh](https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-regions.html).
Do not commit to a future Saudi launch date or automatic cloud migration.

## 8. Research that can actually test the money objective

Keep three separate datasets: historical replay, forward paper observations and
broker sandbox execution tests. None is a substitute for actual execution-cost
measurement. Preserve the existing paper trader; do not repoint its store to a
sandbox or mix either into the real-journal calibration.

Train chat on verified behavior/domain explanations. For trading hypotheses use
point-in-time prices, bid/ask and condition data, as-released news/catalysts and
corporate actions. Include delisted names where appropriate and prevent future
revisions/announcements leaking into earlier features. Freeze data/model/config
versions and prediction/decision timestamps. A random split of similar generated
Q&A cannot validate trading alpha. [Research on LLM look-ahead bias](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4586726)
supports careful evaluation; it does not prove that all future models are useless.

Compare each strategy against no-trade/cash, a relevant passive exposure and a
simple non-LLM baseline with comparable risk and costs. Measure net expectancy,
drawdown, turnover, tail losses, fill assumptions and realistic latency; stress
spreads, fees and slippage. Pre-register trials and holdout periods, purge overlapping
labels and report uncertainty appropriate to dependent trades. Count tuning/model
selection in the multiple-testing budget. Profit in a broker sandbox or a DSR
merely greater than zero is not a promotion rule. The repo's existing 0.95 research
convention is not a guarantee either. Lock a justified statistical/risk protocol
before evaluating the final holdout, with forward validation and kill criteria.

The research gate controls presenting a signal as validated and using it for
sizing. It must not prevent a user from cancelling exposure or closing a position.
No leverage increase, bigger sizing or real-money trial is authorized by this plan.

## 9. Build order and completion evidence

These are acceptance requirements, not completed checkboxes. Build against the
current source in isolated work, preserve concurrent provider migration, and
integrate only after reviewing the resulting diff. Never push for this task.

| Slice | Required result | Evidence to call it done |
|---|---|---|
| Existing correctness boundaries | Ordered/provenanced quotes; coherent sizing/cost/FX; reliable calibration/accounting; lifecycle/privacy | Regression witnesses from FULL_REVIEW at the real caller boundaries, including async interleavings and final decision invariants; no relying on a fallback runner that masks failure |
| Subscription/context | Owner purchase remembered; entitlement inventory | Durable owner note; key-redacted access results for each product; no guessed extras |
| Massive integration | US snapshots/history/trades/quotes plus verified extras | Parser/reconnect/freshness/corporate-action tests and labelled live smoke; Nasdaq attribution distinct from listing |
| Chat | Proactive briefing/feed, specific Q&A, source links, visible connection controls | Real UI run on macOS/iPhone; held-out grounding cases including Arabic, cancellation/offline/privacy and bounded history |
| Order core + mock | BUY/SELL/CANCEL/MODIFY, immutable review, durable state | Replay, expired/altered intents, concurrent duplicates, fill/cancel races, timeout reconciliation, risk-reducing exit and broker-unsupported cases |
| Sandbox | Approved Derayah link and holdings; four operations supported as contracted | Actual authenticated sandbox receipts and reconciliation after restart; no guessed endpoint success |
| Automation | Policy-authorized strategies use the same order core, sandbox first | Disabled-by-default and activation/revocation tests; aggregate risk reservations; stale-data/unknown-order halt; restart and kill-switch/fill-race tests; audit proves the exact active policy |
| AI selection/research | Measured assistant comparison and separate trading evidence | Frozen base-vs-adapter evaluation; point-in-time holdout/forward results with full costs and uncertainty; report failed hypotheses too |
| Production readiness | Contract, security, operational and applicable regulatory sign-off | Revocation/restore drill, authorization review, least privilege, actual capability/fee checks, supported-device confirmation and explicit production authorization |
| Integrated delivery | Updated app plus HANDOFF | Canonical tests on macOS and iPhone 17 Pro (gate), UI smoke, explicit results/remaining external prerequisites, no push |

Begin useful local implementation without waiting for broker approval: existing
client reuse, grounding, Chat and the mock order state machine. Obtain the real
Derayah contract in parallel; no live execution/deployment or external application
submission is implied. Do not mark the overall product goal complete merely
because this architecture or a mock passed review.
