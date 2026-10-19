"""Read-only Tencent quote adapter; no settlement or instrument type inference."""
from datetime import datetime, timezone
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
