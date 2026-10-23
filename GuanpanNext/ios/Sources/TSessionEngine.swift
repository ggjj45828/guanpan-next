import Foundation

/// 一次做T（日内回转）候选方案。
/// 全部数字由真实持仓 + 真实日K + 真实手续费算出；不允许任何硬编码示例价。
struct TSessionQuote {
    /// 卖出参考价（反T先卖 / 正T后卖）。
    let sellPrice: Decimal
    /// 买回参考价。
    let buyBackPrice: Decimal
    let units: Int
    /// 毛价差 =（卖出价 − 买回价）× 份额，未扣费。
    let gross: Decimal
    /// 手续费合计（卖出 + 买回 两笔）。
    let fees: Decimal
    /// 预计净收益 = 毛价差 − 手续费。
    let net: Decimal
    /// 等效降本：完成后持仓每份成本下降多少。
    let costReductionPerUnit: Decimal
    /// 等效降本占当前持仓成本的比例。
    let costReductionPercent: Double
}

struct TSessionPlan: Identifiable, Equatable {
    var id: String { code }
    let code: String
    let name: String
    /// 正T = 先买后卖（需现金，低吸高抛）；反T = 先卖后买（需底仓，高位卖出回落接回）。
    let direction: String
    let directionTitle: String
    /// 是否适合做T。
    let suitable: Bool
    /// 不适合时的原因（数据不足 / 状态不符 / 净收益不达标 …）。
    let blockers: [String]
    let quote: TSessionQuote?
    /// 现价与昨收。
    let lastPrice: Decimal
    let previousClose: Decimal
    /// 近20日日内振幅中位数（真实统计，决定价差的物理上限）。
    let amplitudeMedian: Double?
    /// 历史触及率：过去 lookback 天中，同时出现过卖出价与买回价的天数占比。
    let hitRate: Double?
    let hitLookbackDays: Int
    /// 有效期（日内T默认当日收盘）。
    let validUntil: Date
    /// 失效条件列表。
    let invalidation: [String]
    /// 风险说明。
    let risks: [String]
    /// 参与计算的证据行。
    let basis: [String]

    var netProfit: Decimal { quote?.net ?? 0 }
    var spreadPercent: Double {
        guard let q = quote, NextNum.double(q.buyBackPrice) > 0 else { return 0 }
        return (NextNum.double(q.sellPrice) / NextNum.double(q.buyBackPrice) - 1) * 100
    }
}

enum TSessionEngine {
    /// 价格最小变动（场内基金 0.001 元）。
    private static let tick: Decimal = Decimal(string: "0.001")!

    static func plan(code: String,
                     name: String,
                     position: NextPosition?,
                     lastPrice: Decimal,
                     previousClose: Decimal,
                     samples: [NextChartSample],
                     regime: MarketRegimeResult,
                     cash: Decimal,
                     feePerTrade: Decimal?,
                     lotSize: Int?,
                     preference: TSessionPreference,
                     now: Date = Date()) -> TSessionPlan {
        var blockers: [String] = []
        var basis: [String] = []
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }

        // ---- 0) 数据充分性：不足直接拒绝，不给伪精确价格 ----
        guard ordered.count >= MarketRegimeEngine.minimumSamples else {
            return TSessionPlan(code: code, name: name, direction: "none", directionTitle: "不做T", suitable: false,
                                blockers: ["历史日K只有 \(ordered.count) 根，少于 \(MarketRegimeEngine.minimumSamples) 根；不能估算可触及价差。"],
                                quote: nil, lastPrice: lastPrice, previousClose: previousClose, amplitudeMedian: nil,
                                hitRate: nil, hitLookbackDays: 0, validUntil: now, invalidation: [], risks: [], basis: [])
        }
        if regime.blocksPricePlan {
            blockers.append("市场状态为「\(regime.regime.title)」，数据完整度或新鲜度不达标；不给具体价格。")
        }
        guard lastPrice > 0, previousClose > 0 else {
            blockers.append("现价或昨收无效。")
            return TSessionPlan(code: code, name: name, direction: "none", directionTitle: "不做T", suitable: false, blockers: blockers,
                                quote: nil, lastPrice: lastPrice, previousClose: previousClose, amplitudeMedian: nil,
                                hitRate: nil, hitLookbackDays: 0, validUntil: now, invalidation: [], risks: [], basis: [])
        }
        guard let fee = feePerTrade, let lot = lotSize, lot > 0 else {
            blockers.append("该证券的交易单位或单笔手续费未核实，无法计算净收益。")
            return TSessionPlan(code: code, name: name, direction: "none", directionTitle: "不做T", suitable: false, blockers: blockers,
                                quote: nil, lastPrice: lastPrice, previousClose: previousClose, amplitudeMedian: nil,
                                hitRate: nil, hitLookbackDays: 0, validUntil: now, invalidation: [], risks: [], basis: [])
        }

