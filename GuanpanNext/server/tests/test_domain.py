import copy
import http.client
import json
import tempfile
import threading
import unittest
from unittest.mock import patch
from decimal import Decimal
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from pathlib import Path
from app import make_handler
from ai import analyze_user_context, AIProviderError
from domain import Conflict, InvalidData, NextDatabase, convert_legacy_web_book, validate_book_json
from market import parse_quotes, symbol_for
from datetime import datetime, timezone


def book():
    return {"schemaVersion": 1, "id": "00000000-0000-4000-8000-000000000001", "cash": 1000,
            "positions": [{"code": "159941", "name": "纳指ETF", "units": 100, "bookCost": 123.45}],
            "fills": [], "history": []}


class DomainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = NextDatabase(Path(self.temp.name) / "new.sqlite3")

    def tearDown(self): self.temp.cleanup()

    def test_legacy_conversion_is_preview_only_and_uses_swift_reference_dates(self):
        legacy = {"cash": 500, "db": {"hold": [{"code": "159941", "name": "纳指ETF", "num": 100, "cost": 1.25}],
                  "trades": [{"code": "159941", "side": "buy", "date": "2026-10-19", "num": 100, "price": 1.25}]},
                  "fund": {"hold": [{"code": "000001"}]}}
        converted = convert_legacy_web_book(legacy)
        self.assertEqual(converted["book"]["positions"][0]["bookCost"], Decimal("125.00"))
        self.assertEqual(converted["summary"]["ignoredOTCFunds"], 1)
        self.assertEqual(converted["book"]["dividendEvents"], [])
        legacy["etfDividendEvents"] = [{"code": "563020", "date": "2026-06-10", "amountPerShare": 0.012},
                                        {"code": "159545", "date": "2026-05-15", "amountPerShare": 0.014, "isEstimated": True}]
        converted_with_dividends = convert_legacy_web_book(legacy)
        self.assertEqual(converted_with_dividends["summary"]["dividendEvents"], 2)
        self.assertEqual(converted_with_dividends["book"]["dividendEvents"][1]["isEstimated"], True)
        self.assertGreater(converted["book"]["fills"][0]["date"], 700_000_000)
        self.assertEqual(self.db.get_real("main")["revision"], 0)

    def test_legacy_inbox_is_separate_revisioned_and_never_mutates_real_ledger(self):
        legacy = {"cash": 300, "db": {"hold": [{"code": "159941", "num": 20, "cost": 1.1}]}}
        self.assertEqual(self.db.put_legacy_inbox("main", 0, legacy), 1)
        self.assertEqual(self.db.get_legacy_inbox("main"), {"revision": 1, "data": legacy})
        with self.assertRaises(Conflict): self.db.put_legacy_inbox("main", 0, legacy)
        self.assertEqual(self.db.get_real("main"), {"revision": 0, "bookJSON": None})

    def test_legacy_fractional_units_stop_import(self):
        with self.assertRaises(InvalidData):
            convert_legacy_web_book({"db": {"hold": [{"code": "159941", "num": 1.5, "cost": 1}]}})

    def test_no_legacy_fields_accepted(self):
        for field in ("holdings", "fundDCAPlans", "fundTransactions"):
            data = book(); data[field] = []
            with self.assertRaises(InvalidData): validate_book_json(json.dumps(data))
        data = book(); data["id"] = "local-book"
        with self.assertRaises(InvalidData): validate_book_json(json.dumps(data))

    def test_book_wire_ids_match_swift_uuid_decoders(self):
        for container, item in (
            ("fills", {"id": "bad-id", "date": 810000000, "code": "159941", "side": "buy", "units": 100, "price": 1.2, "fee": 0.1, "realized": 0}),
            ("history", {"id": "bad-id", "date": 810000000, "total": 120, "externalFlow": 0}),
            ("cashMovements", {"id": "bad-id", "date": 810000000, "amount": 10, "reason": "deposit"}),
        ):
            data = book(); data[container] = [item]
            with self.assertRaises(InvalidData): validate_book_json(json.dumps(data))

    def test_decimal_text_preserved_exactly(self):
        text = json.dumps(book()).replace('123.45', '123.4567890123456789012345')
        self.assertEqual(self.db.put_real("main", 0, text), 1)
        self.assertEqual(self.db.get_real("main")["bookJSON"], text)

    def test_duplicate_or_invalid_positions_rejected(self):
        for value in [-1, True, 0.5, "100"]:
            data = book(); data["positions"][0]["units"] = value
            with self.assertRaises(InvalidData): validate_book_json(json.dumps(data))
        data = book(); data["positions"].append(copy.deepcopy(data["positions"][0]))
        with self.assertRaises(InvalidData): validate_book_json(json.dumps(data))

    def test_invalid_money_does_not_write(self):
        for value in [-1, True, "100", float("nan"), float("inf")]:
            data = book(); data["cash"] = value
            with self.assertRaises(InvalidData): self.db.put_real("main", 0, json.dumps(data))
            self.assertEqual(self.db.get_real("main")["revision"], 0)

    def test_conflict_never_overwrites(self):
        first = json.dumps(book()); self.db.put_real("main", 0, first)
        modified = book(); modified["cash"] = 0
        with self.assertRaises(Conflict): self.db.put_real("main", 0, json.dumps(modified))
        self.assertEqual(self.db.get_real("main")["bookJSON"], first)

    def test_research_and_experiment_cannot_mutate_real_ledger(self):
        text = json.dumps(book()); self.db.put_real("main", 0, text)
        self.db.put_research("test", {"cash": 9999999})
        self.db.put_experiment("main", {"cash": 9999999})
        self.assertEqual(self.db.get_real("main"), {"revision": 1, "bookJSON": text})

    def test_income_event_is_validated_as_separate_cash_receipt(self):
        data = book()
        data["incomeEvents"] = [{"id": "00000000-0000-4000-8000-000000000002", "kind": "etfDistribution", "code": "563020", "name": "红利ETF",
            "exDate": 810000000, "payDate": 810000000, "units": 100, "perUnit": 0.012,
            "grossAmount": 1.2, "tax": 0.1, "status": "expected", "note": "公告计划"}]
        validate_book_json(json.dumps(data))
        data["incomeEvents"][0]["tax"] = 1.3
        with self.assertRaises(InvalidData): validate_book_json(json.dumps(data))

    def test_dividend_wire_dates_require_canonical_calendar_format(self):
        data = book()
        data["dividendEvents"] = [{"code": "563020", "date": "2026-W24-3", "amountPerShare": 0.012,
            "recordDate": "2026-06-09", "payDate": "2026-06-15", "isEstimated": False}]
        with self.assertRaises(InvalidData): validate_book_json(json.dumps(data))

    def test_native_cash_movement_schema_is_accepted_and_validated(self):
        data = book(); data["cashMovements"] = [{"id": "00000000-0000-4000-8000-000000000003", "date": 1792375200, "amount": -25, "reason": "确认转出"}]
        self.assertEqual(validate_book_json(json.dumps(data))["cashMovements"][0]["amount"], -25)
        data["cashMovements"][0]["reason"] = " "
        with self.assertRaises(InvalidData): validate_book_json(json.dumps(data))

    def test_concurrent_write_has_only_one_winner(self):
        def put(_):
            try: self.db.put_real("main", 0, json.dumps(book())); return True
            except Conflict: return False
        with ThreadPoolExecutor(max_workers=4) as pool:
            self.assertEqual(sum(pool.map(put, range(4))), 1)

    def test_all_previous_revisions_retained(self):
        self.db.put_real("main", 0, json.dumps(book()))
        data = book(); data["cash"] = 500
        self.db.put_real("main", 1, json.dumps(data))
        with self.db.connect() as db:
            rows = db.execute("SELECT revision FROM real_book_history ORDER BY revision").fetchall()
        self.assertEqual(rows, [(1,), (2,)])

    def test_path_or_sql_id_rejected(self):
        for value in ("../old-data", "a'; DROP TABLE real_books;--", ""):
            with self.assertRaises(InvalidData): self.db.get_real(value)


