import json
import tempfile
import unittest

from app import make_handler
from domain import Conflict, InvalidData, NextDatabase
from simulations import apply_action, create_account


CONFIG = {"initialCash": "10000", "codes": ["159941", "563020"],
          "lotSizes": {"159941": 100, "563020": 100},
          "feesPerFill": {"159941": "0.10", "563020": "0.10"},
          "weights": {"159941": "0.6", "563020": "0.3"}}


class SimulationAccountTests(unittest.TestCase):
    def test_account_actions_are_virtual_revisionable_and_audited(self):
        account = create_account("G", CONFIG, "2026-10-20T08:00:00+00:00")
        self.assertEqual(account["kind"], "live_paper_account")
        self.assertFalse(account["realOrder"])
        paused = apply_action(account, {"action": "pause"}, "2026-10-20T08:01:00+00:00")
        self.assertEqual(paused["status"], "paused")
        funded = apply_action(paused, {"action": "fund", "amount": "250"}, "2026-10-20T08:02:00+00:00")
        self.assertEqual(funded["cash"], "10250")
        withdrawn = apply_action(funded, {"action": "withdraw", "amount": "100"}, "2026-10-20T08:03:00+00:00")
        self.assertEqual(withdrawn["cash"], "10150")
        resumed = apply_action(withdrawn, {"action": "resume"}, "2026-10-20T08:04:00+00:00")
        self.assertEqual(resumed["status"], "running")
        self.assertEqual(len(resumed["audit"]), 5)

    def test_invalid_lot_withdrawal_and_unconfirmed_reset_are_rejected(self):
        with self.assertRaises(InvalidData):
            create_account("G", {**CONFIG, "lotSizes": {"159941": 100}}, "now")
        account = create_account("G", CONFIG, "now")
        with self.assertRaises(InvalidData): apply_action(account, {"action": "withdraw", "amount": "10001"}, "later")
        with self.assertRaises(InvalidData): apply_action(account, {"action": "reset"}, "later")
        with self.assertRaises(InvalidData): apply_action(account, {"action": "reset", "userConfirmed": True, "unexpected": 1}, "later")

    def test_database_compare_and_swap_preserves_revision_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = NextDatabase(tmp + "/next.sqlite3")
            account = create_account("G", CONFIG, "now")
            revision = db.put_twin_account("G", 0, account)
            self.assertEqual(revision, 1)
            changed = apply_action(account, {"action": "pause"}, "later")
            self.assertEqual(db.put_twin_account("G", 1, changed), 2)
            with self.assertRaises(Conflict): db.put_twin_account("G", 1, account)
            self.assertEqual(len(db.twin_account_history("G")), 2)
            self.assertIsNone(db.get_real("main")["bookJSON"])

    def test_ai_decisions_are_g_only_and_idempotent_per_session(self):
        from simulations import append_ai_decision
        account = create_account("G", CONFIG, "now")
        decision = {"asOf": "2026-10-20", "provider": "DeepSeek", "realOrder": False,
                    "targetWeights": {"159941": "0.6", "563020": "0.3"}, "createdAt": "now"}
        one, changed = append_ai_decision(account, decision)
        self.assertTrue(changed)
        two, changed = append_ai_decision(one, decision)
        self.assertFalse(changed)
        self.assertEqual(len(two["decisions"]), 1)
        with self.assertRaises(InvalidData): append_ai_decision(create_account("A", CONFIG, "now"), decision)

    def test_g_queues_after_close_and_executes_next_archived_open(self):
        from simulations import close_g_session, execute_open_orders
        account = create_account("G", CONFIG, "2026-10-19T16:00:00+08:00")
        bars1 = {"159941": {"date": "2026-10-19", "open": "1.0", "close": "1.0"},
                 "563020": {"date": "2026-10-19", "open": "1.0", "close": "1.0"}}
        plan1 = {"asOf": "2026-10-19", "provider": "DeepSeek", "model": "deepseek-chat",
                 "targetWeights": {"159941": "0.6", "563020": "0.3"}, "realOrder": False,
                 "summary": "按目标配置模拟", "risks": ["行情会变化"], "invalidators": ["数据失效"], "createdAt": "2026-10-19T16:00:00+08:00"}
        one, changed = close_g_session(account, bars1, plan1, plan1["createdAt"])
        self.assertTrue(changed)
        self.assertEqual([order["status"] for order in one["orders"]], ["pending", "pending"])
        self.assertEqual(one["curve"][-1]["equity"], "10000.0")
        bars2 = {"159941": {"date": "2026-10-20", "open": "1.1", "close": "1.2"},
                 "563020": {"date": "2026-10-20", "open": "0.9", "close": "0.95"}}
        opened = execute_open_orders(one, bars2, "2026-10-20")
        self.assertTrue(all(order["executionModel"].startswith("archived daily open proxy") for order in opened["orders"]))
        self.assertEqual(len(opened["fills"]), 2)
        self.assertEqual({fill["fee"] for fill in opened["fills"]}, {"0.10"})
        self.assertFalse(any(fill.get("realOrder", True) for fill in opened["fills"]))

    def test_g_records_missing_ai_without_inventing_a_plan_or_losing_session_mark(self):
        from simulations import close_g_session
        account = create_account("G", CONFIG, "2026-10-19T16:00:00+08:00")
        bars = {"159941": {"date": "2026-10-19", "open": "1.0", "close": "1.0"},
                "563020": {"date": "2026-10-19", "open": "1.0", "close": "1.0"}}
        updated, changed = close_g_session(account, bars, None, "2026-10-19T16:00:00+08:00", "missing key")
        self.assertTrue(changed)
        self.assertEqual(updated["lastProcessedSession"], "2026-10-19")
        self.assertEqual(updated["decisions"], [])
        self.assertEqual(updated["orders"], [])
        self.assertEqual(updated["aiRuns"][-1]["status"], "unavailable")

    def test_g_daily_open_insufficient_cash_records_partial_units_and_remainder(self):
        from simulations import close_g_session, execute_open_orders
        config = {"initialCash": "10000", "codes": ["159941"], "lotSizes": {"159941": 100},
                  "feesPerFill": {"159941": "0.10"}, "weights": {"159941": "1"}}
        account = create_account("G", config, "2026-10-19T16:00:00+08:00")
        day1 = {"159941": {"date": "2026-10-19", "open": "1", "close": "1"}}
        plan = {"asOf": "2026-10-19", "provider": "DeepSeek", "model": "mock",
                "targetWeights": {"159941": "1"}, "realOrder": False, "summary": "配置",
                "risks": ["波动"], "invalidators": ["数据失效"], "createdAt": "2026-10-19T16:00:00+08:00"}
        queued, _ = close_g_session(account, day1, plan, plan["createdAt"])
        day2 = {"159941": {"date": "2026-10-20", "open": "2", "close": "2"}}
        result = execute_open_orders(queued, day2, "2026-10-20")
        order = result["orders"][0]
        self.assertEqual(order["status"], "pending_partial")
        self.assertEqual(order["executedUnits"], 4900)
        self.assertEqual(order["remainingUnits"], 5100)
        self.assertEqual(result["positions"]["159941"], 4900)


