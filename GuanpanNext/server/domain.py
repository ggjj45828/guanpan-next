"""Fresh securities schema. No legacy database, OTC model or broker adapter."""
import json
import re
import sqlite3
from decimal import Decimal, InvalidOperation


class InvalidData(ValueError):
    pass


class Conflict(Exception):
    pass


def validate_book_json(text):
    if not isinstance(text, str):
        raise InvalidData("bookJSON must be a JSON string")
    def reject(value):
        raise InvalidData("non-finite number")
    try:
        book = json.loads(text, parse_float=Decimal, parse_constant=reject)
        if not isinstance(book, dict) or book.get("schemaVersion") != 1:
            raise InvalidData("unsupported book schema")
        allowed = {"schemaVersion", "id", "cash", "positions", "fills", "cashMovements", "history", "importedAt"}
        if set(book) - allowed:
            raise InvalidData("unexpected fields; legacy backups are not accepted")
        def number(value, minimum=Decimal(0)):
            if isinstance(value, bool) or not isinstance(value, (Decimal, int)):
                raise InvalidData("invalid numeric field")
            d = Decimal(value)
            if not d.is_finite() or (minimum is not None and d < minimum):
                raise InvalidData("invalid numeric range")
            return d
        def code(value):
            if not isinstance(value, str) or re.fullmatch(r"[0-9]{6}", value) is None:
                raise InvalidData("invalid exchange code")
        number(book["cash"])
        positions = book["positions"]
        if not isinstance(positions, list):
            raise InvalidData("positions must be a list")
        seen = set()
        for p in positions:
            if not isinstance(p, dict) or set(p) != {"code", "name", "units", "bookCost"}:
                raise InvalidData("invalid position fields")
            code(p["code"])
            if p["code"] in seen or not isinstance(p["name"], str):
                raise InvalidData("duplicate code or invalid name")
            seen.add(p["code"])
            if type(p["units"]) is not int or p["units"] < 0:
                raise InvalidData("units must be a nonnegative integer")
            number(p["bookCost"])
        if not isinstance(book.get("fills"), list) or not isinstance(book.get("history"), list):
            raise InvalidData("fills/history must be arrays")
        movements = book.get("cashMovements", [])
        if not isinstance(movements, list):
            raise InvalidData("cashMovements must be an array")
        for movement in movements:
            if not isinstance(movement, dict) or set(movement) != {"id", "date", "amount", "reason"}:
                raise InvalidData("invalid cash movement fields")
            number(movement["amount"], minimum=None)
            number(movement["date"], minimum=None)
            if not isinstance(movement["reason"], str) or not movement["reason"].strip():
                raise InvalidData("cash movement reason is required")
        for fill in book["fills"]:
            if not isinstance(fill, dict) or set(fill) != {"id", "date", "code", "side", "units", "price", "fee", "realized"}:
                raise InvalidData("invalid fill fields")
            code(fill["code"])
            if fill["side"] not in ("buy", "sell") or type(fill["units"]) is not int or fill["units"] <= 0:
                raise InvalidData("invalid fill side/units")
            for key in ("price", "fee"): number(fill[key])
            for key in ("date", "realized"): number(fill[key], minimum=None)
        for point in book["history"]:
            if not isinstance(point, dict) or set(point) != {"id", "date", "total", "externalFlow"}:
                raise InvalidData("invalid history point")
            number(point["total"])
            number(point["date"], minimum=None)
            number(point["externalFlow"], minimum=None)
        return book
    except (KeyError, TypeError, json.JSONDecodeError, InvalidOperation) as error:
        raise InvalidData("invalid securities book") from error


class NextDatabase:
    """Compare-and-swap manual snapshots; real and research tables are separate."""
    def __init__(self, filename):
        self.filename = str(filename)
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS real_books (
                    id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS real_book_history (
                    id TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL,
                    PRIMARY KEY(id, revision));
                CREATE TABLE IF NOT EXISTS research_runs (
                    id TEXT PRIMARY KEY, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS experiments (
                    id TEXT PRIMARY KEY, body TEXT NOT NULL);
            """)

    def connect(self):
        return sqlite3.connect(self.filename, timeout=15)

    @staticmethod
    def validate_id(book_id):
        if not isinstance(book_id, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,80}", book_id) is None:
            raise InvalidData("invalid id")

    def get_real(self, book_id):
        self.validate_id(book_id)
        with self.connect() as db:
            row = db.execute("SELECT revision, body FROM real_books WHERE id=?", (book_id,)).fetchone()
        return {"revision": row[0], "bookJSON": row[1]} if row else {"revision": 0, "bookJSON": None}

    def put_real(self, book_id, expected, book_json):
        self.validate_id(book_id)
        if type(expected) is not int or expected < 0:
            raise InvalidData("invalid expectedRevision")
        validate_book_json(book_json)
        # The exact JSON text is stored; no float re-encoding of money occurs.
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT revision FROM real_books WHERE id=?", (book_id,)).fetchone()
            revision = current[0] if current else 0
            if revision != expected:
                raise Conflict("revision changed; manual conflict resolution required")
            revision += 1
            db.execute("INSERT OR REPLACE INTO real_books VALUES (?, ?, ?)", (book_id, revision, book_json))
            db.execute("INSERT INTO real_book_history VALUES (?, ?, ?)", (book_id, revision, book_json))
        return revision

    def put_research(self, run_id, body):
        self.validate_id(run_id)
        with self.connect() as db:
            db.execute("INSERT INTO research_runs VALUES (?, ?)", (run_id, json.dumps(body, ensure_ascii=False)))

    def put_experiment(self, experiment_id, body):
        self.validate_id(experiment_id)
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO experiments VALUES (?, ?)", (experiment_id, json.dumps(body, ensure_ascii=False)))
