"""Offline broker-boundary checks. No credentials, sockets or real accounts."""
import asyncio
from dataclasses import asdict, replace
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch
import uuid

import ibkr_paper_relay as relay_module
from eventkit import Event
from ib_async import IB, CommissionReport, Execution, Fill, Order, OrderState, OrderStatus, Position, Stock, Trade
from ibkr_paper_relay import (APPLE_EPOCH, CLIENT_ID, Halt, Intent, Journal, Relay,
                             main_async, number, paper_account, read_source)

NOW = datetime(2026, 9, 8, 18, 0, tzinfo=timezone.utc).timestamp()
ACCOUNT = "DU1234567"
FOUNDATION_DISTANT_PAST = -63_114_076_800.0


class Broker:
    """Protocol boundary fake; records every possible side effect."""
    def __init__(self):
        self.accounts, self.connected, self.next_id = [ACCOUNT], False, 100
        self.sent, self.cancelled, self.positions, self.completed, self.opened = [], [], [], [], []
        self.mode, self.qty_override = "fill", None
        self.accountSummaryEvent = Event()
        self.future = None
        self.wrapper = NS(startReq=self.start_request)
        self.client = NS(getReqId=self.get_id, reqAccountSummary=self.summary,
                         cancelAccountSummary=lambda req_id: None)

    def get_id(self):
        self.next_id += 1
        return self.next_id

    def start_request(self, req_id):
        self.future = asyncio.get_running_loop().create_future()
        return self.future

    def summary(self, req_id, group, tags):
        for tag in ["SettledCash", "AvailableFunds", "CashBalance"]:
            self.accountSummaryEvent.emit(NS(account=ACCOUNT, tag=tag, value="10000", currency="USD"))
        self.future.set_result(None)

    async def connectAsync(self, host, port, **kwargs):
        assert host == "127.0.0.1" and port in (4002, 7497) and kwargs["clientId"] == CLIENT_ID
        self.connected = True

    def isConnected(self):
        return self.connected

    def managedAccounts(self):
        return self.accounts

    async def reqContractDetailsAsync(self, contract):
        contract.conId = sum((i + 1) * ord(c) for i, c in enumerate(contract.symbol))
        return [NS(contract=contract, minTick=.01)]

    async def reqPositionsAsync(self):
        return self.positions

    async def reqAllOpenOrdersAsync(self):
        return self.opened

    async def reqOpenOrdersAsync(self):
        return self.opened

    async def reqCompletedOrdersAsync(self, apiOnly):
        return self.completed

    async def reqExecutionsAsync(self):
        return [f for t in self.completed + self.opened for f in t.fills]

    def placeOrder(self, contract, order):
        self.sent.append(order)
        if self.mode == "disconnect":
            raise ConnectionError("Transport lost after durable preparation")
        filled = Decimal(self.qty_override if self.qty_override is not None else order.totalQuantity)
        order.permId = order.orderId + 1000
        status = "Submitted" if self.mode == "pending" else ("Filled" if filled == order.totalQuantity else "Cancelled")
        if self.mode == "pending":
            filled = Decimal(0)
        order.filledQuantity = filled
        trade = Trade(contract, order, OrderStatus(status=status, filled=filled,
                      remaining=Decimal(order.totalQuantity)-filled, avgFillPrice=order.lmtPrice if filled else 0))
        if filled:
            stamp = datetime.fromtimestamp(NOW, timezone.utc)
            execution = Execution(execId=f"E{order.orderId}", acctNumber=ACCOUNT, clientId=CLIENT_ID,
                                  orderId=order.orderId, permId=order.permId, side="BOT" if order.action == "BUY" else "SLD",
                                  shares=filled, price=order.lmtPrice, time=stamp, orderRef=order.orderRef)
            trade.fills.append(Fill(contract, execution, CommissionReport(commission=1, currency="USD"), stamp))
            prior = sum(p.position for p in self.positions if p.contract.conId == contract.conId)
            self.positions = [p for p in self.positions if p.contract.conId != contract.conId]
            total = prior + filled * (1 if order.action == "BUY" else -1)
            if total:
                self.positions.append(Position(ACCOUNT, contract, total, order.lmtPrice))
        (self.opened if status == "Submitted" else self.completed).append(trade)
        return trade

    def cancelOrder(self, order):
        self.cancelled.append(order.orderId)
        for trade in self.opened:
            if trade.order.orderId == order.orderId:
                trade.orderStatus.status = "Cancelled"


