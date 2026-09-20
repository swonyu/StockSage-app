#!/usr/bin/env python3
"""Relay NEW StockSage simulated trades to one verified IBKR PAPER account.

No live mode, credentials, remote hosts, global cancellation or order retries.
The source simulation and IBKR's fills remain separate ledgers.
"""
import argparse
import asyncio
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, ROUND_DOWN, ROUND_UP
import fcntl
import hashlib
import json
import logging
import math
import os
from pathlib import Path
import re
import signal
import sqlite3
import stat
import subprocess
import time
import uuid
from zoneinfo import ZoneInfo

from ib_async import IB, LimitOrder, Stock, StartupFetch

CLIENT_ID = 23817
SOURCE = Path.home() / "Library/Application Support/StockSageQwenPaper/account.json"
STATE = Path.home() / "Library/Application Support/StockSageIBKRPaper"
APPLE_EPOCH = 978307200
FOUNDATION_DISTANT_PAST = -63_114_076_800.0
MAX_AGE = 120
POSITION_CAP = Decimal("2000")
CAPITAL_CAP = Decimal("10000")
FEE_RESERVE = Decimal("5")  # Reservation only; actual IBKR fees are recorded separately.
MAX_SOURCE_BYTES = 32_000_000
MAX_ARCHIVE_BYTES = 32_000_000
MAX_SNAPSHOT_BYTES = 128_000_000
MAX_AUDIT_ARCHIVES = 1_000
MAX_ARCHIVED_DECISIONS = 1_000_000
MAX_ACTIVE_DECISIONS = 50_000
MAX_TRADES = 50_000


class Halt(RuntimeError):
    """Uncertain or unsafe state: preserve receipts and require review."""


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float, str, Decimal)):
        raise Halt("Invalid numeric value")
    try:
        result = Decimal(str(value))
    except Exception as exc:
        raise Halt("Invalid numeric value") from exc
    if not result.is_finite():
        raise Halt("Non-finite numeric value")
    return result


def paper_account(accounts):
    # A paper-looking port alone is insufficient; validate the broker's account list.
    # Gateway 10.50 also reports DUT accounts (verified in its Simulated Trading UI).
    if len(accounts) != 1 or not re.fullmatch(r"DUT?[0-9]{3,20}", accounts[0]):
        raise Halt("Exactly one DU/DUT simulated account is required; live or mixed accounts are refused")
    return accounts[0]


def regular_hours(now):
    at = datetime.fromtimestamp(now, ZoneInfo("America/New_York"))
    return at.weekday() < 5 and (9, 30) <= (at.hour, at.minute) < (16, 0)


@dataclass(frozen=True)
class Intent:
    trade_id: str
    symbol: str
    side: str
    quantity: int
    limit: Decimal
    at: float

    @property
    def key(self):
        return f"{self.trade_id}:{self.side}"

    @property
    def ref(self):
        return f"SSP-{uuid.UUID(self.trade_id).hex}-{self.side[0]}"


def _read_bounded(path, limit, label):
    """Read one regular file generation without following a final symlink."""
    path = Path(path)
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                             | getattr(os, "O_NONBLOCK", 0))
    except FileNotFoundError as exc:
        message = ("StockSage paper ledger is not available" if label == "account"
                   else "Referenced StockSage audit archive is missing")
        raise Halt(message) from exc
    except OSError as exc:
        raise Halt(f"StockSage {label} must be a regular non-symlink file") from exc
    try:
        source = os.fdopen(descriptor, "rb")
    except Exception:
        os.close(descriptor)
        raise
    with source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise Halt(f"StockSage {label} must be a regular non-symlink file")
        if not 0 < before.st_size <= limit:
            raise Halt(f"StockSage {label} exceeds its size limit")
        data = source.read(limit + 1)
        after = os.fstat(source.fileno())
    identity = lambda value: (value.st_dev, value.st_ino, value.st_size,
                              value.st_mtime_ns, value.st_ctime_ns)
    if len(data) > limit:
        raise Halt(f"StockSage {label} exceeds its size limit")
    if len(data) != before.st_size or identity(before) != identity(after):
        raise Halt(f"StockSage {label} changed while reading; retry the captured generation")
    return data


def _reject_duplicate_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise Halt("Duplicate JSON key in StockSage data")
        value[key] = item
    return value


