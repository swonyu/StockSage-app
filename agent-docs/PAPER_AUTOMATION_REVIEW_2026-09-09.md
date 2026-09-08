# Native paper automation review — September 9, 2026

Scope: the native Qwen paper account, not IBKR or real-money execution. Traced
start/stop, lease/read/save, timer, market discovery, history/news/context,
model validation, pending decisions, entries/exits, marking and the panel.
Reviewed the relevant Massive snapshot/tick and MLX request/batching seams.

## Same-day extension — owner selected00:58, expanded review01:09 +03

The native account now uses the existing04:00–20:00 New York session with19:55
entry cutoff and deterministic close-out requests. This supersedes the paper
prompt's next-week horizon, not the separate board badge or frozen research pilot.

- The Book cancels pending entries at cutoff and requests exits without requiring
  Qwen, news or minute bars. A position carried from a previous New York date blocks
  new buys until resolved. Missing later prices, closed sessions or sleep leave an
  explicit unresolved holding; they never produce a synthetic closing fill.
- First activation is saved atomically under the account lease: retire pre-policy
  pending buys, retain holdings/exits/history, and make same-day research due.
  A recorded activation prevents repeating that transition at every restart.
  Without this, an old weekly-policy pending Buy could survive the app update.
- Before and after model inference, evidence must still be fresh. Recent completed
  minute bars are separate from daily technical background. Wrong ticker/status,
  pagination, invalid OHLC/volume, duplicate timestamps and unfinished bars cannot
  create accepted minute evidence. Two completed bars and last-end age≤180s are
  required. Gaps are not padded.
- Live after-hours responses returned HTTP200 with last-bar-start ages1236s AMGN,
  1356s STX,396s LRCX,156s SNOW and336s DELL. This was real sparse candle coverage,
  not a reason to relabel old candles. Reused the condition-checked two-minute
  trade window as an explicitly labelled fallback, requiring two distinct actual
  participant timestamps. These are individual observations, not OHLC, total
  volume, executable quotes or proof of liquidity. Its freshness ceiling is120s.
- New Buy/Strong Buy opinions must cite an actual intraday bar/trade fact, not only
  daily background or the intraday caveat. An otherwise verified opinion stays
  recorded if its entry is skipped. This proves a citation is present, not that
  the model reasoned correctly about it. No automatic strengthening to Buy.
- Position quote fallbacks now reuse the four-worker helper rather than serial
  lookups; the timer remains separate from research. MainActor saves, one cycle,
  cancellation, price-basis protection and all cash/position/cost limits remain.
- The panel exposes100 latest records and measured cycle time, verified opinions,
  unavailable checks and paper fills. Request failures and verification failures
  have separate messages. It does not advertise another research due time during
  close-out. Stored history is still subject to the existing explicit size caps.

Artifacts: `/private/tmp/stocksage-sameday-20260909.RgZox4/`. Initial lifecycle
regression reproduced8 assertion issues before production changes (the red log is
in the preceding fresh-fast artifact directory). The later review-extension red
was a missing-helper compile failure, not an executed assertion-level red. A
45-test focused pass and1869-test macOS pass preceded the activation refinement;
they do not verify the final activation code. An intermediate opt-in live pass
(`third.log`,43 tests) recovered fresh prices for5/5 names and adequate intraday
facts for4/5; STX still lacked adequate evidence at that instant. No claim that
every provider observation becomes available. Final source passed1870 macOS and
1867 iPhone simulator tests, including one-time activation. Installation and live
activation were verified at01:19; exact checksums and retained-ledger checks are in
HANDOFF. No source changes after the final gates. Live closing behavior at the
19:55 New York cutoff is still unobserved; deterministic tests are not a live close.

The earlier installed quote fix produced a real native-ledger USO13-share paper
fill before this extension. It is not a same-day-build result, a broker fill or
evidence of profit. Same-day policy cannot guarantee no overnight carry when this
Mac is asleep or eligible observations are unavailable. Intraday-specific stop,
target and strategy calibration still require prospective net-of-cost research;
the existing2%/4% simulation limits were not presented as optimized parameters.

## Fixed in this review

1. **Stale snapshot masks an available fresh trade.** Paper research and fills
   used `fetchQuotes`, which considers a returned-but-stale snapshot a successful
   result. Both now use one paper-specific resolver: snapshot first, then a
   bounded 100-row `/v3/trades` window. No Yahoo price is relabelled as SIP.
2. **Fresh does not mean later than the decision.** Pending-order requests pass
   their decision timestamps to that same resolver. An earlier snapshot now
   triggers fallback even when younger than 120 seconds. Settlement still requires
   a strictly later market observation and a decision younger than 120 seconds.
3. **Raw tick recency alone is insufficient.** The fallback resolves eligible
   condition IDs from the complete stock-trade reference, rejects unknown,
   prior-reference, average-price and corrected trades, and checks both participant
   and SIP times. The participant time becomes the observation time, preventing a
   late report of an earlier trade from fabricating a post-decision fill.
