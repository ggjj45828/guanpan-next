import Foundation
import CryptoKit
import CoreFoundation

enum NextError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

enum NextMoney {
    static func parse(_ text: String) throws -> Decimal {
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
            throw NextError.invalid("金额格式无效")
        }
        return value
    }
    static func text(_ value: Decimal, digits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "--"
    }
}

// New schema: no OTC position, subscription, redemption or automatic DCA type.
struct NextPosition: Codable, Identifiable, Equatable {
    var id: String { code }
    let code: String
    var name: String
    var units: Int
    var bookCost: Decimal
    var costPerUnit: Decimal { units > 0 ? bookCost / Decimal(units) : 0 }
}
struct NextFill: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var code: String
    var side: String
    var units: Int
    var price: Decimal
    var fee: Decimal
    var realized: Decimal
}
struct NextAssetPoint: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let total: Decimal
    let externalFlow: Decimal
}
struct NextCashMovement: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let amount: Decimal
    let reason: String
}
struct NextBook: Codable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var cash: Decimal = 0
    var positions: [NextPosition] = []
    var fills: [NextFill] = []
    var cashMovements: [NextCashMovement] = []
    // Only snapshots recorded under the new securities schema belong here.
    var history: [NextAssetPoint] = []
    var importedAt: Date?
    func validate() throws {
        guard schemaVersion == 1, !cash.isNaN, cash >= 0,
              Set(positions.map(\.code)).count == positions.count,
              positions.allSatisfy({ $0.code.count == 6 && $0.code.allSatisfy(\.isNumber) && $0.units >= 0 && !$0.bookCost.isNaN && $0.bookCost >= 0 }),
              cashMovements.allSatisfy({ !$0.amount.isNaN && !$0.reason.isEmpty }) else {
            throw NextError.invalid("账本校验失败：现金、持仓或版本无效")
        }
    }
    func total(using quotes: [String: NextQuote]) -> Decimal? {
        var total = cash
        for p in positions where p.units > 0 {
            guard let q = quotes[p.code] else { return nil }
            total += q.price * Decimal(p.units)
        }
        return total
    }
}
struct NextQuote: Codable, Identifiable, Equatable {
    var id: String { code }
    let code: String
    let name: String
    let price: Decimal
    let previousClose: Decimal
    let time: Date
    let source: String
    var iopv: Decimal? = nil
    var providerInstrumentType: String? = nil
    var changePercent: Decimal? { previousClose > 0 ? (price / previousClose - 1) * 100 : nil }
    func isFresh(at now: Date) -> Bool { time <= now && now.timeIntervalSince(time) <= 120 && price > 0 }
}

/// Strict parser for the reviewed Tencent quote payload. It only accepts facts
/// present in the response; instrument class, settlement and IOPV history must
/// come from separately verified sources.
enum NextTencentQuoteParser {
    static func symbol(for code: String) -> String? {
        guard code.count == 6, code.allSatisfy(\.isNumber), let first = code.first else { return nil }
        let prefix: String
        switch first {
        case "5", "6", "9": prefix = "sh"
        case "0", "1", "2", "3": prefix = "sz"
        case "4", "8": prefix = "bj"
        default: return nil
        }
        return prefix + code
    }

    static func parse(_ data: Data, code: String, receivedAt: Date = Date()) -> NextQuote? {
        guard let symbol = symbol(for: code) else { return nil }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
        else {
            let encoding = CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
            guard encoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(encoding)
            guard let decoded = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) else { return nil }
            text = decoded
        }
        let pattern = #"v_([A-Za-z0-9]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: fullRange).first(where: { match in
            guard let range = Range(match.range(at: 1), in: text) else { return false }
            return text[range].lowercased() == symbol
        }), let bodyRange = Range(match.range(at: 2), in: text) else { return nil }
        let fields = text[bodyRange].split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        guard fields.count > 30, fields[1].isEmpty == false,
              let price = Decimal(string: fields[3], locale: Locale(identifier: "en_US_POSIX")), price > 0,
              let previous = Decimal(string: fields[4], locale: Locale(identifier: "en_US_POSIX")), previous > 0,
              let timestamp = parseTimestamp(fields[30], fallback: receivedAt),
              timestamp <= receivedAt.addingTimeInterval(60) else { return nil }
        let providerType = fields.count > 61 ? fields[61].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() : nil
        let rawIopv = providerType == "ETF" && fields.count > 78 ? Decimal(string: fields[78], locale: Locale(identifier: "en_US_POSIX")) : nil
        return NextQuote(code: code, name: fields[1], price: price, previousClose: previous, time: timestamp, source: "Tencent qt.gtimg.cn", iopv: rawIopv.flatMap { $0 > 0 ? $0 : nil }, providerInstrumentType: providerType)
    }

    private static func parseTimestamp(_ raw: String, fallback: Date) -> Date? {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 12 || digits.count == 14,
              let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)), let date = Int(digits.dropFirst(6).prefix(2)),
              let hour = Int(digits.dropFirst(8).prefix(2)), let minute = Int(digits.dropFirst(10).prefix(2)),
              (1...12).contains(month), (1...31).contains(date), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let second = digits.count == 14 ? Int(digits.dropFirst(12).prefix(2)) ?? 0 : 0
        guard (0...59).contains(second) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var components = DateComponents(); components.year = year; components.month = month; components.day = date
        components.hour = hour; components.minute = minute; components.second = second
        guard let parsed = calendar.date(from: components) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
        guard verified.year == year, verified.month == month, verified.day == date,
              verified.hour == hour, verified.minute == minute, verified.second == second else { return nil }
        return parsed <= fallback.addingTimeInterval(60) ? parsed : nil
    }
}

