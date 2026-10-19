"""Independent NAS service. Only an explicit manual-sync route can write real books."""
import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from domain import Conflict, InvalidData, NextDatabase
from market import fetch_tencent_quotes, symbol_for


def make_handler(database, token, market_fetcher=fetch_tencent_quotes):
    if not token or len(token) < 24:
        raise ValueError("GUANPAN_NEXT_TOKEN must contain at least 24 characters")

    class Handler(BaseHTTPRequestHandler):
        server_version = "GuanpanNext/1"

        def log_message(self, format, *args):
            # Never log query strings, tokens, books or personal records.
            pass

        def reply(self, status, value):
            body = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers(); self.wfile.write(body)

        def authorized(self):
            actual = self.headers.get("Authorization", "")
            if not hmac.compare_digest(actual, "Bearer " + token):
                self.reply(401, {"error": "authentication required"})
                return False
            return True

        def do_GET(self):
            parsed = urlparse(self.path); path = parsed.path
            if path == "/health":
                return self.reply(200, {"service": "guanpan-next", "schemaVersion": 1})
            if not self.authorized(): return
            if path == "/v1/market/quotes":
                try:
                    raw = parse_qs(parsed.query, strict_parsing=True).get("codes", [""])[0]
                    codes = raw.split(",") if raw else []
                    if not 1 <= len(codes) <= 60 or len(set(codes)) != len(codes):
                        raise InvalidData("provide 1–60 unique exchange codes")
                    for code in codes: symbol_for(code)
                    return self.reply(200, {"quotes": market_fetcher(codes)})
                except InvalidData as error:
                    return self.reply(400, {"error": str(error)})
                except ValueError as error:
                    return self.reply(400, {"error": str(error)})
                except Exception:
                    return self.reply(502, {"error": "quote source unavailable; local cache remains authoritative"})
            if path.startswith("/v1/real/books/"):
                try: return self.reply(200, database.get_real(path.rsplit("/", 1)[-1]))
                except InvalidData as error: return self.reply(400, {"error": str(error)})
            self.reply(404, {"error": "unknown route"})

        def do_POST(self):
            if not self.authorized(): return
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
                self.reply(404, {"error": "unknown route"})
            except Conflict:
                self.reply(409, {"error": "revision conflict; no changes saved"})
            except (InvalidData, ValueError, UnicodeError) as error:
                self.reply(400, {"error": str(error)})

    return Handler


if __name__ == "__main__":
    root = Path(os.environ.get("GUANPAN_NEXT_DATA", "/data")); root.mkdir(parents=True, exist_ok=True)
    database = NextDatabase(root / "guanpan-next.sqlite3")
    handler = make_handler(database, os.environ.get("GUANPAN_NEXT_TOKEN", ""))
    ThreadingHTTPServer(("0.0.0.0", 8790), handler).serve_forever()
