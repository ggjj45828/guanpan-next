"""Read-only Tencent quote adapter; no settlement or instrument type inference."""
import json
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from re import finditer
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo


def symbol_for(code):
    if not isinstance(code, str) or len(code) != 6 or not code.isascii() or not code.isdigit():
        raise ValueError("invalid mainland exchange code")
    first = code[0]
    prefix = "sh" if first in "569" else "sz" if first in "0123" else "bj" if first in "48" else None
    if prefix is None:
        raise ValueError("unsupported exchange code")
    return prefix + code


def parse_quotes(body, codes, received_at=None):
    received_at = received_at or datetime.now(timezone.utc)
    if received_at.tzinfo is None:
        raise ValueError("received_at must be timezone aware")
    requested = {symbol_for(code): code for code in codes}
    found = {}
    for match in finditer(r'v_([A-Za-z0-9]+)="([^"]*)"', body):
        symbol, payload = match.groups()
        code = requested.get(symbol.lower())
        if not code:
            continue
        fields = payload.split("~")
        if len(fields) <= 30 or not fields[1]:
            continue
        try:
            price, previous = Decimal(fields[3]), Decimal(fields[4])
            digits = "".join(ch for ch in fields[30] if ch.isdigit())
            if len(digits) not in (12, 14):
                continue
            date_format = "%Y%m%d%H%M%S" if len(digits) == 14 else "%Y%m%d%H%M"
            stamp = datetime.strptime(digits, date_format).replace(tzinfo=ZoneInfo("Asia/Shanghai"))
            provider_type = fields[61].strip().upper() if len(fields) > 61 else None
            iopv = Decimal(fields[78]) if provider_type == "ETF" and len(fields) > 78 and fields[78] else None
        except (InvalidOperation, ValueError, IndexError):
            continue
        if not price.is_finite() or not previous.is_finite() or price <= 0 or previous <= 0:
            continue
        if iopv is not None and (not iopv.is_finite() or iopv <= 0):
            iopv = None
        if (stamp.astimezone(timezone.utc) - received_at).total_seconds() > 60:
            continue
        found[code] = {
            "code": code, "name": fields[1], "price": str(price), "previousClose": str(previous),
            "time": stamp.isoformat(), "source": "Tencent qt.gtimg.cn", "providerInstrumentType": provider_type,
            "iopv": str(iopv) if iopv is not None else None,
        }
    return [found[code] for code in codes if code in found]


def fetch_tencent_quotes(codes):
    symbols = [symbol_for(code) for code in codes]
    query = urlencode({"_t": str(int(datetime.now().timestamp()))})
    request = Request("https://qt.gtimg.cn/q=" + ",".join(symbols) + "&" + query, headers={"Accept": "text/plain", "User-Agent": "GuanpanPro/3"})
    with urlopen(request, timeout=8) as response:
        if response.status != 200:
            raise OSError("quote source unavailable")
        raw = response.read(2_000_000)
        try:
            body = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            body = raw.decode("gb18030", errors="strict")
    result = parse_quotes(body, codes)
    if not result:
        raise ValueError("quote response had no validated matching records")
    return result


def parse_daily_bars(body, code, adjustment="qfq"):
    """Validate Tencent daily OHLCV records; never synthesize from minute data."""
    import json
    from datetime import date
    symbol = symbol_for(code)
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end < start: raise ValueError("invalid daily response")
    node = json.loads(body[start:end + 1]).get("data", {}).get(symbol, {})
    rows = node.get("qfqday" if adjustment == "qfq" else "day")
    if not isinstance(rows, list): raise ValueError("daily bars missing")
    result = {}
    for row in rows:
        if not isinstance(row, list) or len(row) < 6: continue
        try:
            business_day = date.fromisoformat(row[0])
            open_, close, high, low, volume = (Decimal(str(v)) for v in row[1:6])
            if (business_day > datetime.now(ZoneInfo("Asia/Shanghai")).date() or
                    any(not n.is_finite() for n in (open_, close, high, low, volume)) or
                    min(open_, close, high, low) <= 0 or volume < 0 or
                    low > min(open_, close) or high < max(open_, close)):
                continue
            result[str(business_day)] = {"date": str(business_day), "open": str(open_),
                "close": str(close), "high": str(high), "low": str(low), "volume": str(volume)}
        except (ValueError, InvalidOperation, TypeError): continue
    if not result: raise ValueError("no validated daily bars")
    return [result[key] for key in sorted(result)]


