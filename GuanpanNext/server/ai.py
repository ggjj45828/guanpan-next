"""Server-only DeepSeek connector. API keys never travel to iOS or the web UI."""
import json
import os
from urllib.request import Request, urlopen

PROFILES = {
    "flash": {"base": "https://api.deepseek.com", "model": "deepseek-flash"},
    "pro": {"base": "https://api.deepseek.com", "model": "deepseek-v4-pro"},
}


def profile_from_environment():
    name = os.environ.get("GUANPAN_AI_PROFILE", "flash").lower()
    if name in PROFILES: return PROFILES[name]
    if name == "custom":
        base = os.environ.get("GUANPAN_AI_BASE_URL", "").rstrip("/")
        model = os.environ.get("GUANPAN_AI_MODEL", "")
        if not base.startswith("https://") or not model or "/" in model:
            raise ValueError("custom AI profile requires HTTPS base URL and model name")
        return {"base": base, "model": model}
    raise ValueError("unknown AI profile")


def generate_research(factors, api_key=None, profile=None, opener=urlopen):
    api_key = os.environ.get("DEEPSEEK_API_KEY", "") if api_key is None else api_key
    if not api_key: return None
    profile = profile or profile_from_environment()
    prompt = {"security": factors["code"], "asOf": factors["asOf"],
              "source": factors["source"], "close": factors["close"],
              "ma20": factors["ma20"], "ma250": factors["ma250"],
              "momentum20": factors["momentum20"], "drawdown20": factors["drawdown20"]}
    payload = {"model": profile["model"], "stream": False, "max_tokens": 550,
               "messages": [
                   {"role": "system", "content": "你是投资研究助手。仅使用给定的有日期与来源的数据。区分事实、推断、风险和等待条件；缺失信息请说未知。不得声称已下单，不得凭空给出 IOPV、盘口或交易规则。用中文简洁回答。"},
                   {"role": "user", "content": json.dumps(prompt, ensure_ascii=False)}]}
    request = Request(profile["base"] + "/chat/completions",
                      data=json.dumps(payload, ensure_ascii=False).encode(), method="POST",
                      headers={"Authorization": "Bearer " + api_key, "Content-Type": "application/json", "Accept": "application/json"})
    with opener(request, timeout=35) as response:
        if response.status != 200: raise OSError("AI provider returned an error")
        result = json.loads(response.read(1_000_000))
    content = result["choices"][0]["message"]["content"]
    if not isinstance(content, str) or not content.strip(): raise ValueError("AI returned empty content")
    return {"code": factors["code"], "asOf": factors["asOf"], "source": factors["source"],
            "provider": "DeepSeek", "model": profile["model"], "content": content[:10000],
            "realOrder": False}
