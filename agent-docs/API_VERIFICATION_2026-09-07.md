# StockSage API acceptance — 2026-09-07

Owner00:59 +03: every API must work. This is an endpoint-by-endpoint acceptance
ledger, not a claim that the integrations below are currently working.

## Latest model result — 01:49 +03

Owner approved4-bit conversion/server startup at01:41. Native Catalysts settings
now select Local server only at127.0.0.1:8765 with the exact fine-tuned model ID
`/Users/saleh/models/salehman-qwen38-27b-4bit`. Actual app `/api/tags` returned404
(expected: this is MLX, not Ollama), `/v1/models` returned200 with the model, and
`/v1/chat/completions` returned responses. SBLK's actual card facts+Massive news
flow produced a cited paragraph that passed validation and rendered. PAA's first
paragraph was withheld by the unchanged numeric guard. No all-model-quality
claim. Details and stop/restart instructions: `LOCAL_QWEN_2026-09-07.md`.

Massive news, ratings, guidance and8-K observations were visible in native
Catalysts during this test. Treat that as consumer evidence, not proof of all
pagination/empty/error/freshness/entitlement cases. Remaining per-route checks
are still open. No key was extracted, and no credential guard was bypassed.

## Latest live provider result — 01:36 +03

Owner01:34 explicitly requested opening the new build and deleting the old one.
The installed `/Applications/StockSageX.app` executable was from July28, not the
tested coverage worktree. Quit its process18626 normally, verified no StockSage
process remained, moved only that bundle to
`/Users/saleh/.Trash/StockSageX-old-20260907-0134.app` (recoverable), and installed
the macOS build tested at d7c84a0. Executable comparison and strict deep codesign
verification passed. One new installed-app process20169 was running afterward.
User data/preferences were not deleted or rewritten by the installation.

The new native Settings → Data sources showed a populated SecureField. Its
existing Test connection control returned **Connected — HTTP 200, AAPL snapshot
parsed.** This proves the configured key works through the real native snapshot
request/parser/settings consumer. No key was read/revealed or passed through a
shell. Full store provenance/freshness and every other paid route remain pending;
a snapshot pass is not proof of WebSocket delivery or add-on entitlements.

This supersedes the blanket credential-blocked description for native Massive
snapshot testing. The separate presence-only shell check at01:32 was still
denied by PreToolUse; no hook/security change or alternate secret extraction was
attempted. Use supported app controls for further live checks. Do not retry the
denied credential read. The table below retains the **initial01:06 audit state**
as history; this section is the newer evidence, not a claim that all routes work.

## Acceptance rule

VERIFIED requires a dated real request using the configured integration, the
expected schema and instrument, correct provider/time/currency handling, and
the actual app consumer. An authenticated socket without T/Q delivery is not
verified. HTTP200 with an error envelope or malformed body is not an answer.
Valid empty results must remain distinguishable from errors. Unit fixtures and
transport-only probes are useful evidence, but neither is end-to-end acceptance.

No key values, authorization headers, account data or raw provider responses are
recorded here. Verification never authorizes real orders, paid provisioning,
guard bypasses, a duplicate Stocks socket or loading the large local model.

## Reachable source inventory — initial 01:06 audit

Fourteen in-tree Swift files contain URLSession/URLRequest/WebSocket or auth
entry points. Caller search includes the store, Markets detail, Catalysts,
NBBO/tape views and model-settings probe; helper presence alone is not wiring.

