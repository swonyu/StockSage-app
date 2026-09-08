# Approved recommendation: paper cash settlement

Owner approved the September 9 same-day/IBKR research recommendations at 02:25
Riyadh. First implementation slice: cash-account realism only. Bid/ask fills,
session unification, and strategy experiments follow separately; no broker relay,
real orders, leverage, model changes, or changes to the frozen prospective pilot.

## Design

Preserve `Book.cash` as total trade-date cash (including sale receivables) and use
it unchanged in equity. Derive unsettled net sale proceeds from existing closed
`TradeRecord`s and subtract them to obtain settled spending capacity. The current
adverse-fill costs are already included in those proceeds; do not deduct twice.
Do not add a second persisted balance or reset/migrate historical fills.

Use one date-injected settlement helper for the next New York settlement date.
The verified calendar covers 2026 and January 2027. Its holidays include bank-only
Columbus Day and Veterans Day, unlike the exchange calendar. Unknown dates return
nil and retain proceeds as unavailable, visibly. Release at New York midnight on
the scheduled T+1 date is an explicit simulation convention, NOT verification of
an IBKR settled-cash balance or a claim of actual intraday delivery time. Unexpected
closures and settlement failures remain outside this scheduled simulation.

All buy paths (proposal, fill-time sizing, discovery affordability and model facts)
use the same settled capacity. Fill-time rechecks prevent concurrent pending buys
from overspending. Sells, protective exits and held-stock research remain permitted
when spending capacity is zero. Retain negative derived settled balances caused by
legacy recycling for disclosure; clamp only spendable capacity to zero.

The existing schema stays at version 1, with a one-time, separately named policy
activation decision. Activation preserves all orders, trades, decision IDs and the
research cadence; pending entries are checked against the new policy when filled.
UI shows total cash, settled spendable cash, unsettled proceeds and their scheduled
dates (or unknown calendar), plus any legacy deficit. It must not call this an
actual broker balance.

Alternatives rejected: duplicated cash ledger (unnecessary migration/drift risk);
weekday/exchange-only T+1 (wrong bank-holiday release); broker-only settlement
(native simulation needs deterministic behavior even with the relay off).

## Implementation and verification

1. Add a production-path regression: after five cash-funded entries and one sale,
   the sale proceeds cannot fund a new same-day entry. Run it red before changing
   production code.
2. Implement derived balances/calendar and route every cash-spending caller through
   them. Add one-time policy evidence and update UI labels/limitations.
3. Exercise next day, weekends, Good Friday, July 3, Columbus/Veterans Day, DST,
   year boundary, unsupported dates, cent rounding, pending-order cash contention,
   continued exits, old-ledger decoding and unchanged equity/history.
4. Run focused tests, then the canonical executed macOS and iPhone 17 Pro (gate)
   tests. Preserve and install the exact tested Mac bundle only after observing
   the currently running app's 02:55 Riyadh close-out. Record actual outcomes and
   remaining limitations in HANDOFF; explicit-path local commits, no push/merge.

Self-review: subtraction uses net sale proceeds, not profit or the original
purchase principal; active purchases already debit total cash immediately. Each
closed trade remains independently dated. Date arithmetic uses a New York calendar,
not a fixed 24-hour delay. No account classification or profitability is inferred.
The writing-plans skill is unavailable in this session; this bounded sequence is
the implementation plan under the already approved research design.

## Calendar evidence, verified September 9, 2026

- [FINRA extension holiday schedule](https://www.finra.org/rules-guidance/key-topics/margin-accounts/margin-extension-holiday-schedule):
  2026 exchange/settlement holidays and January 2027 dates; explicitly distinguishes
  Columbus/Veterans Day as trading days with no settlement.
- [DTCC Good Friday notice 23891-26](https://www.dtcc.com/-/media/Files/pdf/2026/3/6/23891-26.pdf):
  no CNS settlement April 3, 2026.
- [DTCC Independence Day notice A9778](https://www.dtcc.com/-/media/Files/pdf/2026/6/5/a9778.pdf):
  holiday processing differs from normal settlement; do not infer settlement from
  a clearing service being open.
- [SEC T+1 investor bulletin](https://www.investor.gov/introduction-investing/general-resources/news-alerts/alerts-bulletins/investor-bulletins/new-t1-settlement-cycle-what-investors-need-know-investor-bulletin):
  standard next-business-day settlement for most US securities.

## Executed first-slice evidence

- Real production regression: 27 tests/one expected failure, exit65; the method
  filter initially selected zero tests, so only `red-suite` counts as red evidence.
- Final focused53 tests, macOS1877 tests and iPhone1874 tests all passed, exit0.
- Existing schema, equity and history survive round-trip checks; no live ledger
  mutation was performed by the agent. UI is built, not visually verified.
- Exact tested Mac bundle retained in
  `/private/tmp/stocksage-paper-settlement-20260909.iuEqUb/verified-mac/StockSageX.app`.
  At02:43 Riyadh installation is deferred until the running app's02:55 close-out
  is observed. See HANDOFF for hashes, logs, current holdings and safe installation.
