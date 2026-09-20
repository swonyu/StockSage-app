# Massive/Benzinga typed evidence handoff

Worker: `codex/benzinga-evidence-20260909`, isolated from integration baseline
`50c96cc`. Scope: two new source files, one offline test file, this handoff.
No existing parser/consumer/project edits. Owner's 04:37 clarification cancels
all direct-key/provider work; this implementation uses Massive only.

## Concrete integration API

- `StockSageBenzingaEvidence.Product.allCases`: all nine purchased products.
- `request(_:symbol:referenceID:key:) -> URLRequest?`: explicit Massive key,
  fixed origin, bearer header, 12 seconds, limit 20, documented filters only.
- `parse(_:product:symbol:referenceID:checkedAt:) -> Observation`: pure,
  per-product state plus typed records, at most 3 retained from first 20 rows.
- `StockSageBenzingaEvidenceClient(key:permitted:now:load:)`: MainActor concrete
  client; no default transport, no real key lookup, no independent worker pool.
  `load(URLRequest, maximumBytes: Int)` returns `Result<Response, Failure>`;
  `Response` contains `data`, HTTP `status`, optional Retry-After seconds.
- `fetch(_:symbol:referenceID:bypassAuthorizationCache:)` fetches one product.
  `snapshot(symbol:)` captures seven symbol products, then at most three referenced
  analysts and three firms. It returns exactly nine ordered observations.
- Call `invalidate()` synchronously when credentials or policy/configuration
  change. This cancels old tasks, clears cached results, and suppresses late
  completions; throttling is intentionally retained. Recheck the parent's own
  generation before publishing a snapshot into Store/UI/model context.
- `snapshot.analyst(for:)` / `.firm(for:)` join only documented IDs. Missing IDs
  generate no directory/name queries. Reference metadata enriches existing records.

Parent must provide **one shared app-wide request budget**, three in flight maximum,
no retries, one page, actual 12-second receive deadline, no redirects, and a
**streaming receive cap which cancels transport**, not merely a Data-size check
after receipt. The injected client passes a 2,000,000-byte limit and defensively
rejects oversized or late completions, but cannot enforce a loader's receive policy.
Parent should share a single client so its in-flight tasks/cache apply app-wide.
Client has memory-only 500-entry least-recent-access eviction, news 30s, event 5m,
consensus 2h, references 24h; failures 30s; bounded HTTP429 cooldown 1–3600s.
Authorization-cache bypass does not bypass throttling.

The existing folder-synchronized Xcode groups include these paths automatically;
no `project.pbxproj` edit is needed. Module name for tests is `StockSage`.

## Official schemas pinned 2026-09-09

All endpoints are `GET https://api.massive.com` plus the paths below. All root
responses require `status: OK` and array `results`; `next_url` marks partial
coverage and is never retained or followed. No owner API calls were made.

| Product / official contract | Path | Request fields | Retained fields |
| --- | --- | --- | --- |
| [Earnings](https://massive.com/docs/rest/partners/benzinga/earnings) | `/benzinga/v1/earnings` | ticker, limit, sort=last_updated.desc | benzinga_id, ticker, date/date_status, last_updated, fiscal_period/year, currency, eps/revenue_method, actual/estimated EPS/revenue, EPS/revenue surprise, notes |
| [Guidance](https://massive.com/docs/rest/partners/benzinga/corporate-guidance) | `/benzinga/v1/guidance` | ticker, limit, sort=last_updated.desc | benzinga_id, ticker, date, last_updated, fiscal_period/year, release_type, currency, methods, min/max and previous min/max EPS/revenue guidance, estimates, notes |
| [Ratings](https://massive.com/docs/rest/partners/benzinga/analyst-ratings) | `/benzinga/v1/ratings` | ticker, limit, sort=last_updated.desc | benzinga_id, benzinga_analyst_id, benzinga_firm_id, date, last_updated, ticker, analyst, firm, rating/previous_rating/action, currency, original and adjusted current/previous price targets, notes |
| [Insights](https://massive.com/docs/rest/partners/benzinga/analyst-insights) | `/benzinga/v1/analyst-insights` | ticker, limit, sort=last_updated.desc | benzinga_id, benzinga_rating_id, benzinga_firm_id, ticker, date, last_updated, firm, rating/action, price_target, insight |
| [Bulls/Bears](https://massive.com/docs/rest/partners/benzinga/bulls-bears-say) | `/benzinga/v1/bulls-bears-say` | ticker, limit, sort=last_updated.desc | benzinga_id, ticker, last_updated, bull_case and bear_case |
| [Analysts](https://massive.com/docs/rest/partners/benzinga/analyst-details) | `/benzinga/v1/analysts` | benzinga_id, limit; no sort or ticker | benzinga_id, benzinga_firm_id, full_name, firm_name, last_updated, overall_avg_return, overall_success_rate, total_ratings |
| [Firms](https://massive.com/docs/rest/partners/benzinga/firm-details) | `/benzinga/v1/firms` | benzinga_id, limit; no sort or ticker | benzinga_id, name, currency, last_updated |
| [Consensus](https://massive.com/docs/rest/partners/benzinga/consensus-ratings) | `/benzinga/v1/consensus-ratings/{ticker}` | ticker path, limit; no sort | ticker, five rating counts, ratings/price-target contributors, consensus rating/value and mean/low/high targets |
| [News](https://massive.com/docs/rest/partners/benzinga/news) | `/benzinga/v2/news` | tickers, limit, sort=published.desc | integer benzinga_id, tickers, published, last_updated, title, author, teaser/body excerpt, safe HTTPS url |

No estimated dates become reported results: reported EPS/revenue remain separate
from date_status, and contradictory future-date actuals are rejected. Existing
`StockSageMassiveEarnings.parseNext`/fetch retain upcoming calendar semantics.
Existing `StockSageMassiveEvents` ratings/guidance observations retain Catalyst
window/change selection and failure semantics. Parent must continue wrapping those
existing paths for calendar/Catalyst selection; the new recent sample does not
replace them. It reuses their date validation, guidance direction and caveats.
`Payload.companyEvent` accepts an existing typed event for parent wrapping.

The parsers intentionally require a matching symbol and valid record ID for
attribution, even where the vendor schema calls those fields optional. Missing or
malformed rows are rejected with a count, never guessed or called empty. Numeric
strings/booleans/nonfinite numbers are rejected; negative EPS and zero revenue are
valid. Consensus counts are nonnegative integral and must reconcile; target ranges
must be ordered. Empty valid root arrays are different from rejected/missing data.

Source dates have day precision; source instants retain their original offset and
fractional precision. Checked time never becomes publication time. Optional source
updates remain nil, including consensus (which has no documented timestamp).
Revisions use a SHA-256 hash of the canonical original row, separately from stable
provider ID; distinct revised text is not deduplicated by headline/date/ticker.
News can be headline-only. Both bull and bear excerpts remain independently visible;
one missing side is partial. Source excerpts are at most 400 characters each.

Targets (original/adjusted), consensus, guidance and analyst metrics have explicit
opinion payloads and attribution. There is no quote/fill/settlement conversion.
Insight/consensus currency stays unknown; firm metadata never fills it in.
Parent owns the total 12,000-character projection, status reservation for all nine
products, citations, existing numeric acceptance, and consumer/routing integration.
For news, the owner-approved route is Benzinga via Massive → generic Massive →
EODHD, at most three ordered attempts with cancellation/policy denial stopping it.

## Verification

Pending compiler slot / independent review. No build, test pass, installed app,
live entitlement recheck or consumer integration is claimed at this checkpoint.
