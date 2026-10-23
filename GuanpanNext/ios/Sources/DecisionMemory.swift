import Foundation

/// 一次 AI 决策的完整快照。
///
/// 存的是「当时看到了什么」，不是结论本身。这样事后才能回答：
/// 这个建议对不对？如果不对，是市场变了、数据变了，还是判断本身错了？
struct DecisionSnapshot: Codable, Identifiable, Equatable {
    var id = UUID()
    var createdAt: Date
    var code: String
    var name: String
    /// tsession / grid / buy / hold
    var kind: String

    // 当时的行情
    var priceAtDecision: Decimal
    var previousClose: Decimal
    var quoteObservedAt: Date?
    var quoteSource: String

    // 当时的持仓与现金
    var unitsAtDecision: Int
    var costPerUnitAtDecision: Decimal
    var cashAtDecision: Decimal

    // 当时的市场状态与研究
    var regime: String
    var regimeConfidence: Double
    var amplitude20Percent: Double?
    var support: Double?
    var resistance: Double?
    var nasResearchAsOf: String?
    var nasResearchState: String?

    // 当时的画像
    var profileDigest: [String: String]
    var tsessionMinNetProfit: Decimal
    var gridMaxRungs: Int
    /// 资产角色（核心仓 / 机动仓），防止 AI 把核心仓拿去做短线。
    var assetRole: String

    // AI 建议
    var headline: String
    var reasoning: String
    var suggestedPrice: Decimal?
    var suggestedUnits: Int?
    var expectedNetProfit: Decimal?

    // 风险、有效期、失效条件、依据
    var risks: [String]
    var validUntil: Date
    var invalidation: [String]
    var evidence: [String]

    // 后续结果
    /// 待观察 / 已成交 / 已失效 / 已作废
    var status = "待观察"
    var executedAt: Date?
    var executedPrice: Decimal?
    var executedUnits: Int?
    var reviewedAt: Date?
    var priceAtReview: Decimal?
    var actualPnL: Decimal?
    var outcomeNote: String?

    var isSettled: Bool { status == "已成交" || status == "已失效" || status == "已作废" }

    var summaryLine: String {
        var parts: [String] = [headline]
        if let price = suggestedPrice { parts.append("建议 ¥\(NextMoney.text(price, digits: 3))") }
        if let net = expectedNetProfit { parts.append("预计净收益 ¥\(NextMoney.text(net, digits: 2))") }
        return parts.joined(separator: " · ")
    }
}

enum DecisionMemoryStore {
    /// 快照保留天数。
    static let retentionDays = 365

    /// 生成一条决策快照。所有字段都来自调用时传入的真实数据，不在此处推断。
    static func make(code: String,
                     name: String,
                     kind: String,
                     price: Decimal,
                     previousClose: Decimal,
                     quote: NextCachedQuote?,
                     position: NextPosition?,
                     cash: Decimal,
                     regime: MarketRegimeResult,
                     research: NextNASResearch?,
                     profile: InvestorProfile,
                     headline: String,
                     reasoning: String,
                     suggestedPrice: Decimal?,
                     suggestedUnits: Int?,
                     expectedNetProfit: Decimal?,
                     risks: [String],
                     validUntil: Date,
                     invalidation: [String],
                     evidence: [String],
                     now: Date = Date()) -> DecisionSnapshot {
        var digest: [String: String] = [:]
        for key in ["horizon", "tradeFrequency", "limitPatience", "tsession", "grid", "cashStyle"] {
            if let fact = profile.facts[key] { digest[fact.title] = fact.value }
        }
        return DecisionSnapshot(
            createdAt: now, code: code, name: name, kind: kind,
            priceAtDecision: price, previousClose: previousClose,
            quoteObservedAt: quote?.quote.time, quoteSource: quote?.stamp.source ?? "—",
            unitsAtDecision: position?.units ?? 0,
            costPerUnitAtDecision: position?.costPerUnit ?? 0,
            cashAtDecision: cash,
            regime: regime.regime.title, regimeConfidence: regime.confidence,
            amplitude20Percent: regime.metrics.amplitude20Percent,
            support: regime.metrics.support, resistance: regime.metrics.resistance,
            nasResearchAsOf: research?.factors?.asOf, nasResearchState: research?.factors?.state,
            profileDigest: digest,
            tsessionMinNetProfit: profile.tsession.minNetProfit,
            gridMaxRungs: profile.grid.maxRungs,
            assetRole: profile.role(for: code).roleTitle,
            headline: headline, reasoning: reasoning,
            suggestedPrice: suggestedPrice, suggestedUnits: suggestedUnits,
            expectedNetProfit: expectedNetProfit,
            risks: risks, validUntil: validUntil, invalidation: invalidation, evidence: evidence)
    }