        // ---- 1) 真实振幅统计：决定价差的物理上限 ----
        //  日内振幅 =（当日最高 − 当日最低）/ 前收。取近20日中位数，抗单点异常。
        let window = Array(ordered.suffix(20))
        var amplitudes: [Double] = []
        var riseToHigh: [Double] = []   // 当日最高相对前收的涨幅
        var fallFromHigh: [Double] = [] // 当日从最高回落到最低的幅度
        for i in 1..<window.count {
            let prev = window[i - 1]
            let cur = window[i]
            guard let h = cur.high, let l = cur.low else { continue }
            let pc = NextNum.double(prev.close)
            guard pc > 0 else { continue }
            let hi = NextNum.double(h), lo = NextNum.double(l)
            amplitudes.append((hi - lo) / pc)
            riseToHigh.append(hi / pc - 1)
            if hi > 0 { fallFromHigh.append((hi - lo) / hi) }
        }
        let ampMedian = median(amplitudes)
        // 取 60 分位的可达涨幅：比中位数乐观一点，但不用最大值（最大值不可复制）。
        let rise = percentile(riseToHigh, 0.60) ?? 0
        let fall = median(fallFromHigh) ?? 0
        basis.append("近20日日内振幅中位数 \(NextNum.percent(ampMedian ?? 0, digits: 2))；可达涨幅取60分位 \(NextNum.percent(rise, digits: 2))；高点后回落中位数 \(NextNum.percent(fall, digits: 2))。")

        // ---- 2) 方向选择：由区间位置与现金/底仓约束决定，不拍脑袋 ----
        let rangePos = regime.metrics.rangePosition ?? 0.5
        let heldUnits = position?.units ?? 0
        let canReverse = heldUnits >= lot                              // 有底仓才能先卖后买
        let canPositive = cash >= lastPrice * Decimal(lot)              // 有现金才能先买后卖
        var direction = "none"
        if canReverse && rangePos >= 0.45 {
            direction = "reverse"
        } else if canPositive {
            direction = "positive"
        } else if canReverse {
            direction = "reverse"
        }
        if direction == "none" {
            blockers.append("既没有足够底仓做反T（需 ≥\(lot) 份），也没有足够现金做正T。")
            return TSessionPlan(code: code, name: name, direction: "none", directionTitle: "不做T", suitable: false, blockers: blockers,
                                quote: nil, lastPrice: lastPrice, previousClose: previousClose, amplitudeMedian: ampMedian,
                                hitRate: nil, hitLookbackDays: 0, validUntil: now, invalidation: [], risks: [], basis: basis)
        }
        let directionTitle = direction == "reverse" ? "反T（先卖后买）" : "正T（先买后卖）"
        if direction == "reverse" {
            basis.append("现价处于近60日区间的 \(NextNum.percent(rangePos * 100, digits: 0)) 位置，且持有 \(heldUnits) 份底仓，优先反T：不占用现金，回落后接回即可降本。")
        } else {
            basis.append("现价处于近60日区间的 \(NextNum.percent(rangePos * 100, digits: 0)) 位置，现金可买入至少一手，采用正T：低吸后当日高抛。")
        }

