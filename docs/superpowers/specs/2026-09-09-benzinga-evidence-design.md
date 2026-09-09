# Benzinga shared evidence through Massive

Status: shared-evidence approach approved by the owner on 2026-09-09. At 04:37
the owner cancelled direct Benzinga integration: the existing Massive key is enough.
No direct key was collected, saved or tested. Direct-key source was removed from
the parent checkout with a recoverable private scratch copy; it was never installed.
The 04:40 reliability workflow keeps this session as sole repository writer and
installer; six supporting tasks now review read-only.

## Goal and boundaries

Connect the nine purchased Massive/Benzinga products to existing StockSage views
and local Qwen through one bounded evidence snapshot using the existing Massive
credential. Do not add a direct Benzinga key, settings field or transport. Keep
the working Massive quote stream.

Reuse Settings, stock details, Catalysts and Chat. Do not add nine dashboards, a
backend, dependencies, training, broker execution or a second model server. Do not
change paper-trading rules, numeric acceptance, model configuration or the ledger.
The separate numeric-format proposal remains unapproved and is not part of this work.

## Verified starting point

Parent checkout: `StockSage-wt/qwen-context`, `codex/qwen-chat-context`, source
`7e8b312`. Existing earnings parsing selects scheduled dates only. Existing
`StockSageMassiveEvents` already supplies ratings and guidance with availability
and opinion caveats. Mac and iPhone share `StockSageMassiveKeyField`; no dedicated
Benzinga field or Keychain helper was found in the app source.

At 2026-09-09T01:12:10Z, nine bounded GET probes using the existing Massive
credential each returned HTTP 200, status OK and one result. Concurrency was three,
limit one, timeout 15 seconds, response cap 1 MB; only status/count metadata was
reported. This proves access at that time, not app integration, historical coverage,
market-data latency, or direct Benzinga entitlements. Credentials and response bodies
were not retained in the evidence record.

| Product | Verified Massive path | Integration use |
|---|---|---|
| Earnings | `/benzinga/v1/earnings` | Extend date-only handling with separately labelled reported EPS/revenue and fiscal period |
| Guidance | `/benzinga/v1/guidance` | Reuse existing observations; guidance remains an issuer expectation |
| Ratings | `/benzinga/v1/ratings` | Reuse existing observations; analyst actions/targets remain attributed opinions |
| Analyst insights | `/benzinga/v1/analyst-insights` | Bounded, dated explanatory source text |
| Bulls/Bears Say | `/benzinga/v1/bulls-bears-say` | Both sides, attributed and not converted into an app recommendation |
| News | `/benzinga/v2/news` | Dedicated product identity and dated headlines/excerpts |
| Analyst details | `/benzinga/v1/analysts` | Resolve analysts referenced by returned records using documented identifiers |
| Firm details | `/benzinga/v1/firms` | Resolve referenced firms; no full-directory download |
| Consensus | `/benzinga/v1/consensus-ratings/AAPL` | Generalize the documented ticker path; counts and target summary are analyst opinions |

