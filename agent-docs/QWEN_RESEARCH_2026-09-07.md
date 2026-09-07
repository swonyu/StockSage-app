# Qwen research inputs and verification — September7,2026

Owner asked for stronger stock analysis, news and access to two supplied WhatsApp
groups. This slice adds retrieval, not new weights or a claim of predictive skill.
The existing4-bit Qwen/MLX server remains the only model process, on loopback8765.

## What reaches the model

- An immutable dated quote, technical rationale, earnings status and selected
  company observations, with source and missing/stale coverage made explicit.
- Up to three recent news excerpts through the existing Massive-first service,
  at most one EODHD fallback. External-access policy still applies. No result
  does not mean no news. News/provider opinions are attributed, not verified truth.
- Up to three distinct matching messages from the last30days of the private
  WhatsApp export index. Keyword retrieval uses ticker boundaries and aliases
  for Qualcomm, Amazon, AppLovin and Oracle; no new dependency or embedding model.
  These are W-prefixed unverified leads, separate from F-facts. Their numbers
  cannot authorize model assertions. Message instructions are never authority.

No account balances, journal, broker credentials, sender identifiers or contact
links are part of this retrieval. The loopback client rejects HTTP redirects.
Source/reference/number checks cannot establish semantic truth or profitability.

## Private WhatsApp snapshot

The two explicitly supplied ZIPs contain chat.txt/chat.md. Only chat.txt is read
in memory; no archive member is extracted or executed. Importer uses stdlib,
rejects unsupported/oversized/encrypted input, drops sender fields and system
notifications, redacts links/email/international phone patterns, and omits
credential-like content. Redaction is heuristic, not a universal PII detector.

Imported546 messages:24 Community +522 Wealth Club. Private index is273982bytes,
mode0600, at `/Users/saleh/Library/Application Support/StockSageResearch/whatsapp.json`.
Original exports remain untouched. The generated index is outside the repository
and is never staged, uploaded or used for fine-tuning. Export dates have no offset;
Asia/Riyadh is an explicit assumption shown in the UI/prompt. Authors' identity,
CFA claims and performance are unverified. Duplicate broadcasts are deduplicated
for each retrieved selection; they are not independent corroboration.

Runnable importer check: `python3 tools/import_whatsapp_research.py --demo` prints
`WhatsApp import self-check ok`. To refresh intentionally, use explicit new ZIP
paths with `--output` pointing to the same private index and `--replace`; then
Reassess in the app. Import is atomic and defaults to refusing an overwrite.
This is NOT a live WhatsApp subscription. No login, group join, message send,
background WhatsApp read or cloud upload occurred. iPhone access is not configured.

## Real QCOM failure and repair

The original model supplied valid action/reason/risk JSON but omitted evidence.
A captured replay isolated that missing fourth field; the numeric guard passed
both sentences. A single format-repair call preserved Hold and both sentences
exactly, but supplied four genuine F references. The original three-ID cap
rejected it. Regression now pins four valid references and rejects forged IDs,
duplicates, changed actions/reasoning and unsupported numbers. Citation count is
bounded by supplied facts rather than an arbitrary display cap. No retry loop.

The news-enriched native QCOM reply exposed another false rejection: inline
F13 was tokenized as a financial13. The parser now validates offered F/W
identifiers separately, excludes only those valid identifiers from numeric
comparison, and still checks every actual number. W IDs must exist in the
captured lead selection and cannot enter the evidence array. Inline-reference,
forged-ID, unsupported-number and W-as-evidence regressions pin this distinction.

Failed assessment output remains visible as an unverified plain-text draft,
including its original response and context. It cannot become an accepted badge
or enter sizing/EV/stops/trades. The older optional Catalyst explanation path
still has its prior withholding behavior; this change covers the primary AI
assessment path. Missing transport output cannot be displayed as a model answer.

## Strategy research: first evidence pass, not a validated strategy

The practical direction is to test lower-turnover, cost-aware candidates rather
than reward increasingly confident prose. Frazzini/Israel/Moskowitz studied
institutional trading costs and their dependence on trade size and stock/market
characteristics. Those cost estimates are not a substitute for this owner's
broker fees, spreads and slippage. [Trading Costs,2018](https://www.aqr.com/insights/research/working-paper/trading-costs).

Their earlier anomaly study distinguishes value/momentum portfolios from
short-term reversal and explicitly lags formation inputs to make portfolios
implementable. It is a candidate-design reference, not evidence Qwen can pick
next week's winners. [Author-hosted paper](https://pages.stern.nyu.edu/~afrazzin/pdf/Trading%20Cost%20of%20Asset%20Pricing%20Anomalies%20-%20Frazzini%2C%20Israel%20and%20Moskowitz.pdf).

Bailey/LópezdePrado's DSR addresses multiple-testing selection and non-normal
returns. Keep every attempted variant in the trial ledger; selecting only good
backtests would invalidate the comparison. [Original paper](https://www.davidhbailey.com/dhbpapers/deflated-sharpe.pdf).

Proposed next experiment (NOT executed): freeze existing rules, cash/benchmark,
a simple lower-turnover momentum baseline, and Qwen with/without news/group
retrieval before an untouched chronological evaluation. Log model/prompt/source
snapshots; measure total-portfolio net returns, drawdown, turnover and losing
weeks, not language-model loss or isolated winners. Historical Qwen tests also
risk pretrained future knowledge: start with prospective paper snapshots, and
never use a later group post/news item at an earlier decision timestamp.
Reuse existing backtest/cost/DSR helpers; fix known M8 fee-sizing and M4 horizon
defects first. No new baseline was run and no weekly return goal was established.

## Release evidence

Initial news/group feature: focused67/67; macOS1752/1752; iPhone17Pro(gate)1750/1750.
Final inline-reference fix: macOS1752/1752 and iPhone1750/1750, all passed.
Three opt-in suites excluded as in HANDOFF. Final bundles:
`/private/tmp/stocksage-ai-inline-final-macos-20260907-0350.xcresult` and
`/private/tmp/stocksage-ai-inline-final-ios-20260907-0352.xcresult`.
Real replay and native UI checks are recorded in HANDOFF.
No real trades, pushes, cloud purchases, training or second model server.

Native quality caveat: AMZN03:47 and APP03:49 returned accepted Hold opinions
with real news and three private leads each. APP incorrectly generalized a
30-day query window to8-K/guidance; actual feed windows differ. This passed
mechanical validation because30 existed in the inputs. It is a confirmed
semantic error to include in evaluation, not proof every cited model claim is
correct. News was often multi-company commentary rather than primary filings;
better relevance/source coverage remains work, not a hidden completed claim.