class SourceReaderChecks(unittest.TestCase):
    """Synthetic native-book compatibility checks; no relay entrypoint or socket."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "account.json"

    def tearDown(self):
        self.temp.cleanup()

    def assert_reader_halts_in_child(self, reason):
        script = (
            "import sys\n"
            "from pathlib import Path\n"
            "from ibkr_paper_relay import Halt, read_source\n"
            "try:\n"
            "    read_source(Path(sys.argv[1]))\n"
            "except Halt as exc:\n"
            "    print(exc)\n"
            "    raise SystemExit(0)\n"
            "raise SystemExit('reader unexpectedly accepted source')\n"
        )
        try:
            result = subprocess.run(
                [sys.executable, "-c", script, str(self.source)],
                cwd=Path(__file__).parent,
                capture_output=True,
                text=True,
                timeout=2,
            )
        except subprocess.TimeoutExpired as exc:
            self.fail(f"reader blocked before descriptor validation: {exc}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, reason)

    @staticmethod
    def json_bytes(value):
        return json.dumps(value, allow_nan=False, ensure_ascii=False,
                          separators=(",", ":")).encode()

    @staticmethod
    def trade(*, trade_id=None, symbol="AAPL", entry=30, shares=5, closed=False):
        opened = NOW - APPLE_EPOCH
        value = {"id": str(trade_id or uuid.uuid4()), "symbol": symbol, "side": "Long",
                 "entry": entry, "stop": entry - 1, "target": entry + 2,
                 "shares": shares, "openedAt": opened}
        if closed:
            value.update(closedAt=opened + 1, exitPrice=entry + 1)
        return value

    @staticmethod
    def decision(*, decision_id=None, at=1234.5, symbol="AAPL", action="Fixture"):
        return {"id": str(decision_id or uuid.uuid4()), "at": at, "symbol": symbol,
                "action": action, "reason": "Synthetic", "risk": "Synthetic",
                "facts": [], "evidence": [], "model": "fixture"}

    @staticmethod
    def control(records):
        latest = {}
        for record in records:
            if record["symbol"]:
                latest[record["symbol"]] = max(
                    latest.get(record["symbol"], FOUNDATION_DISTANT_PAST), record["at"])
        return {
            "sameDayActivated": any(r["action"] == "Same-day policy activated" for r in records),
            "settlementActivated": any(r["action"] == "T+1 cash policy activated" for r in records),
            "marketScanned": any(r["action"].startswith("Market scan") for r in records),
            "latestAttempt": latest,
        }

    def archive(self, records, *, archive_id=None):
        archive_id = archive_id or uuid.uuid4()
        data = self.json_bytes(records)
        (self.root / f"audit-{str(archive_id).upper()}.json").write_bytes(data)
        return {"id": str(archive_id), "count": len(records), "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "latestAt": max(record["at"] for record in records)}

    def write_v2(self, *, trades=None, groups=None, active=None):
        groups = groups if groups is not None else [[self.decision()]]
        active = active if active is not None else []
        archives = [self.archive(group) for group in groups]
        value = {"version": 2, "trades": trades if trades is not None else [self.trade()],
                 "pending": [], "decisions": active, "cursor": 0,
                 "audit": {"archives": archives,
                           "control": self.control([record for group in groups for record in group])}}
        self.source.write_bytes(self.json_bytes(value))
        return value, archives, groups

    def rewrite_archive(self, descriptor, value, *, keep_count=False, keep_latest=False):
        data = self.json_bytes(value)
        archive_id = uuid.UUID(descriptor["id"])
        (self.root / f"audit-{str(archive_id).upper()}.json").write_bytes(data)
        descriptor["bytes"] = len(data)
        descriptor["sha256"] = hashlib.sha256(data).hexdigest()
        if isinstance(value, list):
            if not keep_count:
                descriptor["count"] = len(value)
            if value and not keep_latest:
                descriptor["latestAt"] = max(record["at"] for record in value)

    def test_valid_v2_reads_only_active_trades_and_ignores_orphans(self):
        records = [[self.decision(action="Same-day policy activated"),
                    self.decision(at=1234.75, symbol="", action="T+1 cash policy activated"),
                    self.decision(at=1235, action="Market scan complete")]]
        value, archives, _ = self.write_v2(trades=[self.trade(symbol="AAPL")], groups=records,
                                           active=[self.decision(at=1236, symbol="MSFT")])
        archive_path = self.root / f"audit-{str(uuid.UUID(archives[0]['id'])).upper()}.json"
        archive_before = archive_path.read_bytes()
        orphan = self.root / "audit-orphan.json"
        orphan.write_bytes(b"not a referenced archive")

        try:
            intents = read_source(self.source)
        except Halt as exc:
            self.fail(f"valid native v2 generation was rejected: {exc}")

        self.assertEqual([(intent.symbol, intent.side, intent.quantity) for intent in intents],
                         [("AAPL", "BUY", 5)])
        self.assertEqual(archive_path.read_bytes(), archive_before)
        self.assertEqual(orphan.read_bytes(), b"not a referenced archive")
        self.assertEqual(value["trades"][0]["id"], intents[0].trade_id)

    def test_fifo_account_is_rejected_without_blocking(self):
        os.mkfifo(self.source)
        self.assert_reader_halts_in_child("account.*regular")

    def test_fifo_referenced_archive_is_rejected_without_blocking(self):
        _, archives, _ = self.write_v2()
        archive = self.root / f"audit-{str(uuid.UUID(archives[0]['id'])).upper()}.json"
        archive.unlink()
        os.mkfifo(archive)
        self.assert_reader_halts_in_child("audit archive.*regular")

    def test_successful_fdopen_transfers_descriptor_ownership_once(self):
        self.source.write_bytes(b"too large")
        real_fdopen, real_close = os.fdopen, os.close
        wrapped, raw_closes = [], []

        def tracked_fdopen(*args, **kwargs):
            source = real_fdopen(*args, **kwargs)
            wrapped.append(source)
            return source

        def tracked_close(descriptor):
            raw_closes.append(descriptor)
            return real_close(descriptor)

        with patch.object(relay_module.os, "fdopen", side_effect=tracked_fdopen), \
                patch.object(relay_module.os, "close", side_effect=tracked_close):
            with self.assertRaisesRegex(Halt, "size limit"):
                relay_module._read_bounded(self.source, 1, "account")

        self.assertEqual(len(wrapped), 1)
        self.assertTrue(wrapped[0].closed)
        self.assertEqual(raw_closes, [], "fdopen-owned descriptor was closed a second time")

    def test_fdopen_constructor_failure_closes_raw_descriptor_once(self):
        self.source.write_bytes(b"fixture")
        real_open, real_close = os.open, os.close
        opened, closed = [], []

        def tracked_open(*args, **kwargs):
            descriptor = real_open(*args, **kwargs)
            opened.append(descriptor)
            return descriptor

        def tracked_close(descriptor):
            closed.append(descriptor)
            return real_close(descriptor)

        with patch.object(relay_module.os, "open", side_effect=tracked_open), \
                patch.object(relay_module.os, "fdopen", side_effect=RuntimeError("fdopen failed")), \
                patch.object(relay_module.os, "close", side_effect=tracked_close):
            with self.assertRaisesRegex(RuntimeError, "fdopen failed"):
                relay_module._read_bounded(self.source, 32, "account")

        self.assertEqual(opened, closed)
        self.assertEqual(len(closed), 1)
        with self.assertRaises(OSError):
            os.fstat(closed[0])

    def test_audit_control_floors_dates_at_foundation_distant_past(self):
        self.assertEqual(FOUNDATION_DISTANT_PAST, -63_114_076_800.0)
        record = self.decision(at=-1e20)
        value, _, _ = self.write_v2(groups=[[record]])
        self.assertEqual(value["audit"]["control"]["latestAttempt"]["AAPL"],
                         FOUNDATION_DISTANT_PAST)
        self.assertEqual(len(read_source(self.source)), 1)

        value["audit"]["control"]["latestAttempt"]["AAPL"] = -1e20
        self.source.write_bytes(self.json_bytes(value))
        with self.assertRaisesRegex(Halt, "audit control"):
            read_source(self.source)

    def test_v1_pairing_types_and_unsupported_versions_fail_closed(self):
        trade = self.trade()
        self.source.write_bytes(self.json_bytes({"version": 1, "trades": [trade]}))
        self.assertEqual(read_source(self.source)[0].trade_id, str(uuid.UUID(trade["id"])))
        self.source.write_bytes(self.json_bytes({"version": 1, "trades": [trade], "audit": None}))
        self.assertEqual(len(read_source(self.source)), 1)

        invalid = [
            ([], "root.*object"),
            ({"version": True, "trades": []}, "version"),
            ({"version": 1.0, "trades": []}, "version"),
            ({"version": "2", "trades": []}, "version"),
            ({"version": 3, "trades": []}, "Unsupported.*version"),
            ({"version": 1, "trades": {}}, "trades.*array"),
            ({"version": 1, "trades": [], "audit": {}}, "version 1.*audit"),
            ({"version": 2, "trades": [], "decisions": []}, "version 2.*audit"),
        ]
        for value, reason in invalid:
            with self.subTest(value=value):
                self.source.write_bytes(self.json_bytes(value))
                with self.assertRaisesRegex(Halt, reason):
                    read_source(self.source)
        self.source.write_bytes(b'{"version":1,"version":2,"trades":[]}')
        with self.assertRaisesRegex(Halt, "Duplicate JSON key"):
            read_source(self.source)
        oversized_number = self.json_bytes({"version": 1, "trades": [trade]}).replace(
            b'"entry":30', b'"entry":1e9999')
        self.assertIn(b'"entry":1e9999', oversized_number)
        self.source.write_bytes(oversized_number)
        with self.assertRaisesRegex(Halt, "trade entry price"):
            read_source(self.source)

    def test_v2_rejects_missing_malformed_and_mismatched_archive_references(self):
        cases = ("descriptor", "missing", "symlink", "json", "bytes", "sha256", "count", "latestAt")
        for case in cases:
            with self.subTest(case=case):
                for child in self.root.iterdir():
                    child.unlink()
                value, archives, groups = self.write_v2()
                descriptor = archives[0]
                path = self.root / f"audit-{str(uuid.UUID(descriptor['id'])).upper()}.json"
                reason = "audit archive"
                if case == "descriptor":
                    del descriptor["id"]
                    reason = "archive ID"
                elif case == "missing":
                    path.unlink()
                    reason = "archive.*missing"
                elif case == "symlink":
                    data = path.read_bytes()
                    target = self.root / "target.json"
                    target.write_bytes(data)
                    path.unlink()
                    path.symlink_to(target)
                    reason = "archive.*regular"
                elif case == "json":
                    self.rewrite_archive(descriptor, {"not": "a decision array"})
                    reason = "archive.*JSON array"
                elif case == "bytes":
                    descriptor["bytes"] += 1
                    reason = "archive.*byte count"
                elif case == "sha256":
                    descriptor["sha256"] = "0" * 64
                    reason = "archive.*SHA-256"
                elif case == "count":
                    descriptor["count"] += 1
                    reason = "archive.*decision count"
                else:
                    descriptor["latestAt"] += 1
                    reason = "archive.*latestAt"
                self.source.write_bytes(self.json_bytes(value))
                with self.assertRaisesRegex(Halt, reason):
                    read_source(self.source)

    def test_v2_rejects_duplicate_archive_and_reused_decision_ids(self):
        shared_trade = uuid.uuid4()
        self.source.write_bytes(self.json_bytes(
            {"version": 1, "trades": [self.trade(trade_id=shared_trade), self.trade(trade_id=shared_trade)]}))
        with self.assertRaisesRegex(Halt, "Duplicate.*trade ID"):
            read_source(self.source)

        value, archives, _ = self.write_v2()
        value["audit"]["archives"].append(dict(archives[0]))
        self.source.write_bytes(self.json_bytes(value))
        with self.assertRaisesRegex(Halt, "Duplicate.*archive ID"):
            read_source(self.source)

        shared = uuid.uuid4()
        duplicate_cases = [
            ([[self.decision(decision_id=shared), self.decision(decision_id=shared, at=1235)]], []),
            ([[self.decision(decision_id=shared)], [self.decision(decision_id=shared, at=1235)]], []),
            ([[self.decision(decision_id=shared)]], [self.decision(decision_id=shared, at=1235)]),
            ([[self.decision()]], [self.decision(decision_id=shared),
                                   self.decision(decision_id=shared, at=1235)]),
        ]
        for groups, active in duplicate_cases:
            with self.subTest(groups=len(groups), active=bool(active)):
                for child in self.root.iterdir():
                    child.unlink()
                self.write_v2(groups=groups, active=active)
                with self.assertRaisesRegex(Halt, "Duplicate.*decision ID"):
                    read_source(self.source)

    def test_hash_valid_semantic_corruption_fails_closed(self):
        value, archives, groups = self.write_v2(
            groups=[[self.decision(action="Same-day policy activated")]])
        value["audit"]["control"]["sameDayActivated"] = False
        self.source.write_bytes(self.json_bytes(value))
        with self.assertRaisesRegex(Halt, "audit control"):
            read_source(self.source)

        value, archives, groups = self.write_v2()
        malformed = dict(groups[0][0])
        del malformed["action"]
        self.rewrite_archive(archives[0], [malformed])
        value["audit"]["archives"] = archives
        self.source.write_bytes(self.json_bytes(value))
        with self.assertRaisesRegex(Halt, "decision.*action"):
            read_source(self.source)

        value, archives, groups = self.write_v2()
        string_date = dict(groups[0][0], at="1234.5")
        self.rewrite_archive(archives[0], [string_date], keep_latest=True)
        self.source.write_bytes(self.json_bytes(value))
        with self.assertRaisesRegex(Halt, "decision time"):
            read_source(self.source)

        value, archives, groups = self.write_v2()
        data = self.json_bytes(groups[0]).replace(b'"at":1234.5', b'"at":1e9999')
        self.assertIn(b'"at":1e9999', data)
        archive_id = uuid.UUID(archives[0]["id"])
        (self.root / f"audit-{str(archive_id).upper()}.json").write_bytes(data)
        archives[0]["bytes"] = len(data)
        archives[0]["sha256"] = hashlib.sha256(data).hexdigest()
        self.source.write_bytes(self.json_bytes(value))
        with self.assertRaisesRegex(Halt, "decision time"):
            read_source(self.source)

    def test_captured_generation_and_content_rereads_ignore_stat_heuristics(self):
        old_trade = self.trade(symbol="AAPL")
        self.write_v2(trades=[old_trade])
        old_account = self.source.read_bytes()
        replacement = self.root / "replacement.json"
        new_trade = self.trade(symbol="MSFT")
        replacement.write_bytes(self.json_bytes({"version": 1, "trades": [new_trade]}))
        bounded_read = getattr(relay_module, "_read_bounded", None)
        self.assertIsNotNone(bounded_read, "reader needs one-descriptor bounded generation capture")
        replaced = False

        def replace_after_capture(path, limit, label):
            nonlocal replaced
            data = bounded_read(path, limit, label)
            if path == self.source and not replaced:
                replaced = True
                os.replace(replacement, self.source)
            return data

        with patch.object(relay_module, "_read_bounded", side_effect=replace_after_capture):
            self.assertEqual(read_source(self.source)[0].symbol, "AAPL")
        self.assertEqual(read_source(self.source)[0].symbol, "MSFT")
        self.assertNotEqual(self.source.read_bytes(), old_account)

        first = self.trade(symbol="AAPL")
        second = self.trade(symbol="MSFT", trade_id=first["id"])
        self.source.write_bytes(self.json_bytes({"version": 1, "trades": [first]}))
        before = self.source.stat()
        same_stat = self.root / "same-stat.json"
        same_stat.write_bytes(self.json_bytes({"version": 1, "trades": [second]}))
        self.assertEqual(same_stat.stat().st_size, before.st_size)
        os.utime(same_stat, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.assertEqual(read_source(self.source)[0].symbol, "AAPL")
        os.replace(same_stat, self.source)
        self.assertEqual((self.source.stat().st_size, self.source.stat().st_mtime_ns),
                         (before.st_size, before.st_mtime_ns))
        self.assertEqual(read_source(self.source)[0].symbol, "MSFT")
        self.assertEqual(read_source(self.source)[0].symbol, "MSFT", "unchanged files remain readable")

    def test_every_reader_bound_and_archive_reread_is_enforced(self):
        self.assertEqual((relay_module.MAX_SOURCE_BYTES, relay_module.MAX_ARCHIVE_BYTES,
                          relay_module.MAX_SNAPSHOT_BYTES, relay_module.MAX_AUDIT_ARCHIVES,
                          relay_module.MAX_ARCHIVED_DECISIONS, relay_module.MAX_ACTIVE_DECISIONS,
                          relay_module.MAX_TRADES),
                         (32_000_000, 32_000_000, 128_000_000, 1_000, 1_000_000, 50_000, 50_000))
        value, archives, groups = self.write_v2()
        archive_path = self.root / f"audit-{str(uuid.UUID(archives[0]['id'])).upper()}.json"
        with patch.object(relay_module, "MAX_SOURCE_BYTES", self.source.stat().st_size - 1):
            with self.assertRaisesRegex(Halt, "account.*size limit"):
                read_source(self.source)
        with patch.object(relay_module, "MAX_ARCHIVE_BYTES", archive_path.stat().st_size - 1):
            with self.assertRaisesRegex(Halt, "archive.*size limit"):
                read_source(self.source)
        with patch.object(relay_module, "MAX_SNAPSHOT_BYTES",
                          self.source.stat().st_size + archive_path.stat().st_size - 1):
            with self.assertRaisesRegex(Halt, "generation.*size limit"):
                read_source(self.source)
        with patch.object(relay_module, "MAX_AUDIT_ARCHIVES", 0):
            with self.assertRaisesRegex(Halt, "archive count"):
                read_source(self.source)
        with patch.object(relay_module, "MAX_ARCHIVED_DECISIONS", 0):
            with self.assertRaisesRegex(Halt, "archived decision count"):
                read_source(self.source)

        self.write_v2(active=[self.decision(), self.decision(at=1235)])
        with patch.object(relay_module, "MAX_ACTIVE_DECISIONS", 1):
            with self.assertRaisesRegex(Halt, "active decision count"):
                read_source(self.source)
        self.source.write_bytes(self.json_bytes({"version": 1, "trades": [self.trade(), self.trade()]}))
        with patch.object(relay_module, "MAX_TRADES", 1):
            with self.assertRaisesRegex(Halt, "trade count"):
                read_source(self.source)

        value, archives, _ = self.write_v2()
        self.assertEqual(len(read_source(self.source)), 1)
        archive_path = self.root / f"audit-{str(uuid.UUID(archives[0]['id'])).upper()}.json"
        data = bytearray(archive_path.read_bytes())
        data[-2] = ord(" ") if data[-2] != ord(" ") else ord("\t")
        archive_path.write_bytes(data)
        with self.assertRaisesRegex(Halt, "archive.*SHA-256"):
            read_source(self.source)


class RelayChecks(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.journal = Journal(self.root, now=NOW-10)
        self.broker = Broker()
        self.relay = Relay(self.broker, self.journal)
        await self.relay.connect()
        self.clock = patch("ibkr_paper_relay.time.time", return_value=NOW)
        self.clock.start()

    async def asyncTearDown(self):
        self.clock.stop()
        self.journal.close()
        self.temp.cleanup()

    def intent(self, **kwargs):
        return replace(Intent(str(uuid.uuid4()), "AAPL", "BUY", 100, Decimal("30"), NOW-1), **kwargs)

    async def test_complete_round_trip_records_real_receipts_and_never_duplicates(self):
        entry = self.intent()
        await self.relay.submit(entry)
        row = self.journal.rows()[0]
        self.assertEqual((row["state"], row["filled"], row["average"]), ("done", "66", "30.0"))
        self.assertLessEqual(self.broker.sent[0].totalQuantity * self.broker.sent[0].lmtPrice + 5, 2000)
        await self.relay.submit(entry)
        self.assertEqual(len(self.broker.sent), 1)
        exit_order = replace(entry, side="SELL", limit=Decimal("31"), at=NOW)
        await self.relay.submit(exit_order)
        self.assertEqual(self.broker.sent[-1].totalQuantity, 66)
        self.assertEqual(self.journal.owned(entry.trade_id), 0)
        self.assertEqual(len(self.journal.rows()), 2)
        self.journal.close()
        self.journal = Journal(self.root, now=NOW)
        self.relay = Relay(self.broker, self.journal)
        await self.relay.connect()
        await self.relay.submit(entry)
        self.assertEqual(len(self.broker.sent), 2, "Restart cannot resend a completed entry")

    async def test_live_mixed_or_changed_accounts_cannot_send_or_cancel(self):
        self.assertEqual(paper_account(["DUT123456"]), "DUT123456")
        for accounts in [["U1234567"], [ACCOUNT, "U7654321"], [], ["DUbad"], [ACCOUNT, "DU7654321"],
                         ["DUT123456", "U7654321"], ["DUTbad"], ["DUTT123456"]]:
            self.broker.accounts = accounts
            with self.assertRaises(Halt):
                await self.relay.submit(self.intent())
        self.broker.accounts = ["DUT123456"]
        await self.relay.connect()
        with self.assertRaisesRegex(Halt, "free-trial"):
            await self.relay.submit(self.intent())
        self.broker.accounts = ["DU7654321"]
        with self.assertRaises(Halt):
            await self.relay.connect()
        self.assertEqual(self.broker.sent, [])
        self.assertEqual(self.broker.cancelled, [])
        for port in [4001, 7496, 0, 65535]:
            with self.assertRaises(Halt):
                Relay(self.broker, self.journal, port)

    async def test_unknown_submission_blocks_new_orders_and_replay(self):
        entry = self.intent()
        self.broker.mode = "disconnect"
        with self.assertRaises(ConnectionError):
            await self.relay.submit(entry)
        self.assertEqual(self.journal.rows()[0]["state"], "prepared")
        with self.assertRaises(Halt):
            await self.relay.reconcile()
        with self.assertRaises(Halt):
            await self.relay.submit(self.intent(symbol="MSFT"))
        self.assertEqual(len(self.broker.sent), 1)

    async def test_partial_entry_only_sells_owned_quantity_and_partial_exit_halts(self):
        entry = self.intent()
        self.broker.qty_override = 5
        await self.relay.submit(entry)
        self.assertEqual(self.journal.owned(entry.trade_id), 5)
        self.broker.qty_override = 2
        with self.assertRaisesRegex(Halt, "partly filled"):
            await self.relay.submit(replace(entry, side="SELL", at=NOW))
        self.assertEqual(self.broker.sent[-1].totalQuantity, 5)
        self.assertEqual(self.journal.owned(entry.trade_id), 3)
        with self.assertRaisesRegex(Halt, "incomplete"):
            await self.relay.reconcile()

    async def test_cancel_is_exactly_owned_and_receipt_is_confirmed(self):
        self.broker.mode = "pending"
        entry = self.intent()
        original = self.relay.finish
        async def immediate(row, trade):
            await original(row, trade, wait=0)
        self.relay.finish = immediate
        await self.relay.submit(entry)
        self.assertEqual(self.broker.cancelled, [self.broker.sent[0].orderId])
        self.assertEqual(self.journal.rows()[0]["broker_status"], "Cancelled")
        self.assertEqual(self.journal.owned(entry.trade_id), 0)

    async def test_old_future_and_paused_events_do_not_submit(self):
        for at in [NOW-121, NOW+1, NOW-11]:
            await self.relay.submit(self.intent(at=at))
        self.relay.enabled = lambda: False
        await self.relay.submit(self.intent())
        self.assertEqual(self.broker.sent, [])

    async def test_caps_and_manual_holdings_are_not_overridden(self):
        for symbol in ["AAPL", "MSFT", "NVDA", "ORCL", "AMD", "GOOG"]:
            await self.relay.submit(self.intent(symbol=symbol))
        self.assertEqual(len(self.broker.sent), 5)
        self.assertLessEqual(self.journal.exposure(), 10000)
        row = next(r for r in self.journal.rows() if number(r["filled"]) > 0)
        self.broker.positions = [p._replace(position=Decimal(999)) if p.contract.conId == row["con_id"] else p
                                 for p in self.broker.positions]
        with self.assertRaisesRegex(Halt, "differs"):
            await self.relay.submit(self.intent(trade_id=row["trade_id"], symbol=row["symbol"], side="SELL"))

    async def test_missing_cash_stops_without_any_order(self):
        def no_values(req_id, group, tags):
            self.broker.future.set_result(None)
        self.broker.client.reqAccountSummary = no_values
        with self.assertRaisesRegex(Halt, "Fresh USD"):
            await self.relay.submit(self.intent())
        self.assertEqual(self.broker.sent, [])

    async def test_gateway_ledger_prefix_and_absent_settlement(self):
        def snapshot(req_id, group, tags):
            for tag in ["SettledCash", "AvailableFunds", "$LEDGER-CashBalance"]:
                self.broker.accountSummaryEvent.emit(NS(account=ACCOUNT, tag=tag, value="9000", currency="USD"))
            self.broker.future.set_result(None)
        self.broker.client.reqAccountSummary = snapshot
        self.assertEqual(await self.relay.fresh_cash(), Decimal("9000"))
        def no_settlement(req_id, group, tags):
            for tag in ["AvailableFunds", "$LEDGER-CashBalance"]:
                self.broker.accountSummaryEvent.emit(NS(account=ACCOUNT, tag=tag, value="9000", currency="USD"))
            self.broker.future.set_result(None)
        self.broker.client.reqAccountSummary = no_settlement
        with self.assertRaisesRegex(Halt, "Fresh USD"):
            await self.relay.submit(self.intent())
        self.assertEqual(self.broker.sent, [])

    async def test_recovery_uses_broker_receipt_without_resubmission(self):
        entry = self.intent()
        await self.relay.submit(entry)
        with self.journal.db:
            self.journal.db.execute("UPDATE orders SET state='prepared', filled='0', average='0'")
        await self.relay.reconcile()
        self.assertEqual(len(self.broker.sent), 1)
        self.assertEqual(self.journal.rows()[0]["state"], "done")
        self.assertEqual(self.journal.owned(entry.trade_id), 66)

    async def test_receipt_mismatch_prevents_even_cancellation(self):
        entry = self.intent()
        await self.relay.submit(entry)
        row, trade = self.journal.rows()[0], self.broker.completed[0]
        trade.order.account = "U1234567"
        with self.assertRaisesRegex(Halt, "does not match"):
            await self.relay.finish(row, trade, wait=0)
        self.assertEqual(self.broker.cancelled, [])

    async def test_recovery_from_actual_sdk_completed_order_shape(self):
        entry = self.intent()
        await self.relay.submit(entry)
        original = self.broker.completed[0]
        ib = IB()
        completed = ib.wrapper.startReq("completedOrders")
        ib.wrapper.completedOrder(original.contract, Order(**dict(asdict(original.order), clientId=0, orderId=0)),
                                  OrderState(status="Filled"))
        ib.wrapper.completedOrdersEnd()
        self.broker.completed = await completed
        self.assertEqual(self.broker.completed[0].orderStatus.filled, 0)
        async def executions():
            return original.fills
        self.broker.reqExecutionsAsync = executions
        with self.journal.db:
            self.journal.db.execute("UPDATE orders SET state='prepared', filled='0', average='0'")
        await self.relay.reconcile()
        self.assertEqual(self.journal.rows()[0]["filled"], "66")
        self.assertEqual(self.journal.rows()[0]["average"], "30.0")
        self.assertEqual(len(self.broker.sent), 1)
        self.assertEqual(self.broker.cancelled, [])
        with self.journal.db:
            self.journal.db.execute("UPDATE orders SET state='prepared', filled='0', average='0'")
        original.fills.clear()
        with self.assertRaises(Halt):
            await self.relay.reconcile()
        self.assertEqual(len(self.broker.sent), 1)
        self.assertEqual(self.broker.cancelled, [])

    async def test_sdk_serializes_paper_account_limit_and_reference_without_network(self):
        entry = self.intent()
        await self.relay.submit(entry)
        order, trade = self.broker.sent[0], self.broker.completed[0]
        client = IB().client
        client._serverVersion = 178
        sent = []
        client.send = lambda *fields, **kwargs: sent.extend(fields)
        client.placeOrder(order.orderId, trade.contract, order)
        self.assertIn(ACCOUNT, sent)
        self.assertIn(entry.ref, sent)
        self.assertIn("IOC", sent)
        self.assertIn("LMT", sent)
        self.assertNotIn("U1234567", sent)

    async def test_source_validation_and_exclusive_journal(self):
        with self.assertRaises(Halt):
            Journal(self.root)
        marker = self.root / "STOP"
        marker.touch()
        with self.assertRaises(Halt):
            await main_async(NS(state=self.root, command="run", port=4002, source=self.root / "source.json"))
        self.assertTrue(marker.exists(), "A second runner must not clear the first runner's stop request")
        path = self.root / "source.json"
        record = {"id": str(uuid.uuid4()), "symbol": "AAPL", "side": "Long", "entry": 30,
                  "shares": 5, "openedAt": NOW-APPLE_EPOCH}
        path.write_text(json.dumps({"version": 1, "trades": [record]}))
        self.assertEqual(read_source(path)[0].quantity, 5)
        for patch_values in [{"shares": -1}, {"entry": float("nan")}, {"side": "Short"},
                             {"closedAt": NOW-APPLE_EPOCH}, {"symbol": "AAPL;bad"}]:
            path.write_text(json.dumps({"version": 1, "trades": [dict(record, **patch_values)]}))
            with self.assertRaises(Halt):
                read_source(path)
        for value in [float("nan"), float("inf"), True, "oops"]:
            with self.assertRaises(Halt):
                number(value)


if __name__ == "__main__":
    unittest.main()
