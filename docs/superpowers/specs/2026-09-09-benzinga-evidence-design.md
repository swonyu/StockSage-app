# Benzinga evidence and separate direct API key

Status: shared-evidence approach approved by the owner on 2026-09-09;
owner subsequently confirmed a key issued directly by Benzinga. This written
spec awaits owner review before implementation planning. No key has been collected,
saved or tested for the direct service; no application behavior changed by this document.

## Goal and boundaries

Connect the nine purchased Massive/Benzinga products to existing StockSage views
and local Qwen through one bounded evidence snapshot. Add a separate, secure place
to enter the owner's direct Benzinga key, starting with a real news connection test
and direct-news consumption. Keep the working Massive credential and quote stream.

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

## First delivery: direct Benzinga key

Add a shared row to **Settings → Data sources** on macOS and iPhone, separate
from Massive. Label it **Benzinga API key (direct)**. Reuse the existing settings
layout, but not its UserDefaults secret storage.

- Use native Security/Keychain storage: a single app-owned, device-local item;
  no iCloud synchronization, generic credential framework or new dependency.
- A blank SecureField accepts a replacement. Explicit Save validates a nonempty,
  bounded value with no embedded whitespace/control characters. Never load the saved
  secret into the visible form. Clear the draft after a successful save or dismissal.
- Show saved/not configured/storage unavailable without showing any part of the key.
  A failed replacement must preserve the previous working item. Remove deletes only
  this provider's item. Keychain access failure is visible, never a plaintext fallback.
- Saving alone makes no network request. **Test Benzinga news** makes one read-only
  `GET https://api.benzinga.com/api/v2/news?pageSize=1&displayOutput=headline`.
  Show checked time and news-only outcome; success is not permission for all products.
- Distinguish HTTP 401, 403, 429, transport failure, malformed response, empty valid
  response, policy denial and cancellation without echoing server bodies or raw errors.
- Apply ToolPolicy before request and after await. Credential changes invalidate
  direct-provider cached authorization/results and suppress old-generation completions.
- Never send this key to Massive, Qwen, chat history, telemetry, backups or source
  control. Do not inspect the user's clipboard or ask them to paste it in chat.

### Authentication contract and verification

The [authentication page](https://docs.benzinga.com/api-reference/authentication)
recommends a header and includes `Authorization: token <key>`, while the
[news endpoint schema](https://docs.benzinga.com/api-reference/news-api/get-news-items)
marks a query token required. The official documentation is inconsistent; header-only
support must therefore be verified with the owner-entered key, not assumed.

Use header-only authentication initially, with a fixed HTTPS origin, no redirects,
ephemeral URLSession, no URL cache/cookies and bounded response handling. Do not
silently retry using a credential-bearing URL. If the service rejects header-only
authentication, retain the key securely and report the unresolved transport contract;
seek a documented resolution before exposing the token in any URL. A test failure
must not disable or replace the working Massive integration.

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

For news, try configured direct Benzinga first, then Massive's dedicated Benzinga
news, then the existing generic Massive/EODHD fallback chain. Retain ordered attempt
outcomes with explicit product identity; at most four attempts, no retries. Stop on
usable data; cancellation or policy denial stops the chain. An absent optional direct
key is not an authentication failure. All other eight product integrations use the
already-verified Massive entitlement in this delivery; buying a direct key does not
prove its other product entitlements or authorize speculative downloads.

Direct news has a different response schema/date format from Massive news. Implement
and test a separate parser, normalizing into the existing NewsItem contract. Preserve
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
2. Add offline tests for credential isolation, storage failure, replacement/removal,
   configuration races, request host/header/redirect policy, secret-safe diagnostics,
   response caps and direct-news parsing. Automated gates use synthetic keys and
   disposable test identities only, never the owner's Keychain item.
3. Cover all nine parsers/adapters, missing versus empty/partial, timestamps/revisions,
   cache/single-flight bounds, fallback provenance, metadata joins and Qwen projections.
   Prove analyst targets cannot enter quote/settlement fields and policy revocation
   suppresses late results. Preserve existing numeric acceptance with regression checks.
4. Run focused tests, full macOS and iPhone 17 Pro (gate) tests and `tools/gate.sh`
   all, keeping the three existing exclusions unchanged. Record real runner exits,
   counts and tested-source hashes. No simultaneous heavy builds.
5. Install through the normal parent-controlled replacement flow after combined gates.
   The owner enters the direct key in the app, then performs the bounded connection
   test. Verify direct/news provenance and the existing local Qwen connection without
   changing model settings or launching a second model. Report access separately from
   completed consumer integration. No push or real orders.

## Self-review

The direct key is separate from already-working Massive access. Initial direct use
is news, not an unsupported promise of every Benzinga SKU. All nine previously
verified purchased products still have a consumer path through Massive. Routing
explicitly expands the news worker's two-attempt limit to four in the parent integration.
Numeric-format approval, live quote freshness and paper rules are untouched. The
authentication documentation conflict remains a named live-verification condition,
not silently guessed or bypassed. No secret or vendor response body is in this spec.