| Route | Shipped consumer | Live acceptance status |
|---|---|---|
| Massive `/v2/snapshot/locale/us/markets/stocks/tickers` | QuoteService → store; settings probe | BLOCKED: credential-access guard; snapshot alone cannot prove other feeds |
| Massive `/v2/aggs/ticker/{ticker}/range/1/day/{from}/{to}` | Adjusted history → quote/scan engines | BLOCKED: same credential access |
| Massive Stocks WebSocket `T.*` | Existing LiveStream → trade quotes/store | BLOCKED: authenticated delivery not verified; no second socket opened |
| Massive Stocks WebSocket `Q.*` | Same socket → NBBO/spread inputs | BLOCKED: independent quote delivery/freshness not verified |
| Massive `/v3/trades/{ticker}` | On-demand tape | BLOCKED: credential access; require pagination/time-window verification |
| Massive `/v3/quotes/{ticker}` | On-demand tape | BLOCKED: same; not interchangeable with trades |
| Massive `/v3/reference/exchanges` | Tape/NBBO/stream exchange attribution | BLOCKED: require live MIC mapping, not guessed Nasdaq ID |
| Massive `/v3/reference/conditions` | Stream quote-condition eligibility | BLOCKED: require actual quote-condition metadata |
| Massive `/benzinga/v1/earnings` | First calendar source → catalyst chain | BLOCKED: credential/entitlement verification |
| Massive `/v2/reference/news` | NewsService → Catalysts/narration context | BLOCKED: credential/entitlement verification |
| Massive `/stocks/v1/splits` | Dated journal-basis comparisons | BLOCKED: credential/complete-result verification |
| Massive `/benzinga/v1/ratings` | Company-event cache → catalyst cards/calendar | BLOCKED: credential/entitlement verification |
| Massive `/benzinga/v1/guidance` | Same event pipeline; paired guidance bounds | BLOCKED: credential/entitlement verification |
| Massive `/stocks/v1/dividends` | Same event pipeline; ex-date/currency | BLOCKED: credential/entitlement verification |
| Massive `/stocks/filings/8-K/vX/disclosures` | Same event pipeline; filing provenance | BLOCKED: credential/early-access entitlement verification |
| Massive `/stocks/filings/vX/form-4` | Same event pipeline; transaction/filing dates | BLOCKED: credential/early-access entitlement verification |
| Yahoo `/v8/finance/chart/{symbol}`, quote/FX request | Non-US/missing-Massive fallback; infra SAR FX | FAILING transport probe: HTTP429 for AAPL,2222.SR,USDSAR=X |
| Yahoo same chart route, history parameters | Missing-Massive/non-US history | UNVERIFIED: no separate historical-range live probe; host returned429 above |
| Yahoo `quoteSummary`, `calendarEvents` | Calendar fallback → catalyst chain | FAILING transport probe: HTTP429 for AAPL and2222.SR |
| Yahoo `quoteSummary`, `earningsHistory` | Non-US historical earnings fallback | FAILING transport probe: HTTP429 for2222.SR |
| EODHD `/api/calendar/earnings` | US calendar fallback/availability probe | BLOCKED: not live-authenticated this pass; historical entitlement state is not new evidence |
| EODHD `/api/fundamentals/{symbol}`, earnings history | US historical earnings fallback | BLOCKED: not live-authenticated this pass |
| EODHD `/api/news` | Empty/unavailable Massive news fallback | BLOCKED: not live-authenticated this pass |
| SEC `company_tickers.json` | Disclosure CIK map; separate Insider CIK loader | FAILING transport probe: HTTP403 using Disclosure's current User-Agent; Insider's different agent not tested |
| SEC `submissions/CIK{cik}.json` | Disclosure and Insider filing selection | BLOCKED by failed live CIK-map prerequisite; not independently probed |
| SEC filing directory `index.json` and selected XML | Insider Form4 parsing | BLOCKED by upstream lookup; neither downstream request sent |
| Model server `GET /api/tags` | Ollama discovery in settings/narrator | Default localhost probe unreachable; configured override not inspected |
| Model server `GET /v1/models` | OpenAI-compatible discovery fallback | UNVERIFIED: actual configured server not inspected/probed |
| Model server `POST /api/chat` or `/v1/chat/completions` | Optional catalyst narrator | UNVERIFIED: no generation/model load performed |
| Derayah linking, portfolio, balances, BUY/SELL/CANCEL/MODIFY, order status | Approved future backend/native execution flow | BLOCKED: supported contract, implementation and sandbox credentials required; no endpoints invented |

The old EODHD quote and WebSocket routes are retired from the shipped quote
chain, not newly disabled by this audit. Calendar/history/news fallbacks are
still reachable. Future native Chat and Derayah services require their own
acceptance entries when implemented. This inventory covers current in-tree
provider requests, not every endpoint offered by every vendor.

## Executed live probes

01:04:28–01:04:30 +03: seven sequential keyless GETs, eight-second timeout,
four-MB response cap, no retries. Python stdlib HTTP/JSON diagnostic used the
same URL/query and User-Agent as the corresponding QuoteService/Earnings or
Disclosure source. These were NOT the native app's URLSession or parser/UI.

- AAPL chart:429;2222.SR chart:429;USDSAR=X chart:429.
- AAPL calendarEvents:429;2222.SR calendarEvents:429;
  2222.SR earningsHistory:429.
- SEC ticker map:403. No CIK was recovered, so no guessed submissions request
  followed. Headers/alternate endpoints/proxies were not changed to evade denial.
- Process completed exit0 because it records per-route failures; that process
  status is NOT an API pass. No retry loop was started after the failures.

01:06:05 +03: one GET to the CODE DEFAULT `127.0.0.1:11434/api/tags`, three-second
timeout, returned a transport URLError. No registered-model names or app
preferences were read. This does not establish that the owner's configured
server is down; only that this default probe did not reach one. No chat request,
model loading, conversion, training or server startup occurred.

Massive/EODHD keys were not retrieved or retried through alternative paths. The
existing credential guard remains a blocker, not evidence of a missing key or
an insufficient subscription. No live trade/quote socket was created.

## Prioritized follow-through

1. Through the supported credential/app path, verify each paid Massive route
   separately and fix genuine request/parser/wiring failures. Read error status
   without logging credentials; do not infer entitlement from a snapshot pass.
2. Distinguish upstream throttling/denial from app bugs. Respect retry limits;
   do not solve429/403 by proxy/IP/header evasion. Required non-US quote/FX
   availability remains an explicit dependency, not synthetic data.
3. N09 response classification now has a passing isolated replay and56 focused
   tests: Yahoo calendars and Yahoo/EODHD history/calendar payloads distinguish
   valid-empty from missing/error/partial. Both Yahoo fetch paths share the
   validated outcome; malformed input cannot earn a refresh stamp in the tested
   response→chain/refresh seam. Canonical gates passed1740 macOS/1738 iPhone,
   documented in HANDOFF01:24. This does not repair the separate live429/403
   failures or prove the provider's live schema; route acceptance above is unchanged.
4. Verify native UI provenance/freshness and cancellation behavior after real
   data is available, using the existing socket and without overwriting the
   owner's running build. Model discovery is not generation/quality proof.
5. Derayah sandbox acceptance must use its real agreed contract, including
   uncertain submission/reconciliation and idempotency. No production orders
   are part of development verification.

M9 dated-FX protection is locally committed as60c8d3d with1738 macOS and1736
iPhone tests passed. Those gates explicitly exclude live-universe verification;
they do not supersede any BLOCKED/FAILING/UNVERIFIED entry above.
