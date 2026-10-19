"""Independent NAS service and local web console for Guanpan Pro Next.

The service intentionally has no application passphrase.  It is designed for a
trusted home LAN / VPN; the iOS app and the web console make real-book writes
explicit and revision-checked.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from datetime import datetime, timezone
from urllib.parse import parse_qs, urlparse
from domain import Conflict, InvalidData, NextDatabase
from market import fetch_tencent_quotes, fetch_tencent_daily, symbol_for
from workers import start_workers

WEB_ROOT = Path(__file__).with_name("web")


def make_handler(database, market_fetcher=fetch_tencent_quotes, daily_fetcher=fetch_tencent_daily):
    class Handler(BaseHTTPRequestHandler):
        server_version = "GuanpanNext/1"

        def log_message(self, format, *args):
            # Personal book data and query strings are deliberately not logged.
            pass

        def reply(self, status, value):
            body = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers(); self.wfile.write(body)

        def html(self):
            body = (WEB_ROOT / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers(); self.wfile.write(body)

        def do_GET(self):
            parsed = urlparse(self.path); path = parsed.path
            if path in ("/", "/index.html"):
                return self.html()
            if path == "/health":
                return self.reply(200, {"service": "guanpan-next", "schemaVersion": 1, "authentication": "none", "web": True, "workers": database.worker_status()})
            if path.startswith("/v1/research/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    return self.reply(200, {"factors": database.get_research("factors-" + code),
                                            "ai": database.get_research("deepseek-" + code),
                                            "providerConfigured": bool(os.environ.get("DEEPSEEK_API_KEY"))})
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            if path.startswith("/v1/market/minute/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    day = parse_qs(parsed.query).get("day", [datetime.now().astimezone().date().isoformat()])[0]
                    return self.reply(200, database.get_minute(code, day))
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            if path.startswith("/v1/market/daily/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    cached = database.get_daily(code)
                    if cached is None:
                        rows = daily_fetcher(code)
                        database.put_daily(code, rows, datetime.now(timezone.utc).isoformat())
                        cached = database.get_daily(code)
                    return self.reply(200, cached)
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
                except Exception: return self.reply(503, {"error": "daily source unavailable and no NAS cache"})
            if path == "/v1/market/quotes":
                try:
                    raw = parse_qs(parsed.query, strict_parsing=True).get("codes", [""])[0]
                    codes = raw.split(",") if raw else []
                    if not 1 <= len(codes) <= 60 or len(set(codes)) != len(codes):
                        raise InvalidData("provide 1–60 unique exchange codes")
                    for code in codes: symbol_for(code)
                    return self.reply(200, {"quotes": market_fetcher(codes)})
                except (InvalidData, ValueError) as error:
                    return self.reply(400, {"error": str(error)})
                except Exception:
                    return self.reply(502, {"error": "quote source unavailable; local cache remains authoritative"})
            if path.startswith("/v1/real/books/"):
                try: return self.reply(200, database.get_real(path.rsplit("/", 1)[-1]))
                except InvalidData as error: return self.reply(400, {"error": str(error)})
            self.reply(404, {"error": "unknown route"})

        def do_POST(self):
            path = urlparse(self.path).path
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 16 * 1024 * 1024:
                    return self.reply(413, {"error": "invalid body size"})
                value = json.loads(self.rfile.read(length))
                if not isinstance(value, dict): raise InvalidData("JSON object required")
                if path.startswith("/v1/real/books/"):
                    if value.get("mode") != "manual-confirmed":
                        raise InvalidData("real books require explicit manual confirmation")
                    revision = database.put_real(path.rsplit("/", 1)[-1], value.get("expectedRevision"), value.get("bookJSON"))
                    return self.reply(200, {"revision": revision})
                if path.startswith("/v1/market/track/"):
                    if value.get("mode") != "track-confirmed":
                        raise InvalidData("instrument tracking requires explicit confirmation")
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    database.track_instrument(code, datetime.now(timezone.utc).isoformat())
                    return self.reply(200, {"code": code, "tracked": True})
                self.reply(404, {"error": "unknown route"})
            except Conflict:
                self.reply(409, {"error": "revision conflict; no changes saved"})
            except (InvalidData, ValueError, UnicodeError) as error:
                self.reply(400, {"error": str(error)})

    return Handler


if __name__ == "__main__":
    root = Path(os.environ.get("GUANPAN_NEXT_DATA", "/data")); root.mkdir(parents=True, exist_ok=True)
    database = NextDatabase(root / "guanpan-next.sqlite3")
    start_workers(database)
    ThreadingHTTPServer(("0.0.0.0", 8786), make_handler(database)).serve_forever()
