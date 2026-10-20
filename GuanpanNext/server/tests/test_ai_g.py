import json
import unittest
from datetime import date, timedelta
from io import BytesIO
from urllib.error import HTTPError

from ai import AIProviderError, generate_g_twin_plan


class Response:
    status = 200
    def __init__(self, body): self.body = body
    def __enter__(self): return self
    def __exit__(self, *_): return None
    def read(self, _limit): return json.dumps({"choices": [{"message": {"content": json.dumps(self.body)}}]}).encode()


def context():
    start = date(2025, 1, 1)
    bars = []
    for index in range(390):
        day = start + timedelta(days=index)
        if day.weekday() >= 5: continue
        bars.append({"date": day.isoformat(), "open": "1.0", "high": "1.1", "low": "0.9", "close": "1.0", "volume": "100"})
    as_of = bars[-1]["date"]
    return {"asOf": as_of, "codes": ["159941"], "dailyBars": {"159941": bars}, "cash": "1000",
            "positions": {"159941": 0}, "currentWeights": {"159941": "0"}, "baseWeights": {"159941": "0.8"}}


class DeepSeekGPlanTests(unittest.TestCase):
    def body(self, ctx, weight="0.7"):
        return {"asOf": ctx["asOf"], "targetWeights": {"159941": weight}, "summary": "按趋势和回撤调整虚拟仓位",
                "risks": ["日 K 无法反映盘口深度"], "invalidators": ["历史数据过期"]}

    def test_validated_plan_is_provider_attributed_and_non_trading(self):
        ctx = context()
        result = generate_g_twin_plan(ctx, api_key="fake", profile={"base": "https://unit.test", "model": "test"},
            opener=lambda *_a, **_kw: Response(self.body(ctx)))
        self.assertEqual(result["provider"], "DeepSeek")
        self.assertEqual(result["targetWeights"]["159941"], "0.7")
        self.assertFalse(result["realOrder"])

    def test_missing_key_or_bad_model_weights_do_not_create_a_decision(self):
        ctx = context()
        with self.assertRaises(AIProviderError): generate_g_twin_plan(ctx, api_key="")
        with self.assertRaises(AIProviderError):
            generate_g_twin_plan(ctx, api_key="fake", profile={"base": "https://unit.test", "model": "test"},
                opener=lambda *_a, **_kw: Response(self.body(ctx, "1.1")))

    def test_rejects_unaligned_or_malformed_historical_bars_before_network(self):
        ctx = context()
        ctx["dailyBars"]["159941"][-1]["date"] = "2020-01-01"
        with self.assertRaises(ValueError):
            generate_g_twin_plan(ctx, api_key="fake", profile={"base": "https://unit.test", "model": "test"},
                                 opener=lambda *_a, **_kw: self.fail("must reject before API call"))

    def test_twelve_security_payload_uses_compact_real_daily_history(self):
        ctx = context()
        codes = [f"1599{i:02d}" for i in range(12)]
        ctx["codes"] = codes
        ctx["dailyBars"] = {code: list(ctx["dailyBars"]["159941"]) for code in codes}
        ctx["positions"] = {code: 0 for code in codes}
        ctx["currentWeights"] = {code: "0" for code in codes}
        ctx["baseWeights"] = {code: "0.05" for code in codes}
        body = {"asOf": ctx["asOf"], "targetWeights": {code: "0.05" for code in codes},
                "summary": "分散配置", "risks": ["无法观察盘口"], "invalidators": ["历史行情过期"]}
        captured = {}
        def opener(request, **_kwargs):
            captured["payload"] = json.loads(request.data)
            return Response(body)
        result = generate_g_twin_plan(ctx, api_key="fake", profile={"base": "https://unit.test", "model": "test"}, opener=opener)
        packed = captured["payload"]["messages"][1]["content"]
        model_ctx = json.loads(packed)["context"]
        self.assertLess(len(packed.encode()), 220_000)
        self.assertEqual(len(model_ctx["dailyBars"][codes[0]]), 250)
        self.assertEqual(len(model_ctx["dailyBars"][codes[0]][0]), 6)
        self.assertEqual(len(result["targetWeights"]), 12)


if __name__ == "__main__": unittest.main()
