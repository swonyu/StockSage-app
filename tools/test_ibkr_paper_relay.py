"""Offline broker-boundary checks. No credentials, sockets or real accounts."""
import asyncio
from dataclasses import asdict, replace
from datetime import datetime, timezone
from decimal import Decimal
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch
import uuid

from eventkit import Event
from ib_async import IB, CommissionReport, Execution, Fill, Order, OrderState, OrderStatus, Position, Stock, Trade
from ibkr_paper_relay import (APPLE_EPOCH, CLIENT_ID, Halt, Intent, Journal, Relay,
                             main_async, number, paper_account, read_source)

NOW = datetime(2026, 9, 8, 18, 0, tzinfo=timezone.utc).timestamp()
ACCOUNT = "DU1234567"


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
