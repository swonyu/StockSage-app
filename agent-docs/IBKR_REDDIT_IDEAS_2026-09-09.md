# IBKR automation thread: ideas worth borrowing for StockSage

Reviewed September 9, 2026. Code baseline: `codex/qwen-chat-context`,
HEAD `3f6fa3f` plus the parent's tested EODHD/reliability batch. This note is
analysis and follow-up acceptance criteria, not a new implemented strategy.

## Assessment

The [Reddit post and visible comments](https://www.reddit.com/r/interactivebrokers/comments/1rzt7bn/built_an_automated_trading_system_on_ibkrs_api/)
offer useful engineering prompts: durable restart recovery, separate entry and
exit handling, quote validation, duplicate-tolerant order tracking and explicit
transaction costs. They provide no independently verified performance evidence.
The author describes a weighted scoring engine, not an LLM trader. More signals
and weight updates after every trade are not evidence that a model improves.
Do not adopt the claimed cash-account restrictions, numerical filters or
profitability implications as specifications.

## Verified corrections

- **API distinction:** 7496/7497 are TWS socket defaults (live/paper); Gateway
  defaults are 4001/4002. These are not Client Portal REST ports. A port is not
  proof of account identity. [IBKR connection parameters](https://www.interactivebrokers.com/docs/excel/rtd/connection-parameters),
  [separate Web API documentation](https://www.interactivebrokers.com/campus/ibkr-api-page/webapi-doc/).
- **Reconnect messages:** 1101 means restored with subscriptions lost;
  1102 means restored with data maintained, requiring no resubmission. The
  comment reverses this distinction. [IBKR system messages](https://www.interactivebrokers.com/docs/tws-api/doc/error-handling/system-message-codes).
- **Pacing:** the six-in-two-seconds and sixty-in-ten-minutes rules cited as
  order limits belong to small-bar historical requests, with contract/exchange/
  tick-type qualifications. Use the limits for the actual API and request class.
  [IBKR historical pacing](https://www.interactivebrokers.com/docs/tws-api/doc/market-data-historical/historical-data-limitations/pacing-violations-for-small-bars-30-secs-or-less).
- **Receipt handling:** IBKR recommends monitoring errors, order status,
  open-order warnings and execution details together. Filled quantity needs
  execution evidence; a status label alone is insufficient.
  [IBKR order placement considerations](https://www.interactivebrokers.com/docs/tws-api/doc/orders/place-order/order-placement-considerations).

## Current code versus useful next work

These are parent source findings, not assertions about verified broker behavior.

| Area | Already present | Gap / smallest useful next step |
| --- | --- | --- |
| Restart safety | Native `acquire`, `read`, `save` use a single writer lease and atomic account publication; `StockSagePaperAudit` validates immutable archive hashes. Relay `reconcile` refuses ambiguous submissions. | Reuse these stores. Add boundary fixtures, not a second event-sourcing framework. Keep simulated and broker ledgers separate. |
| Protective exits | `Book.settle` retains triggered STOP intent across attempt expiry, recovery and restart; `enforceDayLimit` requests overdue exits. | Preserve urgency independent of new-entry screening. Never satisfy an exit using stale or invented data. |
| Fill realism | `fetchPaperQuotes` and `qualified` require eligible, fresh Massive observations after the saved decision. | `Book.settle` still uses trade price plus assumed 10 bps adverse cost; it does not consume bid/ask or displayed size. Reuse existing `StockSageNBBO` for the approved quote-side/size fill work, including stale/crossed/zero-size and partial-fill fixtures. |
| Cost accounting | Native cost assumption is explicit. Relay receipt records missing commission as null and deduplicates executions by `execId`. | Late commission reports are not backfilled after terminal relay receipts. Future fee handling must be idempotent and preserve fills; do not copy a universal dollar fee or overwrite old simulated costs. |
| Data recovery | Stream has connection/gap/backlog diagnostics and session generations. Parent follow-up now renews expired quote-condition references through the existing publisher, with single-flight minute retry after failure/empty data and generation checks. | Original first-fetch/24-hour loss was reproduced and repaired; see HANDOFF for gates/install status. Metadata renewal never changes a quote timestamp. Exchange-list failure still lacks an independent retry. No extra socket or force-LIVE fallback. |
| Research throughput | `researchCycle` screens US snapshots, prioritizes holdings, selects up to 100 new candidates and runs four workers. | Keep this bounded pipeline; do not replace Massive coverage with an IBKR subscription-per-symbol design or conflate screening with completed Qwen analysis. |

Source paths: `StockSage/Sources/StockSage/StockSagePaperAutomation.swift`,
`StockSagePaperAudit.swift`, `StockSageLiveStream.swift`, and
`tools/ibkr_paper_relay.py` / `tools/ibkr_paper_relay.md`.

The full-gated condition-reference repair is installed (see HANDOFF).
Next: approved native quote-side/size realism, then deterministic
restart/duplicate/late-receipt tests. Broker-specific changes
remain offline-only; relay OFF. No new strategy, adaptive exits, model-weight
changes, market-data purchase or real orders are authorized by this note.
Price/volume activity may identify something to investigate; it must never become
a confirmed news catalyst without a cited source. Any new strategy needs a frozen
out-of-sample/forward evaluation with costs, drawdowns and failures reported.
