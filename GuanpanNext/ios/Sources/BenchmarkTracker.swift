import Foundation

/// 跑赢基准 · 每日对比。
///
/// ## 为什么要「净买入校正」
/// 直接拿两天市值相减会把「今天加仓 1 万」算成今天赚了 1 万。所以日快照里同时记
/// **当日净买入**，算收益时扣掉它：
///
/// ```
/// 组合日收益 =（今日市值 − 昨日市值 − 今日净买入）÷ 昨日市值
/// 基准日收益 =（今日点位 − 昨日点位）÷ 昨日点位
/// 超额       = 组合日收益 − 基准日收益
/// ```
///
/// 这样买卖进出不会污染收益，得出的超额才拿去和基准比。
///
/// ## 拿来干什么
/// 累积够天数后给出**胜率、累计超额、最好/最差单日**，用来总结「我的持仓在这个
/// 市场里是跑得赢还是跑不赢」——是给后续仓位和节奏提供数据的经验记录，
/// 不是预测明天涨跌。样本少于 3 天时界面会明确说「样本还少，别下结论」。
enum BenchmarkTracker {

    /// 基准：上证指数。用 `GlobalIndexFeed` 已经验证过的新浪源，不另起一套解析。
    static let symbol = "s_sh000001"
    static let benchmarkName = "上证指数"

    private static let storageKey = "guanpan.bench.v1"
    /// 最多留 180 个交易日，够看半年，也不会让 UserDefaults 无限膨胀。
    private static let maxDays = 180

    struct DayRecord: Codable, Equatable {
        var date: String
        var marketValue: Double
        var netBuy: Double
        var benchmark: Double
    }

    struct DayResult: Identifiable {
        var date: String
        var portfolio: Double
        var benchmarkReturn: Double
        var excess: Double
        var id: String { date }
    }

    struct Summary {
        var days = 0
        var winDays = 0
        var winRate = 0.0
        var cumulativeExcess = 0.0
        var avgExcess = 0.0
        var best: DayResult?
        var worst: DayResult?
        var latest: DayResult?
    }

    // MARK: - 存取

    static func records() -> [DayRecord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([DayRecord].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [DayRecord]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// 记一次当日快照。同一天重复调用会覆盖，不会攒出重复行。
    static func record(marketValue: Decimal, netBuy: Decimal, benchmark: Double) {
        let today = dividendTodayString()
        let mv = NSDecimalNumber(decimal: marketValue).doubleValue
        let nb = NSDecimalNumber(decimal: netBuy).doubleValue
        var list = records()
        if let idx = list.firstIndex(where: { $0.date == today }) {
            list[idx].marketValue = mv
            list[idx].netBuy = nb
            list[idx].benchmark = benchmark
        } else {
            list.append(DayRecord(date: today, marketValue: mv, netBuy: nb, benchmark: benchmark))
            list.sort { $0.date < $1.date }
            if list.count > maxDays { list = Array(list.suffix(maxDays)) }
        }
        save(list)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: storageKey) }

    // MARK: - 计算

    static func results() -> [DayResult] {
        let list = records()
        guard list.count >= 2 else { return [] }
        var out: [DayResult] = []
        for i in 1..<list.count {
            let prev = list[i - 1], cur = list[i]
            guard prev.marketValue > 0, prev.benchmark > 0 else { continue }
            let port = (cur.marketValue - prev.marketValue - cur.netBuy) / prev.marketValue * 100
            let bench = (cur.benchmark - prev.benchmark) / prev.benchmark * 100
            out.append(DayResult(date: cur.date, portfolio: port, benchmarkReturn: bench, excess: port - bench))
        }
        return out
    }

    static func summary() -> Summary {
        let rs = results()
        var s = Summary()
        guard !rs.isEmpty else { return s }
        s.days = rs.count
        s.winDays = rs.filter { $0.excess > 0 }.count
        s.winRate = Double(s.winDays) / Double(s.days) * 100
        s.cumulativeExcess = rs.reduce(0) { $0 + $1.excess }
        s.avgExcess = s.cumulativeExcess / Double(s.days)
        s.best = rs.max { $0.excess < $1.excess }
        s.worst = rs.min { $0.excess < $1.excess }
        s.latest = rs.last
        return s
    }

    /// 经验总结。样本不足时不下结论，只催继续记录。
    static func guidance(_ s: Summary) -> String {
        guard s.days >= 3 else {
            return "已记录 \(s.days) 个交易日的对比，样本还少——先攒数据，别急着下结论。"
        }
        var parts: [String] = []
        parts.append("近 \(s.days) 个交易日跑赢 \(s.winDays) 天（胜率 \(String(format: "%.0f", s.winRate))%）")
        parts.append(s.cumulativeExcess >= 0
                     ? "累计超额 +\(String(format: "%.2f", s.cumulativeExcess)) 个百分点"
                     : "累计落后 \(String(format: "%.2f", abs(s.cumulativeExcess))) 个百分点")
        var advice: String
        if s.winRate >= 60 {
            advice = "多数日子跑赢，说明当前持仓结构在这个市场环境下是有效的，可按原节奏执行、不必频繁改动。"
        } else if s.winRate >= 45 {
            advice = "输赢各半，超额主要来自少数几天。别因为单日波动改策略，先看累计超额是不是站得住。"
        } else {
            advice = "多数日子跑输，优先检查两件事：仓位是否过重、持仓是否集中在单一板块；先降集中度再谈加仓。"
        }
        parts.append(advice)
        return parts.joined(separator: "；") + "。"
    }
}
