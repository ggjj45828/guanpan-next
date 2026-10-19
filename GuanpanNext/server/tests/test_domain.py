import copy
import http.client
import json
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from pathlib import Path
from app import make_handler
from domain import Conflict, InvalidData, NextDatabase, validate_book_json
from market import parse_quotes, symbol_for
from datetime import datetime, timezone


def book():
    return {"schemaVersion": 1, "id": "local-book", "cash": 1000,
            "positions": [{"code": "159941", "name": "纳指ETF", "units": 100, "bookCost": 123.45}],
            "fills": [], "history": []}


class DomainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = NextDatabase(Path(self.temp.name) / "new.sqlite3")

    def tearDown(self): self.temp.cleanup()

    def test_no_legacy_fields_accepted(self):
        for field in ("holdings", "fundDCAPlans", "fundTransactions"):
            data = book(); data[field] = []
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

    def test_native_cash_movement_schema_is_accepted_and_validated(self):
        data = book(); data["cashMovements"] = [{"id": "event-1", "date": 1792375200, "amount": -25, "reason": "确认转出"}]
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
        from ai import PROFILES, generate_research
        self.assertEqual(PROFILES["flash"]["model"], "deepseek-flash")
        self.assertEqual(PROFILES["pro"]["model"], "deepseek-v4-pro")
        factors = {"code": "159941", "asOf": "2026-10-16", "source": "source",
            "close": "1.2", "ma20": "1.1", "ma250": "1.0", "momentum20": "0.1", "drawdown20": "-0.02"}
        self.assertIsNone(generate_research(factors, api_key=""))

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
        status, value = self.request("GET", "/health")
        self.assertEqual(status, 200); self.assertEqual(value["service"], "guanpan-next"); self.assertEqual(value["authentication"], "none"); self.assertEqual(value["workers"], [])

    def test_real_records_are_available_without_app_passphrase(self):
        self.assertEqual(self.request("GET", "/v1/real/books/main"), (200, {"revision": 0, "bookJSON": None}))
        self.assertEqual(self.request("POST", "/v1/real/books/main", {})[0], 400)

    def test_explicit_manual_confirmation_and_revision(self):
        payload = {"bookJSON": json.dumps(book()), "expectedRevision": 0}
        self.assertEqual(self.request("POST", "/v1/real/books/main", payload)[0], 400)
        payload["mode"] = "manual-confirmed"
        self.assertEqual(self.request("POST", "/v1/real/books/main", payload), (200, {"revision": 1}))
        self.assertEqual(self.request("POST", "/v1/real/books/main", payload)[0], 409)

    def test_daily_archive_persists_and_serves_offline(self):
        rows = [{"date": "2026-10-16", "open": "1.2", "close": "1.3", "high": "1.4", "low": "1.1", "volume": "123"}]
        self.db.put_daily("159941", rows, "2026-10-19T08:00:00+00:00")
        status, payload = self.request("GET", "/v1/market/daily/159941")
        self.assertEqual(status, 200)
        self.assertEqual(payload["bars"], rows)
        self.assertEqual(payload["source"], "Tencent newfqkline qfqday")

    def test_no_real_trading_endpoint(self):
        for path in ("/v1/trade", "/api/data", "/api/native/data"):
            self.assertEqual(self.request("POST", path, {})[0], 404)

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
