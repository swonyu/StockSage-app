# StockSage API acceptance — 2026-09-07

Owner00:59 +03: every API must work. This is an endpoint-by-endpoint acceptance
ledger, not a claim that the integrations below are currently working.

## Form4 Store/UI acceptance completed — 06:07 +03

Normal toolbar refresh after the retry window persisted all nine previously
truncated Form4 observations as answered at03:04:39–03:04:45Z. No manual cache
change. Native CRWD card and expanded Company feeds disclosure show5/5 current
checks, selected Form4 sale filedSeptember4 and checkedSeptember7. The remaining
cached failures are exactly SBLK/TEM's genuine direction conflicts. The nine-case
request/parser acceptance below now includes Store/UI publication. Broader API
routes and P5 retain their independent requirements.

## Form4 pagination: all nine configured fetches pass — 05:54 +03

Shared company-event fetch now follows up to10 sequential100-row pages with a
2MB aggregate validation cap, exact-host/path header authentication/no redirects,
and policy/cancellation/cooldown checks on every request. Any bad/incomplete
later page remains unavailable with no selected event. All five feeds use this
path; no new Store concurrency, retry loop or partial-success semantics.

Installed app's actual fetches at02:51:17–02:51:32Z answered for all nine former
pagination failures: CRWD,UTHR,NAVN,STX,CRNX,CBRS,FLYW,CHYM,CLBK. Eight required
two pages; CHYM required eight (706rows/1,748,224bytes), within measured bounds.
CRNX is complete-empty of qualifying transactions; the other eight select an
event. All24 captured pages replay offline to identical native Observations.
No key/header was inspected; raw cursor/request-ID stripped from private captures.
Regression red→21focused passed; full1764macOS/1762iPhone passed with the same
three opt-in exclusions. Tested app installed; exact artifacts/limits in HANDOFF.

Request/parser acceptance is complete for THESE nine responses. Store/UI is not
yet verified: the cache still holds nine failures checked05:48 until their normal
15-minute retry is due after06:03. No manual cache edit/reset. Verify normal
refresh and native feed disclosure next; SBLK/TEM source conflicts remain real.
No universal API success or pipeline-completion claim.

## SBLK/TEM Form4: source conflict, not access failure — 05:34 +03

Both configured fetches reached the installed app's parser. Offline replay
isolated one contradictory row each: S transaction code with A acquired/disposed
flag. The original SBLK SEC filing and TEM issuer-hosted filing contain the SAME
conflict; exact primary-source links and accessions are in HANDOFF05:32. Do not
guess which field is correct, call the feed empty, or override the validator.

The existing failure path now distinguishes conflictingTransactionDirection from
generic invalidPayload. Focused18/18 and serial1761macOS/1759iPhone passed,
with the same three opt-in exclusions. Installed native SBLK disclosure visibly
states the conflict, still4/5 checks. Normal refresh persisted the precise reason
for TEM02:33:22Z and SBLK02:33:24Z. No manual cache edits or credential inspection.
These two remain data-quality failures; nine separate incompleteResponse cases
remain at the measured one-page/100-row ceiling. Pagination is the next code
issue; no all-API or pipeline-completion claim. Full artifacts in HANDOFF.

## Form4 configured response and native consumer — 05:19 +03

One GILD request returnedHTTP200/13,663bytes/11rows; the actual shared parser
rejected live security_type=non_derivative, although docs specify non-derivative.
Field-only control proved the mismatch. Both exact aliases are now accepted;
unknown security types, derivatives and incomplete pages retain existing checks.
Original captured response now passes without normalization. Regression red,
then17/17 focused and1760macOS/1758iPhone full serial gates passed (same three
opt-in exclusions). Exact evidence and limitations are in HANDOFF05:19.

The newly installed app's normal refresh and native GILD disclosure independently
show5/5 current company-feed checks, including a Form4 sale filedSeptember2;
the persisted Form4 checkedAt is2026-09-07T02:17:12Z. This is actual configured
request→parser→store→UI evidence for this response, not universal feed acceptance.
The private offline diagnostic used normal configuration helpers; it did not
print/export key values or headers. No app cache was manually edited.

Across the app's company cache, Form4 invalidPayload fell285→2. Still failing:
SBLK,TEM (invalidPayload); CRWD,UTHR,NAVN,STX,CRNX,CBRS,FLYW,CHYM,CLBK
(incompleteResponse, existing one-page/100-row ceiling). These11 remain explicitly
unavailable, not empty or verified. Diagnose the two validation cases next, then
bounded pagination using real evidence. Other routes below retain their separate
acceptance requirements. No real orders, pushes or extra model process.

## Native research consumer verified — 03:57 +03

QCOM03:55, AMZN03:47 and APP03:49 rendered Hold opinions from the exact local
Qwen model with selected Massive news and3 local group leads each. AMZN news
links/source labels/dates were inspected; QCOM's full supplied facts showed
actual Massive news rows, not fixtures. This verifies this bounded news→model→UI
consumer, not the EODHD fallback or every provider route. Form4 still reports
Response failed data validation for QCOM/AMZN; not a guessed missing credential.
Semantic mistakes and sample-header inconsistency remain recorded in HANDOFF.
Final software gates1752macOS/1750iPhone passed; final installed build includes
inline-reference parsing. No new subscription, key extraction or WhatsApp API.

## Qwen primary assessment and research — 03:45 +03

The final tested research build is installed (macOS1752/iPhone1750, all passed).
Actual captured QCOM response replay against the local model now repairs missing
citations while preserving its Hold action and reasoning, exit0. No credential
access involved. Assessment reuses existing Massive-first/EODHD-fallback news;
source-bearing native checks follow in HANDOFF. This does not certify every
provider route.546 private export messages are a local snapshot, not a WhatsApp
API integration. No model training or cloud upload. See QWEN_RESEARCH/HANDOFF.

## Company-feed diagnostics and ORCL — 02:31 +03

Native company-feed disclosures showed GILD4/5 (Form4 unavailable), with five
successful checks on other symbols. Ratings, dividends,8-K and news records
were rendered. These are consumer observations, not full route acceptance;
GILD's precise failure is still unknown, not assumed to be an entitlement issue.
Added fixed failure categories/HTTP status through the real shared response,
cache and UI path. Future due checks can identify HTTP/transport/timeout,
cooldown/policy/configuration, validation, pagination and size-limit failures.
Old cache records explicitly say their reason was not recorded. No new requests,
retries, cap changes or credential extraction. Focused16/16; macOS1741/1741 and
iPhone1739/1739 passed. Exact evidence/limits in HANDOFF02:31. Not installed yet.

Read-only ORCL app cache: priceSource massiveSIP; history source massiveDaily,
251 bars through September4; catalyst_records_v1.json records dateKnown,
confirmed=true, source Massive/Benzinga earnings, earningsDate September10.
Oracle's official September2 announcement independently confirms earnings after
US close September10,2026:
https://investor.oracle.com/investor-news/news-details/2026/Oracle-Sets-the-Date-for-its-First-Quarter-Fiscal-Year-2027-Earnings-Announcement/default.aspx
This confirms the scheduled date, not a beat, price direction or profitable trade.
No data cache was edited. Qwen badge assessment is requested but not implemented.

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

01:06:05 +03: one GET to `127.0.0.1:11434/api/tags` -- THE CODE DEFAULT AS OF THIS
2026-09-07 SESSION, not current (Qwen removal Step 7, 2026-09-16, flipped the
shipped default to the managed Gemma pair at 127.0.0.1:1234) -- three-second
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