        // ---- 3) 价格：由真实可达涨幅与回落幅度推出，再对齐最小变动位 ----
        let anchor = direction == "reverse" ? lastPrice : previousClose
        let rawSell = NextNum.double(anchor) * (1 + rise)
        let sellPrice = roundToTick(NextNum.decimal(rawSell))
        // 买回价：从卖出价按真实回落幅度的 60% 回撤（留 40% 余量，避免要求回落到当日最低才成交）
        let buyBackPrice = roundToTick(sellPrice * (1 - NextNum.decimal(fall * 0.6)))
        guard sellPrice > buyBackPrice, buyBackPrice > 0 else {
            blockers.append("按历史振幅算出的可触及价差不足以形成买卖两端。")
            return TSessionPlan(code: code, name: name, direction: direction, directionTitle: directionTitle, suitable: false, blockers: blockers,
                                quote: nil, lastPrice: lastPrice, previousClose: previousClose, amplitudeMedian: ampMedian,
                                hitRate: nil, hitLookbackDays: 0, validUntil: now, invalidation: [], risks: [], basis: basis)
        }
        basis.append("卖出参考 ¥\(NextMoney.text(sellPrice, digits: 3)) = 锚点 ¥\(NextMoney.text(anchor, digits: 3)) ×（1 + 可达涨幅 \(NextNum.percent(rise, digits: 2))）；买回 ¥\(NextMoney.text(buyBackPrice, digits: 3)) = 卖出价 ×（1 − 回落 \(NextNum.percent(fall * 0.6, digits: 2))）。")

        // ---- 4) 份额：受底仓 / 现金 / 偏好上限 约束，并取整到手 ----
        var unitsByCapital: Int
        if direction == "reverse" {
            unitsByCapital = heldUnits
        } else {
            let affordable = cash / (sellPrice > 0 ? lastPrice : lastPrice)
            let lots = NSDecimalNumber(decimal: affordable / (lastPrice * Decimal(lot))).intValue
            unitsByCapital = max(0, lots) * lot
        }
        var units = min(unitsByCapital, preference.maxUnitsPerSession ?? unitsByCapital)
        units = (units / lot) * lot
        if units <= 0 {
            blockers.append("按现金/持仓与偏好上限折算后不足一手（\(lot) 份）。")
            return TSessionPlan(code: code, name: name, direction: direction, directionTitle: directionTitle, suitable: false, blockers: blockers,
                                quote: nil, lastPrice: lastPrice, previousClose: previousClose, amplitudeMedian: ampMedian,
                                hitRate: nil, hitLookbackDays: 0, validUntil: now, invalidation: [], risks: [], basis: basis)
        }
        basis.append("份额 \(units) 份：\(direction == "reverse" ? "不超过底仓 \(heldUnits) 份" : "不超过现金可买手数")，取 \(lot) 份整数倍。")

        // ---- 5) 价差 / 手续费 / 净收益 ----
        let gross = (sellPrice - buyBackPrice) * Decimal(units)
        let fees = fee * 2
        let net = gross - fees
        let totalUnits = max(1, heldUnits)
        let costPerUnit = position?.costPerUnit ?? 0
        let costReductionPerUnit = net / Decimal(totalUnits)
        let costReductionPercent = costPerUnit > 0 ? NextNum.double(costReductionPerUnit / costPerUnit) * 100 : 0
        basis.append("毛价差 ¥\(NextMoney.text(gross, digits: 2)) =（¥\(NextMoney.text(sellPrice, digits: 3)) − ¥\(NextMoney.text(buyBackPrice, digits: 3))）× \(units)；手续费 ¥\(NextMoney.text(fees, digits: 2))（买卖两笔 × ¥\(NextMoney.text(fee, digits: 2))）；净收益 ¥\(NextMoney.text(net, digits: 2))。")

        // ---- 6) 历史触及率：过去 60 天里同时出现过这两个价格的天数 ----
        let lookback = Array(ordered.suffix(60))
        var hits = 0, evaluated = 0
        for i in 1..<lookback.count {
            let prev = lookback[i - 1]
            let cur = lookback[i]
            guard let h = cur.high, let l = cur.low else { continue }
            let pc = NextNum.double(prev.close)
            guard pc > 0 else { continue }
            evaluated += 1
            let needHigh = NextNum.double(sellPrice)
            let needLow = NextNum.double(buyBackPrice)
            if NextNum.double(h) >= needHigh && NextNum.double(l) <= needLow { hits += 1 }
        }
        let hitRate = evaluated > 0 ? Double(hits) / Double(evaluated) : nil
        if let hr = hitRate {
            basis.append("历史触及：过去 \(evaluated) 个交易日中有 \(hits) 天同时出现过卖出价与买回价（\(NextNum.percent(hr * 100, digits: 0))）；日K只有高低点，先后顺序不可知，实际需盯盘确认。")
        }