def _reject_json_constant(token):
    raise ValueError(token)


def _decode_json(data, label):
    try:
        return json.loads(data, parse_float=Decimal, object_pairs_hook=_reject_duplicate_keys,
                          parse_constant=_reject_json_constant)
    except Halt:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise Halt(f"Invalid StockSage {label} JSON; existing files preserved") from exc


def _uuid_value(value, label):
    if not isinstance(value, str) or not re.fullmatch(
            r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", value):
        raise Halt(f"Invalid StockSage {label} UUID")
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise Halt(f"Invalid StockSage {label} UUID") from exc


def _integer(value, label, minimum=0):
    if type(value) is not int or value < minimum:
        raise Halt(f"Invalid StockSage {label}")
    return value


def _finite_number(value, label):
    try:
        result = number(value)
        if not math.isfinite(float(result)):
            raise Halt("Outside native numeric range")
        return result
    except (Halt, OverflowError) as exc:
        raise Halt(f"Invalid StockSage {label}") from exc


def _finite_date(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float, Decimal)):
        raise Halt(f"Invalid StockSage {label}")
    try:
        result = float(_finite_number(value, label))
    except OverflowError as exc:
        raise Halt(f"Invalid StockSage {label}") from exc
    if not math.isfinite(result):
        raise Halt(f"Invalid StockSage {label}")
    return result


def _decision_projection(record, label):
    if not isinstance(record, dict):
        raise Halt(f"Invalid StockSage {label} decision record")
    decision_id = _uuid_value(record.get("id"), f"{label} decision ID")
    at = _finite_date(record.get("at"), f"{label} decision time")
    if not isinstance(record.get("symbol"), str):
        raise Halt(f"Invalid StockSage {label} decision symbol")
    if not isinstance(record.get("action"), str):
        raise Halt(f"Invalid StockSage {label} decision action")
    return decision_id, at, record["symbol"], record["action"]


def _audit_control(records):
    latest = {}
    for _, at, symbol, _ in records:
        if symbol:
            latest[symbol] = max(latest.get(symbol, FOUNDATION_DISTANT_PAST), at)
    return {
        "sameDayActivated": any(action == "Same-day policy activated" for _, _, _, action in records),
        "settlementActivated": any(action == "T+1 cash policy activated" for _, _, _, action in records),
        "marketScanned": any(action.startswith("Market scan") for _, _, _, action in records),
        "latestAttempt": latest,
    }


def _validate_audit_control(control, records):
    if not isinstance(control, dict):
        raise Halt("Invalid StockSage audit control")
    actual = {}
    latest = control.get("latestAttempt")
    if not isinstance(latest, dict) or any(not isinstance(key, str) for key in latest):
        raise Halt("Invalid StockSage audit control latestAttempt")
    for key, value in latest.items():
        actual[key] = _finite_date(value, "audit control latestAttempt")
    supplied = {key: control.get(key) for key in
                ("sameDayActivated", "settlementActivated", "marketScanned")}
    if any(type(value) is not bool for value in supplied.values()):
        raise Halt("Invalid StockSage audit control Boolean")
    supplied["latestAttempt"] = actual
    if supplied != _audit_control(records):
        raise Halt("StockSage audit control does not match referenced decisions")


