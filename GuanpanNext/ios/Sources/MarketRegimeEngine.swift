import Foundation

/// 市场状态识别：做T / 网格 / 持有 / 不交易 自动选择的前置条件。
/// 全部由真实日K序列算出；样本不足时明确返回 `.insufficient`，绝不猜。
enum MarketRegime: String, Codable, CaseIterable, Identifiable {
    case uptrend, downtrend, narrowRange, wideRange, abnormal, insufficient

    var id: String { rawValue }
    var title: String {
        switch self {
        case .uptrend: return "上涨趋势"
        case .downtrend: return "下跌趋势"
        case .narrowRange: return "窄幅震荡"
        case .wideRange: return "宽幅震荡"
        case .abnormal: return "异常波动"
        case .insufficient: return "数据不足"
        }
    }
    /// 一句话说明该状态对策略选择的含义。
    var strategyHint: String {
        switch self {
        case .uptrend: return "趋势向上；网格容易卖飞，更适合持有或反T回落买回。"
        case .downtrend: return "趋势向下；网格买档容易一路接跌，优先持有或降低档数。"
        case .narrowRange: return "窄幅震荡；网格与做T的主战场，但价差小、需扣净手续费后仍有余量。"
        case .wideRange: return "宽幅震荡；做T与网格空间大，注意单档份额别过大。"
        case .abnormal: return "波动异常；先观察，不新增档位，避免按常规振幅定价。"
        case .insufficient: return "历史数据不足；不输出任何具体价格与份额。"
        }
    }
    /// 是否适合网格（震荡市才适合）。
    var gridSuitable: Bool { self == .narrowRange || self == .wideRange }
    /// 是否适合做T。
    var tsessionSuitable: Bool { self == .narrowRange || self == .wideRange || self == .abnormal }
}

struct MarketRegimeMetrics: Codable, Equatable {
    var sampleCount = 0
    var lastClose: Double = 0
    var ma5: Double?
    var ma20: Double?
    var ma60: Double?
    var ma120: Double?
    /// 近20日真实波幅均值占收盘价百分比（(high-low)/close 均值）。
    var atr20Percent: Double?
    /// 近20日日内振幅均值百分比。
    var amplitude20Percent: Double?
    /// 60日收盘对数线性回归的年化斜率（0.18 ≈ 一年涨18%）。
    var trendSlopeAnnual: Double?
    /// 年化波动率（日收益标准差 × √250）。
    var volatilityAnnual: Double?
    /// 近5日均量 ÷ 近60日均量，衡量放量/缩量。
    var volumeRatio: Double?
    var rangeHigh: Double?
    var rangeLow: Double?
    /// 当前价在近60日区间中的分位（0=最低，1=最高）。
    var rangePosition: Double?
    var support: Double?
    var resistance: Double?
    /// 距今最后一个交易日的自然日数（数据新鲜度）。
    var stalenessDays: Int?
    /// 数据完整度 0–1：样本数 / 期望样本数，且检查高低价缺失。
    var completeness: Double?

    var summaryLines: [String] {
        var lines: [String] = []
        lines.append("样本 \(sampleCount) 根 · 最新 ¥\(NextNum.text(lastClose, digits: 3))")
        if let m = ma20 { lines.append("MA20 ¥\(NextNum.text(m, digits: 3))") }
        if let m = ma60 { lines.append("MA60 ¥\(NextNum.text(m, digits: 3))") }
        if let a = atr20Percent { lines.append("近20日真实波幅 \(NextNum.percent(a, digits: 2))") }
        if let v = volatilityAnnual { lines.append("年化波动 \(NextNum.percent(v, digits: 1))") }
        if let p = rangePosition { lines.append("区间位置 \(NextNum.percent(p * 100, digits: 0))") }
        if let s = support, let r = resistance { lines.append("支撑 ¥\(NextNum.text(s, digits: 3)) · 压力 ¥\(NextNum.text(r, digits: 3))") }
        if let st = stalenessDays { lines.append("数据 \(st) 天前") }
        return lines
    }
}

struct MarketRegimeResult: Codable, Equatable {
    let regime: MarketRegime
    let confidence: Double
    let reasons: [String]
    let metrics: MarketRegimeMetrics
    /// 若为 true，下游策略必须拒绝给出具体价格/份额。
    var blocksPricePlan: Bool { regime == .insufficient || (completenessOK == false) }
    private let completenessOK: Bool

