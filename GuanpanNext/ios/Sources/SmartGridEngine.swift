import Foundation

struct GridRung: Identifiable, Equatable {
    var id: Int { level }
    let level: Int
    let price: Decimal
    let units: Int
    /// buy = 回落到该价买入；sell = 涨到该价卖出。
    let side: String
    let capital: Decimal
    /// 该档成交并走到相邻档后的预计净收益（已扣两笔手续费）。
    let netIfFilled: Decimal
}

struct SmartGridPlan: Identifiable, Equatable {
    var id: String { code }
    let code: String
    let name: String
    let suitable: Bool
    let blockers: [String]
    let lower: Decimal
    let upper: Decimal
    /// 档距百分比（相邻档价差 / 现价）。
    let stepPercent: Double
    let rungs: [GridRung]
    /// 所有买入档占用的资金合计。
    let totalCapital: Decimal
    /// 单档成交后走到相邻档的净收益（代表性值）。
    let netPerRung: Decimal
    /// 全部买入档都成交并各走一格的合计净收益。
    let netIfAllFilled: Decimal
    let breakoutPolicy: [String]
    let basis: [String]
    let lastPrice: Decimal

    var buyRungCount: Int { rungs.filter { $0.side == "buy" }.count }
    var sellRungCount: Int { rungs.filter { $0.side == "sell" }.count }
}

enum SmartGridEngine {
    private static let minimumSamples = 60