enum NextTencentMinuteParser {
    static func parse(_ data: Data, code: String, receivedAt: Date = Date()) -> NextChartDataset? {
        guard let symbol = NextTencentQuoteParser.symbol(for: code),
              let raw = String(data: data, encoding: .utf8),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let root = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any],
              let nodes = root["data"] as? [String: Any],
              let node = nodes[symbol] as? [String: Any],
              let payload = node["data"] as? [String: Any],
              let rows = (payload["data"] as? [String]) ?? (payload["items"] as? [String]),
              let day = payload["date"] as? String, day.count == 8 else { return nil }
        let y = Int(day.prefix(4)), m = Int(day.dropFirst(4).prefix(2)), d = Int(day.suffix(2))
        guard let year = y, let month = m, let date = d else { return nil }
        guard (1...12).contains(month), (1...31).contains(date) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var samples = [NextChartSample](), previousVolume: Decimal?
        for row in rows {
            let parts = row.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0].count == 4,
                  let hour = Int(parts[0].prefix(2)), let minute = Int(parts[0].suffix(2)),
                  (0...23).contains(hour), (0...59).contains(minute),
                  let price = Decimal(string: parts[1], locale: Locale(identifier: "en_US_POSIX")), price > 0 else { continue }
            var components = DateComponents(); components.year = year; components.month = month; components.day = date; components.hour = hour; components.minute = minute
            guard let timestamp = calendar.date(from: components), timestamp <= receivedAt.addingTimeInterval(60) else { continue }
            let actualDay = calendar.dateComponents([.year, .month, .day], from: timestamp)
            guard actualDay.year == year, actualDay.month == month, actualDay.day == date else { continue }
            var volume: Decimal?
            if parts.count > 2, let cumulative = Decimal(string: parts[2], locale: Locale(identifier: "en_US_POSIX")), cumulative >= 0 {
                if let previousVolume, cumulative >= previousVolume { volume = cumulative - previousVolume }
                previousVolume = cumulative
            }
            samples.append(NextChartSample(timestamp: timestamp, open: nil, high: nil, low: nil, close: price, iopv: nil, volume: volume))
        }
        samples = Dictionary(samples.map { ($0.timestamp, $0) }, uniquingKeysWith: { _, latest in latest }).values.sorted { $0.timestamp < $1.timestamp }
        guard !samples.isEmpty else { return nil }
        let result = NextChartDataset(code: code, interval: .intraday, samples: samples, costPerUnit: nil, costObservedAt: nil, priceSource: "Tencent minute history", iopvSource: nil, observedAt: receivedAt)
        do { try result.validate(); return result } catch { return nil }
    }
}

// Trading behavior is supplied by verified instrument metadata. Never infer
// settlement rules from an ETF label, code prefix, or a hard-coded T+0 flag.
enum NextSettlementRule: String, Codable { case t0, t1, unknown }
enum NextAssetClass: String, Codable { case etf, equity, other, unknown }
struct NextInstrumentRules: Codable, Equatable {
    let code: String
    let market: String
    let assetClass: NextAssetClass
    let settlement: NextSettlementRule
    let lotSize: Int?
    let feePerTrade: Decimal?
    let source: String
    let verifiedAt: Date?
    var isVerified: Bool { assetClass != .unknown && settlement != .unknown && lotSize != nil && feePerTrade != nil && verifiedAt != nil && !source.isEmpty && !market.isEmpty }
    func validate() throws {
        guard code.count == 6, code.allSatisfy(\.isNumber),
              (market.isEmpty || market.count <= 16), (source.isEmpty || source.count <= 160),
              lotSize.map({ $0 > 0 }) ?? true,
              feePerTrade.map({ $0 >= 0 }) ?? true else {
            throw NextError.invalid("证券交易规则无效")
        }
    }
}

struct NextBookLevel: Codable, Equatable {
    let price: Decimal
    let units: Int
}
struct NextOrderBookSnapshot: Codable, Equatable {
    let code: String
    let observedAt: Date
    let source: String
    let bids: [NextBookLevel]
    let asks: [NextBookLevel]
    func validate() throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), !source.isEmpty,
              bids.count == 5, asks.count == 5,
              bids.allSatisfy({ $0.price > 0 && $0.units > 0 }), asks.allSatisfy({ $0.price > 0 && $0.units > 0 }),
              zip(bids, bids.dropFirst()).allSatisfy({ pair in pair.0.price >= pair.1.price }),
              zip(asks, asks.dropFirst()).allSatisfy({ pair in pair.0.price <= pair.1.price }),
              bids[0].price <= asks[0].price else {
            throw NextError.invalid("五档盘口数据无效或档位顺序错误")
        }
    }
}

