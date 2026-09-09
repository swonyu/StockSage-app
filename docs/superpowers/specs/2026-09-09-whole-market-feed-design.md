# Whole-market US trade and quote feed

Owner choices: one Massive real-time stocks socket, `T.*,Q.*`, whole market,
maximum ten-second live-price age, no accumulating consumer backlog. Parent owns
integration/installation; this branch owns implementation and offline tests.

## Bounded design

The existing MainActor receive/parse/per-trade-store loop is the bottleneck.
Replacing only the subscription string leaves that bottleneck intact. Use native
Swift concurrency: the socket callback offers raw frames to a bounded mailbox;
one worker actor parses and coalesces latest trades and quotes independently.
A bounded mailbox is preferable to an unbounded task per frame or a UI-owned
receive loop. Latest-value coalescing is deliberately a display cache, not a
lossless trade archive, volume calculation, or execution signal.

Caps: 1 MiB/frame, eight queued frames/8 MiB plus one processing frame, 32,768
symbols per channel. Retained quote indicator arrays are capped at 64; larger
arrays become explicitly unknown metadata and increment the rejection count,
while preserving prices/withdrawals and denying cost qualification. Exceeding a frame/queue/symbol cap invalidates the session and cancels/reconnects
the socket, clears liquidity, and records a visible gap. Never silently narrow the
wildcard subscription. Invalid/missing timestamps and skipped malformed elements
are counted; exact Int64 sequences and zero-side withdrawals remain supported.
Provider-native class/preferred suffixes are preserved in the market cache;
REST symbol-coverage rules remain unchanged. Native NBBO lookup/cost guards
preserve case. Mixed-case trades remain in the exact market cache and are
explicitly refused at the legacy uppercase store and gap-poll projection; a
persistent canonical-symbol migration is outside this slice.

The UI pulls one bounded snapshot at a time every 250 ms for current board/idea
symbols (maximum 4,096 per publication, rotating if necessary). There is never a
queue of pending UI publications. The worker retains off-board observations.
A single store batch reuses mergedPolledQuotes and preserves row shape/ordering.
Changing viewed symbols changes snapshot selection, never the subscription.

Measure frame/byte/event rates, mailbox depth/bytes/high water, receive-to-process,
receive-to-publish, SIP-to-receive (separate from participant/exchange time),
coalescing count, malformed observations, future clocks, overload/gaps and recovery.
Use monotonic elapsed time for local backlog; wall time only for market clocks.
Observed stale frames alone cannot prove consumer backlog: delayed reports and
quiet symbols exist. Local backlog exceeding ten seconds aborts the session;
stale upstream observations are disclosed and cannot qualify as LIVE. Three
stale quote-bearing frames across at least one second, with no quote-channel SIP
watermark within ten seconds, trigger a disclosed recovery. This is a heuristic
for upstream/socket buffering or device clock skew, not proof of either. Quiet
markets and isolated delayed trade reports do not trigger that recovery. Auth and
ping health are independent of per-symbol freshness. A quiet market stays
connected without a claim of new prints. SwiftUI publication time is measured;
actual display/compositor timing needs subsequent live profiling.

PaperAutomation.fresh changes from 120 to 10 seconds. After Qwen, actionable
opinions fetch one separately qualified observation; keep original cited facts
and check context expiry, eligibility, holding identity, policy, configuration
and generation again. Read the current book and commit without another await.
Hold/Avoid records no skipped order and makes no extra quote request. A fill still
needs a later-than-proposal observation. This addition was explicitly approved
by the parent on 2026-09-09. Policy/cancellation guards,
REST condition qualification and NBBO five-second cost eligibility stay intact.
WebSocket ticks do not become paper-fill inputs. Historical QuoteFreshness and
strategy thresholds remain unchanged.

## Verification

First reproduce wildcard/off-board/suffix and >10-second freshness failures in
existing runtime helpers. Then test actual mailbox/worker ingestion, auth and
session reset, stop/replacement/cancellation, independent clocks and sequences,
withdrawals, future/missing times, ten-second boundaries, caps and overflow.
Replay synthetic whole-market bursts through the real ingestion API, including
slow publication and overload. Report throughput, latency and resource bounds.
Run focused suites and canonical macOS/iPhone tests with jobs=2 and separate
DerivedData. No authenticated live socket while the installed app owns one.
Synthetic measurements cannot guarantee live upstream latency or sustainable
peak-market rates. Parent must perform the single-socket live verification.

Sources checked 2026-09-09:
- https://massive.com/docs/websocket/quickstart
- https://massive.com/docs/websocket/stocks/trades
- https://massive.com/docs/websocket/stocks/quotes
- https://massive.com/knowledge-base/article/how-many-tickers-can-you-subscribe-to-on-a-single-massive-websocket-connection
- https://massive.com/knowledge-base/article/why-do-massive-websocket-disconnects-happen
- https://massive.com/knowledge-base/article/why-are-ticker-symbols-with-dashes-not-showing-in-polygons-system