def fetch_tencent_daily(code, adjustment="qfq"):
    if adjustment not in ("qfq", "raw"):
        raise ValueError("unsupported adjustment")
    symbol = symbol_for(code)
    adjust_code = "qfq" if adjustment == "qfq" else ""
    url = "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get?" + urlencode({"param": f"{symbol},day,,,640,{adjust_code}"})
    request = Request(url, headers={"Accept": "application/json", "User-Agent": "GuanpanProNext/3", "Referer": "https://gu.qq.com/"})
    with urlopen(request, timeout=12) as response:
        if response.status != 200: raise OSError("daily source unavailable")
        raw = response.read(2_000_000).decode("utf-8", errors="strict")
    return parse_daily_bars(raw, code, adjustment)


def parse_eastmoney_dividends(body, code):
    """Return implemented mainland cash distributions only; proposals are excluded."""
    import json
    rows = json.loads(body).get("result", {}).get("data") or []
    found = {}
    for row in rows:
        if not isinstance(row, dict) or "实施" not in str(row.get("ASSIGN_PROGRESS", "")):
            continue
        raw_date = row.get("EX_DIVIDEND_DATE")
        date = str(raw_date or "")[:10]
        try: per_share = Decimal(str(row.get("PRETAX_BONUS_RMB"))) / Decimal(10)
        except (InvalidOperation, ValueError): continue
        if len(date) == 10 and per_share.is_finite() and per_share > 0:
            found[date] = {"code": code, "date": date, "amountPerShare": str(per_share), "isEstimated": False}
    return list(found.values())


def fetch_eastmoney_dividends(code):
    from urllib.parse import urlencode
    from urllib.request import Request, urlopen
    params = {"reportName": "RPT_SHAREBONUS_DET", "columns": "SECURITY_CODE,PRETAX_BONUS_RMB,EX_DIVIDEND_DATE,ASSIGN_PROGRESS,REPORT_DATE",
        "filter": f'(SECURITY_CODE="{code}")', "pageSize": "30", "pageNumber": "1", "sortColumns": "EX_DIVIDEND_DATE", "sortTypes": "-1"}
    url = "https://datacenter-web.eastmoney.com/api/data/v1/get?" + urlencode(params)
    request = Request(url, headers={"Referer": "https://data.eastmoney.com/", "User-Agent": "GuanpanProNext/3"})
    with urlopen(request, timeout=12) as response:
        if response.status != 200: raise OSError("dividend source unavailable")
        return parse_eastmoney_dividends(response.read(2_000_000).decode("utf-8"), code)