    /// 用真实成交流水回填「是否成交」与「实际结果」。
    /// 只有真实成交才会改变状态；没有成交就是没成交，不会用价格猜测。
    static func reconcile(_ snapshots: inout [DecisionSnapshot], book: NextBook, quotes: [String: NextCachedQuote], now: Date = Date()) {
        for index in snapshots.indices {
            var snap = snapshots[index]

            // 过期判定：过了有效期仍未成交 → 失效
            if snap.status == "待观察" && now > snap.validUntil {
                snap.status = "已失效"
                snap.outcomeNote = "超过有效期 \(snap.validUntil.formatted(date: .numeric, time: .shortened)) 未成交，方案作废。"
            }

            // 真实成交匹配：有效期内同标的同方向成交
            if snap.status == "待观察" || snap.status == "已失效" {
                // 成交匹配窗口：有效期之后再给 1 天宽限，避免收盘后录入的成交被漏掉。
                let windowEnd = snap.validUntil.addingTimeInterval(86_400)
                let matched = book.fills.filter { fill in
                    fill.code == snap.code
                    && fill.date >= snap.createdAt
                    && fill.date <= windowEnd
                    && (snap.kind == "buy" ? fill.side == "buy" : true)
                }.sorted { $0.date < $1.date }
                if let fill = matched.first {
                    snap.status = "已成交"
                    snap.executedAt = fill.date
                    snap.executedPrice = fill.price
                    snap.executedUnits = fill.units
                }
            }

            // 复盘：已有成交且还没复盘时，用最新报价算实际盈亏
            if snap.status == "已成交", snap.reviewedAt == nil, let executed = snap.executedPrice,
               let current = quotes[snap.code]?.quote.price {
                let units = Decimal(snap.executedUnits ?? 0)
                if snap.kind == "tsession" {
                    // 做T的盈亏 =（成交价 − 当前价）× 份额 − 手续费，买回才算完成
                    snap.actualPnL = (executed - current) * units
                } else {
                    snap.actualPnL = (current - executed) * units
                }
                snap.priceAtReview = current
            }
            snapshots[index] = snap
        }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        snapshots = snapshots.filter { $0.createdAt >= cutoff }
    }

    /// 回答「什么发生了变化」：AI 改变判断时必须能解释。
    static func whatChanged(before: DecisionSnapshot, after: DecisionSnapshot) -> [String] {
        var changes: [String] = []
        if before.regime != after.regime {
            changes.append("市场状态：\(before.regime) → \(after.regime)（置信度 \(Int((before.regimeConfidence * 100).rounded()))% → \(Int((after.regimeConfidence * 100).rounded()))%）")
        }
        let beforePrice = NextNum.double(before.priceAtDecision)
        let afterPrice = NextNum.double(after.priceAtDecision)
        if abs(beforePrice - afterPrice) > 1e-9 {
            let diff = afterPrice - beforePrice
            let percent = beforePrice > 0 ? diff / beforePrice * 100 : 0
            changes.append("价格：¥\(NextMoney.text(before.priceAtDecision, digits: 3)) → ¥\(NextMoney.text(after.priceAtDecision, digits: 3))（\(NextNum.signed(percent, digits: 2))%）")
        }
        if before.unitsAtDecision != after.unitsAtDecision {
            changes.append("持仓：\(before.unitsAtDecision) 份 → \(after.unitsAtDecision) 份")
        }
        if before.cashAtDecision != after.cashAtDecision {
            changes.append("可用现金：¥\(NextMoney.text(before.cashAtDecision, digits: 2)) → ¥\(NextMoney.text(after.cashAtDecision, digits: 2))")
        }
        if before.nasResearchAsOf != after.nasResearchAsOf {
            changes.append("NAS 研究日期：\(before.nasResearchAsOf ?? "无") → \(after.nasResearchAsOf ?? "无")")
        }
        if before.assetRole != after.assetRole {
            changes.append("资产角色：\(before.assetRole) → \(after.assetRole)")
        }
        for (title, value) in after.profileDigest {
            if let previous = before.profileDigest[title], previous != value {
                changes.append("画像「\(title)」：\(previous) → \(value)")
            }
        }
        if before.tsessionMinNetProfit != after.tsessionMinNetProfit {
            changes.append("做T门槛：¥\(NextMoney.text(before.tsessionMinNetProfit, digits: 2)) → ¥\(NextMoney.text(after.tsessionMinNetProfit, digits: 2))")
        }
        if before.gridMaxRungs != after.gridMaxRungs {
            changes.append("网格档数上限：\(before.gridMaxRungs) → \(after.gridMaxRungs)")
        }
        if changes.isEmpty {
            changes.append("市场状态、价格、持仓、画像与 NAS 研究均无变化；判断变化来自有效期到期或你对方案的重新评估。")
        }
        return changes
    }

    /// 命中率统计：真实成交的建议里，实际盈亏为正的比例。
    static func hitRate(_ snapshots: [DecisionSnapshot]) -> (total: Int, wins: Int, rate: Double?) {
        let settled = snapshots.filter { $0.status == "已成交" && $0.actualPnL != nil }
        guard !settled.isEmpty else { return (0, 0, nil) }
        let wins = settled.filter { ($0.actualPnL ?? 0) > 0 }.count
        return (settled.count, wins, Double(wins) / Double(settled.count))
    }
}