def _validate_v2(value, account, account_bytes):
    audit = value.get("audit")
    active = value.get("decisions")
    if not isinstance(audit, dict):
        raise Halt("StockSage version 2 requires an audit manifest")
    if not isinstance(active, list):
        raise Halt("StockSage version 2 requires an active decisions array")
    if len(active) > MAX_ACTIVE_DECISIONS:
        raise Halt("StockSage active decision count exceeds its limit")
    archives = audit.get("archives")
    if not isinstance(archives, list):
        raise Halt("Invalid StockSage audit manifest archives")
    if len(archives) > MAX_AUDIT_ARCHIVES:
        raise Halt("StockSage audit archive count exceeds its limit")

    seen_decisions = set()
    for record in active:
        decision_id, _, _, _ = _decision_projection(record, "active")
        if decision_id in seen_decisions:
            raise Halt("Duplicate StockSage decision ID across active and archived history")
        seen_decisions.add(decision_id)

    parsed, archive_ids = [], set()
    total_bytes, total_decisions = account_bytes, 0
    for descriptor in archives:
        if not isinstance(descriptor, dict):
            raise Halt("Invalid StockSage audit archive descriptor")
        archive_id = _uuid_value(descriptor.get("id"), "audit archive ID")
        if archive_id in archive_ids:
            raise Halt("Duplicate StockSage audit archive ID")
        archive_ids.add(archive_id)
        count = _integer(descriptor.get("count"), "audit archive decision count", minimum=1)
        size = _integer(descriptor.get("bytes"), "audit archive byte count", minimum=1)
        if size > MAX_ARCHIVE_BYTES:
            raise Halt("StockSage audit archive exceeds its size limit")
        digest = descriptor.get("sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise Halt("Invalid StockSage audit archive SHA-256")
        latest = _finite_date(descriptor.get("latestAt"), "audit archive latestAt")
        total_bytes += size
        total_decisions += count
        if total_bytes > MAX_SNAPSHOT_BYTES:
            raise Halt("StockSage captured generation exceeds its size limit")
        if total_decisions > MAX_ARCHIVED_DECISIONS:
            raise Halt("StockSage archived decision count exceeds its limit")
        parsed.append((archive_id, count, size, digest, latest))

    archived = []
    directory = Path(account).parent
    # ponytail: revalidate at most 1,000 whole archives sequentially per poll;
    # add a content index only if parent measurements show this ceiling is too slow.
    for archive_id, count, size, digest, latest in parsed:
        path = directory / f"audit-{str(archive_id).upper()}.json"
        data = _read_bounded(path, MAX_ARCHIVE_BYTES, "audit archive")
        if len(data) != size:
            raise Halt("StockSage audit archive byte count does not match manifest")
        if hashlib.sha256(data).hexdigest() != digest:
            raise Halt("StockSage audit archive SHA-256 does not match manifest")
        records = _decode_json(data, "audit archive")
        if not isinstance(records, list):
            raise Halt("StockSage audit archive must contain a JSON array")
        if len(records) != count:
            raise Halt("StockSage audit archive decision count does not match manifest")
        projected = [_decision_projection(record, "audit") for record in records]
        for decision_id, _, _, _ in projected:
            if decision_id in seen_decisions:
                raise Halt("Duplicate StockSage decision ID across active and archived history")
            seen_decisions.add(decision_id)
        if max(record[1] for record in projected) != latest:
            raise Halt("StockSage audit archive latestAt does not match its decisions")
        archived.extend(projected)
    _validate_audit_control(audit.get("control"), archived)


def _trade_intents(trades):
    ids, intents = set(), []
    for trade in trades:
        if not isinstance(trade, dict):
            raise Halt("Invalid StockSage trade record")
        trade_uuid = _uuid_value(trade.get("id"), "trade ID")
        trade_id = str(trade_uuid)
        symbol = trade.get("symbol")
        if trade_uuid in ids:
            raise Halt("Duplicate StockSage trade ID")
        if trade.get("side") != "Long" or not isinstance(symbol, str) \
                or not re.fullmatch(r"[A-Z][A-Z0-9.]{0,11}", symbol):
            raise Halt("Invalid StockSage trade side or symbol")
        ids.add(trade_uuid)
        qty = _finite_number(trade.get("shares"), "trade share count")
        entry = _finite_number(trade.get("entry"), "trade entry price")
        try:
            opened = float(_finite_number(trade.get("openedAt"), "trade open time")) + APPLE_EPOCH
        except OverflowError as exc:
            raise Halt("Invalid StockSage trade open time") from exc
        if qty < 1 or qty > 1_000_000 or qty != qty.to_integral_value() \
                or entry < 1 or not math.isfinite(opened):
            raise Halt("Invalid StockSage trade price, size or open time")
        intents.append(Intent(trade_id, symbol, "BUY", int(qty), entry, opened))
        close, price = trade.get("closedAt"), trade.get("exitPrice")
        if (close is None) != (price is None):
            raise Halt("StockSage trade close time and exit price must be paired")
        if close is not None:
            try:
                closed = float(_finite_number(close, "trade close time")) + APPLE_EPOCH
            except OverflowError as exc:
                raise Halt("Invalid StockSage trade close time") from exc
            exit_price = _finite_number(price, "trade exit price")
            if not math.isfinite(closed) or closed < opened or exit_price <= 0:
                raise Halt("Invalid StockSage trade exit price or close time")
            intents.append(Intent(trade_id, symbol, "SELL", int(qty), exit_price, closed))
    return sorted(intents, key=lambda item: (item.at, item.side == "SELL"))


def read_source(path):
    data = _read_bounded(path, MAX_SOURCE_BYTES, "account")
    value = _decode_json(data, "account")
    if not isinstance(value, dict):
        raise Halt("StockSage source ledger root must be a JSON object")
    version = value.get("version")
    if type(version) is not int:
        raise Halt("StockSage source ledger version must be an integer")
    if version not in (1, 2):
        raise Halt(f"Unsupported StockSage source ledger version {version}")
    trades = value.get("trades")
    if not isinstance(trades, list):
        raise Halt("StockSage source ledger trades must be a JSON array")
    if len(trades) > MAX_TRADES:
        raise Halt("StockSage trade count exceeds its limit")
    intents = _trade_intents(trades)
    if version == 1:
        if value.get("audit") is not None:
            raise Halt("StockSage version 1 cannot contain an audit manifest")
    else:
        _validate_v2(value, path, len(data))
    return intents


def source_running(path):
    try:
        enabled = subprocess.run(["defaults", "read", "SA.StockSage", "stocksage.qwenPaper.enabled"],
                                 capture_output=True, text=True, timeout=3)
        if enabled.returncode or enabled.stdout.strip() != "1":
            return False
        with path.with_suffix(".json.lock").open("r+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(lock, fcntl.LOCK_UN)
                return False
            except BlockingIOError:
                return True
    except (OSError, subprocess.TimeoutExpired):
        return False


class Journal:
    def __init__(self, root, now=None):
        self.root = root
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.lock = (root / "relay.lock").open("a+")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            self.lock.close()
            raise Halt("Another paper relay holds the writer lock") from exc
        path = root / "receipts.sqlite3"
        self.db = sqlite3.connect(path)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS orders(
                key TEXT PRIMARY KEY, trade_id TEXT NOT NULL, symbol TEXT NOT NULL,
                side TEXT NOT NULL, ref TEXT UNIQUE NOT NULL, source_at REAL NOT NULL,
                con_id INTEGER NOT NULL, quantity INTEGER NOT NULL, limit_price TEXT NOT NULL,
                order_id INTEGER NOT NULL, state TEXT NOT NULL, broker_status TEXT NOT NULL DEFAULT '',
                filled TEXT NOT NULL DEFAULT '0', average TEXT NOT NULL DEFAULT '0',
                receipt TEXT NOT NULL DEFAULT '{}');
            CREATE TABLE IF NOT EXISTS events(at REAL NOT NULL, detail TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS orders_trade ON orders(trade_id);
        """)
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO meta VALUES('version','1')")
            self.db.execute("INSERT OR IGNORE INTO meta VALUES('armed_at',?)", (str(time.time() if now is None else now),))
        if self.meta("version") != "1" or self.db.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise Halt("Invalid relay journal; do not reset it to bypass reconciliation")
        if not math.isfinite(float(self.meta("armed_at"))) or float(self.meta("armed_at")) <= 0:
            raise Halt("Invalid relay activation timestamp")
        for row in self.rows():
            qty, filled, average, limit = row["quantity"], number(row["filled"]), number(row["average"]), number(row["limit_price"])
            if (row["side"] not in ("BUY", "SELL") or row["state"] not in ("prepared", "submitted", "done", "skipped")
                    or not isinstance(qty, int) or not 0 <= qty <= 1_000_000 or not 0 <= filled <= qty
                    or average < 0 or limit < 0 or not math.isfinite(row["source_at"])
                    or row["key"] != f"{str(uuid.UUID(row['trade_id']))}:{row['side']}"):
                raise Halt("Invalid persisted paper order")

    def close(self):
        self.db.close()
        self.lock.close()

    def meta(self, key):
        row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def bind(self, account):
        paper_account([account])
        if self.meta("account") not in (None, account):
            raise Halt("Paper account changed; journal belongs to another account")
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO meta VALUES('account',?)", (account,))

    def rows(self):
        return self.db.execute("SELECT * FROM orders ORDER BY source_at,key").fetchall()

    def owned(self, trade_id):
        return sum((number(r["filled"]) * (1 if r["side"] == "BUY" else -1)
                    for r in self.db.execute("SELECT side,filled FROM orders WHERE trade_id=?", (trade_id,))), Decimal(0))

    def exposure(self):
        return sum((self.owned(r["trade_id"]) * number(r["average"])
                    for r in self.rows() if r["side"] == "BUY"), Decimal(0))

    def has(self, key):
        return self.db.execute("SELECT 1 FROM orders WHERE key=?", (key,)).fetchone() is not None

    def record(self, intent, *, con_id=0, quantity=0, price=Decimal(0), order_id=0, state="skipped", reason=""):
        with self.db:
            self.db.execute("INSERT INTO orders(key,trade_id,symbol,side,ref,source_at,con_id,quantity,limit_price,order_id,state,broker_status) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                            (intent.key, intent.trade_id, intent.symbol, intent.side, intent.ref, intent.at,
                             con_id, quantity, str(price), order_id, state, reason))

    def note(self, detail):
        with self.db:
            self.db.execute("INSERT INTO events VALUES(?,?)", (time.time(), detail))

    def status(self, message):
        value = {"at": time.time(), "mode": "paper", "status": message,
                 "account": ("DU…" + self.meta("account")[-4:]) if self.meta("account") else None,
                 "owned_shares": {r["symbol"]: str(self.owned(r["trade_id"])) for r in self.rows()
                                  if r["side"] == "BUY" and self.owned(r["trade_id"]) > 0},
                 "orders": [dict(r) for r in self.rows()[-20:]]}
        target = self.root / "status.json"
        temp = target.with_suffix(".tmp")
        with temp.open("w") as f:
            json.dump(value, f, indent=2, allow_nan=False); f.flush(); os.fsync(f.fileno())
        os.replace(temp, target)


class Relay:
    def __init__(self, ib, journal, port=4002, enabled=lambda: True):
        if port not in (4002, 7497):
            raise Halt("Only the standard loopback paper ports 4002/7497 are supported")
        self.ib, self.journal, self.port, self.account = ib, journal, port, None
        self.enabled = enabled

    def guard(self, write=False):
        if not self.ib.isConnected() or paper_account(self.ib.managedAccounts()) != self.account:
            raise Halt("Paper connection lost or account identity changed")
        if write and self.account.startswith("DUT"):
            raise Halt("IBKR free-trial accounts do not support API trading; use the paper account linked to an approved brokerage account")

    async def connect(self):
        await self.ib.connectAsync("127.0.0.1", self.port, clientId=CLIENT_ID, readonly=True,
                                   timeout=15, raiseSyncErrors=True, fetchFields=StartupFetch(0))
        self.account = paper_account(self.ib.managedAccounts())
        if not self.account.startswith("DUT"):
            self.journal.bind(self.account)
        self.guard()

    async def fresh_cash(self):
        self.guard()
        # Observe only this completed request, not cached accountSummary values.
        values = {}
        def receive(v):
            if v.account == self.account:
                tag = v.tag.removeprefix("$LEDGER-")
                if tag in ("SettledCash", "AvailableFunds", "CashBalance"):
                    values[(tag, v.currency)] = number(v.value)
        self.ib.accountSummaryEvent += receive
        request_id = self.ib.client.getReqId()
        try:
            completed = self.ib.wrapper.startReq(request_id)
            self.ib.client.reqAccountSummary(request_id, "All", "SettledCash,AvailableFunds,$LEDGER:USD")
            await asyncio.wait_for(completed, 15)
        finally:
            self.ib.client.cancelAccountSummary(request_id)
            self.ib.accountSummaryEvent -= receive
        self.guard()
        try:
            return min(number(values[(tag, "USD")]) for tag in ("SettledCash", "AvailableFunds", "CashBalance"))
        except KeyError as exc:
            raise Halt("Fresh USD settled cash, cash balance and available funds are required; no FX or margin assumed") from exc

    async def positions_and_orders(self):
        self.guard()
        positions = await asyncio.wait_for(self.ib.reqPositionsAsync(), 15)
        orders = await asyncio.wait_for(self.ib.reqAllOpenOrdersAsync(), 15)
        self.guard()
        return positions, orders

    def receipt(self, row, trade, completed_executions=None):
        row = self.journal.db.execute("SELECT * FROM orders WHERE key=?", (row["key"],)).fetchone()
        order, status = trade.order, trade.orderStatus
        completed = completed_executions is not None
        if (order.account != self.account or (not completed and order.clientId != CLIENT_ID) or order.orderRef != row["ref"]
                or order.action != row["side"] or trade.contract.conId != row["con_id"]
                or number(order.totalQuantity) != row["quantity"] or number(order.lmtPrice) != number(row["limit_price"])
                or (completed and order.permId <= 0)):
            raise Halt("Broker receipt does not match the prepared paper order")
        # Completed-order packets omit client/order IDs and status fill totals.
        # Their filledQuantity must reconcile with executions from our exact API client.
        filled = number(order.filledQuantity if completed else status.filled)
        executions = {f.execution.execId: f for f in (completed_executions if completed else trade.fills)}
        average = (sum((number(f.execution.price) * number(f.execution.shares) for f in executions.values()), Decimal(0))
                   / filled if completed and filled else (Decimal(0) if completed else number(status.avgFillPrice)))
        if filled < number(row["filled"]) or filled < 0 or filled > row["quantity"] or (filled > 0 and average <= 0):
            raise Halt("Invalid or regressing broker fill receipt")
        # Receipt must have executions supporting all filled shares; status alone is not a fill ledger.
        executed = sum((number(f.execution.shares) for f in executions.values()), Decimal(0))
        if executed != filled:
            return False
        if any(f.execution.acctNumber != self.account or f.execution.clientId != CLIENT_ID
               or f.execution.orderId != row["order_id"]
               or f.execution.orderRef != row["ref"] or f.contract.conId != row["con_id"]
               or f.execution.side != ("BOT" if row["side"] == "BUY" else "SLD")
               or number(f.execution.price) <= 0 or number(f.execution.shares) <= 0
               for f in executions.values()):
            raise Halt("Execution account or client mismatch")
        if filled and abs(sum((number(f.execution.price) * number(f.execution.shares)
                               for f in executions.values()), Decimal(0)) / filled - average) > Decimal("0.0001"):
            raise Halt("Execution prices do not reconcile with average fill price")
        terminal = status.status in ("Filled", "Cancelled", "ApiCancelled", "Inactive")
        if completed and not terminal:
            raise Halt("Completed-order snapshot has no terminal status; review required")
        if status.status == "Filled" and filled != row["quantity"]:
            raise Halt("Filled status has an inconsistent quantity")
        evidence = {"perm_id": order.permId, "status": status.status, "executions": [
            {"id": f.execution.execId, "shares": str(f.execution.shares), "price": f.execution.price,
             "at": f.time.isoformat(), "commission": (f.commissionReport.commission
                 if f.commissionReport.currency and math.isfinite(f.commissionReport.commission)
                    and abs(f.commissionReport.commission) < 1e100 else None),
             "commission_currency": f.commissionReport.currency}
            for f in executions.values()], "messages": [entry.message for entry in trade.log if entry.message]}
        with self.journal.db:
            self.journal.db.execute("UPDATE orders SET state=?,broker_status=?,filled=?,average=?,receipt=? WHERE key=?",
                                    ("done" if terminal else "submitted", status.status, str(filled), str(average),
                                     json.dumps(evidence, allow_nan=False), row["key"]))
        return terminal

    async def finish(self, row, trade, wait=30):
        until = time.monotonic() + wait
        while time.monotonic() < until:
            self.guard()
            if self.receipt(row, trade):
                return
            if not self.enabled():
                break
            await asyncio.sleep(.2)
        self.guard()
        # Never use reqGlobalCancel: only this journal's exact verified order may be cancelled.
        if self.receipt(row, trade):
            return
        self.guard(write=True)
        self.ib.cancelOrder(trade.order)
        until = time.monotonic() + 10
        while time.monotonic() < until:
            self.guard()
            if self.receipt(row, trade):
                return
            await asyncio.sleep(.2)
        raise Halt("Paper order cancellation/fill is unconfirmed; reconciliation required before any further submission")

    async def reconcile(self):
        self.require_complete_exits()
        pending = [r for r in self.journal.rows() if r["state"] not in ("done", "skipped")]
        if not pending:
            return
        self.guard()
        opened = await asyncio.wait_for(self.ib.reqOpenOrdersAsync(), 15)
        completed = await asyncio.wait_for(self.ib.reqCompletedOrdersAsync(False), 15)
        executions = await asyncio.wait_for(self.ib.reqExecutionsAsync(), 15)
        self.guard()
        for row in pending:
            matches = [t for t in opened + completed if t.order.orderRef == row["ref"]]
            if len(matches) != 1:
                raise Halt("A previous submission has no unique broker receipt; it will NOT be resent")
            trade = matches[0]
            if any(trade is t for t in completed):
                fills = [f for f in executions if f.execution.permId == trade.order.permId]
                if not self.receipt(row, trade, completed_executions=fills):
                    raise Halt("Completed order has incomplete execution history; no resubmission or cancellation attempted")
            else:
                await self.finish(row, trade, wait=0)
        self.require_complete_exits()

    def require_complete_exits(self):
        if any(r["side"] == "SELL" and r["state"] == "done" and number(r["filled"]) < r["quantity"]
               for r in self.journal.rows()):
            raise Halt("A previous paper exit was incomplete; review retained shares before continuing")

    async def submit(self, intent, now=None):
        now = time.time() if now is None else now
        self.guard(write=True)
        self.require_complete_exits()
        if self.journal.has(intent.key):
            return
        if intent.at < float(self.journal.meta("armed_at")) or not 0 <= now - intent.at < MAX_AGE or not regular_hours(now):
            if intent.side == "SELL" and self.journal.owned(intent.trade_id) > 0:
                raise Halt("Exit observation was missed; paper holdings require review rather than a stale replay")
            self.journal.record(intent, reason="Old, future-dated or outside-session source event; no replay")
            return
        if any(r["state"] not in ("done", "skipped") for r in self.journal.rows()):
            raise Halt("Unresolved previous order blocks submission")
        details = await asyncio.wait_for(self.ib.reqContractDetailsAsync(Stock(intent.symbol, "SMART", "USD")), 15)
        self.guard()
        if len(details) != 1:
            raise Halt("Stock contract could not be uniquely resolved")
        detail, contract = details[0], details[0].contract
        if contract.secType != "STK" or contract.currency != "USD" or contract.symbol != intent.symbol or contract.conId <= 0:
            raise Halt("Only uniquely resolved USD stock contracts are supported")
        tick = number(detail.minTick)
        if tick <= 0 or tick > 1:
            raise Halt("Unsupported contract price increment")
        rounding = ROUND_DOWN if intent.side == "BUY" else ROUND_UP
        price = (intent.limit / tick).to_integral_value(rounding=rounding) * tick
        if price < 1:
            raise Halt("Paper relay supports stock prices of at least one dollar")
        positions, orders = await self.positions_and_orders()
        if any(t.order.account == self.account and t.contract.conId == contract.conId for t in orders):
            raise Halt("An existing order for this contract requires review")
        broker_quantity = sum((number(p.position) for p in positions
                               if p.account == self.account and p.contract.conId == contract.conId), Decimal(0))
        owned = self.journal.owned(intent.trade_id)
        if intent.side == "BUY":
            if broker_quantity != 0 or owned != 0:
                self.journal.record(intent, reason="Existing paper holding; no position adopted or enlarged")
                return
            held = {r["trade_id"] for r in self.journal.rows() if self.journal.owned(r["trade_id"]) > 0}
            if len(held) >= 5:
                self.journal.record(intent, reason="Five-position limit")
                return
            cash = await self.fresh_cash()
            budget = min(POSITION_CAP, CAPITAL_CAP - self.journal.exposure(), cash) - FEE_RESERVE
            quantity = min(intent.quantity, max(0, int(budget // price)))
        elif intent.side == "SELL":
            if owned <= 0:
                self.journal.record(intent, reason="No IBKR shares owned by this source trade")
                return
            if owned != broker_quantity or owned != int(owned):
                raise Halt("Paper position differs from relay-owned shares; no sale or short order sent")
            quantity = int(owned)
        else:
            raise Halt("Unsupported order side")
        if quantity < 1:
            self.journal.record(intent, reason="Insufficient cash or capacity for a whole share")
            return
        # Revalidate after network waits. Never turn a stale source event into a new order.
        self.guard()
        if not self.enabled() or not 0 <= time.time() - intent.at < MAX_AGE or not regular_hours(time.time()):
            if intent.side == "SELL" and owned > 0:
                raise Halt("Paper exit expired or paused during validation; retained shares require review")
            self.journal.record(intent, reason="Source event expired while validating the order")
            return
        order_id = self.ib.client.getReqId()
        order = LimitOrder(intent.side, quantity, float(price), account=self.account,
                           orderId=order_id, clientId=CLIENT_ID, orderRef=intent.ref,
                           tif="IOC", outsideRth=False, transmit=True)
        # Durable intent BEFORE the network side effect. A crash here never triggers blind resubmission.
        self.journal.record(intent, con_id=contract.conId, quantity=quantity, price=price,
                            order_id=order_id, state="prepared")
        row = next(r for r in self.journal.rows() if r["key"] == intent.key)
        self.guard(write=True)
        trade = self.ib.placeOrder(contract, order)
        await self.finish(row, trade)
        if intent.side == "SELL" and self.journal.owned(intent.trade_id) > 0:
            raise Halt("Paper exit only partly filled; remaining shares require review, not an automatic stale-price retry")


async def main_async(args):
    journal, ib = Journal(args.state), IB()
    stop = asyncio.Event()
    relay = Relay(ib, journal, args.port, enabled=lambda: not stop.is_set()
                  and not (args.state / "STOP").exists() and source_running(args.source))
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    try:
        if args.command == "run":
            # Clear a previous stop only after acquiring the exclusive writer lease.
            (args.state / "STOP").unlink(missing_ok=True)
        await relay.connect()
        if args.command == "check":
            positions, orders = await relay.positions_and_orders()
            if relay.account.startswith("DUT"):
                journal.status("Connected to free-trial simulation; API trading unsupported; submission disabled")
                print(json.dumps({"mode": "free-trial simulation", "account": "DUT…" + relay.account[-4:],
                                  "connected": True, "api_trading_supported": False,
                                  "positions": len(positions), "open_orders": len(orders)}))
                return
            cash = await relay.fresh_cash()
            journal.status("Verified paper connection; read-only check completed")
            print(json.dumps({"mode": "paper", "account": "DU…" + relay.account[-4:],
                              "positions": len(positions), "open_orders": len(orders), "usd_cash": str(cash)}))
            return
        relay.guard(write=True)
        await relay.reconcile()
        if args.command == "cancel":
            journal.status("Reconciled and cancelled this relay's pending paper orders")
            return
        await relay.fresh_cash()
        journal.note("Relay started; new simulated trades only; IOC limit orders; paper account verified")
        print("IBKR paper relay running. Ctrl-C stops the relay; receipts remain in", args.state, flush=True)
        while not stop.is_set() and not (args.state / "STOP").exists():
            relay.guard()
            if source_running(args.source):
                for intent in read_source(args.source):
                    if stop.is_set() or (args.state / "STOP").exists() or not source_running(args.source):
                        break
                    await relay.submit(intent)
                journal.status("Running: waiting for new StockSage simulated trades")
            else:
                journal.status("Waiting: start StockSage paper automation")
            try:
                await asyncio.wait_for(stop.wait(), timeout=3)
            except asyncio.TimeoutError:
                pass
        await relay.reconcile()
        journal.status("Stopped; paper holdings retained")
    except Exception as exc:
        journal.note(type(exc).__name__ + ": " + str(exc))
        journal.status("Stopped: " + str(exc))
        raise
    finally:
        ib.disconnect()
        journal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "run", "cancel", "status", "stop"])
    parser.add_argument("--port", type=int, choices=[4002, 7497], default=4002)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--state", type=Path, default=STATE)
    args = parser.parse_args()
    os.umask(0o077)
    logging.basicConfig(level=logging.CRITICAL)  # Do not dump account callbacks or market data to a shared terminal.
    if args.command == "status":
        path = args.state / "status.json"
        print(path.read_text() if path.exists() else "Paper relay has not run yet")
        return
    if args.command == "stop":
        args.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        (args.state / "STOP").touch()
        print("Stop requested; existing paper holdings will be retained")
        return
    try:
        asyncio.run(main_async(args))
    except (Halt, OSError, asyncio.TimeoutError, sqlite3.Error) as exc:
        raise SystemExit("Paper relay stopped: " + str(exc))


if __name__ == "__main__":
    main()