class MarketAdapterTests(unittest.TestCase):
    def test_quote_parser_validates_symbol_time_decimal_and_raw_iopv(self):
        fields = [""] * 90
        fields[1] = "纳指ETF"; fields[3] = "1.234"; fields[4] = "1.200"
        fields[30] = "20261019143000"; fields[61] = "ETF"; fields[78] = "1.230"
        body = 'v_sz159941="' + "~".join(fields) + '";'
        received = datetime(2026, 10, 19, 6, 30, 30, tzinfo=timezone.utc)
        quote, = parse_quotes(body, ["159941"], received)
        self.assertEqual(quote["price"], "1.234")
        self.assertEqual(quote["iopv"], "1.230")
        fields[61] = "Stock"
        non_etf = 'v_sz159941="' + "~".join(fields) + '";'
        self.assertIsNone(parse_quotes(non_etf, ["159941"], received)[0]["iopv"])
        self.assertEqual(symbol_for("159941"), "sz159941")
        self.assertEqual(parse_quotes(body, ["510300"], received), [])
        self.assertEqual(parse_quotes(body, ["159941"], datetime(2026, 10, 19, 6, 28, tzinfo=timezone.utc)), [])


class DividendDataTests(unittest.TestCase):
    def test_source_outage_is_not_returned_as_empty_history(self):
        from market import fetch_dividend_events
        def fail(*_args): raise OSError("offline")
        with self.assertRaises(OSError): fetch_dividend_events("563020", daily_fetcher=fail, stock_fetcher=fail, fund_fetcher=fail)
        with self.assertRaises(OSError): fetch_dividend_events("563020", daily_fetcher=fail, stock_fetcher=lambda _code: [], fund_fetcher=fail)

    def test_adjustment_factor_dividend_is_marked_as_estimate(self):
        from market import infer_adjustment_dividends, parse_eastmoney_dividends, parse_eastmoney_fund_dividends
        adjusted, raw = [], []
        for index in range(61):
            day = (datetime(2026, 1, 1) + __import__("datetime").timedelta(days=index)).date().isoformat()
            factor = Decimal("1.10") if index < 60 else Decimal("1.08")
            adjusted.append({"date": day, "close": "1.00"})
            raw.append({"date": day, "close": str(factor)})
        events = infer_adjustment_dividends("563020", adjusted, raw)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["amountPerShare"], "0.02")
        self.assertTrue(events[0]["isEstimated"])
        payload = {"result": {"data": [
            {"ASSIGN_PROGRESS": "实施分配", "EX_DIVIDEND_DATE": "2026-06-10 00:00:00", "PRETAX_BONUS_RMB": "0.12"},
            {"ASSIGN_PROGRESS": "股东大会决议通过", "EX_DIVIDEND_DATE": "2026-08-10", "PRETAX_BONUS_RMB": "1.00"}]}}
        confirmed = parse_eastmoney_dividends(json.dumps(payload), "600000")
        self.assertEqual(len(confirmed), 1)
        self.assertEqual(confirmed[0]["amountPerShare"], "0.012")
        self.assertFalse(confirmed[0]["isEstimated"])
        fund_html = """<html><body><h2>分红送配详情</h2><table><tr><th>年份</th><th>权益登记日</th><th>除息日</th><th>每10份分红</th><th>分红发放日</th></tr>
        <tr><td>2026年</td><td>2026-09-10</td><td>2026-09-11</td><td>每10份派现金0.1200元</td><td>2026-09-16</td></tr></table></body></html>"""
        fund_events = parse_eastmoney_fund_dividends(fund_html, "563020")
        self.assertEqual(fund_events, [{"code": "563020", "date": "2026-09-11", "amountPerShare": "0.012",
            "isEstimated": False, "recordDate": "2026-09-10", "payDate": "2026-09-16"}])

    def test_official_fund_history_supersedes_adjustment_estimate(self):
        from market import fetch_dividend_events
        adjusted, raw = [], []
        for index in range(61):
            day = (datetime(2026, 1, 1) + __import__("datetime").timedelta(days=index)).date().isoformat()
            factor = Decimal("1.10") if index < 60 else Decimal("1.08")
            adjusted.append({"date": day, "close": "1.00"})
            raw.append({"date": day, "close": str(factor)})
        result = fetch_dividend_events("563020", daily_fetcher=lambda _code, mode: adjusted if mode == "qfq" else raw,
            fund_fetcher=lambda code: [{"code": code, "date": "2026-03-02", "amountPerShare": "0.012", "isEstimated": False,
                "recordDate": "2026-03-01", "payDate": "2026-03-05"}])
        self.assertEqual(len(result), 1)
        self.assertFalse(result[0]["isEstimated"])
        self.assertEqual(result[0]["payDate"], "2026-03-05")

    def test_etf_distribution_is_never_falsely_confirmed_by_stock_feed(self):
        from market import fetch_dividend_events
        adjusted, raw = [], []
        for index in range(61):
            day = (datetime(2026, 1, 1) + __import__("datetime").timedelta(days=index)).date().isoformat()
            factor = Decimal("1.10") if index < 60 else Decimal("1.08")
            adjusted.append({"date": day, "close": "1.00"})
            raw.append({"date": day, "close": str(factor)})
        stock_feed_called = []
        result = fetch_dividend_events("563020", daily_fetcher=lambda _code, mode: adjusted if mode == "qfq" else raw,
            stock_fetcher=lambda code: stock_feed_called.append(code) or [{"code": code, "date": "2026-03-02", "amountPerShare": "0.12", "isEstimated": False}],
            fund_fetcher=lambda _code: (_ for _ in ()).throw(OSError("offline")))
        self.assertEqual(stock_feed_called, [])
        self.assertEqual(len(result), 1)
        self.assertTrue(result[0]["isEstimated"])