class SimulationHTTPTests(unittest.TestCase):
    def test_http_requires_explicit_confirmation_and_is_revisioned(self):
        import threading
        from http.server import ThreadingHTTPServer
        from urllib.request import Request, urlopen
        with tempfile.TemporaryDirectory() as tmp:
            db = NextDatabase(tmp + "/next.sqlite3")
            server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(db))
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                base = f"http://127.0.0.1:{server.server_port}/v1/simulations/G"
                def post(body):
                    request = Request(base, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
                    with urlopen(request) as response: return json.loads(response.read())
                with self.assertRaises(Exception): post({"action": "start", "expectedRevision": 0, "config": CONFIG})
                started = post({"action": "start", "expectedRevision": 0, "userConfirmed": True, "config": CONFIG})
                self.assertEqual(started["revision"], 1)
                paused = post({"action": "pause", "expectedRevision": 1, "userConfirmed": True})
                self.assertEqual(paused["account"]["status"], "paused")
                reset = post({"action": "reset", "expectedRevision": 2, "userConfirmed": True})
                self.assertEqual(reset["account"]["status"], "reset")
                self.assertEqual(len(db.twin_account_history("G")), 3)
                restarted = post({"action": "start", "expectedRevision": 3, "userConfirmed": True, "config": CONFIG})
                self.assertEqual(restarted["revision"], 4)
                self.assertEqual(restarted["account"]["status"], "running")
                self.assertEqual(len(db.twin_account_history("G")), 4)
                self.assertIsNone(db.get_real("main")["bookJSON"])
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=2)


if __name__ == "__main__": unittest.main()