The catalog is [Massive's partner overview](https://massive.com/docs/rest/partners/overview).
Analyst/firm joins must use documented IDs, not name matching or invented filters.
The plan must pin each product's documented request/response contract before coding it.

## Credential and transport boundary

Reuse Massive's existing bearer-header, fixed HTTPS origin and no-redirect policy.
Never place credentials in URLs, Qwen context, chat history, reports or logs.
Recheck ToolPolicy, cancellation and credential generation before dispatch and
after every await. Distinguish authorization, entitlement, throttling, transport,
malformed, partial and successful-empty outcomes without echoing server bodies.

## Shared evidence and provider routing

Use one concrete product-aware snapshot type with per-product observations, not
a new generalized provider framework. Retain provider/product, symbol, stable record
identity, publication/event time, provider update time, local checked time, data,
availability and any bounded failure category. Never substitute checked time for
publication time. Missing/failed/partial is different from a successful empty response.

Reuse existing earnings, ratings and guidance parsers/caveats. Keep upcoming-date
selection independent from reported earnings. Metadata products do not become new
scheduled Catalyst kinds. A consumer receives the same captured snapshot, not a
second independent fetch that changes evidence while Qwen is answering.

For news, try Massive's dedicated Benzinga news, then the existing generic Massive
news and EODHD fallback chain. Retain ordered attempt outcomes with explicit product
identity; at most three attempts, no retries. Stop on usable data; cancellation or
policy denial stops the chain. All nine products use the existing Massive credential.

Normalize dedicated Massive/Benzinga news into the existing NewsItem contract. Preserve
original publication offset and precision; retain material revisions. Do not deduplicate
different text solely by headline, date or ticker. A missing full body is legitimate;
the [Massive news contract](https://massive.com/docs/rest/partners/benzinga/news)
allows headline-only records. HTML/script content is text, never executable UI or instructions.

## Bounded work, not per-tick fetching

Fetch on explicit stock research, existing paper-research cycles and relevant view
refreshes, never on each quote tick. Share in-flight requests by provider, product,
symbol/query and credential generation. Maximum three evidence requests in flight
app-wide; keep the existing paper candidate count and worker count unchanged.

New product lookups have a 12-second deadline, at most one page of 20 records and
2 MB received bytes per response, cancelling transport at the byte limit. Label
bounded results as a recent sample, not complete coverage; existing calendar/event
pagination and failure semantics remain unchanged. Reference metadata is fetched
only for retained records, at most three analysts and three firms per snapshot.

Cache new news lookups for 30 seconds, other event lookups for five minutes,
consensus for two hours and reference metadata for 24 hours; at most 500 product/query
entries, oldest-access eviction, memory only. Expiry is a refetch policy, not proof
of source freshness. Consensus itself is documented as updating every two hours in
the [product contract](https://massive.com/docs/rest/partners/benzinga/consensus-ratings).
Respect Retry-After with bounded cooldown; no retry storms. Manual connection tests
bypass old authorization-denial caches only, not provider throttling. Preserve quote
transport and its separate ten-second executable-observation rule.

## StockSage and Qwen consumers

Present product availability and provenance inside existing detail/Catalysts/Chat
surfaces. Analyst/firm details enrich their parent records rather than gaining tabs.
Both bull and bear source summaries remain visible when supplied; incomplete products
are labelled independently. Do not claim the entire market or all history was checked.

Chat, assessment and automatic paper research consume bounded projections of the
shared snapshot: at most three retained records per product, 400 characters per
source excerpt and 12,000 characters total added evidence, including attribution.
Reserve one compact status/summary per product first, then use remaining budget for
dated records; disclose omitted records. News text and external claims remain untrusted
source context, separate from compiled price/balance facts. Targets, consensus and
guidance are never executable prices or promised returns. No automatic training.

Keep evidence IDs tied to the captured snapshot and preserve existing citation,
numeric, schema, time and execution checks. Recheck permission and configuration
generation before publishing any asynchronous result. A provider failure can reduce
available evidence but cannot become an invented fact or forced Buy/Sell decision.

## Verification and release

1. Review/integrate the completed feed and Qwen diagnostics plus the independently
   tested news-outcome work before touching overlapping consumers. Parent is the
   integration writer; heavy tests stay serial with isolated DerivedData and two jobs.
2. Add offline tests for configuration races, request host/header/redirect policy,
   secret-safe diagnostics, streaming response caps and dedicated-news parsing.
   Automated gates use synthetic keys, never the owner's credential.
3. Cover all nine parsers/adapters, missing versus empty/partial, timestamps/revisions,
   cache/single-flight bounds, fallback provenance, metadata joins and Qwen projections.
   Prove analyst targets cannot enter quote/settlement fields and policy revocation
   suppresses late results. Preserve existing numeric acceptance with regression checks.
4. Run focused tests, full macOS and iPhone 17 Pro (gate) tests and `tools/gate.sh`
   all, keeping the three existing exclusions unchanged. Record real runner exits,
   counts and tested-source hashes. No simultaneous heavy builds.
5. Install through the normal parent-controlled replacement flow after combined gates.
   Verify Massive/Benzinga provenance and the existing local Qwen connection without
   changing model settings or launching a second model. Report access separately from
   completed consumer integration. No push or real orders.

## Self-review

All nine previously verified products use Massive; direct Benzinga is cancelled.
Routing expands the news worker's two-attempt limit to three in parent integration.
Numeric-format approval, live quote freshness and paper rules are untouched.
No secret or vendor response body is in this spec. Access checks are not a claim
that the nine-product consumer integration is already implemented or verified.