enum NextChartInterval: String, Codable, CaseIterable { case intraday, fiveDay, day, week, month, threeMonth, year, all }
struct NextChartSample: Codable, Identifiable, Equatable {
    var id: Date { timestamp }
    let timestamp: Date
    let open: Decimal?
    let high: Decimal?
    let low: Decimal?
    let close: Decimal
    let iopv: Decimal?
    let volume: Decimal?
}
struct NextChartDataset: Codable, Equatable {
    let code: String
    let interval: NextChartInterval
    let samples: [NextChartSample]
    let costPerUnit: Decimal?
    let costObservedAt: Date?
    let priceSource: String
    let iopvSource: String?
    let observedAt: Date

    var orderedSamples: [NextChartSample] { samples.sorted { $0.timestamp < $1.timestamp } }
    var priceDomain: ClosedRange<Decimal>? {
        let values = orderedSamples.flatMap { [$0.low, $0.high, Optional($0.close)].compactMap { $0 } }
        guard let low = values.min(), let high = values.max() else { return nil }
        if low == high { let pad = max(abs(low) * Decimal(string: "0.01")!, Decimal(string: "0.0001")!); return (low - pad)...(high + pad) }
        let pad = (high - low) * Decimal(string: "0.06")!
        return (low - pad)...(high + pad)
    }
    // IOPV gets its own secondary percent axis; it cannot distort the price axis.
    var iopvPremiumDomain: ClosedRange<Decimal>? {
        let values = orderedSamples.compactMap { sample -> Decimal? in
            guard let iopv = sample.iopv, iopv != 0 else { return nil }
            return (sample.close / iopv - 1) * 100
        }
        guard let low = values.min(), let high = values.max() else { return nil }
        if low == high { return (low - 0.1)...(high + 0.1) }
        let pad = (high - low) * Decimal(string: "0.1")!
        return (low - pad)...(high + pad)
    }
    var timeDomain: ClosedRange<Date>? {
        guard let first = orderedSamples.first?.timestamp, let last = orderedSamples.last?.timestamp else { return nil }
        return first == last ? first.addingTimeInterval(-30)...last.addingTimeInterval(30) : first...last
    }
    func validate() throws {
        guard code.count == 6, code.allSatisfy(\.isNumber),
              !samples.isEmpty,
              zip(orderedSamples, orderedSamples.dropFirst()).allSatisfy({ pair in pair.0.timestamp < pair.1.timestamp }),
              orderedSamples.allSatisfy({ $0.close > 0 && ($0.iopv.map({ $0 > 0 }) ?? true) && ($0.volume.map({ $0 >= 0 }) ?? true) }),
              (iopvSource != nil || orderedSamples.allSatisfy({ $0.iopv == nil })) else {
            throw NextError.invalid("图表数据时间、价格或来源无效")
        }
    }
}
struct NextGoal: Codable, Equatable {
    var years = 10
    var monthlyBudget: Decimal = 1000
    var concentrationLimit: Decimal = 40
    func validate() throws {
        guard years > 0, years <= 50, !monthlyBudget.isNaN, monthlyBudget >= 0,
              concentrationLimit > 0, concentrationLimit <= 100 else { throw NextError.invalid("目标或预算无效") }
    }
}
struct NextEvidence: Codable, Identifiable, Equatable {
    var id: String
    let title: String
    let detail: String
    let level: String
    let observedAt: Date
}
struct NextOption: Codable, Identifiable, Equatable {
    var id: String
    let title: String
    let rationale: String
    let tradeoff: String
    let evidenceIDs: [String]
}
struct NextDecision: Codable, Identifiable, Equatable {
    var id = UUID()
    let createdAt: Date
    var title: String
    var evidence: [NextEvidence]
    var options: [NextOption]
    var selectedOption: String?
    var review: String = ""
    var status: String = "待比较"
    let origin: String
}
enum NextResearch {
    // Local arithmetic and data checks are explicitly not model-generated AI.
    static func prepare(book: NextBook, goal: NextGoal, quotes: [String: NextQuote], now: Date) throws -> NextDecision {
        try book.validate(); try goal.validate()
        var evidence = [NextEvidence(id: "budget", title: "新增资金独立规划", detail: "每月预算 ¥\(NextMoney.text(goal.monthlyBudget))；不占用或改动真实现金。", level: "事实", observedAt: now)]
        let missing = book.positions.filter { $0.units > 0 && quotes[$0.code]?.isFresh(at: now) != true }
        evidence.append(NextEvidence(id: "quotes", title: missing.isEmpty ? "报价检查通过" : "行情证据待补齐",
                                     detail: missing.isEmpty ? "所有现有持仓报价在两分钟内。" : "\(missing.count) 只持仓没有新鲜报价；不生成带价交易方案。", level: missing.isEmpty ? "事实" : "缺口", observedAt: now))
        if let total = book.total(using: quotes), total > 0 {
            let largest = book.positions.map { Decimal($0.units) * (quotes[$0.code]?.price ?? 0) / total * 100 }.max() ?? 0
            evidence.append(NextEvidence(id: "concentration", title: "当前单只最高占比", detail: "\(NextMoney.text(largest))%；你设置的检查阈值为 \(NextMoney.text(goal.concentrationLimit))%。", level: largest > goal.concentrationLimit ? "待核对" : "事实", observedAt: now))
        }
        let options = [
            NextOption(id: "wait", title: "暂不调整，补齐证据", rationale: "保留当前仓位，先核对行情与预算。", tradeoff: "维持现有集中度，也可能错过部分行情。", evidenceIDs: ["quotes"]),
            NextOption(id: "budget", title: "用新增资金逐月靠近目标", rationale: "把每月预算单独用于下一步配置研究；不足一手时先累计。", tradeoff: "调整较慢，需要持续投入；没有收益保证。", evidenceIDs: ["budget", "quotes"])
        ]
        return NextDecision(createdAt: now, title: "本次账户研究", evidence: evidence, options: options, origin: "本地规则检查")
    }
    static func acceptModelOptions(_ options: [NextOption], evidence: [NextEvidence]) throws -> [NextOption] {
        let known = Set(evidence.map(\.id))
        guard (2...4).contains(options.count), Set(options.map(\.id)).count == options.count,
              options.allSatisfy({ !$0.title.isEmpty && !$0.rationale.isEmpty && !$0.tradeoff.isEmpty && !$0.evidenceIDs.isEmpty && Set($0.evidenceIDs).isSubset(of: known) }) else {
            throw NextError.invalid("AI 方案缺少依据、取舍说明或引用了不存在的证据，未采用")
        }
        return options
    }
}

