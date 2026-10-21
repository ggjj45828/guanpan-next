"""NAS-side DeepSeek connector. The NAS key never travels to iOS or the web UI."""
import json
import os
from datetime import date
from decimal import Decimal, InvalidOperation
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# DeepSeek 现行模型名（deepseek-chat / deepseek-reasoner 已于 2026-07-24 停用）。
# flash 用 deepseek-v4-flash，pro 用 deepseek-v4-pro；写成 deepseek-flash 会直接 400。
PROFILES = {
    "flash": {"base": "https://api.deepseek.com", "model": "deepseek-v4-flash"},
    "pro": {"base": "https://api.deepseek.com", "model": "deepseek-v4-pro"},
}


def profile_from_environment():
    name = os.environ.get("GUANPAN_AI_PROFILE", "flash").strip().lower()
    if name in PROFILES: return PROFILES[name]
    if name == "custom":
        base = os.environ.get("GUANPAN_AI_BASE_URL", "").rstrip("/")
        model = os.environ.get("GUANPAN_AI_MODEL", "")
        if not base.startswith("https://") or not model or "/" in model:
            raise ValueError("custom AI profile requires HTTPS base URL and model name")
        return {"base": base, "model": model}
    raise ValueError("unknown AI profile")


def provider_status():
    """Report safe configuration metadata; never reveal or partially echo the API key."""
    key_configured = bool(os.environ.get("DEEPSEEK_API_KEY", "").strip())
    name = os.environ.get("GUANPAN_AI_PROFILE", "flash").strip().lower()
    try:
        profile = profile_from_environment()
    except ValueError:
        return {"state": "invalid_profile", "configured": key_configured,
                "profile": name, "model": None, "message": "AI 配置档案无效"}
    if not key_configured:
        return {"state": "missing_key", "configured": False,
                "profile": name, "model": profile["model"], "message": "NAS 尚未配置 DeepSeek API key"}
    return {"state": "configured_unverified", "configured": True,
            "profile": name, "model": profile["model"], "message": "key 已配置；真实可用性需等待一次模型请求验证"}


class AIProviderError(OSError):
    def __init__(self, category):
        self.category = category
        super().__init__(category)