        // ---- 7) 画像门槛：净收益不达标就明确不推荐 ----
        let spreadPct = (NextNum.double(sellPrice) / NextNum.double(buyBackPrice) - 1) * 100
        if net < preference.minNetProfit {
            blockers.append("预计净收益 ¥\(NextMoney.text(net, digits: 2)) 低于你历史执行偏好的 ¥\(NextMoney.text(preference.minNetProfit, digits: 2))；机会存在但不主动推荐。")
        }
        if spreadPct < preference.minSpreadPercent {
            blockers.append("价差 \(NextNum.percent(spreadPct, digits: 2)) 低于你偏好的 \(NextNum.percent(preference.minSpreadPercent, digits: 2))。")
        }
        if !regime.regime.tsessionSuitable {
            blockers.append("当前市场状态为「\(regime.regime.title)」，不是做T的适配环境。")
        }
        // 异常波动时收紧：要求更高净收益
        if regime.regime == .abnormal && net < preference.minNetProfit * 2 {
            blockers.append("异常波动状态下要求双倍净收益门槛才建议动手。")
        }

        let suitable = blockers.isEmpty

        // ---- 8) 有效期与失效条件 ----
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 15; components.minute = 0; components.second = 0
        let validUntil = calendar.date(from: components) ?? now.addingTimeInterval(3600)

        var invalidation: [String] = []
        invalidation.append("当日收盘（\(Self.shortDate(validUntil)) 15:00）前未成交即失效。")
        invalidation.append("价格已高于 ¥\(NextMoney.text(sellPrice, digits: 3)) 而未卖出 → 本轮反T作废，不要追高卖出。")
        invalidation.append("价格跌破 ¥\(NextMoney.text(buyBackPrice, digits: 3)) 且尚未买回 → 视为降本成功，不要因继续下跌否定本轮。")
        if let amp = ampMedian {
            invalidation.append("当日振幅已超过近20日中位数 \(NextNum.percent(amp, digits: 2)) 的 1.2 倍 → 剩余空间已被用掉，不再追加。")
        }
        invalidation.append("出现重大公告/停牌/流动性骤降 → 立即作废并重新评估。")

        var risks: [String] = []
        risks.append("反T卖飞后价格不回落 → 踏空；可接受度按你的偏好设定为 \(NextNum.percent(preference.gapRiskTolerance * 100, digits: 0))。")
        if let hr = hitRate, hr < 0.3 { risks.append("历史触及率仅 \(NextNum.percent(hr * 100, digits: 0))，两个价格同日出现的概率偏低。") }
        if direction == "reverse" { risks.append("卖出份额不能超过底仓 \(heldUnits) 份，超出的部分无法当日买回。") }
        else { risks.append("正T占用现金 ¥\(NextMoney.text(lastPrice * Decimal(units), digits: 2))，若当日不回落，资金会被占用。") }
        risks.append("本方案只是价格与份额的计算结果，不会自动下单；是否成交由你手工决定。")

        let quote = TSessionQuote(sellPrice: sellPrice, buyBackPrice: buyBackPrice, units: units, gross: gross, fees: fees,
                                  net: net, costReductionPerUnit: costReductionPerUnit, costReductionPercent: costReductionPercent)
        return TSessionPlan(code: code, name: name, direction: direction, directionTitle: directionTitle, suitable: suitable,
                            blockers: blockers, quote: quote, lastPrice: lastPrice, previousClose: previousClose,
                            amplitudeMedian: ampMedian, hitRate: hitRate, hitLookbackDays: evaluated,
                            validUntil: validUntil, invalidation: invalidation, risks: risks, basis: basis)
    }

    // MARK: - 工具

    private static func roundToTick(_ value: Decimal) -> Decimal {
        guard value > 0 else { return 0 }
        var raw = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 3, .plain)
        return rounded
    }
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return percentile(values, 0.5)
    }
    private static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[max(0, min(sorted.count - 1, idx))]
    }
    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }
}
