# Whole-market US feed implementation and verification

Worktree: `/Users/saleh/StockSage-wt/whole-market-feed`

Branch: `codex/whole-market-feed`

Base: `18d30709f149a9aa1ff5014f7041db911a291d97`

Parent integration task: `01a0772c-d7ba-7c50-906c-0a3a3e9baef1`

Artifacts: `/private/tmp/stocksage-whole-market-feed-20260909/`

## Behavior

One authenticated Massive stocks socket subscribes to `T.*,Q.*`. Board/watchlist
changes only affect display selection. The receive callback offers raw frames
without waiting for MainActor; one actor parses all accepted events and retains
latest trades and quotes separately. This is a latest-value display cache, not a
lossless time series, volume accumulator, strategy input or execution feed.

The mailbox holds at most eight queued frames/8 MiB, plus one processing frame;
each frame is at most 1 MiB. Each channel retains at most 32,768 symbols. Symbols
are at most 32 bytes and quote indicator arrays at most 64 elements. Larger
indicator arrays become unknown metadata, are counted, and cannot qualify costs;
price/size withdrawals still replace previous liquidity. Frame/queue/symbol
capacity failure invalidates the session, cancels the socket and reports a gap.
These limits bound application-owned structures, not Foundation's private network
buffers or total process RSS. The replay measures process RSS separately.

One UI task awaits one capped snapshot at a time, at 250 ms cadence. It projects
at most 4,096 selected symbols (rotating if the board exceeds that size), then
uses the existing store merge in one batch. Full-market off-board observations
remain in the worker. There is no queue of per-event MainActor tasks, pending
store tick tasks, or UI snapshots. Auth-to-subscribe is the one status transition
that checks policy on MainActor; data parsing never does.

Provider-native spelling is preserved, including `BRK.B` and `APTVpA`. Native
quote lookup, `withNBBO`, scan book preservation and shared cost guards compare
exact provider identity. The legacy uppercase trade store and gap-poll coverage
explicitly refuse mixed-case tick projection rather than alias `APTVpA` into
`APTVPA`. Those observations remain in the exact whole-market cache. This change
does not migrate persisted symbol IDs or widen unrelated REST coverage.

## Freshness, delay and failure semantics

SIP time, optional trade participant time, local receive time, local processing
and publication are distinct. Local elapsed measurements use monotonic uptime;
SIP-to-receive measurements depend on the device's wall clock. Receive-to-publish
ends after the actual published-model update and synchronous store merge. It does
not measure the compositor or pixels appearing on screen. Only outstanding
selected latest-value replacements count toward that publication latency; an old
quiet symbol is not reported as a consumer queue.

LIVE and delivered-trade coverage require nonfuture observations aged 0...10s.
Independent quote and trade diagnostics prevent fresh trades hiding old bid/ask.
The existing five-second NBBO cost rule stays unchanged. The existing parser's
bounded future-clock ordering tolerance remains; future observations cannot
qualify as current prices/costs before their time arrives. Missing timestamps are
never filled with receive time. Historical QuoteFreshness is unchanged.

A queued/processing frame or captured UI publication exceeding ten seconds
invalidates the session. Three stale quote-bearing frames across at least one
second, without a quote-channel SIP watermark within ten seconds, also trigger
recovery. That is explicitly a heuristic for upstream/socket backlog OR device
clock skew, not proof of which occurred. Quiet markets and isolated late trade
reports do not trigger that heuristic. Recovery uses the existing capped backoff;
this cannot promise recovery within ten seconds during an outage.

A stopped, failed or authorization-reset session cannot publish an earlier
captured snapshot. Publication checks current ingress validity before and after
store work without holding the receive lock. Replacement sockets use new ingress
objects and callbacks remain bound to their original socket. Ping/auth watchdogs
are separate from per-symbol observation age. The header button exposes counters,
queue high water, rates, timing, rejected data and persistent session gap count.

## Paper observation boundary

`PaperAutomation.fresh` now accepts only qualifying Massive prices aged 0...10s.
After inference, actionable opinions fetch a separately qualified observation via
the existing REST helper. The original cited facts/timestamps remain unchanged;
revalidation provenance is a separate decision record. Permission, cancellation,
configuration/generation, eligibility, context/session expiry and holding identity
are checked again. The current book is read and committed on MainActor without
another suspension. Hold/Avoid makes no extra quote request and is not labelled
a skipped order. A fill still requires another qualifying observation strictly
later than proposal. No raw WS tick is supplied to paper settlement. Cash, sizing,
risk, order TTL, monitor cadence, ledger schema and broker activation are unchanged.

