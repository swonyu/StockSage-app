# Same-day native paper trading

Owner chose same-day positions at00:58 Riyadh September9, replacing the prior
next-trading-week paper horizon. Reuse the current native simulator, not a new
strategy engine or broker service. Work inline in the sole-writer qwen-context
worktree; no new agents, model weights, paid services, merge or push.

The selected approach combines explicit same-day lifecycle rules with recent
minute-bar evidence (or clearly labelled qualified trade observations when sparse
after-hours trading leaves no recent completed candle). A prompt-only edit would leave holdings open indefinitely;
forcing a close at20:00 without a later market observation would fabricate fills.
Neither is acceptable. Use the existing04:00–20:00 New York extended session, with
a conservative five-minute close-out buffer beginning19:55. DST follows the
existing America/New_York calendar. This is not the owner's Riyadh calendar day.

- No new buys from19:55. Cancel pending buys at the cutoff. Request exits for all
  open paper positions; ordinary sells/stops can still exit earlier.
- A holding from a previous New York date is overdue. Block new buys until it is
  resolved, and retry its exit in the next open session. Closed markets, sleep and
  missing observations never manufacture a same-day close. Surface overdue state.
- Preserve120s order expiry, strictly later fresh observations, cost/cash/position
  limits, durable ledger and one-writer rules. Timer exits do not depend on Qwen.
- On first activation, atomically record the policy, retire pre-policy pending
  buys and make fresh research due. Retain holdings, exit requests and history;
  subsequent starts must not repeat the transition.
- For new Qwen opinions fetch up to the last hour of completed one-minute Massive
  OHLCV bars within today's session. Require at least two valid bars and last
  completed bar no more than three minutes old. Disclose actual timestamps and
  gaps; never pad missing bars or call daily bars intraday. Daily technical rules
  remain labelled background. If bars are unavailable, reuse the bounded two-minute
  trade fallback and its condition/participant-time checks. Require two distinct
  qualified trade timestamps, last age≤120s; label these as individual observations,
  not OHLC, a volume census or executable liquidity. Missing both forms of intraday
  context blocks new model actions,
  not deterministic same-day exits.
- Keep100 discovery candidates, four bounded workers, full fact citations and
  existing evidence validator. The model's horizon is the remainder of this
  session, not a week; no promised returns or new trade quota.

Owner's01:09 follow-up asks for continued autonomous improvement of this system.
The focused review extension reuses the four-worker helper for position quote
fallbacks, so five independent slow lookups need not run serially. New Buy/Strong
Buy opinions must cite at least one actual intraday observation, not just the
daily background or intraday caveat; the opinion remains visible if entry is
skipped. Preserve earlier sell/stop/close-out behavior. Separate transport failure
from response-verification failure in the history. Show100 recent decision records,
actual cycle duration, verified-opinion/unavailable counts and simulated fills.
These are operational improvements, not proof of a predictive edge or4x speedup.

Verification: deterministic cutoff/DST/date-rollover/late-quote/missing-data tests,
minute-payload validation, prompt horizon assertion, then canonical macOS and
iPhone gates. Install exact tested bundle normally and preserve the prior app.
Record actual live outcomes without treating a synthetic test as a real fill.