// Persisted navigation lets deep links, search and scene restoration return to
// the same user context instead of rebuilding a flow from an internal menu.
enum NextTab: String, Codable, CaseIterable { case overview, market, decision, laboratory, assets }
enum NextRoute: Codable, Equatable {
    case instrument(String), intent(String, String), chart(String), portfolio(String), replay(String)
    case settings, alerts, fills, history, backups, twin(String)
}
struct NextChartState: Codable, Equatable {
    var interval = "intraday"
    var visibleLayers: Set<String> = ["price", "cost"]
    var lowerBound: Date?
    var upperBound: Date?
    var crosshairTime: Date?
    var scale = 1.0
}
struct NextNavigationState: Codable, Equatable {
    var selectedTab: NextTab = .overview
    var routes: [NextRoute] = []
    var tabRoutes: [String: [NextRoute]] = [:]
    var selectedSecurity: String?
    var searchQuery = ""
    var listFilters: [String: String] = [:]
    var listSorts: [String: String] = [:]
    var scrollAnchors: [String: String] = [:]
    var chartStates: [String: NextChartState] = [:]
    mutating func openInstrument(_ code: String) {
        selectedTab = .market; selectedSecurity = code; routes.append(.instrument(code))
    }
    mutating func openIntent(_ intent: String, code: String) {
        selectedTab = .decision; selectedSecurity = code; routes.append(.intent(intent, code))
    }
}

enum NextDataQuality: String, Codable { case live, delayed, cached, stale, missing }
struct NextDataStamp: Codable, Equatable {
    let source: String
    let observedAt: Date?
    let quality: NextDataQuality
    let detail: String
    func label(now: Date) -> String {
        if quality == .live || quality == .delayed {
            guard let observedAt else { return "\(quality == .live ? "刚更新" : "延迟") · \(source)" }
            let seconds = max(0, Int(now.timeIntervalSince(observedAt)))
            if seconds <= 120 && quality == .live { return "刚更新 · \(source) · \(seconds) 秒前" }
            let age = seconds / 60
            return "\(seconds <= 900 ? "延迟" : seconds <= 86_400 ? "缓存" : "已过期") · \(age) 分钟前 · \(source)"
        }
        switch quality {
        case .live, .delayed: return "\(quality.rawValue) · \(source)"
        case .cached, .stale:
            guard let observedAt else { return quality == .cached ? "缓存数据" : "数据过期" }
            let age = max(0, Int(now.timeIntervalSince(observedAt) / 60))
            return "\(quality == .cached ? "缓存" : "已过期") · \(age) 分钟前 · \(source)"
        case .missing: return "暂无数据 · \(detail)"
        }
    }
    var canSupportPricePlan: Bool { quality == .live && source.hasPrefix("licensed:") }
}