## Reproduce the actual ingestion replay

The suite runs without an authenticated socket or a model call. Use a new output
directory so an existing xcresult is not overwritten:

```sh
cd /Users/saleh/StockSage-wt/whole-market-feed
feed_run=$(mktemp -d /private/tmp/stocksage-feed-replay.XXXXXX)
xcodebuild test -project StockSage.xcodeproj -scheme StockSage \
  -destination 'platform=macOS' -derivedDataPath "$feed_run/DerivedData" \
  -resultBundlePath "$feed_run/replay.xcresult" -jobs 2 \
  -parallel-testing-enabled NO \
  -only-testing:StockSageTests/StockSageFeedIngressTests \
  > "$feed_run/replay.log" 2>&1
```

Read the exit status and `FEED_REPLAY`, `FEED_CADENCE`, `FEED_PUBLISHED`,
`FEED_UI_STALL`, `FEED_OVERLOAD` and test-summary lines from that log. The suite
filter is intentional; a method filter selecting zero tests is not evidence.

The representative replay uses 20,000 synthetic symbols, 50% T / 50% Q, five
rounds: 200,000 events in 200 frames of 1,000 events, up to 117,001 bytes/frame.
Trade fields include price, size, exchange, tape, ID, conditions, participant/SIP
milliseconds and exact sequence. Quote fields include both prices/sizes,
exchanges, condition, indicators, tape, SIP milliseconds and sequence. Example:

```json
[
  {"ev":"T","sym":"S123","p":100,"s":100,"x":4,"z":3,"i":"abc","c":[0],"pt":1700000000000,"t":1700000000001,"q":1},
  {"ev":"Q","sym":"S123","bp":99,"ap":101,"bs":100,"as":100,"bx":4,"ax":12,"z":3,"c":0,"i":[],"t":1700000000001,"q":1}
]
```

The throughput replay drains each bounded burst and publishes immediately; its
latency is not the production cadence. A separate replay uses the actual
published model at 250 ms cadence, including a quiet observation waiting for the
next publication. Another adds 10 ms of store work to verify the timing boundary,
and another stalls MainActor for 250 ms while the receiver/worker continues.
The unpaced flood intentionally exceeds capacity and must report an explicit gap.
It is a safety result, not proof that overload never occurs.

## Regression evidence

- `red.log` / `red.xcresult`: 13 stream tests, five expected failures, exit 65.
  Wildcard, off-board acceptance, class/preferred spelling and >10s paper age.
- `identity-red.log` / `identity-red.xcresult`: 12 NBBO tests, six expected
  failures, exit 65. Wrong-instrument quote reached store/scan/cost paths; a
  synthetic preferred spread of 800 bps replaced another symbol's 8 bps floor.
- `auth-reset-red.log` / `auth-reset-red.xcresult`: 15 ingress tests, one
  expected failure, exit 65. A captured authorized snapshot remained publishable
  after the protocol reset authorization.
- Additional passing regressions cover exact Int64 sequence ties, daily sequence
  reset, independent trade/quote clocks, zero withdrawals, missing/future times,
  ten-second boundaries, limits, malformed/oversized metadata, auth callbacks,
  stale session callbacks, post-capture invalidation, delayed inference, stale
  revalidation, policy/cancellation, current-book changes and no-fetch Hold/Avoid.

## Live verification still required by the parent

No authenticated live-market probe, installed-app replacement, model change,
real order, merge or push was performed by this task. Synthetic Debug replay
cannot establish peak live T+Q sustainability, upstream latency, every-symbol
coverage, uninterrupted service, clock synchronization or actual screen-render
latency. A quiet stock is not guaranteed to print every ten seconds.

After reviewing/integrating the commit, the parent owns installation and a
single-socket live check: confirm T/Q auth/subscription and market-cache counts;
observe sustained queue/rate/latency and process RSS through active-market bursts;
check venue/SIP/device clocks, per-channel age, recovery gaps and UI responsiveness;
confirm policy stop and identity-safe liquidity clearing. Do not open a competing
authenticated stocks socket while the installed app owns its connection.

## Provider sources checked 2026-09-09