    init(regime: MarketRegime, confidence: Double, reasons: [String], metrics: MarketRegimeMetrics, completenessOK: Bool) {
        self.regime = regime
        self.confidence = confidence
        self.reasons = reasons
        self.metrics = metrics
        self.completenessOK = completenessOK
    }
}

enum MarketRegimeEngine {
    /// 判定所需的最少日K根数。少于此数不输出任何价格计划。
    static let minimumSamples = 40

    static func evaluate(samples: [NextChartSample], now: Date = Date()) -> MarketRegimeResult {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        var m = MarketRegimeMetrics()
        m.sampleCount = ordered.count
        guard let last = ordered.last else {
            return MarketRegimeResult(regime: .insufficient, confidence: 0, reasons: ["没有可用的历史K线。"], metrics: m, completenessOK: false)
        }
        let closes = ordered.map { NextNum.double($0.close) }
        m.lastClose = closes.last ?? 0
        if let days = Calendar.current.dateComponents([.day], from: last.timestamp, to: now).day { m.stalenessDays = max(0, days) }

        // 完整度：样本数占比 × 高低价齐全占比。
        let withHighLow = ordered.filter { $0.high != nil && $0.low != nil }.count
        let countScore = min(1.0, Double(ordered.count) / 120.0)
        let fieldScore = ordered.isEmpty ? 0 : Double(withHighLow) / Double(ordered.count)
        m.completeness = countScore * 0.6 + fieldScore * 0.4

        guard ordered.count >= minimumSamples else {
            let reason = "历史K线只有 \(ordered.count) 根，少于判定所需的 \(minimumSamples) 根；不做状态判定，也不给具体价格。"
            return MarketRegimeResult(regime: .insufficient, confidence: 0, reasons: [reason], metrics: m, completenessOK: false)
        }

        m.ma5 = mean(closes.suffix(5))
        m.ma20 = mean(closes.suffix(20))
        m.ma60 = mean(closes.suffix(60))
        m.ma120 = mean(closes.suffix(120))

        // 真实波幅与日内振幅（(high-low)/close）
        let recent = ordered.suffix(20)
        var trs: [Double] = []
        var amps: [Double] = []
        for s in recent {
            guard let h = s.high, let l = s.low else { continue }
            let c = NextNum.double(s.close)
            guard c > 0 else { continue }
            trs.append((NextNum.double(h) - NextNum.double(l)) / c)
            amps.append((NextNum.double(h) - NextNum.double(l)) / c)
        }
        m.atr20Percent = trs.isEmpty ? nil : mean(trs)
        m.amplitude20Percent = amps.isEmpty ? nil : mean(amps)

        // 年化波动率
        var rets: [Double] = []
        for i in 1..<closes.count where closes[i - 1] > 0 { rets.append(closes[i] / closes[i - 1] - 1) }
        if rets.count >= 20 {
            let mu = mean(rets) ?? 0
            let variance = mean(rets.map { ($0 - mu) * ($0 - mu) }) ?? 0
            m.volatilityAnnual = sqrt(variance) * sqrt(250.0)
        }

        // 60日对数回归斜率年化
        let window = Array(closes.suffix(60))
        if window.count >= 20, window.allSatisfy({ $0 > 0 }) {
            let logs = window.map { log($0) }
            let slope = linearRegressionSlope(logs)
            m.trendSlopeAnnual = slope * 250.0
        }

        // 区间与支撑压力（近60日）
        let window60 = ordered.suffix(60)
        let highs = window60.compactMap { $0.high.map { NextNum.double($0) } }
        let lows = window60.compactMap { $0.low.map { NextNum.double($0) } }
        if let hi = highs.max(), let lo = lows.min(), hi > lo {
            m.rangeHigh = hi; m.rangeLow = lo
            m.rangePosition = NextNum.clamp((m.lastClose - lo) / (hi - lo), 0, 1)
            // 支撑：最低的5个低点均值；压力：最高的5个高点均值（真实极值聚类，不用拍脑袋的整数关口）
            let sortedLows = lows.sorted()
            let sortedHighs = highs.sorted(by: >)
            m.support = mean(Array(sortedLows.prefix(5)))
            m.resistance = mean(Array(sortedHighs.prefix(5)))
        }

        // 量能
        let vols = ordered.compactMap { $0.volume.map { NextNum.double($0) } }
        if vols.count >= 60 {
            let v5 = mean(Array(vols.suffix(5))) ?? 0
            let v60 = mean(Array(vols.suffix(60))) ?? 0
            if v60 > 0 { m.volumeRatio = v5 / v60 }
        }

        var reasons: [String] = []
        var regime: MarketRegime = .narrowRange
        var confidence = 0.5

        // 1) 异常波动优先判定
        if let amp20 = m.amplitude20Percent, let lastH = last.high, let lastL = last.low, m.lastClose > 0 {
            let prevClose = closes.count >= 2 ? closes[closes.count - 2] : m.lastClose
            guard prevClose > 0 else {
                return MarketRegimeResult(regime: .insufficient, confidence: 0, reasons: ["前收盘价无效。"], metrics: m, completenessOK: false)
            }
            let lastAmp = (NextNum.double(lastH) - NextNum.double(lastL)) / prevClose
            let dayChange = m.lastClose / prevClose - 1
            if lastAmp > amp20 * 2.5 && lastAmp > 0.03 {
                regime = .abnormal
                confidence = 0.72
                reasons.append("最新一根振幅 \(NextNum.percent(lastAmp, digits: 2))，是近20日均值 \(NextNum.percent(amp20, digits: 2)) 的 \(NextNum.text(lastAmp / max(amp20, 1e-9), digits: 1)) 倍，属于异常放大。")
            } else if abs(dayChange) > 0.07 {
                regime = .abnormal
                confidence = 0.7
                reasons.append("最新收盘单日变动 \(NextNum.signed(dayChange * 100, digits: 2))%，超过 7% 的异常阈值。")
            }
        }

        // 2) 趋势判定
        if regime != .abnormal, let slope = m.trendSlopeAnnual, let ma60 = m.ma60 {
            if slope > 0.15 && m.lastClose > ma60 {
                regime = .uptrend
                confidence = min(0.9, 0.55 + abs(slope) * 0.6)
                reasons.append("60日对数回归年化斜率 \(NextNum.percent(slope, digits: 1))，且现价高于 MA60，判定为上涨趋势。")
            } else if slope < -0.15 && m.lastClose < ma60 {
                regime = .downtrend
                confidence = min(0.9, 0.55 + abs(slope) * 0.6)
                reasons.append("60日对数回归年化斜率 \(NextNum.percent(slope, digits: 1))，且现价低于 MA60，判定为下跌趋势。")
            }
        }

        // 3) 震荡细分
        if regime != .abnormal && regime != .uptrend && regime != .downtrend {
            let atr = m.atr20Percent ?? 0
            if atr < 0.015 {
                regime = .narrowRange
                confidence = 0.5 + min(0.3, (0.015 - atr) * 12)
                reasons.append("近20日真实波幅 \(NextNum.percent(atr, digits: 2))，低于 1.5% 的窄幅阈值，判定为窄幅震荡。")
            } else {
                regime = .wideRange
                confidence = 0.5 + min(0.32, (atr - 0.015) * 10)
                reasons.append("近20日真实波幅 \(NextNum.percent(atr, digits: 2))，达到宽幅震荡区间。")
            }
        }

        if let slope = m.trendSlopeAnnual, regime != .insufficient {
            reasons.append("趋势强度参考：60日年化斜率 \(NextNum.percent(slope, digits: 1))。")
        }
        if let c = m.completeness { reasons.append("数据完整度 \(NextNum.percent(c * 100, digits: 0))；完整度不足时下游会拒绝精确价格建议。") }
        if let st = m.stalenessDays, st >= 3 { reasons.append("最新K线距今 \(st) 天，数据已不新鲜。") }

        let completenessOK = (m.completeness ?? 0) >= 0.6 && (m.stalenessDays ?? 99) < 5
        return MarketRegimeResult(regime: regime, confidence: confidence, reasons: reasons, metrics: m, completenessOK: completenessOK)
    }

    // MARK: - 数学工具（本地计算，不涉及任何外部服务）

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
    private static func mean(_ values: ArraySlice<Double>) -> Double? { mean(Array(values)) }

    /// 一元线性回归斜率（x 为 0..n-1）。用于趋势强度，避免只用首尾两点受单点噪声影响。
    private static func linearRegressionSlope(_ values: [Double]) -> Double {
        let n = Double(values.count)
        guard n >= 2 else { return 0 }
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for (i, y) in values.enumerated() {
            let x = Double(i)
            sumX += x; sumY += y; sumXY += x * y; sumXX += x * x
        }
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > 1e-12 else { return 0 }
        return (n * sumXY - sumX * sumY) / denominator
    }
}