struct NextCachedQuote: Codable, Equatable {
    let quote: NextQuote
    let stamp: NextDataStamp
    func usableForDisplay(at now: Date) -> Bool { quote.time <= now }
    func usableForPricePlan(at now: Date) -> Bool { usableForDisplay(at: now) && stamp.canSupportPricePlan && quote.isFresh(at: now) }
}
struct NextAssetValuation: Equatable {
    let total: Decimal?
    let partialTotal: Decimal
    let dailyChange: Decimal?
    let dailyChangePercent: Decimal?
    let pricedPositions: Int
    let totalPositions: Int
    let earliestQuote: Date?
    let quality: NextDataQuality?
    var isComplete: Bool { pricedPositions == totalPositions }
}
extension NextBook {
    func valuation(using quotes: [String: NextCachedQuote], at now: Date) -> NextAssetValuation {
        var partial = cash
        var priced = 0
        var earliest: Date?
        var qualities = [NextDataQuality]()
        var previousTotal = cash
        var allQuotesFresh = true
        for position in positions where position.units > 0 {
            guard let cached = quotes[position.code], cached.usableForDisplay(at: now) else { allQuotesFresh = false; continue }
            partial += cached.quote.price * Decimal(position.units)
            previousTotal += cached.quote.previousClose * Decimal(position.units)
            priced += 1
            earliest = min(earliest ?? cached.quote.time, cached.quote.time)
            let age = now.timeIntervalSince(cached.quote.time)
            let quality: NextDataQuality = age <= 120 ? cached.stamp.quality : age <= 86_400 ? .cached : .stale
            qualities.append(quality)
            if !cached.quote.isFresh(at: now) { allQuotesFresh = false }
        }
        let complete = priced == positions.filter({ $0.units > 0 }).count
        let quality = qualities.max { qualityRank($0) < qualityRank($1) }
        let delta = complete && allQuotesFresh ? partial - previousTotal : nil
        let deltaPercent = delta.flatMap { previousTotal > 0 ? $0 / previousTotal * 100 : nil }
        return NextAssetValuation(total: complete ? partial : nil, partialTotal: partial, dailyChange: delta, dailyChangePercent: deltaPercent, pricedPositions: priced,
                                  totalPositions: positions.filter({ $0.units > 0 }).count, earliestQuote: earliest, quality: quality)
    }
}
private func qualityRank(_ quality: NextDataQuality) -> Int {
    switch quality { case .live: 0; case .delayed: 1; case .cached: 2; case .stale: 3; case .missing: 4 }
}

// Buy research never invents a fair price. A limit plan is offered only when
// fresh quotations and an explicit, cited research range are both available.
struct NextPriceResearch: Codable, Equatable {
    let lower: Decimal
    let upper: Decimal
    let evidenceIDs: [String]
    let observedAt: Date
    func validate(evidence: [NextEvidence]) throws {
        guard lower > 0, upper >= lower, !evidenceIDs.isEmpty,
              Set(evidenceIDs).isSubset(of: Set(evidence.map(\.id))) else {
            throw NextError.invalid("合理价格区间缺少有效来源，不能生成限价建议")
        }
    }
}
struct NextPatientLimitStep: Codable, Identifiable, Equatable {
    var id: Int { level }
    let level: Int
    let limit: Decimal
    let units: Int
    let budget: Decimal
    let fee: Decimal
}
struct NextBuyOpportunity: Codable, Equatable {
    let code: String
    let evidence: [NextEvidence]
    let priceResearch: NextPriceResearch?
    let limitSteps: [NextPatientLimitStep]
    let riskSummary: String
    let status: String
    let canSavePlan: Bool
    static func prepare(code: String, book: NextBook, goal: NextGoal, quote: NextCachedQuote?, research: NextPriceResearch?, rules: NextInstrumentRules?, evidence: [NextEvidence], now: Date) throws -> NextBuyOpportunity {
        try book.validate(); try goal.validate()
        var reasons: [String] = []
        guard let quote, quote.usableForPricePlan(at: now) else {
            reasons.append("缺少新鲜行情，暂不生成价格或限价档位。")
            return NextBuyOpportunity(code: code, evidence: evidence, priceResearch: nil, limitSteps: [], riskSummary: reasons.joined(separator: " "), status: "行情待更新", canSavePlan: false)
        }
        guard let research else {
            reasons.append("尚无可验证的合理价格研究，暂不猜测买入价。")
            return NextBuyOpportunity(code: code, evidence: evidence, priceResearch: nil, limitSteps: [], riskSummary: reasons.joined(separator: " "), status: "价格依据待补", canSavePlan: false)
        }
        try research.validate(evidence: evidence)
        guard let rules, rules.code == code, rules.isVerified, rules.assetClass == .etf,
              let fee = rules.feePerTrade, fee == NextExperiment.fee, let lotSize = rules.lotSize else {
            reasons.append("该证券类别、交易单位或 ETF 固定手续费未核实，暂不生成限价数量。")
            return NextBuyOpportunity(code: code, evidence: evidence, priceResearch: research, limitSteps: [], riskSummary: reasons.joined(separator: " "), status: "交易规则待核验", canSavePlan: false)
        }
        let budget = goal.monthlyBudget
        guard budget > fee else {
            return NextBuyOpportunity(code: code, evidence: evidence, priceResearch: research, limitSteps: [], riskSummary: "新增预算不足以覆盖一手及费用；计划保持空白，不动用真实现金。", status: "预算不足", canSavePlan: false)
        }
        let center = (research.lower + research.upper) / 2
        let prices = [research.lower, center]
        let perStepBudget = budget / 2
        let steps = prices.enumerated().compactMap { index, price -> NextPatientLimitStep? in
            guard price > 0, perStepBudget > fee else { return nil }
            var lotCost = price * Decimal(lotSize)
            let availableBudget = perStepBudget - fee
            let unroundedLotCount = NSDecimalNumber(decimal: availableBudget)
                .dividing(by: NSDecimalNumber(decimal: lotCost)).decimalValue
            var roundedLotCount = Decimal()
            var unroundedLotCountCopy = unroundedLotCount
            NSDecimalRound(&roundedLotCount, &unroundedLotCountCopy, 0, .down)
            let rawUnits = NSDecimalNumber(decimal: roundedLotCount).intValue * lotSize
            guard rawUnits >= lotSize else { return nil }
            let amount = price * Decimal(rawUnits)
            return NextPatientLimitStep(level: index + 1, limit: price, units: rawUnits, budget: amount, fee: fee)
        }
        if steps.isEmpty { reasons.append("当前每档预算不足一手，建议先累计新增预算。") }
        reasons.append("价格只作用户可修改的等待计划；不会占用真实现金或提交订单。")
        return NextBuyOpportunity(code: code, evidence: evidence, priceResearch: research, limitSteps: steps, riskSummary: reasons.joined(separator: " "), status: "待你核对", canSavePlan: !steps.isEmpty)
    }
}

