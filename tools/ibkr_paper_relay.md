# StockSage → IBKR paper relay

> **Current status — manual research only.** This legacy relay is dormant and retained for offline compatibility tests. The operational examples and September 8 observations below are historical, not current setup or release-verification instructions. Do not start the relay or native paper automation under the current direction; this source integration does not authorize broker or automation activity.

Relays new trades from StockSage's separate Qwen simulation to an eligible IBKR
paper account automatically, without a confirmation click for each order.
There is no live-account mode. This uses the TWS/Gateway API, separately from
the ChatGPT connector, which prepares orders for user review.

## Verified on September 8, 2026

- Gateway 10.50.1e is installed and its loopback API on port 4002 connects.
- Gateway identifies the current DUT account as Simulated Trading; the owner
  confirmed it is a **free-trial account**. IBKR says trial accounts are not
  supported for API trading. This relay permits a read-only diagnostic for DUT
  accounts but blocks their order submission and cancellation.
- The diagnostic saw zero positions and zero open orders. Its USD cash balance
  was available, but SettledCash was absent; missing settlement is never replaced
  with total cash. **No broker orders have been placed; the relay is not running.**
- 14 offline checks pass, including Buy/Sell receipts, caps, partial fills,
  exact-order cancellation, duplicate prevention, unresolved submissions,
  account checks, Gateway's $LEDGER- prefix, protocol serialization and recovery
  from the actual client's completed-order callback format.
- Actual broker order acceptance, fills, cancellation and reconnect recovery
  remain unverified.
- The combined Mac app is installed with native Qwen paper automation **ON**;
  its enabled flag and active writer lease were verified. It preserves the
  separately approved Form 4 and copied-plan freshness fixes. Final combined
  suites passed 1,848 Mac and 1,845 iPhone tests with the existing three exclusions.
  Original Qwen runtime is unchanged. Native automation waits for eligible
  regular-session data; the IBKR relay remains off until an eligible paper login.

## Start, inspect and stop

Use the paper login attached to an approved brokerage account. Authentication
stays in IB Gateway; this tool never requests or stores a password. Configure
the paper API for localhost port 4002 (TWS paper: 7497). Gateway's Read-Only API
setting must permit paper orders before acceptance can be tested. Keep remote
connections disabled. A successful read-only check does not verify write access.

The isolated Python environment is already installed on this Mac. To recreate:

```sh
cd /Users/saleh/StockSage-wt/qwen-context
python3 -m venv .research/ibkr-venv
.research/ibkr-venv/bin/python -m pip install -r tools/ibkr_paper_requirements.txt
```

Commands from that directory:

```sh
tools/ibkr-paper.command check   # Broker reads only; free-trial status is explicit
tools/ibkr-paper.command run     # Foreground relay; verifies paper account first
tools/ibkr-paper.command status  # Saved local status; check its timestamp
tools/ibkr-paper.command stop    # Requests stop; existing holdings remain
```

Double-clicking `ibkr-paper.command` starts the same foreground `run` command.
Keep StockSage's Qwen paper automation enabled, Gateway signed in, and the Mac
awake. Pause in StockSage stops new submissions. Ctrl-C or `stop` stops the relay;
neither liquidates holdings. `cancel` reconciles/cancels only pending orders
already identified by this relay's journal, never manual or account-wide orders.

## Execution rules and records

Only one standard DU paper account is eligible. The actual broker account list
is checked before every order/cancellation; a port alone is insufficient. The
journal stays bound to that account. There is one writer and a durable intent
is saved **before** sending. Unknown submissions are never blindly retried.

Only new local simulated trade events, less than 120 seconds old, qualify.
Historical events are not replayed. Limits are whole-share USD stocks priced
at least $1, five positions, $2,000 per position and $10,000 entry-cost exposure.
Sizing uses the smallest of fresh USD settled cash, available funds, cash
balance and remaining caps, less a $5 fee reservation. Actual fees can differ;
this reservation is not a guarantee of maximum fees or account margin behavior.

Orders are IOC limits during weekday 09:30–16:00 New York time, outside-RTH
disabled. There is no exchange holiday/early-close calendar. Limit orders can
expire unfilled. Sells use only broker-confirmed shares owned by this relay;
manual holdings are not adopted. Partial or missed exits stop for review.