class DailyParserTests(unittest.TestCase):
    def test_source_ohlcv_validation_and_date_dedup(self):
        from market import parse_daily_bars
        payload = {"data": {"sz159941": {"qfqday": [
            ["2026-10-16", "1.20", "1.30", "1.40", "1.10", "123"],
            ["2026-10-16", "1.21", "1.31", "1.41", "1.11", "124"],
            ["2026-10-17", "1.30", "1.20", "1.10", "1.00", "100"]]}}}
        rows = parse_daily_bars(json.dumps(payload), "159941")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["close"], "1.31")


class IndependentWorkersTests(unittest.TestCase):
    def test_minute_archive_deduplicates_and_never_prunes(self):
        from workers import parse_minute
        # Use a completed business day to avoid dependence on test clock.
        payload = {"data": {"sz159941": {"data": {"date": "20261016", "data": [
            "0930 1.234 100", "0931 1.236 120", "0931 1.237 125"]}}}}
        rows = parse_minute(json.dumps(payload), "159941")
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[-1]["price"], "1.237")
        with tempfile.TemporaryDirectory() as folder:
            db = NextDatabase(Path(folder) / "archive.sqlite3")
            db.put_minute("159941", rows, "2026-10-16T07:00:00Z")
            self.assertEqual(len(db.get_minute("159941", "2026-10-16")["rows"]), 2)

    def test_minute_iopv_is_optional_but_verified_value_survives_later_pull(self):
        with tempfile.TemporaryDirectory() as folder:
            db = NextDatabase(Path(folder) / "iopv.sqlite3")
            stamped = "2026-10-16T09:30:00+08:00"
            db.put_minute("159941", [{"timestamp": stamped, "price": "1.2", "volume": "100", "iopv": "1.19"}], "one")
            db.put_minute("159941", [{"timestamp": stamped, "price": "1.2", "volume": "100", "iopv": None}], "two")
            self.assertEqual(db.get_minute("159941", "2026-10-16")["rows"][0]["iopv"], "1.19")

    def test_iopv_is_attached_only_for_near_time_etf_quote(self):
        from workers import attach_quote_iopv
        rows = [{"timestamp": "2026-10-16T09:30:00+08:00", "price": "1.2", "volume": "10", "iopv": None}]
        etf = {"time": "2026-10-16T09:33:00+08:00", "providerInstrumentType": "ETF", "iopv": "1.19"}
        self.assertEqual(attach_quote_iopv(rows, etf)[0]["iopv"], "1.19")
        rows[0]["iopv"] = None
        late = {"time": "2026-10-16T09:40:01+08:00", "providerInstrumentType": "ETF", "iopv": "1.19"}
        self.assertIsNone(attach_quote_iopv(rows, late)[0]["iopv"])

    def test_deepseek_profiles_and_missing_key_do_not_fake_ai(self):
        from ai import PROFILES, generate_research, provider_status, verify_provider, AIProviderError
        self.assertEqual(PROFILES["flash"]["model"], "deepseek-flash")
        self.assertEqual(PROFILES["pro"]["model"], "deepseek-v4-pro")
        factors = {"code": "159941", "asOf": "2026-10-16", "source": "source",
            "close": "1.2", "ma20": "1.1", "ma250": "1.0", "momentum20": "0.1", "drawdown20": "-0.02"}
        self.assertIsNone(generate_research(factors, api_key=""))
        with patch.dict("os.environ", {"DEEPSEEK_API_KEY": ""}, clear=False):
            self.assertEqual(provider_status()["state"], "missing_key")
            with self.assertRaises(AIProviderError): verify_provider(opener=lambda *_args, **_kwargs: self.fail("must not make a request without a key"))

    def test_deepseek_probe_uses_key_only_in_auth_and_returns_safe_result(self):
        from ai import verify_provider
        captured = {}
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_args): return False
            def read(self, _limit): return json.dumps({"choices": [{"message": {"content": "OK"}}]}).encode()
        def opener(request, timeout):
            captured["request"] = request; captured["timeout"] = timeout
            return Response()
        secret = "never-return-this-secret"
        with patch.dict("os.environ", {"DEEPSEEK_API_KEY": secret, "GUANPAN_AI_PROFILE": "flash"}):
            result = verify_provider(opener=opener)
        self.assertEqual(captured["request"].get_header("Authorization"), "Bearer " + secret)
        self.assertEqual(captured["timeout"], 20)
        self.assertEqual(result["state"], "verified")
        self.assertNotIn(secret, json.dumps(result))

    def test_research_is_replaced_for_new_completed_day(self):
        with tempfile.TemporaryDirectory() as folder:
            db = NextDatabase(Path(folder) / "research.sqlite3")
            db.put_research("factors-159941", {"asOf": "2026-10-16", "state": "观察"})
            db.put_research("factors-159941", {"asOf": "2026-10-17", "state": "谨慎"})
            self.assertEqual(db.get_research("factors-159941")["asOf"], "2026-10-17")

    def test_minute_archive_rejects_untrusted_rows_and_invalid_dates(self):
        with tempfile.TemporaryDirectory() as folder:
            db = NextDatabase(Path(folder) / "minute.sqlite3")
            with self.assertRaises(InvalidData):
                db.put_minute("159941", [{"timestamp": "bad", "price": "1.2", "volume": None}], "now")
            with self.assertRaises(InvalidData):
                db.get_minute("159941", "2026-13-40")

    def test_dividend_archive_is_persistent_and_separate_from_real_ledger(self):
        with tempfile.TemporaryDirectory() as folder:
            db = NextDatabase(Path(folder) / "dividends.sqlite3")
            events = [{"code": "563020", "date": "2026-06-10", "amountPerShare": "0.012", "isEstimated": False,
                "recordDate": "2026-06-09", "payDate": "2026-06-15"}]
            db.put_dividend_events("563020", events, "2026-10-19T08:00:00+00:00")
            self.assertEqual(db.get_dividend_events("563020")["events"], events)
            db.put_dividend_events("563020", [{"code": "563020", "date": "2026-06-10", "amountPerShare": "0.011", "isEstimated": True}], "2026-10-20T08:00:00+00:00")
            self.assertEqual(db.get_dividend_events("563020")["events"], events)
            db.put_dividend_events("563020", [{"code": "563020", "date": "2026-09-11", "amountPerShare": "0.012", "isEstimated": False}], "2026-10-20T08:01:00+00:00")
            self.assertEqual(len(db.get_dividend_events("563020")["events"]), 2)
            self.assertEqual(db.get_real("main")["revision"], 0)

    def test_tracked_instrument_is_separate_from_real_ledger(self):
        with tempfile.TemporaryDirectory() as folder:
            db = NextDatabase(Path(folder) / "tracked.sqlite3")
            db.track_instrument("159941", "2026-10-19T08:00:00+00:00")
            db.track_instrument("159941", "2026-10-19T09:00:00+00:00")
            self.assertEqual(db.tracked_instruments(), ["159941"])
            self.assertEqual(db.get_real("main"), {"revision": 0, "bookJSON": None})

    def test_worker_status_is_not_part_of_real_ledger(self):
        with tempfile.TemporaryDirectory() as folder:
            db = NextDatabase(Path(folder) / "status.sqlite3")
            db.put_worker_status("daily-archive", "2026-10-19T08:00:00+00:00", "degraded", "0/4 source replies")
            self.assertEqual(db.worker_status()[0]["state"], "degraded")
            self.assertEqual(db.get_real("main")["revision"], 0)

    def test_worker_health_marks_old_or_invalid_heartbeat_stale(self):
        with tempfile.TemporaryDirectory() as folder:
            db = NextDatabase(Path(folder) / "worker-health.sqlite3")
            now = datetime.fromisoformat("2026-10-20T08:00:00+00:00")
            db.put_worker_status("daily-archive", "2026-10-20T07:59:00+00:00", "ok", "recent")
            db.put_worker_status("minute-archive", "2026-10-20T06:00:00+00:00", "ok", "old")
            db.put_worker_status("factor-research", "not-a-time", "ok", "bad timestamp")
            by_name = {item["name"]: item for item in db.worker_health(now=now, stale_after_seconds=1200)}
            self.assertEqual(by_name["daily-archive"]["health"], "ok")
            self.assertEqual(by_name["daily-archive"]["ageSeconds"], 60)
            self.assertTrue(by_name["minute-archive"]["stale"])
            self.assertEqual(by_name["minute-archive"]["health"], "stale")
            self.assertTrue(by_name["factor-research"]["stale"])