4. **Serial research/server bottleneck.** Four rolling workers overlap history,
   news and inference, with holdings completed before new-entry research. One
   cycle remains active. Each worker takes the latest book immediately before its
   synchronous MainActor save; concurrent completions cannot overwrite each other.
   Cancellation stops queue refill; generation checks retire old work. A changed
   holding invalidates an in-flight paper action. Configuration changes produce an
   interrupted-cycle record rather than a misleading successful-completion note.

## Verification evidence

Artifacts: `/private/tmp/stocksage-fresh-fast-20260909.9o4k2X/`.

- Before changes, live snapshot/trades comparison returned HTTP 200 for both but
  snapshot ages of roughly 360 seconds versus fresh tick ages of 13–75 seconds.
  `Cache-Control: no-cache` did not cure this provider-path difference.
- New API tests initially failed to compile against the absent resolver/scheduler
  (`red.log`); this is not claimed as an assertion-level red. Existing live probes
  establish the behavioral reproduction. Focused final checks exercise actual
  resolver → pending → settlement, stale/future/pre-decision failures, trade
  conditions, participant time, four-worker concurrency and cancellation.
- Opt-in live tests call the production resolver without changing the ledger or
  printing credentials. `live2.log` recovered four of five probe symbols: AMGN
  397s→79s, STX 545s→5s, SNOW 347s→26s, DELL 123s→57s. LRCX was already fresh.
  A repeat recovered three currently stale symbols; all five had eligible data.
- Eight identical saved evidence sets were sent to the same local 27B model.
  Baseline serial/full-response: 68.517s, 7/8 passed the production validator.
  Four clients against the still-serial service: 60.573s, 6/8 valid.
  Actual four-way batching, prefill128: 41.686s, 7/8 valid.
  Four-way batching, prefill512: 35.435s, 6/8 valid.
  This is **1.93x raw response throughput**, or **1.66x valid-response throughput**
  for the last small sample, NOT a proven 4x speedup or an end-to-end 100-stock SLA.
  Sampling remains stochastic at temperature0.2; eight cases cannot establish
  statistical quality equivalence. No validator checks were relaxed. No response
  in these trials hit its token cap. All evidence was retained; paper conclusions
  request at most20 words for each case/counter-case with a192-token ceiling.
- Existing MLX service was restarted in-place with decode/prompt concurrency4,
  prefill512, loopback8765, offline loading, the same model path, 20GiB MLX memory
  limit and512MiB cache limit. One model resident; observed RSS about15.2GB.
  The first TERM automatically respawned the old launchd job; that run is explicitly
  the still-serial control above, not misreported as batching.

Final platform gates, installation checksum and live account outcome are recorded
in HANDOFF.md after rollout. Ordinary test gates do not access live credentials;
`TEST_RUNNER_STOCKSAGE_PAPER_DIAGNOSTICS=<artifact-directory>` explicitly opts into
the diagnostic suite and its saved benchmark files.

## Remaining limitations / follow-ups

- **No guaranteed trade or return.** Hold/Avoid and invalid model output still
  create no order. No genuine market observation means no simulated fill. Native
  paper results are not brokerage acceptance, liquidity or profitability evidence.
- **Snapshot semantics remain unchanged.** Fresh primary snapshots retain the
  existing SIP timestamp semantics; strict condition/participant filtering applies
  to the new tick fallback. Full-market discovery still screens fresh snapshots,
  so names with stale screening snapshots can be absent from the100-name shortlist.
  Broadening this requires a separately bounded discovery policy, not thousands of
  tick calls on every timer. Unsupported symbol formats and OTC remain excluded.
- **Bounded tick evidence.** A single100-row window can contain only rejected
  trades. Empty/missing condition arrays, missing participant times, incomplete
  reference results and unknown conditions fail closed. Missing data is not a
  claim that the exchange had no trades. Reference cache lifetime is24hours.
- **Fill realism.** Observed trade plus assumed10bps is not bid/ask depth or actual
  executable liquidity. Stops are sampled, not resting exchange orders. Market
  gaps, dividends, exact holiday sessions and corporate actions are not fully
  simulated. Large price-basis changes still pause for review.
- **Retention.** The existing32MB/50,000-decision limits intentionally pause before
  data loss. At100 reviews per cycle the ledger grows faster. No evidence is
  silently dropped; durable archive/rotation is a follow-up, not an untested
  retention rewrite bundled into this urgent quote fix.
- **Model correctness.** Numeric membership is not semantic entailment. The sample
  still contains invalid model replies; shorter output does not prove better stock
  analysis. Typed source-bound claims and prospective, net-of-cost evaluation are
  needed before any promotion to real orders. No forced Buy, new leverage or
  unrequested strategy thresholds were introduced.

Provider contracts checked: [Trades](https://massive.com/docs/rest/stocks/trades-quotes/trades)
and [condition reference](https://massive.com/docs/rest/stocks/market-operations/condition-codes).