    static func plan(code: String,
                     name: String,
                     lastPrice: Decimal,
                     samples: [NextChartSample],
                     regime: MarketRegimeResult,
                     cash: Decimal,
                     heldUnits: Int,
                     feePerTrade: Decimal?,
                     lotSize: Int?,
                     preference: GridPreference,
                     now: Date = Date()) -> SmartGridPlan {
        var blockers: [String] = []
        var basis: [String] = []
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let empty = SmartGridPlan(code: code, name: name, suitable: false, blockers: [], lower: 0, upper: 0, stepPercent: 0,
                                  rungs: [], totalCapital: 0, netPerRung: 0, netIfAllFilled: 0, breakoutPolicy: [], basis: [], lastPrice: lastPrice)

        guard ordered.count >= minimumSamples else {
            return SmartGridPlan(code: code, name: name, suitable: false,
                                 blockers: ["历史日K只有 \(ordered.count) 根，少于 \(minimumSamples) 根；无法确定网格区间。"],
                                 lower: 0, upper: 0, stepPercent: 0, rungs: [], totalCapital: 0, netPerRung: 0,
                                 netIfAllFilled: 0, breakoutPolicy: [], basis: [], lastPrice: lastPrice)
        }
        guard lastPrice > 0 else {
            return SmartGridPlan(code: code, name: name, suitable: false, blockers: ["现价无效。"],
                                 lower: 0, upper: 0, stepPercent: 0, rungs: [], totalCapital: 0, netPerRung: 0,
                                 netIfAllFilled: 0, breakoutPolicy: [], basis: [], lastPrice: lastPrice)
        }
        guard let fee = feePerTrade, let lot = lotSize, lot > 0 else {
            return SmartGridPlan(code: code, name: name, suitable: false,
                                 blockers: ["该证券的交易单位或单笔手续费未核实，无法计算每档净收益。"],
                                 lower: 0, upper: 0, stepPercent: 0, rungs: [], totalCapital: 0, netPerRung: 0,
                                 netIfAllFilled: 0, breakoutPolicy: [], basis: [], lastPrice: lastPrice)
        }

        // ---- 1) 区间：近120日收盘分位数，而不是拍脑袋的整数关口 ----
        let closes = ordered.suffix(120).map { NextNum.double($0.close) }
        let p15 = percentile(closes, 0.15) ?? NextNum.double(lastPrice) * 0.9
        let p85 = percentile(closes, 0.85) ?? NextNum.double(lastPrice) * 1.1
        var lowerD = min(p15, NextNum.double(lastPrice) * 0.92)
        var upperD = max(p85, NextNum.double(lastPrice) * 1.08)
        // 宽网格偏好：把区间按偏好放大
        if preference.preferWideGrid == true {
            let mid = (lowerD + upperD) / 2
            lowerD = mid - (mid - lowerD) * 1.35
            upperD = mid + (upperD - mid) * 1.35
        }
        if upperD <= lowerD { upperD = lowerD * 1.06 }
        let lower = round3(NextNum.decimal(lowerD))
        let upper = round3(NextNum.decimal(upperD))
        basis.append("区间 ¥\(NextMoney.text(lower, digits: 3)) – ¥\(NextMoney.text(upper, digits: 3))：取近120日收盘的 15%/85% 分位，并保证覆盖现价上下 8%。")

        // ---- 2) 档距下限：必须让每档扣费后仍有余量 ----
        //  每档净收益 = 档距金额 × 份额 − 2×手续费。要求净收益 ≥ 手续费的 3 倍且 ≥ 偏好下限。
        let atr = regime.metrics.atr20Percent ?? 0.015
        var stepD = max(atr * 0.8, 0.004)
        // 用「每档资金」反推份额，再验证净收益是否达标；不达标就加大档距。
        let usableCapital = cash * NextNum.decimal(max(0.05, min(1.0, preference.maxCapitalRatio)))
        var rungCount = 0
        var unitsPerRung = 0
        var stepPrice = Decimal(0)
        var netPerRung = Decimal(0)
        for attempt in 0..<12 {
            let spanD = upperD - lowerD
            let stepPriceD = NextNum.double(lastPrice) * stepD
            let raw = Int((spanD / max(stepPriceD, 1e-9)).rounded())
            rungCount = min(max(raw, 3), max(3, preference.maxRungs))
            let buyRungs = max(1, rungCount / 2)
            stepPrice = round3(NextNum.decimal(stepPriceD))
            let perRungCapital = usableCapital / Decimal(buyRungs)
            let lots = NSDecimalNumber(decimal: perRungCapital / max(lastPrice * Decimal(lot), Decimal(string: "0.001")!)).intValue
            unitsPerRung = max(0, lots) * lot
            if unitsPerRung < lot {
                stepD *= 1.25
                continue
            }
            let gross = stepPrice * Decimal(unitsPerRung)
            netPerRung = gross - fee * 2
            let minimum = max(fee * 3, preference.minNetPerRung)
            if netPerRung >= minimum || attempt == 11 { break }
            stepD *= 1.2
        }
        if unitsPerRung < lot {
            blockers.append("可用现金 ¥\(NextMoney.text(usableCapital, digits: 2))（按偏好最多占用 \(NextNum.percent(preference.maxCapitalRatio * 100, digits: 0))）拆到各档后不足一手（\(lot) 份）。")
            return SmartGridPlan(code: code, name: name, suitable: false, blockers: blockers, lower: lower, upper: upper,
                                 stepPercent: stepD * 100, rungs: [], totalCapital: 0, netPerRung: 0, netIfAllFilled: 0,
                                 breakoutPolicy: [], basis: basis, lastPrice: lastPrice)
        }
        basis.append("档距 \(NextNum.percent(stepD * 100, digits: 2))（≈¥\(NextMoney.text(stepPrice, digits: 3))）：取近20日真实波幅 \(NextNum.percent(atr, digits: 2)) 的 0.8 倍，并反复放大直到每档净收益覆盖手续费。")

        // ---- 3) 生成档位：现价以下为买入档，以上为卖出档 ----
        let priceD = NextNum.double(lastPrice)
        var buyPrices: [Decimal] = []
        var sellPrices: [Decimal] = []
        var cursor = priceD - NextNum.double(stepPrice)
        while cursor >= lowerD, buyPrices.count < 20 {
            buyPrices.append(round3(NextNum.decimal(cursor)))
            cursor -= NextNum.double(stepPrice)
        }
        cursor = priceD + NextNum.double(stepPrice)
        while cursor <= upperD, sellPrices.count < 20 {
            sellPrices.append(round3(NextNum.decimal(cursor)))
            cursor += NextNum.double(stepPrice)
        }
        // 卖出档不能超过底仓（没有底仓就只有买入档）
        let maxSellUnits = max(0, heldUnits)
        var rungs: [GridRung] = []
        var level = 1
        var totalCapital: Decimal = 0
        var totalNet: Decimal = 0
        for price in buyPrices.sorted(by: >) {
            let capital = price * Decimal(unitsPerRung)
            let net = stepPrice * Decimal(unitsPerRung) - fee * 2
            rungs.append(GridRung(level: level, price: price, units: unitsPerRung, side: "buy", capital: capital, netIfFilled: net))
            totalCapital += capital
            totalNet += net
            level += 1
        }
        for price in sellPrices.sorted() {
            let sellUnits = min(unitsPerRung, maxSellUnits)
            if sellUnits < lot { continue }
            let net = stepPrice * Decimal(sellUnits) - fee * 2
            rungs.append(GridRung(level: level, price: price, units: sellUnits, side: "sell", capital: 0, netIfFilled: net))
            totalNet += net
            level += 1
        }
        if rungs.isEmpty {
            blockers.append("按当前价格与区间无法生成任何有效档位。")
            return SmartGridPlan(code: code, name: name, suitable: false, blockers: blockers, lower: lower, upper: upper,
                                 stepPercent: stepD * 100, rungs: [], totalCapital: 0, netPerRung: netPerRung,
                                 netIfAllFilled: 0, breakoutPolicy: [], basis: basis, lastPrice: lastPrice)
        }
        basis.append("共 \(rungs.count) 档（买 \(rungs.filter { $0.side == "buy" }.count) / 卖 \(rungs.filter { $0.side == "sell" }.count)）：现价以下每 \(NextNum.percent(stepD * 100, digits: 2)) 挂一买档，以上挂卖档；卖出档不超过底仓 \(heldUnits) 份。")
        basis.append("每档份额 \(unitsPerRung) 份（\(lot) 的整数倍），单档净收益 ¥\(NextMoney.text(netPerRung, digits: 2))，买入档合计占用 ¥\(NextMoney.text(totalCapital, digits: 2))。")

        // ---- 4) 状态与偏好门槛 ----
        if !regime.regime.gridSuitable {
            blockers.append("当前市场状态为「\(regime.regime.title)」，不是网格的适配环境（网格只适用于震荡市）。")
        }
        if regime.regime == .downtrend && preference.pauseOnDowntrend {
            blockers.append("处于下跌趋势且你设置了「单边下跌时暂停网格」，暂不生成新网格。")
        }
        if totalCapital > usableCapital {
            blockers.append("所需资金 ¥\(NextMoney.text(totalCapital, digits: 2)) 超过你允许的占用上限 ¥\(NextMoney.text(usableCapital, digits: 2))，请降低档数或每档份额。")
        }
        if netPerRung < max(fee * 3, preference.minNetPerRung) {
            blockers.append("单档净收益 ¥\(NextMoney.text(netPerRung, digits: 2)) 未达到下限 ¥\(NextMoney.text(max(fee * 3, preference.minNetPerRung), digits: 2))。")
        }

        var policy: [String] = []
        policy.append("上破 ¥\(NextMoney.text(upper, digits: 3))：暂停所有买入档，已成交仓位保留卖出档；区间失效，需按新区间重算。")
        policy.append("下破 ¥\(NextMoney.text(lower, digits: 3))：\(preference.pauseOnDowntrend ? "按你的设置暂停新增买入档，避免一路接跌" : "继续按档买入，但请确认资金能承受")。")
        policy.append("连续 3 个交易日波动率超过建网时的 1.5 倍 → 暂停并重估档距。")
        policy.append("最长持有 \(preference.maxDurationDays) 天，到期无论盈亏都重估区间与档距。")
        policy.append("所有档位只是手工挂单参考，不会自动下单；成交与否由你决定。")

        return SmartGridPlan(code: code, name: name, suitable: blockers.isEmpty, blockers: blockers, lower: lower, upper: upper,
                             stepPercent: stepD * 100, rungs: rungs, totalCapital: totalCapital, netPerRung: netPerRung,
                             netIfAllFilled: totalNet, breakoutPolicy: policy, basis: basis, lastPrice: lastPrice)
    }

    private static func round3(_ value: Decimal) -> Decimal {
        var raw = value
        var out = Decimal()
        NSDecimalRound(&out, &raw, 3, .plain)
        return out
    }
    private static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[max(0, min(sorted.count - 1, idx))]
    }
}