def verify_provider(opener=urlopen):
    """Perform an explicit, minimal connectivity probe without sending portfolio data."""
    api_key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if not api_key: raise AIProviderError("NAS 尚未配置 DeepSeek API key")
    try: profile = profile_from_environment()
    except ValueError as error: raise AIProviderError("DeepSeek 模型配置无效") from error
    payload = {"model": profile["model"], "stream": False, "max_tokens": 8,
               "messages": [{"role": "user", "content": "Reply with OK only."}]}
    request = Request(profile["base"] + "/chat/completions",
                      data=json.dumps(payload).encode(), method="POST",
                      headers={"Authorization": "Bearer " + api_key,
                               "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with opener(request, timeout=20) as response:
            result = json.loads(response.read(1_000_000))
            content = result["choices"][0]["message"]["content"]
            if response.status != 200 or not isinstance(content, str) or not content.strip():
                raise AIProviderError("DeepSeek 探针响应无效")
    except HTTPError as error:
        if error.code in (401, 403): category = "DeepSeek key 无效或无权限"
        elif error.code == 429: category = "DeepSeek 请求频率或额度受限"
        elif error.code >= 500: category = "DeepSeek 服务暂时异常"
        else: category = f"DeepSeek HTTP {error.code}"
        raise AIProviderError(category) from None
    except (URLError, TimeoutError) as error:
        reason = getattr(error, "reason", None)
        category = "DeepSeek 请求超时" if isinstance(reason, TimeoutError) or isinstance(error, TimeoutError) else "DeepSeek 网络连接失败"
        raise AIProviderError(category) from None
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        raise AIProviderError("DeepSeek 探针响应格式无效") from error
    return {"state": "verified", "profile": os.environ.get("GUANPAN_AI_PROFILE", "flash").strip().lower(),
            "model": profile["model"], "message": "DeepSeek 连通性验证成功"}


def generate_research(factors, api_key=None, profile=None, opener=urlopen):
    api_key = os.environ.get("DEEPSEEK_API_KEY", "") if api_key is None else api_key
    api_key = api_key.strip() if isinstance(api_key, str) else ""
    if not api_key: return None
    profile = profile or profile_from_environment()
    prompt = {"security": factors["code"], "asOf": factors["asOf"],
              "source": factors["source"], "close": factors["close"],
              "ma20": factors["ma20"], "ma250": factors["ma250"],
              "momentum20": factors["momentum20"], "drawdown20": factors["drawdown20"]}
    payload = {"model": profile["model"], "stream": False, "max_tokens": 900,
               "messages": [
                   {"role": "system", "content": "你是投资研究助手。仅使用给定的有日期与来源的数据。区分事实、推断、风险和等待条件；缺失信息请说未知。不得声称已下单，不得凭空给出 IOPV、盘口或交易规则。用中文简洁回答。"},
                   {"role": "user", "content": json.dumps(prompt, ensure_ascii=False)}]}
    request = Request(profile["base"] + "/chat/completions",
                      data=json.dumps(payload, ensure_ascii=False).encode(), method="POST",
                      headers={"Authorization": "Bearer " + api_key, "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with opener(request, timeout=35) as response:
            if response.status != 200: raise AIProviderError("AI 服务返回异常状态")
            result = json.loads(response.read(1_000_000))
    except HTTPError as error:
        if error.code in (401, 403): category = "DeepSeek key 无效或无权限"
        elif error.code == 429: category = "DeepSeek 请求频率或额度受限"
        elif error.code >= 500: category = "DeepSeek 服务暂时异常"
        else: category = f"DeepSeek HTTP {error.code}"
        raise AIProviderError(category) from None
    except (URLError, TimeoutError) as error:
        reason = getattr(error, "reason", None)
        if isinstance(reason, TimeoutError) or isinstance(error, TimeoutError): category = "DeepSeek 请求超时"
        else: category = "DeepSeek 网络连接失败"
        raise AIProviderError(category) from None
    except json.JSONDecodeError as error:
        raise AIProviderError("DeepSeek 返回内容无法解析") from error
    content = result["choices"][0]["message"]["content"]
    if not isinstance(content, str) or not content.strip(): raise AIProviderError("DeepSeek 返回空内容")
    return {"code": factors["code"], "asOf": factors["asOf"], "source": factors["source"],
            "provider": "DeepSeek", "model": profile["model"], "content": content[:10000],
            "realOrder": False}


def analyze_user_context(context, api_key=None, profile=None, opener=urlopen):
    """On-demand, user-authorized ETF analysis; accepts only explicit research facts.

    The caller must disclose this transfer in the app. No credentials or real
    broker/order fields are accepted in the context schema.
    """
    if not isinstance(context, dict) or set(context) != {"security", "dailyBars", "position", "allPositions", "cash", "recentFills", "goal", "dividends"}:
        raise ValueError("analysis context schema is invalid")
    security = context["security"]
    if not isinstance(security, dict) or set(security) - {"code", "name", "price", "previousClose", "iopv", "quoteTime", "source", "technical", "targetWeight"}:
        raise ValueError("security context is invalid")
    code = security.get("code")
    if not isinstance(code, str) or len(code) != 6 or not code.isdigit():
        raise ValueError("security code is invalid")
    if not isinstance(context["dailyBars"], list) or len(context["dailyBars"]) > 250:
        raise ValueError("daily history must contain at most 250 bars")
    for row in context["dailyBars"]:
        if not isinstance(row, dict) or set(row) != {"date", "open", "high", "low", "close", "volume"} or not isinstance(row["date"], str) or not isinstance(row["close"], str):
            raise ValueError("daily history row is invalid")
    if not isinstance(context["allPositions"], list) or len(context["allPositions"]) > 100:
        raise ValueError("portfolio may contain at most 100 securities")
    position_fields = {"code", "name", "units", "bookCost", "costPerUnit", "lastPrice", "currentWeight", "targetWeight"}
    for row in context["allPositions"]:
        if not isinstance(row, dict) or set(row) != position_fields or not isinstance(row.get("code"), str) or len(row["code"]) != 6 or not row["code"].isdigit():
            raise ValueError("portfolio position row is invalid")
    if not isinstance(context["recentFills"], list) or len(context["recentFills"]) > 30:
        raise ValueError("recent fills must contain at most 30 rows")
    for fill in context["recentFills"]:
        if not isinstance(fill, dict) or set(fill) != {"date", "side", "units", "price", "fee"}:
            raise ValueError("recent fill row is invalid")
    if not isinstance(context["dividends"], list) or len(context["dividends"]) > 30:
        raise ValueError("dividend history must contain at most 30 rows")
    if not isinstance(context["goal"], dict) or set(context["goal"]) != {"years", "monthlyBudget", "concentrationLimit", "targetWeights"}:
        raise ValueError("investment goal is invalid")
    if context["position"] is not None and (not isinstance(context["position"], dict) or set(context["position"]) != {"units", "bookCost", "costPerUnit", "currentWeight"}):
        raise ValueError("position context is invalid")
    if not isinstance(context["cash"], str): raise ValueError("cash context is invalid")
    encoded = json.dumps(context, ensure_ascii=False, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > 30000:
        raise ValueError("analysis context exceeds 30 KB")
    api_key = os.environ.get("DEEPSEEK_API_KEY", "") if api_key is None else api_key
    api_key = api_key.strip() if isinstance(api_key, str) else ""
    if not api_key: raise AIProviderError("NAS 尚未配置 DeepSeek API key")
    profile = profile or profile_from_environment()
    payload = {"model": profile["model"], "stream": False, "max_tokens": 1200,
        "messages": [
            {"role": "system", "content": "你是谨慎的 ETF 私人投资研究助手。用户已明确请求本次分析，并同意将下面精简后的单证券数据发送给模型。只使用提供的数据；区分结论、事实依据、推断、风险、建议观察区间、等待/分档方案和失效条件。不可把分析转换为真实委托，不可假造缺失的 IOPV、盘口、交易规则、价格目标或收益。历史 K 线不代表未来。若缺少数据或可靠估值依据，必须明确说不能给出合理买价。"},
            {"role": "user", "content": encoded}
        ]}
    request = Request(profile["base"] + "/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode(), method="POST",
        headers={"Authorization": "Bearer " + api_key, "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with opener(request, timeout=45) as response:
            if response.status != 200: raise AIProviderError("AI 服务返回异常状态")
            result = json.loads(response.read(1_000_000))
    except HTTPError as error:
        if error.code in (401, 403): category = "DeepSeek key 无效或无权限"
        elif error.code == 429: category = "DeepSeek 请求频率或额度受限"
        elif error.code >= 500: category = "DeepSeek 服务暂时异常"
        else: category = f"DeepSeek HTTP {error.code}"
        raise AIProviderError(category) from None
    except (URLError, TimeoutError) as error:
        reason = getattr(error, "reason", None)
        category = "DeepSeek 请求超时" if isinstance(reason, TimeoutError) or isinstance(error, TimeoutError) else "DeepSeek 网络连接失败"
        raise AIProviderError(category) from None
    except json.JSONDecodeError as error:
        raise AIProviderError("DeepSeek 返回内容无法解析") from error
    try: content = result["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as error: raise AIProviderError("DeepSeek 返回格式无效") from error
    if not isinstance(content, str) or not content.strip(): raise AIProviderError("DeepSeek 返回空内容")
    return {"code": code, "provider": "DeepSeek", "model": profile["model"], "content": content[:16000], "realOrder": False}


def generate_g_twin_plan(context, api_key=None, profile=None, opener=urlopen):
    """Request a constrained G virtual-portfolio allocation, never a broker order."""
    required = {"asOf", "codes", "dailyBars", "cash", "positions", "currentWeights", "baseWeights"}
    if not isinstance(context, dict) or set(context) != required:
        raise ValueError("G simulation context schema is invalid")
    codes = context["codes"]
    if not isinstance(codes, list) or not 1 <= len(codes) <= 12 or any(not isinstance(code, str) or len(code) != 6 or not code.isascii() or not code.isdigit() for code in codes) or len(set(codes)) != len(codes):
        raise ValueError("G simulation codes are invalid")
    try:
        date.fromisoformat(context["asOf"])
        cash = Decimal(str(context["cash"]))
        if not cash.is_finite() or cash < 0: raise ValueError
    except (TypeError, ValueError, InvalidOperation):
        raise ValueError("G session date or virtual cash is invalid") from None
    if not isinstance(context["dailyBars"], dict) or set(context["dailyBars"]) != set(codes):
        raise ValueError("G daily bars must cover every configured security")
    for code in codes:
        bars = context["dailyBars"][code]
        if not isinstance(bars, list) or not 250 <= len(bars) <= 640: raise ValueError("G needs 250–640 real daily bars per security")
        prior_date = None
        for row in bars:
            if not isinstance(row, dict) or set(row) != {"date", "open", "high", "low", "close", "volume"}:
                raise ValueError("G daily bar schema is invalid")
            try:
                date.fromisoformat(row["date"])
                values = {key: Decimal(str(row[key])) for key in ("open", "high", "low", "close", "volume")}
                if (any(not value.is_finite() for value in values.values()) or
                    min(values[k] for k in ("open", "high", "low", "close")) <= 0 or values["volume"] < 0 or
                    values["low"] > min(values["open"], values["close"]) or values["high"] < max(values["open"], values["close"]) or
                    (prior_date is not None and row["date"] <= prior_date)):
                    raise ValueError
            except (TypeError, ValueError, InvalidOperation):
                raise ValueError("G daily bar values or ordering are invalid") from None
            prior_date = row["date"]
        if bars[-1].get("date") != context["asOf"]: raise ValueError("G daily history is not aligned to its session date")
    if not isinstance(context["positions"], dict) or set(context["positions"]) != set(codes) or any(type(context["positions"][c]) is not int or context["positions"][c] < 0 for c in codes): raise ValueError("G virtual positions are invalid")
    for key in ("currentWeights", "baseWeights"):
        mapping = context[key]
        if not isinstance(mapping, dict) or set(mapping) != set(codes): raise ValueError(f"G {key} are invalid")
        try:
            values = [Decimal(str(mapping[code])) for code in codes]
            if any(not value.is_finite() or value < 0 for value in values) or sum(values, Decimal(0)) > Decimal("1.000001"): raise ValueError
        except (InvalidOperation, TypeError, ValueError):
            raise ValueError(f"G {key} are invalid") from None
    encoded = json.dumps(context, ensure_ascii=False, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > 600_000: raise ValueError("G research context exceeds 600 KB")
    api_key = os.environ.get("DEEPSEEK_API_KEY", "") if api_key is None else api_key
    api_key = api_key.strip() if isinstance(api_key, str) else ""
    if not api_key: raise AIProviderError("NAS 尚未配置 DeepSeek API key；G 本日模拟未运行")
    profile = profile or profile_from_environment()
    schema = {"asOf": context["asOf"], "targetWeights": {code: "decimal string from 0 to 1" for code in codes},
              "summary": "short Chinese explanation", "risks": ["data-grounded risk"],
              "invalidators": ["observable condition that invalidates the plan"]}
    # Send a compact representation of the latest 250 validated daily bars so
    # a full 12-security account stays within a practical provider context.
    model_context = {key: value for key, value in context.items() if key != "dailyBars"}
    model_context["dailyBars"] = {code: [[row[k] for k in ("date", "open", "high", "low", "close", "volume")]
                                         for row in context["dailyBars"][code][-250:]] for code in codes}
    payload = {"model": profile["model"], "stream": False, "max_tokens": 1100,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": "你是 G 数字孪生的 AI 研究员。只可使用输入中的真实日 K、虚拟账户和规则，不得声称真实下单。dailyBars 每条按 [date,open,high,low,close,volume] 排列。必须只返回符合指定 JSON 结构的对象。目标权重必须是 0 到 1 的字符串，所有权重之和不得超过 1，剩余资金留在虚拟现金。不得输出虚构价格、盘口、成交或交易制度。数据不足时保持现金权重（所有证券目标权重为 0），并在 risks 说明缺口。"},
            {"role": "user", "content": json.dumps({"context": model_context, "requiredOutput": schema}, ensure_ascii=False, separators=(",", ":"))}
        ]}
    request = Request(profile["base"] + "/chat/completions", data=json.dumps(payload, ensure_ascii=False).encode(),
        method="POST", headers={"Authorization": "Bearer " + api_key, "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with opener(request, timeout=45) as response:
            if response.status != 200: raise AIProviderError("DeepSeek G 研究返回异常状态")
            result = json.loads(response.read(1_000_000))
        content = result["choices"][0]["message"]["content"]
        if not isinstance(content, str): raise AIProviderError("DeepSeek G 研究响应无效")
        body = json.loads(content)
    except HTTPError as error:
        if error.code in (401, 403): category = "DeepSeek key 无效或无权限"
        elif error.code == 429: category = "DeepSeek 请求频率或额度受限"
        elif error.code >= 500: category = "DeepSeek 服务暂时异常"
        else: category = f"DeepSeek HTTP {error.code}"
        raise AIProviderError(category) from None
    except (URLError, TimeoutError) as error:
        reason = getattr(error, "reason", None)
        category = "DeepSeek 请求超时" if isinstance(reason, TimeoutError) or isinstance(error, TimeoutError) else "DeepSeek 网络连接失败"
        raise AIProviderError(category) from None
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        raise AIProviderError("DeepSeek G 研究返回格式无效") from error
    if not isinstance(body, dict) or set(body) != {"asOf", "targetWeights", "summary", "risks", "invalidators"}:
        raise AIProviderError("DeepSeek G 研究缺少必需字段")
    if body["asOf"] != context["asOf"] or not isinstance(body["targetWeights"], dict) or set(body["targetWeights"]) != set(codes):
        raise AIProviderError("DeepSeek G 研究日期或证券代码不匹配")
    weights = {}
    try:
        for code in codes:
            value = Decimal(str(body["targetWeights"][code]))
            if not value.is_finite() or value < 0 or value > 1: raise ValueError
            weights[code] = format(value, "f")
    except (InvalidOperation, ValueError, TypeError):
        raise AIProviderError("DeepSeek G 研究目标权重无效") from None
    if sum((Decimal(value) for value in weights.values()), Decimal(0)) > Decimal("1.000001"):
        raise AIProviderError("DeepSeek G 研究目标权重合计超过 100%")
    for key in ("summary",):
        if not isinstance(body[key], str) or not body[key].strip() or len(body[key]) > 2000:
            raise AIProviderError("DeepSeek G 研究说明无效")
    for key in ("risks", "invalidators"):
        if not isinstance(body[key], list) or not 1 <= len(body[key]) <= 8 or any(not isinstance(x, str) or not x.strip() or len(x) > 400 for x in body[key]):
            raise AIProviderError("DeepSeek G 研究风险或失效条件无效")
    return {**body, "targetWeights": weights, "provider": "DeepSeek", "model": profile["model"], "realOrder": False}
