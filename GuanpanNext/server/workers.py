"""Independent NAS workers. No worker reads the mobile sync preference."""
import json
import threading
import time
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo
from market import symbol_for, fetch_tencent_daily, fetch_tencent_quotes
from ai import generate_research

SHANGHAI = ZoneInfo("Asia/Shanghai")
DEFAULT_CODES = ("159941", "563020", "159545", "159352")


def parse_minute(body, code):
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end < start: raise ValueError("invalid minute response")
    node = json.loads(body[start:end + 1]).get("data", {}).get(symbol_for(code), {}).get("data", {})
    day = node.get("date", "")
    rows = node.get("data") or node.get("items")
    if not isinstance(rows, list) or len(day) != 8 or not day.isdigit(): raise ValueError("minute source missing")
    result = {}
    last_volume = None
    for row in rows:
        parts = row.split() if isinstance(row, str) else []
        if len(parts) < 2 or len(parts[0]) != 4 or not parts[0].isdigit(): continue
        try:
            hour, minute = int(parts[0][:2]), int(parts[0][2:])
            price = Decimal(parts[1]); cumulative = Decimal(parts[2]) if len(parts) > 2 else None
            if not (9 <= hour <= 15 and 0 <= minute <= 59 and price.is_finite() and price > 0): continue
            if cumulative is not None and (not cumulative.is_finite() or cumulative < 0): continue
            stamp = datetime.strptime(day + parts[0], "%Y%m%d%H%M").replace(tzinfo=SHANGHAI)
            if stamp > datetime.now(timezone.utc): continue
            volume = str(cumulative - last_volume) if cumulative is not None and last_volume is not None and cumulative >= last_volume else None
            if cumulative is not None: last_volume = cumulative
            result[stamp.isoformat()] = {"timestamp": stamp.isoformat(), "price": str(price), "volume": volume, "iopv": None}
        except (ValueError, ArithmeticError): continue
    if not result: raise ValueError("no validated minute rows")
    return [result[key] for key in sorted(result)]


def fetch_minute(code):
    symbol = symbol_for(code)
    url = "https://web.ifzq.gtimg.cn/appstock/app/minute/query?" + urlencode({"code": symbol, "_var": "min_data_" + symbol})
    with urlopen(Request(url, headers={"Referer": "https://gu.qq.com/", "User-Agent": "GuanpanProNext/3"}), timeout=12) as response:
        if response.status != 200: raise OSError("minute source unavailable")
        return parse_minute(response.read(2_000_000).decode("utf-8"), code)


def attach_quote_iopv(rows, quote):
    """Attach only a same-session, near-time ETF IOPV to the latest sample."""
    if not rows or not quote or not quote.get("iopv") or quote.get("providerInstrumentType") != "ETF":
        return rows
    quote_time = datetime.fromisoformat(quote["time"])
    last_time = datetime.fromisoformat(rows[-1]["timestamp"])
    if quote_time.astimezone(SHANGHAI).date() == last_time.astimezone(SHANGHAI).date() and abs((quote_time - last_time).total_seconds()) <= 300:
        rows[-1]["iopv"] = quote["iopv"]
    return rows


def research_factors(code, bars):
    """Traceable local factor research; no model-generated claims or real trading."""
    closes = [Decimal(row["close"]) for row in bars]
    if len(closes) < 250: return None
    ma20 = sum(closes[-20:]) / 20
    ma250 = sum(closes[-250:]) / 250
    delta = closes[-1] / closes[-21] - 1
    drawdown = closes[-1] / max(closes[-20:]) - 1
    return {"code": code, "asOf": bars[-1]["date"], "close": str(closes[-1]),
        "ma20": str(ma20), "ma250": str(ma250), "momentum20": str(delta),
        "drawdown20": str(drawdown), "state": "观察" if closes[-1] >= ma250 and delta > 0 else "谨慎",
        "source": "NAS archived Tencent qfqday", "type": "local-factor-research", "realOrder": False}


def start_workers(database, daily_fetcher=fetch_tencent_daily, minute_fetcher=fetch_minute, quote_fetcher=fetch_tencent_quotes):
    """Each loop owns its own timer and failure handling; sync APIs never stop them."""
    def tracked():
        with database.connect() as connection:
            rows = connection.execute("SELECT code FROM daily_bars UNION SELECT DISTINCT code FROM minute_archive").fetchall()
        return sorted(set(DEFAULT_CODES) | set(database.tracked_instruments()) | {row[0] for row in rows})

    def update(name, state, detail):
        database.put_worker_status(name, datetime.now(timezone.utc).isoformat(), state, detail[:500])

    def daily_loop():
        update("daily-archive", "starting", "worker starting")
        while True:
            codes = tracked(); failures = 0
            for code in codes:
                try: database.put_daily(code, daily_fetcher(code), datetime.now(timezone.utc).isoformat())
                except Exception: failures += 1  # Last verified archive stays available.
            update("daily-archive", "ok" if failures == 0 else "degraded", f"{len(codes) - failures}/{len(codes)} codes archived; next run in 30m")
            time.sleep(1800)

    def minute_loop():
        update("minute-archive", "starting", "worker starting")
        while True:
            local = datetime.now(SHANGHAI)
            if local.weekday() < 5 and ((9, 15) <= (local.hour, local.minute) <= (11, 35) or (13, 0) <= (local.hour, local.minute) <= (15, 5)):
                codes = tracked(); failures = 0
                for code in codes:
                    try:
                        rows = minute_fetcher(code)
                        quote = next(iter(quote_fetcher([code])), None)
                        attach_quote_iopv(rows, quote)
                        database.put_minute(code, rows, datetime.now(timezone.utc).isoformat())
                    except Exception: failures += 1
                update("minute-archive", "ok" if failures == 0 else "degraded", f"{len(codes) - failures}/{len(codes)} codes collected; next attempt in 1m")
            else:
                update("minute-archive", "idle", "outside mainland market collection window; historical archive remains available")
            time.sleep(60)

    def research_loop():
        update("factor-research", "starting", "worker starting")
        while True:
            codes = tracked(); failures = 0; researched = 0
            for code in codes:
                try:
                    data = database.get_daily(code)
                    result = research_factors(code, data["bars"]) if data else None
                    if result:
                        database.put_research("factors-" + code, result)
                        # One provider call per completed business day; no key means offline factor record only.
                        previous = database.get_research("deepseek-" + code)
                        if previous is None or previous.get("asOf") != result["asOf"]:
                            narrative = generate_research(result)
                            if narrative: database.put_research("deepseek-" + code, narrative)
                        researched += 1
                except Exception: failures += 1
            update("factor-research", "ok" if failures == 0 else "degraded", f"{researched}/{len(codes)} codes have usable 250-day research; next run in 15m")
            time.sleep(900)

    for name, target in (("daily-archive", daily_loop), ("minute-archive", minute_loop), ("factor-research", research_loop)):
        threading.Thread(target=target, name=name, daemon=True).start()