The wildcard channels, clocks and stock/quote payload semantics follow the
[trade specification](https://massive.com/docs/websocket/stocks/trades),
[quote specification](https://massive.com/docs/websocket/stocks/quotes) and
[WebSocket quickstart](https://massive.com/docs/websocket/quickstart).
Ticker spelling follows Massive's [SIP symbology explanation](https://massive.com/knowledge-base/article/why-are-ticker-symbols-with-dashes-not-showing-in-polygons-system).
Full-market subscriptions depend on consuming quickly enough; slow consumers can
be disconnected, as explained in the [subscription limits](https://massive.com/knowledge-base/article/how-many-tickers-can-you-subscribe-to-on-a-single-massive-websocket-connection)
and [disconnect guidance](https://massive.com/knowledge-base/article/why-do-massive-websocket-disconnects-happen).

## Final-source executable results

Verified host: Apple M5 Max, Mac17,7, 51,539,607,552 bytes RAM (48 GiB),
macOS 27.0, Xcode 26.6 (17F113). Builds use Debug, jobs=2, one heavy check at a
time, and this task's isolated DerivedData. The iPhone gate uses the available
iOS 26.5 iPhone 17 Pro (gate), UUID `3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA`.

| Execution | Result | Artifact prefix |
| --- | --- | --- |
| macOS full suite | 1,903 tests / 193 suites passed, 59.983s, exit 0 | `macos-final-source` |
| iPhone full suite | 1,900 tests / 193 suites passed, 59.031s, exit 0 | `ios-final-source` |
| Strict compile / test type-check | macOS 55s, iOS 52s, tests 74s; all OK, exit 0 | `gate-final-source.log`, `gate-tmp/stocksage_gate/whole-market-feed/` |

Both use the unchanged exclusions: `CalibrationPersistRunTests`,
`LiveUniverseVerificationTests`, `StrategyBaselineMeasurementTests`. The final
full runs include the publication timing, metadata-cap and authorization-reset
regressions added after the earlier 75-test focused pass. No zero-test result is
counted as verification.

| Synthetic measurement | macOS | iPhone simulator |
| --- | ---: | ---: |
| Representative T/Q events | 200,000 | 200,000 |
| Elapsed replay | 1.402856s | 1.319658s |
| Replay events/second | 142,566 | 151,554 |
| Peak receive→process | 21.628ms | 12.612ms |
| Peak immediate replay receive→snapshot consumption | 21.823ms | 12.778ms |
| Actual 250ms model-publication cadence, quiet update peak | 230.558ms | 235.005ms |
| Actual publication including injected 10ms store work | 13.280ms | 13.805ms |
| Worker peak during 250ms MainActor stall | 0.160ms | 0.172ms |
| Peak representative raw queue | 1 frame / 117,001 bytes | 1 frame / 117,001 bytes |
| Retained latest values | 20,000 T + 20,000 Q | 20,000 T + 20,000 Q |
| Whole test-process peak RSS | 238,649,344 bytes | 330,678,272 bytes |
| Increase in process RSS high water during replay | 3,325,952 bytes | 9,355,264 bytes |

RSS is the host test process's high-water reading, influenced by earlier tests
and allocator reuse; its increase is not an isolated feed-memory allocation
measurement or a live-app RSS guarantee. Queue occupancy was zero after draining.
The unpaced flood hit eight queued frames / 400,008 bytes on both platforms and
reported `Feed overloaded: raw frame capacity exceeded; gap and reconnect`.
Intermediate latest-value replacements were coalesced deliberately (160,000 in
the representative replay); this is not preservation of all market events.

The tested Swift files are recorded in `tested-source.sha256` in the artifact
root. Only this report/design/HANDOFF metadata was completed after the checks;
no tested source was changed. The parent was explicitly notified that this
heavy-build window was released before scheduling the next task.

## Integration handoff

Review the single commit on `codex/whole-market-feed`, then cherry-pick it onto
the parent's current integration branch. The common Git directory is
`/Users/saleh/StockSage-app/.git`; no remote fetch or push is needed. The parent
owns combined-source verification, any HANDOFF merge conflict, installation and
single-socket live acceptance. This worktree is retained for review; do not
replace the installed bundle merely because these offline checks pass.

Touched files: `StockSageFeedIngress.swift`, `StockSageLiveStream.swift`,
`StockSageNBBO.swift`, `StockSageNetEdge.swift`, `StockSagePaperAutomation.swift`,
`StockSageStore.swift`, `MarketsView.swift`, `StockSageNBBOView.swift`, their four
feed/NBBO/paper test files, this report, the design spec and `HANDOFF.md`.
`project.pbxproj` and all parent/other worktrees are unchanged by this task.