StockSage's simulated ledger and IBKR fills are separate. The relay does not
rewrite the simulation or the real trade journal. Broker executions must support
the recorded filled quantity and average price. Fees not yet received are null,
not zero; late commission reports are not backfilled after a terminal receipt.

## Native ledger reader compatibility

The offline source reader accepts native account versions 1 and 2. Version 1
keeps the original minimal `version` + `trades` contract. Version 2 still reads
trades only from `account.trades`: its immutable `audit-<UUID>.json` chunks contain
older decisions, not relocated trades, and can never create broker intents.

Before returning any version-2 trade, the reader validates the consumed audit
integrity projection: version/audit pairing, canonical manifest references,
regular non-symlink files, exact byte counts and SHA-256 hashes, archive JSON and
record counts, finite decision dates, archive maximum dates, unique archive IDs,
unique decision IDs across all chunks and the active tail, and recomputed audit
control flags/latest-attempt dates. The per-symbol control maximum starts at
Foundation `Date.distantPast` (`-63114076800` seconds since the Apple reference
date), matching native audit derivation even for earlier finite decision dates.
Hash-valid semantic inconsistencies therefore fail closed. Unreferenced archive
orphans are ignored and never deleted.

Account and referenced-archive paths are opened nonblocking without following a
final symlink, then the opened descriptor must identify a regular file before any
read. FIFOs and other non-regular descriptors therefore fail closed without
waiting for a producer. A successfully wrapped descriptor has only the file
object as owner; if wrapping fails, the raw descriptor is closed exactly once.

Reads are bounded to 32 MB for the account, 32 MB per archive, and 128 MB for one
captured account-plus-archive generation, with at most 1,000 archives, 1,000,000
archived decisions, 50,000 active decisions, and 50,000 trades. There is no cache:
each poll rereads the captured account and all of its references, so same-size and
same-mtime atomic replacements and later archive corruption cannot reuse an old
success. Atomic replacement during a call does not mix generations; that call
validates the manifest captured from the account bytes it opened.

The whole referenced archive set is revalidated sequentially on every poll, up to
the stated 1,000-archive ceiling. Add a content index only if parent measurements
show this bounded path is too slow; integrity checks must not be skipped.

This is deliberately a trades-only consumed-integrity boundary, not a certificate
of the complete native `Book`. Pending orders, cursor/cash/account rules, trade
stop/target and optional measurement fields, and decision prose/facts/evidence/
model/plan semantics remain native Swift's responsibility and are not projected
into broker intents.

State lives in `~/Library/Application Support/StockSageIBKRPaper/`:
`receipts.sqlite3`, `status.json`, `relay.lock` and the optional `STOP` marker.
The source is `~/Library/Application Support/StockSageQwenPaper/account.json`.
Treat both directories as private. Do not delete/reset the receipt journal to
bypass an unresolved order or retained position.

Disconnects stop the relay. Restart attempts reconciliation before new orders;
missing, ambiguous or incomplete broker receipts require review. Completed-order
snapshots are reconciled using their filledQuantity and matching executions;
missing execution history stops recovery without resubmitting. Existing holdings have no broker-hosted
protective stop: exits depend on StockSage observing and recording an exit while
both programs are running. This is a paper-testing integration, not verified
live-trading software or evidence of profitable performance.

## Reproduce checks and references

```sh
.research/ibkr-venv/bin/python -m unittest discover -s tools -p test_ibkr_paper_relay.py -v
```

- [IBKR paper-account and free-trial guidance](https://ibkrcampus.com/campus/trading-lessons/request-paper-trading-account/?retakeFinal=1)
- [IBKR paper API limitations](https://www.interactivebrokers.com/docs/tws-api/doc/notes-limitations/limitations/paper-trading)
- [IBKR account-summary fields](https://interactivebrokers.github.io/tws-api/account_summary.html)
- [ib_async](https://github.com/ib-api-reloaded/ib_async): independent community
  client, BSD-2-Clause, not an official IBKR SDK. Dependencies are pinned and
  isolated from the Qwen runtime.
