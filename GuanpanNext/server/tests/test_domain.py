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


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = NextDatabase(Path(self.temp.name) / "new.sqlite3")
        self.token = "test-only-token-1234567890123456"
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.db, self.token, lambda codes: [{"code": code} for code in codes]))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(); self.temp.cleanup()

    def request(self, method, path, payload=None, auth=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=3)
        headers = {"Content-Type": "application/json"}
        if auth: headers["Authorization"] = "Bearer " + self.token
        connection.request(method, path, json.dumps(payload) if payload is not None else None, headers)
        response = connection.getresponse(); value = json.loads(response.read()); status = response.status
        connection.close(); return status, value

    def test_health_has_no_private_records(self):
        status, value = self.request("GET", "/health", auth=False)
        self.assertEqual(status, 200); self.assertEqual(value, {"service": "guanpan-next", "schemaVersion": 1})

    def test_auth_required_for_real_records(self):
        self.assertEqual(self.request("GET", "/v1/real/books/main", auth=False)[0], 401)
        self.assertEqual(self.request("POST", "/v1/real/books/main", {}, auth=False)[0], 401)

    def test_explicit_manual_confirmation_and_revision(self):
        payload = {"bookJSON": json.dumps(book()), "expectedRevision": 0}
        self.assertEqual(self.request("POST", "/v1/real/books/main", payload)[0], 400)
        payload["mode"] = "manual-confirmed"
        self.assertEqual(self.request("POST", "/v1/real/books/main", payload), (200, {"revision": 1}))
        self.assertEqual(self.request("POST", "/v1/real/books/main", payload)[0], 409)

    def test_no_real_trading_endpoint(self):
        for path in ("/v1/trade", "/api/data", "/api/native/data"):
            self.assertEqual(self.request("POST", path, {})[0], 404)

    def test_market_quote_endpoint_requires_auth_and_valid_codes(self):
        self.assertEqual(self.request("GET", "/v1/market/quotes?codes=159941", auth=False)[0], 401)
        status, value = self.request("GET", "/v1/market/quotes?codes=159941,510300")
        self.assertEqual(status, 200)
        self.assertEqual(value["quotes"], [{"code": "159941"}, {"code": "510300"}])
        for query in ("", "codes=12", "codes=159941,159941", "codes=700000"):
            self.assertEqual(self.request("GET", "/v1/market/quotes" + ("?" + query if query else ""))[0], 400)

    def test_empty_or_short_token_rejected(self):
        for value in ("", "short"):
            with self.assertRaises(ValueError): make_handler(self.db, value)


if __name__ == "__main__": unittest.main()