enum NextTwinStrategy: String, Codable, CaseIterable, Identifiable, Hashable {
    case A, B, C, D, E, F, G, H
    var id: String { rawValue }
    var title: String {
        switch self { case .A: "不操作基准"; case .B: "原始权重"; case .C: "目标权重"; case .D: "定期再平衡"; case .E: "估值与红利调仓"; case .F: "趋势风控减仓"; case .G: "AI 多因子自主模拟交易"; case .H: "用户自定义策略" }
    }
}

struct NextAlert: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    let fingerprint: String
    let level: String
    let title: String
    let detail: String
    let createdAt: Date
    let stamp: NextDataStamp
    var read = false
    var delivery: String = "待处理"
}
struct NextQuietHours: Codable, Equatable {
    var enabled = true
    var startMinute = 22 * 60
    var endMinute = 8 * 60
    func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute == endMinute { return true }
        return startMinute < endMinute ? (minute >= startMinute && minute < endMinute) : (minute >= startMinute || minute < endMinute)
    }
}
struct NextNotificationCenter: Codable, Equatable {
    var alerts: [NextAlert] = []
    var quietHours = NextQuietHours()
    var dedupeMinutes = 30
    mutating func append(_ alert: NextAlert, now: Date) -> Bool {
        let duplicate = alerts.contains { $0.fingerprint == alert.fingerprint && now.timeIntervalSince($0.createdAt) >= 0 && now.timeIntervalSince($0.createdAt) < Double(max(0, dedupeMinutes) * 60) }
        guard !duplicate else { return false }
        alerts.insert(alert, at: 0)
        return true
    }
    var unreadCount: Int { alerts.filter { !$0.read }.count }
}

struct NextAuditEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    let at: Date
    let action: String
    let reason: String
    let before: NextBook
    let after: NextBook
    var undoneAt: Date?
}
struct NextAuditedBook: Codable, Equatable {
    var current: NextBook
    var events: [NextAuditEvent] = []
    mutating func apply(_ updated: NextBook, action: String, reason: String, at: Date) throws {
        try updated.validate()
        events.append(NextAuditEvent(at: at, action: action, reason: reason, before: current, after: updated))
        current = updated
    }
    mutating func undo(_ eventID: UUID, at: Date) throws {
        guard let index = events.lastIndex(where: { $0.id == eventID }), events[index].undoneAt == nil,
              events[index].after == current else { throw NextError.invalid("此变更已失效或账本已继续更新；请先核对版本") }
        current = events[index].before
        events[index].undoneAt = at
    }
}

