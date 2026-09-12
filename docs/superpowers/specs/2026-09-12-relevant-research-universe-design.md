# Date-relevant research universe

Owner instruction, September 12: 1–7 and 7–14 trading-day research must not take the
first 500 alphabetical listings; select currently relevant/popular stocks instead.
This changes research selection only, not paper entry eligibility or trading policy.

## Decision

Use observed traded dollar volume (volume × VWAP) as the transparent market-activity
proxy for popularity. Rank descending, alphabetically only to break equal activity.
Do not invent a social-popularity/composite score or label this a best-investment list.
The existing per-stock Benzinga/news/catalyst and Qwen analysis still runs afterward.
Do not bias selection toward already-watched stocks with better cached-news coverage.

Alternatives considered: a static famous-company list becomes stale; a composite of
news/social/price-move ranks requires comparable whole-market coverage not provided by
the current per-symbol evidence cache. Date-bound dollar activity is observable, cheap
to collect in bulk, and does not require arbitrary score weights.

## Source and dates

Join the existing fully paginated active-US directory with Massive's dated daily-market
summary. Explicit `adjusted=true`, `include_otc=false`, Bearer header, fixed host/path,
bounded response, no redirects. No separate credentials, vendor or subscription added.
Keep existing listed instrument scope (including ETFs/share classes), require confirmed
USD and a valid symbol for analysis, and do not silently fill gaps alphabetically.

Use New York dates and the existing published NASDAQ calendar. Today's activity is
eligible after 04:00 ET on a supported trading date; otherwise use the latest preceding
trading session. Reject unsupported calendar years. During an incomplete current day,
if fewer than 500 eligible observations are available, check the preceding session and
use it only if it offers wider eligible coverage. Never combine partial-day and full-day
volumes into a single ranking. Show the actual selected session and fallback reason.
No successful response means no new ranked run; retain the previous run with its dates.

A current-day summary is partial activity used ONLY for selection. The model's existing
completed-daily-bar gate, horizon prompt, stops/targets and validation remain unchanged.

Validate response status, adjustment flag, count, no continuation, unique symbols, finite
positive VWAP/volume/product and the millisecond bar date against the requested NY date
and captured clock. Exclude unusable/unmapped observations and expose eligible/returned
coverage. Never substitute close × volume when VWAP is missing.

## Workflow / UI

Every manual Run fetches a new ranking. Freeze that selection for the one-time scan;
settings changes and cancellation are checked before and after every request/publication.
Store a selection receipt with the scan, preserving it if a failed preflight restores the
previous scan. Display selection session, source, eligibility count and activity basis.
Keep existing progress, stop, filter and research detail interactions; no layout rewrite.

No live provider calls during this implementation's tests, no installs/model changes,
and no owner-record or credential reads. Preserve the completed 22-finding review diff.
The owner's subsequent instruction authorizes committing and pushing all reviewed StockSage
changes after validation to `swonyu/StockSage-app`, then explicitly authorized merging and
pushing `main` as well. Preserve unrelated worktrees and the installed app.

Sources checked September 12:
- https://massive.com/docs/rest/stocks/aggregates/daily-market-summary
- https://massive.com/docs/rest/stocks/snapshots/full-market-snapshot

The dated aggregate endpoint avoids the full snapshot's un-dated `day` field and daily
reset ambiguity. Vendor documents milliseconds for grouped-bar `t`; the test fixtures
must cover wrong units, dates and future times rather than treating receipt time as data time.
