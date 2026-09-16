# Research outcome lifecycle

Date: 2026-09-16

## Goal

Complete each newly saved 1–7 or 7–14 trading-day prediction at the first verified target or stop event. If neither event occurs, complete it at the scheduled seventh or fourteenth Nasdaq session close. This measures the prediction's captured scenario; it does not place an order or claim an executable fill.

## Chosen behavior

New runs carry an explicit daily-bar outcome policy. Existing runs and completed evaluation receipts retain their captured endpoint-only policy and bytes. The original prediction, evidence, reference price, stop, and target remain immutable.

For each new prediction, monitoring begins with the next Nasdaq trading date after the research run completes. StockSage checks only ended New York dates so Massive's adjusted daily OHLC aggregate is settled. It examines sessions in chronological order and stops at the first terminal event:

1. If a session reaches both stop and target, record `stopHit`.
2. If it reaches only the stop, record `stopHit`.
3. If it reaches only the target, record `targetHit`.
4. If neither occurs before the horizon, record `horizonClose` at the seventh or fourteenth session close.

For a gap through a terminal level, the session open is the observed outcome price. Otherwise the captured stop or target is the observed outcome price. This is a conservative daily-bar convention, not a guaranteed execution price. The receipt states that intraday ordering is unavailable and that the same-bar rule favors the stop.

The review request also includes the prediction's saved reference date. StockSage compares the freshly adjusted close for that date with the immutable saved reference price and applies their finite positive ratio to the captured entry, stop, and target. A ratio of one leaves the levels unchanged; a later split keeps the scenario economically equivalent. If the reference bar or adjustment ratio cannot be verified, first-hit evaluation fails closed.

## Data contract

Add a versioned evaluation policy to `Run`; new snapshots use `dailyBarFirstHit`, while absent and current values decode as the existing endpoint policy. Never infer a new policy for an old run.

Extend `Evaluation` with optional, backward-compatible fields:

- terminal kind: `targetHit`, `stopHit`, or `horizonClose`;
- terminal New York session date;
- outcome price and its basis;
- the complete verified daily OHLC path examined through the terminal session;
- the captured stop and target used for the decision;
- an explicit same-bar resolution when applicable.

The scheduled horizon close remains in `targetCloseAt`, even when a prediction finishes early. This preserves the original window. The terminal session is stored separately. Existing endpoint fields remain readable; new terminal receipts must validate their policy, dates, OHLC invariants, captured levels, and recomputed first-hit result before they can be persisted.

An evaluated receipt is immutable. Later provider revisions, richer paths, or repeated checks cannot rewrite it. Invalid or incomplete responses produce no terminal result.

## Checking lifecycle

The app checks unfinished daily-policy predictions when it launches or becomes active, subject to the existing external-access, credential-revision, sample-data, cancellation, storage, and maximum-per-pass guards. It does not poll while closed or continuously in the background. The Saved Research action remains available and becomes **Check active results**.

A prediction is eligible for a check after at least one monitoring session has fully ended. Before the horizon, a no-hit result remains active and no final receipt is stored. At the horizon, a valid no-hit path is finalized at the horizon close. Re-entering the foreground on the same ended session may refetch the short bounded window, but cannot alter a completed receipt.

Automatic checks use the same `fetchReviewObservation` request builder, parser, cancellation gates, and Massive adjusted-history contract as manual checks. The request end date becomes the latest fully ended session, capped at the prediction's horizon.

## UI

Saved Research and Home distinguish:

- **Active** — waiting for another completed session;
- **Target hit** — successful terminal scenario with date and measured return;
- **Stop hit** — unsuccessful terminal scenario with date and measured return;
- **Horizon close** — neither level was reached; show the seventh- or fourteenth-session return and direction;
- **Data unavailable** — the required verified bars could not be obtained.

The detail view shows the captured entry, stop, target, terminal basis, provider/fetch time, and the disclosure that daily bars cannot establish intraday order or actual fills. Same-bar outcomes explicitly say that the conservative stop-first rule was applied.

Aggregate accuracy treats `targetHit` as target success, `stopHit` as stop failure, and reports `horizonClose` separately with its signed return. It does not silently convert a small positive horizon return into a target hit. Prediction-quality summaries must identify the policy and exclude unavailable or still-active predictions from the denominator.

## Error handling and compatibility

- Missing levels cannot use the first-hit policy; they remain active until the horizon and then use the horizon close.
- Missing, duplicated, unordered, non-finite, wrong-symbol, wrong-source, unadjusted, or incomplete required bars cannot produce a completed outcome.
- Unknown evaluation-policy or terminal-kind values fail closed when decoding.
- A missing interior session cannot establish first-hit order. Before the horizon it stays active; at the horizon it reports data unavailable rather than substituting an adjacent bar.
- Corporate-action consistency remains protected by the single adjusted history series and the explicit saved-reference adjustment ratio. The original levels stay immutable; only the evaluation receipt contains the adjusted comparison levels. Missing reference data or an invalid ratio produces an unavailable result rather than silently mixing price bases.
- Old run schedules, old receipt encodings, and old evaluated results round-trip unchanged.

## Verification

Test the pure first-hit evaluator before production changes. Required cases:

- target on an earlier session beats a later stop;
- stop on an earlier session beats a later target;
- both levels in one bar resolve to stop;
- gap below stop and gap above target use the session open as outcome price;
- no hit completes at exactly session 7 or 14;
- no hit before the horizon remains active;
- missing interior session cannot finalize;
- holidays, early closes, and DST preserve the correct session count;
- completed receipts cannot be rewritten;
- legacy runs retain endpoint-only results and exact encoding behavior;
- automatic and manual triggers honor cancellation, credential revision, sample-data, and external-access gates;
- Mac and iPhone Saved Research surfaces render each terminal state and remain usable at accessibility text sizes.

Focused history, fetch, persistence, and view tests run first, followed by the canonical Mac and iPhone gates and a signed local app inspection. No live broker or paper-trading state is involved.