enum NextTheme: String, Codable, CaseIterable { case system, light, dark, comfort }
struct NextAppArchive: Codable, Equatable {
    var schemaVersion = 1
    var book = NextBook()
    var experiment = NextExperiment()
    var twins = NextTwinLedger()
    var goal = NextGoal()
    var watch = ["159941", "563020", "159545", "159352"]
    var navigation = NextNavigationState()
    var cachedQuotes: [String: NextCachedQuote] = [:]
    var chartData: [String: NextChartDataset] = [:]
    var instrumentRules: [String: NextInstrumentRules] = [:]
    var orderBooks: [String: NextOrderBookSnapshot] = [:]
    var notifications = NextNotificationCenter()
    var audits: [NextAuditEvent] = []
    var decisionHistory: [NextDecision] = []
    var theme: NextTheme = .system
    private enum CodingKeys: String, CodingKey { case schemaVersion, book, experiment, twins, goal, watch, navigation, cachedQuotes, chartData, instrumentRules, orderBooks, notifications, audits, decisionHistory, theme }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        book = try values.decodeIfPresent(NextBook.self, forKey: .book) ?? NextBook()
        experiment = try values.decodeIfPresent(NextExperiment.self, forKey: .experiment) ?? NextExperiment()
        twins = try values.decodeIfPresent(NextTwinLedger.self, forKey: .twins) ?? NextTwinLedger()
        goal = try values.decodeIfPresent(NextGoal.self, forKey: .goal) ?? NextGoal()
        watch = try values.decodeIfPresent([String].self, forKey: .watch) ?? ["159941", "563020", "159545", "159352"]
        navigation = try values.decodeIfPresent(NextNavigationState.self, forKey: .navigation) ?? NextNavigationState()
        cachedQuotes = try values.decodeIfPresent([String: NextCachedQuote].self, forKey: .cachedQuotes) ?? [:]
        chartData = try values.decodeIfPresent([String: NextChartDataset].self, forKey: .chartData) ?? [:]
        instrumentRules = try values.decodeIfPresent([String: NextInstrumentRules].self, forKey: .instrumentRules) ?? [:]
        orderBooks = try values.decodeIfPresent([String: NextOrderBookSnapshot].self, forKey: .orderBooks) ?? [:]
        notifications = try values.decodeIfPresent(NextNotificationCenter.self, forKey: .notifications) ?? NextNotificationCenter()
        audits = try values.decodeIfPresent([NextAuditEvent].self, forKey: .audits) ?? []
        decisionHistory = try values.decodeIfPresent([NextDecision].self, forKey: .decisionHistory) ?? []
        theme = try values.decodeIfPresent(NextTheme.self, forKey: .theme) ?? .system
    }
    func validate() throws {
        guard schemaVersion == 1 else { throw NextError.invalid("本机数据版本不受支持") }
        try book.validate(); try goal.validate(); try twins.validate(); try experiment.validate()
        for (code, cached) in cachedQuotes {
            guard code == cached.quote.code, code.count == 6, code.allSatisfy(\.isNumber), cached.quote.price > 0,
                  cached.quote.previousClose > 0, !cached.quote.name.isEmpty, !cached.quote.source.isEmpty,
                  cached.quote.iopv.map({ $0 > 0 && cached.quote.providerInstrumentType == "ETF" }) ?? true else { throw NextError.invalid("缓存行情代码、价格、IOPV 或来源校验失败") }
        }
        guard watch.allSatisfy({ $0.count == 6 && $0.allSatisfy(\.isNumber) }), Set(watch).count == watch.count else {
            throw NextError.invalid("自选清单校验失败")
        }
        for (code, chart) in chartData { guard code == chart.code else { throw NextError.invalid("图表证券代码不匹配") }; try chart.validate() }
        for (code, rule) in instrumentRules { guard code == rule.code else { throw NextError.invalid("证券规则代码不匹配") }; try rule.validate() }
        for (code, book) in orderBooks { guard code == book.code else { throw NextError.invalid("盘口证券代码不匹配") }; try book.validate() }
        guard decisionHistory.count <= 1000,
              decisionHistory.allSatisfy({ decision in
                  !decision.title.isEmpty && !decision.origin.isEmpty &&
                  Set(decision.evidence.map(\.id)).count == decision.evidence.count &&
                  (decision.selectedOption == nil || decision.options.contains(where: { $0.id == decision.selectedOption }))
              }) else { throw NextError.invalid("历史决策记录校验失败") }
    }
}
struct NextArchiveEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let payload: Data
    let sha256: String
    init(archive: NextAppArchive) throws {
        try archive.validate()
        schemaVersion = 1
        payload = try JSONEncoder().encode(archive)
        sha256 = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
    func archive() throws -> NextAppArchive {
        guard schemaVersion == 1, SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw NextError.invalid("备份校验值不匹配，未恢复任何数据")
        }
        let value = try JSONDecoder().decode(NextAppArchive.self, from: payload)
        try value.validate()
        return value
    }
}