def parse_eastmoney_fund_dividends(body, code):
    """Parse implemented fund/ETF cash distributions from Eastmoney F10 history."""
    from html.parser import HTMLParser
    import re

    class Tables(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.tables = []; self.table = None; self.row = None; self.cell = None
        def handle_starttag(self, tag, attrs):
            if tag == "table": self.table = []
            elif tag == "tr" and self.table is not None: self.row = []
            elif tag in ("td", "th") and self.row is not None: self.cell = []
        def handle_data(self, data):
            if self.cell is not None: self.cell.append(data)
        def handle_endtag(self, tag):
            if tag in ("td", "th") and self.cell is not None:
                self.row.append(" ".join(self.cell).strip()); self.cell = None
            elif tag == "tr" and self.row is not None:
                self.table.append(self.row); self.row = None
            elif tag == "table" and self.table is not None:
                self.tables.append(self.table); self.table = None

    if not (len(code) == 6 and code.isascii() and code.isdigit()): raise ValueError("invalid fund code")
    parser = Tables(); parser.feed(body)
    found = {}
    for table in parser.tables:
        header = " ".join(cell for row in table[:3] for cell in row)
        if "权益登记日" not in header or "除息日" not in header or "每10份分红" not in header: continue
        for row in table:
            text = " ".join(row)
            dates = re.findall(r"(?<!\d)(20\d{2}-\d{2}-\d{2})(?!\d)", text)
            amount_match = re.search(r"每\s*10\s*份\s*派现金\s*([0-9]+(?:\.[0-9]+)?)\s*元", text)
            if len(dates) < 2 or amount_match is None: continue
            try:
                record_date, ex_date = dates[0], dates[1]
                pay_date = dates[2] if len(dates) > 2 else None
                per_share = Decimal(amount_match.group(1)) / Decimal(10)
                for day in (record_date, ex_date, pay_date):
                    if day: date.fromisoformat(day)
            except (ValueError, InvalidOperation): continue
            if not per_share.is_finite() or per_share <= 0: continue
            found[ex_date] = {"code": code, "date": ex_date, "amountPerShare": format(per_share.normalize(), "f"),
                "isEstimated": False, "recordDate": record_date, "payDate": pay_date}
    return sorted(found.values(), key=lambda item: item["date"])


def fetch_eastmoney_fund_dividends(code):
    """Fetch a fund's server-rendered F10 distribution history from Eastmoney."""
    from urllib.request import Request, urlopen
    if not (len(code) == 6 and code.isascii() and code.isdigit()): raise ValueError("invalid fund code")
    url = f"https://fundf10.eastmoney.com/fhsp_{code}.html"
    request = Request(url, headers={"Accept": "text/html", "User-Agent": "Mozilla/5.0 (compatible; GuanpanProNext/3)",
        "Referer": f"https://fund.eastmoney.com/{code}.html"})
    with urlopen(request, timeout=12) as response:
        if response.status != 200: raise OSError("fund dividend source unavailable")
        raw = response.read(3_000_000)
        charset = response.headers.get_content_charset() or "utf-8"
        body = raw.decode(charset, errors="replace")
    events = parse_eastmoney_fund_dividends(body, code)
    # A valid F10 page with an empty history is distinct from a block/error page.
    if "分红送配详情" not in body: raise ValueError("fund dividend page did not contain a validated history section")
    return events


def infer_adjustment_dividends(code, adjusted, raw):
    """Detect qfq/raw factor steps. Estimated only; never reported as confirmed cash."""
    if len(adjusted) < 60 or len(raw) < 60: return []
    raw_by_day = {row["date"]: Decimal(row["close"]) for row in raw}
    factors = []
    for row in adjusted:
        close = Decimal(row["close"]); raw_close = raw_by_day.get(row["date"])
        if close > 0 and raw_close and raw_close > 0: factors.append((row["date"], raw_close / close, close))
    candidates = []
    for before, after in zip(factors, factors[1:]):
        move = after[1] / before[1] - 1
        amount = (before[1] - after[1]) * after[2]
        # 两条硬约束，缺一条就会把「份额折算 / 数据源复权口径切换」当成分红：
        # 1. 复权因子跳变不能超过 -20%（真实分红很少超过 5%）；
        # 2. 单次每份分红不能超过前收盘价的 20%。
        if not (Decimal("-0.20") < move < Decimal("-0.0025")):
            continue
        if amount < Decimal("0.003") or amount > before[2] * Decimal("0.20"):
            continue
        candidates.append((after[0], amount))
    merged = []
    for day, amount in candidates:
        if merged and (date.fromisoformat(day) - date.fromisoformat(merged[-1][0])).days <= 8:
            merged[-1] = (day, merged[-1][1] + amount)
        else: merged.append((day, amount))
    return [{"code": code, "date": day, "amountPerShare": format(amount.normalize(), "f"), "isEstimated": True} for day, amount in merged]


# 分红识别规则版本。改动推断/过滤规则时 +1，NAS 上旧缓存会自动失效重抓。
# v2: 不分红的 ETF 不再用复权因子跳变硬推；单次每份分红不得超过前收 20%。
DIVIDEND_RULES_VERSION = 2


def fetch_dividend_events(code, daily_fetcher=fetch_tencent_daily, stock_fetcher=fetch_eastmoney_dividends,
                          fund_fetcher=fetch_eastmoney_fund_dividends):
    official = []; inferred = []; succeeded = False
    # Eastmoney's RPT_SHAREBONUS_DET is an A-share corporate-action feed. It is
    # not an ETF distribution feed: querying it for fund codes can mislabel an
    # unrelated share-bonus record as ETF cash income.
    is_etf_code = len(code) == 6 and code.isdigit() and code.startswith(("15", "16", "18", "50", "51", "52", "56", "58", "59"))
    if is_etf_code:
        fund_answered = False
        try:
            official = fund_fetcher(code); fund_answered = True; succeeded = True
        except Exception: pass
        # 三种情况要分开处理：
        # - 官方接口返回了记录   → 用价差补齐历史（历史更完整）；
        # - 官方接口成功但为空   → **不推断**。不分红的 ETF（半导体设备 560780 这类）
        #   在 qfq/raw 上同样会因为数据源复权口径或份额折算产生跳变，硬推会得出
        #   「每份分 2.6 元」，乘上价格就是 300% 股息率，直接把评分带偏；
        # - 官方接口报错（不知道有没有）→ 仍用价差推断兜底，总比完全没数据好。
        if official or not fund_answered:
            try:
                adjusted = daily_fetcher(code, "qfq"); raw = daily_fetcher(code, "raw")
                inferred = infer_adjustment_dividends(code, adjusted, raw); succeeded = True
            except Exception: pass
    else:
        try:
            official = stock_fetcher(code); succeeded = True
        except Exception: pass
        # 个股保留价差推断（用来补缺失的除权记录），但同样受上面的硬约束保护。
        try:
            adjusted = daily_fetcher(code, "qfq"); raw = daily_fetcher(code, "raw")
            inferred = infer_adjustment_dividends(code, adjusted, raw); succeeded = True
        except Exception: pass
    if not succeeded: raise OSError("all dividend data sources unavailable")
    values = {(item["code"], item["date"]): item for item in inferred}
    for item in official: values[(item["code"], item["date"])] = item
    return sorted(values.values(), key=lambda item: item["date"])

# --- 全球指数（网页版看板用） -------------------------------------------------
# 口径与 App 一致，2026-10-20 三源交叉验证过：
#   b_NDX 是 2025-09-26 的陈旧值，东财 100.NDX 实际是纳斯达克综合 —— 两者都不能用；
#   纳指 100 走 gb_$ndx（与腾讯 usNDX 一致）。
# 第三个元素是该指数在新浪 K 线接口里的代码，网页版点指数看历史曲线用。
INDEX_SYMBOLS = [
    ("s_sh000001", "上证指数", "sh000001"),
    ("gb_$ndx", "纳斯达克100", "gb_$ndx"),
    ("b_NKY", "日经225", "b_NKY"),
    ("b_KOSPI", "韩国KOSPI", "b_KOSPI"),
    ("rt_hkHSTECH", "恒生科技", "rt_hkHSTECH"),
]


def parse_indices(body):
    """解析新浪多行响应。只取数字字段，名称用本地固定表（响应是 GB18030）。"""
    found = {}
    for line in body.splitlines():
        start = line.find('hq_str_')
        eq = line.find('="')
        if start < 0 or eq < 0:
            continue
        symbol = line[start + 7:eq]
        end = line.rfind('";')
        if end <= eq:
            continue
        fields = line[eq + 2:end].split(',')
        quote = _parse_index_fields(symbol, fields)
        if quote:
            found[symbol] = quote
    return [dict(found[symbol], kline=kline) for symbol, _, kline in INDEX_SYMBOLS if symbol in found]


def _parse_index_fields(symbol, fields):
    def num(index):
        try:
            return float(fields[index])
        except (IndexError, ValueError):
            return None

    price = pct = close = stamp = None
    if symbol.startswith("gb_"):
        price, pct = num(1), num(2)
        stamp = fields[3] if len(fields) > 3 else None
    elif symbol.startswith("rt_hk"):
        close, price, pct = num(3), num(6), num(8)
        stamp = f"{fields[16]} {fields[17]}" if len(fields) > 17 else None
    elif symbol.startswith("b_"):
        price, pct = num(1), num(3)
        stamp = f"{fields[6]} {fields[5]}" if len(fields) > 6 else None
    else:
        price, pct = num(1), num(3)
    if not price or price <= 0:
        return None
    name = {item[0]: item[1] for item in INDEX_SYMBOLS}.get(symbol, symbol)
    return {"symbol": symbol, "name": name, "price": price,
            "changePercent": pct if pct is not None else 0.0,
            "previousClose": close, "observedAt": stamp}


def fetch_indices():
    query = ",".join(symbol for symbol, _, _ in INDEX_SYMBOLS)
    request = Request("https://hq.sinajs.cn/list=" + query,
                      headers={"Referer": "https://finance.sina.com.cn/",
                               "User-Agent": "Mozilla/5.0 (compatible; GuanpanNext/1)"})
    with urlopen(request, timeout=8) as response:
        body = response.read().decode("utf-8", "replace")
    quotes = parse_indices(body)
    if not quotes:
        raise ValueError("index source returned no parsable data")
    return quotes


def _valid_kline_symbol(symbol):
    if not isinstance(symbol, str) or not symbol or len(symbol) > 24:
        return False
    return all(ch.isalnum() or ch in "._$: " for ch in symbol)


def fetch_kline(symbol, datalen=320):
    """新浪日 K 历史（网页版点指数看曲线用）。与 A 股日 K 走不同接口，按原始符号转发。"""
    if not _valid_kline_symbol(symbol):
        raise ValueError("invalid kline symbol")
    url = ("https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/"
           "CN_MarketDataService.getKLineData?" + urlencode(
               {"symbol": symbol, "scale": 240, "ma": "no", "datalen": datalen}))
    request = Request(url, headers={"Referer": "https://finance.sina.com.cn/",
                                    "User-Agent": "Mozilla/5.0 (compatible; GuanpanNext/1)"})
    with urlopen(request, timeout=10) as response:
        body = response.read(4_000_000).decode("utf-8", "replace")
    try:
        rows = json.loads(body)
    except json.JSONDecodeError:
        raise ValueError("kline source returned undecodable data")
    if not isinstance(rows, list):
        raise ValueError("kline source returned unexpected shape")
    bars = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        try:
            day = str(row.get("day", ""))[:10]
            o, h, l, c = (float(row[k]) for k in ("open", "high", "low", "close"))
            v = float(row.get("volume") or 0)
        except (KeyError, ValueError, TypeError):
            continue
        if not (c > 0 and o > 0 and h > 0 and l > 0):
            continue
        bars.append({"date": day, "open": str(o), "high": str(h), "low": str(l),
                     "close": str(c), "volume": str(v)})
    if len(bars) < 2:
        raise ValueError("kline source returned no usable bars")
    return sorted(bars, key=lambda b: b["date"])