class AIAnalysisTests(unittest.TestCase):
    class Response:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self, _limit):
            return json.dumps({"choices": [{"message": {"content": "结论：等待；依据：提供的数据；风险：行情可能变化。"}}]}).encode()

    def context(self):
        return {"security": {"code": "159941", "name": "纳指ETF", "price": "1.2", "previousClose": "1.1",
                "iopv": None, "quoteTime": "2026-10-20T02:00:00Z", "source": "test", "technical": {"MA20": "1.15"}, "targetWeight": None},
            "dailyBars": [{"date": "2026-10-19", "open": "1.1", "high": "1.3", "low": "1.0", "close": "1.2", "volume": "1000"}], "position": None, "allPositions": [], "cash": "1000",
            "recentFills": [], "goal": {"years": 10, "monthlyBudget": "1000", "concentrationLimit": "40", "targetWeights": {}}, "dividends": []}

    def test_on_demand_ai_uses_nas_secret_and_only_returns_model_text(self):
        captured = {}
        def opener(request, timeout):
            captured["request"] = request; captured["timeout"] = timeout
            return self.Response()
        with patch.dict("os.environ", {"GUANPAN_AI_PROFILE": "flash"}):
            result = analyze_user_context(self.context(), api_key="nas-secret", opener=opener)
        self.assertEqual(result["code"], "159941")
        self.assertFalse(result["realOrder"])
        self.assertEqual(result["model"], "deepseek-flash")
        self.assertEqual(captured["request"].get_header("Authorization"), "Bearer nas-secret")
        sent = json.loads(captured["request"].data)
        self.assertIn("dailyBars", json.loads(sent["messages"][1]["content"]))
        self.assertNotIn("nas-secret", json.dumps(result))
        self.assertEqual(captured["timeout"], 45)

    def test_on_demand_ai_rejects_credentials_and_malformed_context(self):
        context = self.context(); context["apiKey"] = "should-not-pass"
        with self.assertRaises(ValueError): analyze_user_context(context, api_key="secret")
        context = self.context(); context["dailyBars"] = [{"date": "2026-10-19", "open": "1.1", "high": "1.3", "low": "1.0", "close": "1.2", "volume": "1000", "order": "buy"}]
        with self.assertRaises(ValueError): analyze_user_context(context, api_key="secret")
        with self.assertRaises(AIProviderError): analyze_user_context(self.context(), api_key="")


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = NextDatabase(Path(self.temp.name) / "new.sqlite3")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.db, lambda codes: [{"code": code} for code in codes]))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(); self.temp.cleanup()

    def request(self, method, path, payload=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=3)
        headers = {"Content-Type": "application/json"}
        connection.request(method, path, json.dumps(payload) if payload is not None else None, headers)
        response = connection.getresponse(); value = json.loads(response.read()); status = response.status
        connection.close(); return status, value

    def test_health_has_no_private_records(self):
        with patch.dict("os.environ", {"DEEPSEEK_API_KEY": ""}, clear=False):
            status, value = self.request("GET", "/health")
        self.assertEqual(status, 200); self.assertEqual(value["service"], "guanpan-next"); self.assertEqual(value["authentication"], "none"); self.assertEqual(value["workers"], [])
        self.assertEqual(value["aiProvider"]["state"], "missing_key")
        self.db.put_worker_status("daily-archive", datetime.now(timezone.utc).isoformat(), "ok", "4/4 codes archived")
        status, value = self.request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(value["workers"][0]["health"], "ok")
        self.assertFalse(value["workers"][0]["stale"])
        self.assertNotIn("bookJSON", json.dumps(value))

    def test_on_demand_ai_route_requires_configured_nas_key(self):
        context = {"security": {"code": "159941", "name": "纳指ETF", "price": None, "previousClose": None, "iopv": None, "quoteTime": None, "source": "无缓存", "technical": {}, "targetWeight": None},
            "dailyBars": [], "position": None, "allPositions": [], "cash": "0", "recentFills": [],
            "goal": {"years": 10, "monthlyBudget": "1000", "concentrationLimit": "40", "targetWeights": {}}, "dividends": []}
        payload = {"userConfirmed": True, "context": context}
        with patch.dict("os.environ", {"DEEPSEEK_API_KEY": "", "GUANPAN_AI_PROFILE": "flash"}):
            status, result = self.request("POST", "/v1/ai/analyze", payload)
        self.assertEqual(status, 503)
        self.assertIn("未配置", result["error"])

    def test_on_demand_ai_route_returns_research_without_real_order(self):
        expected = {"code": "159941", "provider": "DeepSeek", "model": "deepseek-flash", "content": "等待", "realOrder": False}
        with patch("app.analyze_user_context", return_value=expected) as call:
            status, result = self.request("POST", "/v1/ai/analyze", {"userConfirmed": True, "context": {"security": {"code": "159941"}}})
        self.assertEqual(status, 200)
        self.assertEqual(result["content"], "等待")
        self.assertFalse(result["realOrder"])
        call.assert_called_once()

    def test_research_reports_key_state_without_disclosing_secret(self):
        secret = "never-return-this-secret"
        with patch.dict("os.environ", {"DEEPSEEK_API_KEY": secret, "GUANPAN_AI_PROFILE": "flash"}):
            status, value = self.request("GET", "/v1/research/159941")
        self.assertEqual(status, 200)
        self.assertEqual(value["providerStatus"]["state"], "configured_unverified")
        self.assertEqual(value["providerStatus"]["model"], "deepseek-flash")
        self.assertNotIn(secret, json.dumps(value))

    def test_real_records_are_available_without_app_passphrase(self):
        self.assertEqual(self.request("GET", "/v1/real/books/main"), (200, {"revision": 0, "bookJSON": None}))
        self.assertEqual(self.request("POST", "/v1/real/books/main", {})[0], 400)

    def test_explicit_manual_confirmation_and_revision(self):
        payload = {"bookJSON": json.dumps(book()), "expectedRevision": 0}
        self.assertEqual(self.request("POST", "/v1/real/books/main", payload)[0], 400)
        payload["mode"] = "manual-confirmed"
        self.assertEqual(self.request("POST", "/v1/real/books/main", payload), (200, {"revision": 1}))
        self.assertEqual(self.request("POST", "/v1/real/books/main", payload)[0], 409)

    def test_dividend_history_route_serves_archive(self):
        self.db.put_dividend_events("563020", [{"code": "563020", "date": "2026-06-10", "amountPerShare": "0.012", "isEstimated": False,
            "recordDate": "2026-06-09", "payDate": "2026-06-15"}], datetime.now(timezone.utc).isoformat())
        status, response = self.request("GET", "/v1/market/dividends/563020")
        self.assertEqual(status, 200)
        self.assertEqual(response["events"][0]["amountPerShare"], "0.012")
        self.assertFalse(response["events"][0]["isEstimated"])

    def test_daily_archive_persists_and_serves_offline(self):
        rows = [{"date": "2026-10-16", "open": "1.2", "close": "1.3", "high": "1.4", "low": "1.1", "volume": "123"}]
        self.db.put_daily("159941", rows, "2026-10-19T08:00:00+00:00")
        status, payload = self.request("GET", "/v1/market/daily/159941")
        self.assertEqual(status, 200)
        self.assertEqual(payload["bars"], rows)
        self.assertEqual(payload["source"], "Tencent newfqkline qfqday")

    def test_backtest_endpoint_uses_archived_daily_bars_and_persists_run(self):
        for code, start in (("159941", "1.00"), ("563020", "1.10")):
            values = [Decimal(start), Decimal(start) + Decimal("0.02"), Decimal(start) + Decimal("0.04")]
            rows = []
            for index, close in enumerate(values):
                opened = values[max(0, index - 1)]
                rows.append({"date": f"2026-10-{19 + index}", "open": str(opened), "close": str(close),
                             "high": str(max(opened, close) + Decimal("0.01")),
                             "low": str(min(opened, close) - Decimal("0.01")), "volume": "1000"})
            self.db.put_daily(code, rows, "2026-10-20T00:00:00+00:00")
        request = {"strategy": "B", "codes": ["159941", "563020"], "initialCash": "10020",
                   "weights": {"159941": "0.5", "563020": "0.5"}, "lotSizes": {"159941": 100, "563020": 100}}
        status, result = self.request("POST", "/v1/backtests/B", request)
        self.assertEqual(status, 200, result)
        self.assertEqual(result["sessions"], 3)
        self.assertFalse(result["realOrder"])
        self.assertTrue(result["runId"])
        self.assertEqual(self.request("GET", "/v1/backtests/runs/" + result["runId"]), (200, result))
        self.assertEqual(self.request("POST", "/v1/backtests/A", request)[0], 400)

    def test_daily_refresh_appends_history_and_updates_overlapping_days(self):
        old = [
            {"date": "2024-01-02", "open": "1.0", "close": "1.1", "high": "1.2", "low": "0.9", "volume": "10"},
            {"date": "2024-01-03", "open": "1.1", "close": "1.2", "high": "1.3", "low": "1.0", "volume": "11"},
        ]
        self.db.put_daily("159941", old, "2026-10-19T08:00:00+00:00")
        refreshed = [
            {"date": "2024-01-03", "open": "1.1", "close": "1.25", "high": "1.3", "low": "1.0", "volume": "12"},
            {"date": "2024-01-04", "open": "1.25", "close": "1.3", "high": "1.4", "low": "1.2", "volume": "13"},
        ]
        self.db.put_daily("159941", refreshed, "2026-10-20T08:00:00+00:00")
        bars = self.db.get_daily("159941")["bars"]
        self.assertEqual([row["date"] for row in bars], ["2024-01-02", "2024-01-03", "2024-01-04"])
        self.assertEqual(bars[1]["close"], "1.25")
        self.assertEqual(bars[2]["close"], "1.3")
        with self.assertRaises(InvalidData):
            self.db.put_daily("159941", [{"date": "2024-01-05", "open": "1.2", "close": "1.1", "high": "1.0", "low": "1.3", "volume": "1"}], "2026-10-20T09:00:00+00:00")
        with self.assertRaises(InvalidData):
            self.db.put_daily("159941", [{"date": "2024-W01-2", "open": "1.2", "close": "1.3", "high": "1.4", "low": "1.1", "volume": "1"}], "2026-10-20T09:00:00+00:00")
        self.assertEqual(len(self.db.get_daily("159941")["bars"]), 3)

    def test_dividend_archive_rejects_noncanonical_optional_dates(self):
        with self.assertRaises(InvalidData):
            self.db.put_dividend_events("563020", [{"code": "563020", "date": "2026-06-10", "amountPerShare": "0.012",
                "isEstimated": False, "recordDate": "2026-W24-2"}], datetime.now(timezone.utc).isoformat())

    def test_real_trading_endpoint_absent_and_legacy_stage_is_explicit(self):
        self.assertEqual(self.request("POST", "/v1/trade", {})[0], 404)
        self.assertEqual(self.request("POST", "/api/native/data", {})[0], 404)
        self.assertEqual(self.request("POST", "/api/data", {})[0], 400)
        legacy = {"cash": 500, "db": {"hold": [{"code": "159941", "num": 100, "cost": 1.25}]}}
        self.assertEqual(self.request("POST", "/api/data", {"data": legacy, "expectedRevision": 0})[0], 400)
        status, staged = self.request("POST", "/api/data", {"mode": "legacy-stage-confirmed", "expectedRevision": 0, "data": legacy})
        self.assertEqual((status, staged["revision"]), (200, 1))
        self.assertEqual(self.request("GET", "/api/data")[1]["data"], legacy)
        status, preview = self.request("GET", "/v1/legacy/books/main")
        self.assertEqual(status, 200)
        self.assertEqual(preview["book"]["positions"][0]["units"], 100)
        self.assertEqual(self.db.get_real("main")["revision"], 0)
        self.assertEqual(self.request("POST", "/api/data", {"mode": "legacy-stage-confirmed", "expectedRevision": 0, "data": legacy})[0], 409)

    def test_market_quote_endpoint_and_valid_codes(self):
        status, value = self.request("GET", "/v1/market/quotes?codes=159941,510300")
        self.assertEqual(status, 200)
        self.assertEqual(value["quotes"], [{"code": "159941"}, {"code": "510300"}])
        for query in ("", "codes=12", "codes=159941,159941", "codes=700000"):
            self.assertEqual(self.request("GET", "/v1/market/quotes" + ("?" + query if query else ""))[0], 400)

    def test_tracking_endpoint_requires_confirmation(self):
        self.assertEqual(self.request("POST", "/v1/market/track/159941", {})[0], 400)
        status, body = self.request("POST", "/v1/market/track/159941", {"mode": "track-confirmed"})
        self.assertEqual((status, body), (200, {"code": "159941", "tracked": True}))
        self.assertEqual(self.db.tracked_instruments(), ["159941"])

    def test_web_console_is_available(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=3)
        connection.request("GET", "/")
        response = connection.getresponse(); body = response.read().decode(); connection.close()
        self.assertEqual(response.status, 200); self.assertIn("观盘 Pro Next", body); self.assertIn("行情档案核对", body)


if __name__ == "__main__": unittest.main()