// Entirely independent experiment ledger. No real-book reference or write API.
struct NextExperiment: Codable, Equatable {
    struct Order: Codable, Identifiable, Equatable {
        var id = UUID()
        let code: String
        let limit: Decimal
        let units: Int
        let placedAt: Date
        let expiresAt: Date
        var state = "等待"
        var filledAt: Date?
        var averageFillPrice: Decimal?
    }
    var cash: Decimal = 10000
    var positions: [NextPosition] = []
    var orders: [Order] = []
    static let fee = Decimal(string: "0.10")!
    var reserved: Decimal { orders.filter { $0.state == "等待" }.reduce(0) { $0 + $1.limit * Decimal($1.units) + Self.fee } }
    var available: Decimal { cash - reserved }
    func validate() throws {
        guard !cash.isNaN, cash >= 0,
              positions.allSatisfy({ $0.units >= 0 && $0.bookCost >= 0 && $0.code.count == 6 }),
              orders.allSatisfy({ $0.limit > 0 && $0.units > 0 && $0.expiresAt > $0.placedAt && $0.code.count == 6 }),
              reserved <= cash else { throw NextError.invalid("模拟账本校验失败") }
    }
    mutating func place(code: String, limit: Decimal, units: Int, rules: NextInstrumentRules, at now: Date, until expiry: Date) throws {
        expire(at: now)
        try rules.validate()
        guard rules.isVerified, rules.code == code, rules.assetClass == .etf,
              rules.feePerTrade == Self.fee,
              let lot = rules.lotSize, code.count == 6, code.allSatisfy(\.isNumber),
              !limit.isNaN, limit > 0, limit <= 100000, units > 0, units <= 100000000, units % lot == 0,
              expiry > now, limit * Decimal(units) + Self.fee <= available else { throw NextError.invalid("仅可在证券类别、交易单位和规则来源经核验后模拟 ETF 限价单；请检查数量、有效期和虚拟资金") }
        orders.append(Order(code: code, limit: limit, units: units, placedAt: now, expiresAt: expiry))
    }
    mutating func expire(at now: Date) {
        for i in orders.indices where orders[i].state == "等待" && orders[i].expiresAt <= now { orders[i].state = "到期" }
    }
    mutating func cancel(_ id: UUID) {
        if let i = orders.firstIndex(where: { $0.id == id && $0.state == "等待" }) { orders[i].state = "已撤销" }
    }
    // Last-trade prices are not execution evidence. Quote-only refreshes never fill an order.
    mutating func observe(_ quote: NextQuote, now: Date, marketOpen: Bool) {
        expire(at: now)
        guard marketOpen, quote.isFresh(at: now) else { return }
    }
    mutating func observe(_ book: NextOrderBookSnapshot, rules: NextInstrumentRules, now: Date, marketOpen: Bool) throws {
        expire(at: now)
        try book.validate(); try rules.validate()
        guard marketOpen, rules.isVerified, rules.assetClass == .etf, rules.feePerTrade == Self.fee, rules.code == book.code,
              book.observedAt <= now, now.timeIntervalSince(book.observedAt) <= 5 else { return }
        for i in orders.indices where orders[i].state == "等待" && orders[i].code == book.code {
            let o = orders[i]
            guard book.observedAt > o.placedAt, book.observedAt < o.expiresAt else { continue }
            var remaining = o.units
            var gross: Decimal = 0
            for level in book.asks where level.price <= o.limit && remaining > 0 {
                let fillUnits = min(remaining, level.units)
                gross += level.price * Decimal(fillUnits)
                remaining -= fillUnits
            }
            guard remaining == 0 else { continue }
            let amount = gross + Self.fee
            guard amount <= cash else { continue }
            cash -= amount
            let averagePrice = gross / Decimal(o.units)
            if let j = positions.firstIndex(where: { $0.code == o.code }) { positions[j].units += o.units; positions[j].bookCost += amount }
            else { positions.append(NextPosition(code: o.code, name: o.code, units: o.units, bookCost: amount)) }
            orders[i].state = "触价模拟"
            orders[i].filledAt = book.observedAt
            orders[i].averageFillPrice = averagePrice
        }
    }
}

struct NextTwinAccount: Codable, Equatable, Identifiable {
    var id: String { strategy.rawValue }
    let strategy: NextTwinStrategy
    var simulation: NextExperiment
    var isPaused = false
    var seedSource = "空白模拟账户"
}
struct NextTwinFunding: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let amount: Decimal
    let reason: String
}
struct NextTwinLedger: Codable, Equatable {
    var accounts: [String: NextTwinAccount] = Dictionary(uniqueKeysWithValues: NextTwinStrategy.allCases.map { strategy in
        (strategy.rawValue, NextTwinAccount(strategy: strategy, simulation: NextExperiment(), seedSource: "空白模拟账户"))
    })
    var funding: [NextTwinFunding] = []
    mutating func fundAll(_ amount: Decimal, reason: String, at date: Date) throws {
        guard amount > 0, !amount.isNaN, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accounts.count == NextTwinStrategy.allCases.count,
              NextTwinStrategy.allCases.allSatisfy({ accounts[$0.rawValue]?.strategy == $0 }) else { throw NextError.invalid("注资金额、用途或 A–H 模拟账户校验失败") }
        var next = accounts
        for strategy in NextTwinStrategy.allCases {
            guard var account = next[strategy.rawValue] else { throw NextError.invalid("模拟账户不完整，未注资") }
            account.simulation.cash += amount
            next[strategy.rawValue] = account
        }
        accounts = next
        funding.append(NextTwinFunding(date: date, amount: amount, reason: reason))
    }
    func validate() throws {
        guard accounts.count == NextTwinStrategy.allCases.count,
              NextTwinStrategy.allCases.allSatisfy({ accounts[$0.rawValue]?.strategy == $0 }) else { throw NextError.invalid("数字孪生账户不完整") }
        for account in accounts.values { try account.simulation.validate() }
        guard funding.allSatisfy({ $0.amount > 0 && !$0.reason.isEmpty }) else { throw NextError.invalid("模拟资金流水无效") }
    }
    mutating func setPaused(_ paused: Bool, strategy: NextTwinStrategy) throws {
        guard var account = accounts[strategy.rawValue] else { throw NextError.invalid("模拟账户不存在") }
        account.isPaused = paused
        accounts[strategy.rawValue] = account
    }
}

