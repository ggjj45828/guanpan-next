import Foundation

// MARK: - 三类画像信息的来源

/// A. 用户明确规则（AI 不得自行修改） / B. AI 从真实行为学习 / C. 当前短期状态。
enum ProfileSource: String, Codable, CaseIterable, Identifiable {
    case explicit, learned, temporary

    var id: String { rawValue }
    var title: String {
        switch self {
        case .explicit: return "你明确设置"
        case .learned: return "AI 学习"
        case .temporary: return "最近状态"
        }
    }
    var note: String {
        switch self {
        case .explicit: return "AI 不会自行修改；只有你能改。"
        case .learned: return "随真实成交与反馈调整，达到最低样本量才生效。"
        case .temporary: return "只反映最近窗口，不会直接变成长期画像。"
        }
    }
}

// MARK: - 单条画像属性

/// 每个画像属性都带：当前值 / 置信度 / 数据来源 / 最近更新 / 为什么这么判断。
struct ProfileFact: Codable, Identifiable, Equatable {
    var id: String { key }
    let key: String
    let title: String
    var value: String
    var confidence: Double
    var source: ProfileSource
    var sampleSize: Int
    var updatedAt: Date
    /// 用户锁定后 AI 不得再改（即使学习到不同结论）。
    var locked: Bool
    var reason: String
    /// 依据行，用于「AI 为什么这样认为」。
    var evidence: [String]

    var confidenceTitle: String { "AI 置信度 \(Int((confidence * 100).rounded()))%" }
}

// MARK: - 偏好参数（供做T / 网格引擎直接消费）

struct TSessionPreference: Codable, Equatable {
    /// nil = 还没学到足够样本，不表态。
    var enabled: Bool? = nil
    /// 最低值得动手的预计净收益。
    var minNetProfit: Decimal = Decimal(string: "5")!
    /// 最低值得动手的价差百分比。
    var minSpreadPercent: Double = 0.6
    var maxPerDay: Int = 1
    var maxUnitsPerSession: Int? = nil
    /// 踏空容忍度 0–1：0 = 极怕踏空（少做反T），1 = 完全不在乎。
    var gapRiskTolerance: Double = 0.5
}

struct GridPreference: Codable, Equatable {
    var enabled: Bool? = nil
    var preferWideGrid: Bool? = nil
    var maxRungs: Int = 6
    /// 网格最多占用可用现金的比例。
    var maxCapitalRatio: Double = 0.6
    var pauseOnDowntrend: Bool = true
    var maxDurationDays: Int = 90
    var minNetPerRung: Decimal = Decimal(string: "3")!
}

struct CashPreference: Codable, Equatable {
    /// 愿意长期保留现金（等待机会）还是有钱就买。
    var willingToHoldCash: Bool? = nil
    var minimumCashReservePercent: Double = 10
    /// true = 倾向有钱就买。
    var deployImmediately: Bool? = nil
}

// MARK: - 资产角色（核心仓 / 机动仓）

/// 不同资产不能用同一套行为画像：核心仓允许波动、不轻易卖；机动仓可做T/网格。
struct AssetRole: Codable, Identifiable, Equatable {
    var id: String { code }
    let code: String
    var role: String            // core / flex
    var source: ProfileSource
    var updatedAt: Date
    var note: String

    var roleTitle: String { role == "core" ? "长期核心仓" : "行业机动仓" }
    static func defaultRole(for code: String, at date: Date = Date()) -> AssetRole {
        AssetRole(code: code, role: "flex", source: .temporary, updatedAt: date,
                  note: "未指定；按机动仓处理，可做T与网格。")
    }
}

// MARK: - AI 建议的观察记录（学习素材）

/// AI 每次出建议后记录用户反应。只记真实行为与真实反馈。
struct ProfileObservation: Codable, Identifiable, Equatable {
    var id = UUID()
    var at: Date
    /// tsession / grid / buy / limit
    var kind: String
    var code: String
    /// 建议当时的预计净收益（用于判断用户偏好高质量机会）。
    var proposedNetProfit: Decimal?
    var proposedSpreadPercent: Double?
    /// accepted / ignored / modified / cancelled / executed
    var outcome: String
    /// 用户主动反馈标签。
    var feedback: String?
    /// 最终是否真实成交。
    var reallyExecuted: Bool
}

/// 用户在建议卡上可以点的一键反馈。不是问卷。
enum ProfileFeedback: String, CaseIterable, Identifiable {
    case suitsMe, priceTooAggressive, spreadTooSmall, riskTooHigh, wantToHold, noTradeNow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .suitsMe: return "这个机会适合我"
        case .priceTooAggressive: return "价格太激进"
        case .spreadTooSmall: return "价差太小"
        case .riskTooHigh: return "风险太高"
        case .wantToHold: return "我想继续持有"
        case .noTradeNow: return "暂时不想交易"
        }
    }
    /// 该反馈对画像的影响方向，供学习算法使用。
    var implication: String {
        switch self {
        case .suitsMe: return "正样本：提高同类机会的推荐优先级。"
        case .priceTooAggressive: return "提高卖出价要求 / 降低激进档位。"
        case .spreadTooSmall: return "提高最低价差与最低净收益门槛。"
        case .riskTooHigh: return "降低单档份额与资金占用。"
        case .wantToHold: return "降低该标的的交易频率，倾向持有。"
        case .noTradeNow: return "计入忽略样本，降低同类提醒频率。"
        }
    }
}

// MARK: - 真实交易行为统计（只用真实成交）

struct TradeBehavior: Codable, Equatable {
    var fillCount = 0
    var buyCount = 0
    var sellCount = 0
    var avgHoldingDays: Double?
    var fillsPerMonth: Double = 0
    var monthsObserved: Double = 0
    var avgTradeAmount: Decimal = 0
    var avgTradeShareOfHoldings: Double?
    var totalFees: Decimal = 0
    var totalRealized: Decimal = 0
    /// 卖出中盈利单占比。
    var takeProfitRatio: Double?
    /// 卖出中亏损单占比。
    var stopLossRatio: Double?
    /// 买入价低于当时持仓成本的比例（下跌后补仓倾向）。
    var buyBelowCostRatio: Double?
    /// 买入价高于当时持仓成本的比例（上涨后追涨倾向）。
    var chaseAboveCostRatio: Double?
    /// 被异常过滤排除的成交笔数。
    var excludedOutliers = 0

    var summaryLines: [String] {
        var lines: [String] = ["真实成交 \(fillCount) 笔（买 \(buyCount) / 卖 \(sellCount)）"]
        if let d = avgHoldingDays { lines.append("平均持仓 \(NextNum.text(d, digits: 0)) 天") }
        if monthsObserved > 0 { lines.append("月均 \(NextNum.text(fillsPerMonth, digits: 1)) 笔") }
        lines.append("累计手续费 ¥\(NextMoney.text(totalFees, digits: 2)) · 已实现 ¥\(NextMoney.text(totalRealized, digits: 2))")
        if let t = takeProfitRatio { lines.append("卖出中盈利占 \(NextNum.percent(t * 100, digits: 0))") }
        if let b = buyBelowCostRatio { lines.append("下跌后补仓倾向 \(NextNum.percent(b * 100, digits: 0))") }
        if let c = chaseAboveCostRatio { lines.append("上涨后追涨倾向 \(NextNum.percent(c * 100, digits: 0))") }
        if excludedOutliers > 0 { lines.append("已过滤异常成交 \(excludedOutliers) 笔（单次金额超中位数 3 倍）") }
        return lines
    }
}

// MARK: - 画像主体

struct InvestorProfile: Codable, Equatable {
    var schemaVersion = 1
    /// 维度 key → 画像属性。
    var facts: [String: ProfileFact] = [:]
    var tsession = TSessionPreference()
    var grid = GridPreference()
    var cash = CashPreference()
    /// 投资风格标签（可多个）。
    var styleTags: [String] = []
    /// 资产角色（核心仓 / 机动仓）。
    var assetRoles: [String: AssetRole] = [:]
    /// AI 建议观察记录（真实行为学习素材）。
    var observations: [ProfileObservation] = []
    var lastLearnedAt: Date?
    var lastBehavior: TradeBehavior?

    // MARK: 默认值

    static func empty() -> InvestorProfile {
        let now = Date()
        var profile = InvestorProfile()
        let seed: [(String, String, String, ProfileSource, String)] = [
            ("horizon", "长期目标", "尚未学习", .learned, "还没有足够的真实成交与持仓周期数据。"),
            ("tradeFrequency", "交易风格", "尚未学习", .learned, "样本不足，不推断交易频率。"),
            ("limitPatience", "耐心限价", "尚未学习", .learned, "还没有耐心限价计划的执行记录。"),
            ("tsession", "做T习惯", "尚未学习", .learned, "还没有做T建议的执行记录。"),
            ("grid", "网格习惯", "尚未学习", .learned, "还没有网格建议的执行记录。"),
            ("cashStyle", "现金偏好", "尚未学习", .learned, "现金比例样本不足。"),
            ("execution", "交易执行", "AI 推荐 / 手工下单", .explicit, "系统默认：AI 只出建议，不自动下单。"),
            ("risk.drawdown", "账户回撤承受", "尚未学习", .learned, "需要更长的资产曲线才能判断。"),
            ("risk.singleAsset", "单资产回撤承受", "尚未学习", .learned, "由最大单资产仓位与集中度上限推断。"),
            ("risk.sectorETF", "行业ETF风险承受", "尚未学习", .learned, "看行业类 ETF 的持有占比。"),
            ("risk.cashflow", "现金流压力", "尚未学习", .learned, "看现金比例与新增资金节奏。")
        ]
        for (key, title, value, source, reason) in seed {
            profile.facts[key] = ProfileFact(key: key, title: title, value: value, confidence: 0,
                                             source: source, sampleSize: 0, updatedAt: now,
                                             locked: source == .explicit, reason: reason, evidence: [])
        }
        return profile
    }

    func role(for code: String) -> AssetRole {
        assetRoles[code] ?? AssetRole.defaultRole(for: code)
    }
    var isCoreAssetLocked: [String] {
        assetRoles.values.filter { $0.role == "core" && $0.source == .explicit }.map(\.code).sorted()
    }
}

// MARK: - 机会候选（参与画像排序）

struct OpportunityCandidate: Identifiable, Equatable {
    var id: String
    var code: String
    var title: String
    /// 预计净收益（真实计算得出）。
    var netProfit: Decimal
    /// 成交概率 0–1（由历史触及率等真实统计得出）。
    var fillProbability: Double
    /// 踏空风险 0–1。
    var gapRisk: Double
}

struct RankedOpportunity: Identifiable, Equatable {
    var id: String { candidate.id }
    let candidate: OpportunityCandidate
    let score: Double
    /// 为什么排在这里（含与纯收益排序的差异解释）。
    var explanation: String
}

// MARK: - 学习引擎

enum InvestorProfileEngine {
    /// 升级为「已学习」所需的最低样本量。低于此数只记为 Temporary State。
    static let minSamplesToLearn = 8
    /// 学习窗口（天）。超出窗口的样本不计入长期画像。
    static let learningWindowDays = 180
    /// 异常过滤阈值：单次金额超过中位数的这个倍数即视为异常，不参与频率类统计。
    static let outlierMultiple = 3.0

    // MARK: 真实交易行为统计

    static func tradeBehavior(book: NextBook, now: Date = Date()) -> TradeBehavior {
        var behavior = TradeBehavior()
        let fills = book.fills.sorted { $0.date < $1.date }
        guard !fills.isEmpty else { return behavior }

        // 异常过滤：先算金额中位数，超 3 倍的不进频率统计。
        let amounts = fills.map { $0.price * Decimal($0.units) }
        let sortedAmounts = amounts.sorted()
        let medianAmount = sortedAmounts[sortedAmounts.count / 2]
        let outlierCut = NextNum.double(medianAmount) * outlierMultiple

        var usable: [NextFill] = []
        for fill in fills {
            let amount = NextNum.double(fill.price * Decimal(fill.units))
            if medianAmount > 0 && amount > outlierCut { behavior.excludedOutliers += 1; continue }
            usable.append(fill)
        }
        // 金额与手续费仍按全部成交统计（这是事实，不是偏好）。
        behavior.fillCount = fills.count
        behavior.totalFees = fills.reduce(Decimal.zero) { $0 + $1.fee }
        behavior.totalRealized = fills.reduce(Decimal.zero) { $0 + $1.realized }
        behavior.buyCount = fills.filter { $0.side == "buy" }.count
        behavior.sellCount = fills.filter { $0.side == "sell" }.count
        if !usable.isEmpty {
            behavior.avgTradeAmount = usable.reduce(Decimal.zero) { $0 + $1.price * Decimal($1.units) } / Decimal(usable.count)
        }
        guard let first = fills.first else { return behavior }
        let months = max(0.5, Double(now.timeIntervalSince(first.date)) / 2_592_000.0)
        behavior.monthsObserved = months
        behavior.fillsPerMonth = Double(usable.count) / months

        // 平均持仓天数：按代码 FIFO 配买卖对。
        var holdingDays: [Double] = []
        var byCode: [String: [NextFill]] = [:]
        for fill in usable { byCode[fill.code, default: []].append(fill) }
        for (_, items) in byCode {
            var queue: [(Date, Int)] = []
            for fill in items {
                if fill.side == "buy" {
                    queue.append((fill.date, fill.units))
                } else {
                    var remaining = fill.units
                    while remaining > 0, let oldest = queue.first {
                        let take = min(remaining, oldest.1)
                        let days = Double(fill.date.timeIntervalSince(oldest.0)) / 86_400.0
                        if days >= 0 { holdingDays.append(days) }
                        remaining -= take
                        queue.removeFirst()
                        if oldest.1 - take > 0 { queue.insert((oldest.0, oldest.1 - take), at: 0) }
                    }
                }
            }
        }
        behavior.avgHoldingDays = holdingDays.isEmpty ? nil : holdingDays.reduce(0, +) / Double(holdingDays.count)

        // 止盈 / 止损习惯：卖出价相对当时持仓成本。
        var wins = 0, losses = 0, sells = 0
        var below = 0, above = 0, buys = 0
        for (code, items) in byCode {
            var runningUnits = 0
            var runningCost: Decimal = 0
            for fill in items {
                if fill.side == "buy" {
                    runningCost += fill.price * Decimal(fill.units)
                    runningUnits += fill.units
                } else {
                    guard runningUnits > 0 else { continue }
                    let costPerUnit = runningCost / Decimal(runningUnits)
                    sells += 1
                    if fill.price > costPerUnit { wins += 1 }
                    if fill.price < costPerUnit { losses += 1 }
                    runningUnits = max(0, runningUnits - fill.units)
                    runningCost = max(0, runningCost - costPerUnit * Decimal(min(fill.units, runningUnits + fill.units)))
                }
                if fill.side == "buy" && runningUnits > fill.units {
                    let priorCostPerUnit = (runningCost - fill.price * Decimal(fill.units)) / Decimal(max(1, runningUnits - fill.units))
                    buys += 1
                    if fill.price < priorCostPerUnit { below += 1 }
                    if fill.price > priorCostPerUnit { above += 1 }
                }
            }
        }
        if sells > 0 { behavior.takeProfitRatio = Double(wins) / Double(sells); behavior.stopLossRatio = Double(losses) / Double(sells) }
        if buys > 0 { behavior.buyBelowCostRatio = Double(below) / Double(buys); behavior.chaseAboveCostRatio = Double(above) / Double(buys) }
        return behavior
    }

    // MARK: 主学习入口

    static func learn(profile: inout InvestorProfile,
                      book: NextBook,
                      quotes: [String: NextQuote],
                      goal: NextGoal,
                      plans: [NextPatientLimitPlan],
                      now: Date = Date()) {
        let windowStart = now.addingTimeInterval(-Double(learningWindowDays) * 86_400)
        let behavior = tradeBehavior(book: book, now: now)
        profile.lastBehavior = behavior

        // 只保留窗口内的观察
        profile.observations = profile.observations.filter { $0.at >= windowStart }

        update(&profile, key: "horizon", from: horizonFact(goal: goal, behavior: behavior, now: now))
        update(&profile, key: "tradeFrequency", from: frequencyFact(behavior: behavior, now: now))
        update(&profile, key: "limitPatience", from: limitFact(plans: plans, now: now))
        update(&profile, key: "tsession", from: tsessionFact(profile: profile, now: now))
        update(&profile, key: "grid", from: gridFact(profile: profile, now: now))
        update(&profile, key: "cashStyle", from: cashFact(book: book, quotes: quotes, goal: goal, now: now))
        update(&profile, key: "risk.drawdown", from: drawdownFact(goal: goal, behavior: behavior, now: now))
        update(&profile, key: "risk.singleAsset", from: singleAssetFact(book: book, quotes: quotes, goal: goal, now: now))
        update(&profile, key: "risk.sectorETF", from: sectorFact(book: book, quotes: quotes, now: now))
        update(&profile, key: "risk.cashflow", from: cashflowFact(book: book, quotes: quotes, now: now))

        // 资产角色：AI 只能推断 flex，绝不能把 explicit 的 core 改成 flex。
        for position in book.positions where position.units > 0 {
            if profile.assetRoles[position.code] == nil {
                profile.assetRoles[position.code] = AssetRole.defaultRole(for: position.code, at: now)
            }
        }

        profile.styleTags = buildStyleTags(behavior: behavior, profile: profile, goal: goal)
        profile.lastLearnedAt = now
    }

    /// 写入一条画像属性。规则：
    /// - 用户锁定（locked）或来源为 explicit 的，AI 一律不得覆盖；
    /// - 样本量不足时降级为 temporary，不改变已有的长期结论。
    private static func update(_ profile: inout InvestorProfile, key: String, from candidate: ProfileFact?) {
        guard let candidate else { return }
        if let existing = profile.facts[key], existing.locked || existing.source == .explicit { return }
        let demoted: ProfileFact = {
            if candidate.sampleSize < minSamplesToLearn {
                var copy = candidate
                copy.source = .temporary
                copy.confidence = min(candidate.confidence, 0.45)
                if !copy.reason.hasPrefix("样本不足") {
                    copy.reason = "样本不足（\(candidate.sampleSize)/\(minSamplesToLearn)），仅记为最近状态，不升级为长期画像。" + candidate.reason
                }
                return copy
            }
            return candidate
        }()
        profile.facts[key] = demoted
    }

    // MARK: 各维度推断

    private static func horizonFact(goal: NextGoal, behavior: TradeBehavior, now: Date) -> ProfileFact {
        let years = goal.years
        let value: String
        switch years {
        case ..<3: value = "短期"
        case ..<8: value = "中期"
        case ..<15: value = "长期"
        default: value = "超长期"
        }
        var evidence = ["你在「目标与资金」里设定的投资期限是 \(years) 年。"]
        if let d = behavior.avgHoldingDays {
            evidence.append("真实成交配对出的平均持仓时间 \(NextNum.text(d, digits: 0)) 天。")
        }
        // 投资期限属于用户明确设定 → explicit，AI 不得改。
        return ProfileFact(key: "horizon", title: "长期目标", value: value, confidence: 0.95,
                           source: .explicit, sampleSize: max(1, behavior.fillCount), updatedAt: now,
                           locked: true, reason: "来自你主动填写的投资期限，属于明确规则，AI 不会自行修改。", evidence: evidence)
    }

    private static func frequencyFact(behavior: TradeBehavior, now: Date) -> ProfileFact? {
        guard behavior.monthsObserved >= 1 else { return nil }
        let perMonth = behavior.fillsPerMonth
        let value: String
        if perMonth < 1.2 { value = "低频择机" }
        else if perMonth < 4 { value = "正常" }
        else { value = "积极" }
        let confidence = min(0.9, 0.4 + min(0.45, Double(behavior.fillCount) / 24.0))
        var evidence = ["真实成交 \(behavior.fillCount) 笔，覆盖 \(NextNum.text(behavior.monthsObserved, digits: 1)) 个月，月均 \(NextNum.text(perMonth, digits: 1)) 笔。"]
        if let d = behavior.avgHoldingDays { evidence.append("平均持仓 \(NextNum.text(d, digits: 0)) 天，持股周期越长越偏低频。") }
        if behavior.excludedOutliers > 0 { evidence.append("已剔除 \(behavior.excludedOutliers) 笔异常大额成交，避免单次行为影响判断。") }
        return ProfileFact(key: "tradeFrequency", title: "交易风格", value: value, confidence: confidence,
                           source: .learned, sampleSize: behavior.fillCount, updatedAt: now, locked: false,
                           reason: "按真实成交频率与平均持仓时间推断；样本低于 \(minSamplesToLearn) 笔时只作短期状态。", evidence: evidence)
    }

    private static func limitFact(plans: [NextPatientLimitPlan], now: Date) -> ProfileFact? {
        guard !plans.isEmpty else { return nil }
        let executed = plans.filter { $0.state == "价格已触发" }
        let cancelled = plans.filter { $0.state == "已撤销" }
        let expired = plans.filter { $0.state == "已过期" }
        let waiting = plans.filter { $0.state == "等待价格提醒" }
        // 等待时长：已结束的计划从建立到结束的天数
        var waits: [Double] = []
        for plan in plans where plan.state != "等待价格提醒" {
            let end = plan.triggeredAt ?? plan.expiresAt
            waits.append(max(0, Double(end.timeIntervalSince(plan.createdAt)) / 86_400))
        }
        let avgWait = waits.isEmpty ? nil : waits.reduce(0, +) / Double(waits.count)
        let value: String
        if let w = avgWait, w >= 14 { value = "愿意长期挂单" }
        else if waiting.count >= executed.count && !waiting.isEmpty { value = "不追求立即成交" }
        else { value = "追求较快成交" }
        var evidence = ["耐心限价计划 \(plans.count) 条：触发 \(executed.count) / 撤销 \(cancelled.count) / 过期 \(expired.count) / 等待中 \(waiting.count)。"]
        if let w = avgWait { evidence.append("已结束计划的平均存续 \(NextNum.text(w, digits: 0)) 天。") }
        return ProfileFact(key: "limitPatience", title: "耐心限价", value: value, confidence: min(0.85, 0.35 + Double(plans.count) * 0.08),
                           source: .learned, sampleSize: plans.count, updatedAt: now, locked: false,
                           reason: "按耐心限价计划的触发率、撤销率与平均挂单天数推断。", evidence: evidence)
    }

    private static func tsessionFact(profile: InvestorProfile, now: Date) -> ProfileFact? {
        let items = profile.observations.filter { $0.kind == "tsession" }
        guard !items.isEmpty else { return nil }
        let executed = items.filter { $0.reallyExecuted }
        let rate = Double(executed.count) / Double(items.count)
        // 执行的机会是否集中在高质量（净收益前 30%）？
        let profits = items.compactMap { NextNum.double($0.proposedNetProfit ?? 0) }.sorted()
        let topThreshold = profits.isEmpty ? 0 : profits[Int((Double(profits.count - 1) * 0.7).rounded())]
        let executedHighQuality = executed.filter { NextNum.double($0.proposedNetProfit ?? 0) >= topThreshold }.count
        let highShare = executed.isEmpty ? 0 : Double(executedHighQuality) / Double(executed.count)

        let value: String
        if rate < 0.25 && highShare >= 0.6 { value = "低频 · 只做高质量机会" }
        else if rate < 0.25 { value = "低频 · 很少执行" }
        else if rate < 0.6 { value = "择机执行" }
        else { value = "积极执行" }

        var evidence = ["过去收到 \(items.count) 次做T建议，实际执行 \(executed.count) 次（\(NextNum.percent(rate * 100, digits: 0))）。"]
        if !executed.isEmpty {
            evidence.append("执行的 \(executed.count) 次中有 \(executedHighQuality) 次属于预计净收益排名前 30% 的机会（\(NextNum.percent(highShare * 100, digits: 0))）。")
        }
        // 反推偏好门槛：把已执行机会的净收益中位数作为新的最低门槛（避免小价差打扰）
        if executed.count >= 3 {
            let executedProfits = executed.compactMap { NextNum.double($0.proposedNetProfit ?? 0) }.sorted()
            let medianProfit = executedProfits[executedProfits.count / 2]
            evidence.append("已按你实际执行的净收益中位数 ¥\(NextNum.text(medianProfit, digits: 2)) 上调提醒门槛。")
        }
        let confidence = min(0.92, 0.35 + Double(items.count) * 0.05)
        return ProfileFact(key: "tsession", title: "做T习惯", value: value, confidence: confidence,
                           source: .learned, sampleSize: items.count, updatedAt: now, locked: false,
                           reason: "按做T建议的执行率与执行机会的质量分布推断；若长期只执行高质量机会，系统会自动减少小价差提醒。",
                           evidence: evidence)
    }

    private static func gridFact(profile: InvestorProfile, now: Date) -> ProfileFact? {
        let items = profile.observations.filter { $0.kind == "grid" }
        guard !items.isEmpty else { return nil }
        let executed = items.filter { $0.reallyExecuted }
        let rate = Double(executed.count) / Double(items.count)
        let value: String
        if rate >= 0.5 { value = "震荡行情常用" }
        else if rate > 0 { value = "偶尔使用" }
        else { value = "基本不用" }
        var evidence = ["收到 \(items.count) 次网格建议，实际采用 \(executed.count) 次（\(NextNum.percent(rate * 100, digits: 0))）。"]
        let cancelled = items.filter { $0.outcome == "cancelled" }.count
        if cancelled > 0 { evidence.append("其中 \(cancelled) 次被取消，可能是不希望资金长期被多个买档占用。") }
        return ProfileFact(key: "grid", title: "网格习惯", value: value, confidence: min(0.85, 0.35 + Double(items.count) * 0.06),
                           source: .learned, sampleSize: items.count, updatedAt: now, locked: false,
                           reason: "按网格建议的采用率与取消原因推断；若频繁取消，会自动减少档数与资金占用。", evidence: evidence)
    }

    private static func cashFact(book: NextBook, quotes: [String: NextQuote], goal: NextGoal, now: Date) -> ProfileFact? {
        var holdingValue: Decimal = 0
        for p in book.positions where p.units > 0 {
            let price = quotes[p.code]?.price ?? p.costPerUnit
            holdingValue += price * Decimal(p.units)
        }
        let total = book.cash + holdingValue
        guard total > 0 else { return nil }
        let cashRatio = NextNum.double(book.cash / total)
        let value: String
        if cashRatio >= 0.3 { value = "愿意等待机会" }
        else if cashRatio >= 0.12 { value = "保留适度现金" }
        else { value = "倾向满仓" }
        var evidence = ["当前现金 ¥\(NextMoney.text(book.cash, digits: 2))，占总资产 \(NextNum.percent(cashRatio * 100, digits: 1))。"]
        if let target = goal.targetCashWeight {
            evidence.append("你设置的现金目标为 \(NextMoney.text(target, digits: 1))%。")
        }
        return ProfileFact(key: "cashStyle", title: "现金偏好", value: value, confidence: 0.55,
                           source: .learned, sampleSize: 1, updatedAt: now, locked: false,
                           reason: "按当前现金占比推断；这是瞬时快照，样本少，只作参考。", evidence: evidence)
    }

    private static func drawdownFact(goal: NextGoal, behavior: TradeBehavior, now: Date) -> ProfileFact? {
        guard behavior.sellCount > 0 else { return nil }
        let limit = NextNum.double(goal.concentrationLimit)
        let value: String
        if limit >= 50 { value = "较高" }
        else if limit >= 30 { value = "中等" }
        else { value = "较低" }
        var evidence = ["你设置的单只集中度上限 \(NextMoney.text(goal.concentrationLimit, digits: 0))%，越高说明越能容忍单只波动。"]
        if let s = behavior.stopLossRatio { evidence.append("卖出中亏损了结占 \(NextNum.percent(s * 100, digits: 0))，越低说明越能扛住浮亏。") }
        return ProfileFact(key: "risk.drawdown", title: "账户回撤承受", value: value, confidence: 0.6,
                           source: .learned, sampleSize: behavior.sellCount, updatedAt: now, locked: false,
                           reason: "由你设置的集中度上限与真实卖出行为共同推断。", evidence: evidence)
    }

    private static func singleAssetFact(book: NextBook, quotes: [String: NextQuote], goal: NextGoal, now: Date) -> ProfileFact? {
        var values: [(String, Decimal)] = []
        for p in book.positions where p.units > 0 {
            let price = quotes[p.code]?.price ?? p.costPerUnit
            values.append((p.code, price * Decimal(p.units)))
        }
        let total = values.reduce(Decimal.zero) { $0 + $1.1 } + book.cash
        guard total > 0, let max = values.map(\.1).max() else { return nil }
        let weight = NextNum.double(max / total) * 100
        let value: String
        if weight >= 45 { value = "集中持有" }
        else if weight >= 25 { value = "适度集中" }
        else { value = "分散" }
        let top = values.max(by: { $0.1 < $1.1 })?.0 ?? "—"
        return ProfileFact(key: "risk.singleAsset", title: "单资产回撤承受", value: value, confidence: 0.7,
                           source: .learned, sampleSize: values.count, updatedAt: now, locked: false,
                           reason: "按当前最大单只占比 \(NextNum.percent(weight, digits: 1))% 推断；超过你设置的集中度上限 \(NextMoney.text(goal.concentrationLimit, digits: 0))% 时会提示风险。",
                           evidence: ["最大单只 \(top) 占 \(NextNum.percent(weight, digits: 1))%。", "你的集中度上限 \(NextMoney.text(goal.concentrationLimit, digits: 0))%。"])
    }

    private static func sectorFact(book: NextBook, quotes: [String: NextQuote], now: Date) -> ProfileFact? {
        let sectorPrefixes = ["159", "516", "512", "560", "588"]
        var sectorValue: Decimal = 0
        var total: Decimal = book.cash
        for p in book.positions where p.units > 0 {
            let price = quotes[p.code]?.price ?? p.costPerUnit
            let value = price * Decimal(p.units)
            total += value
            if sectorPrefixes.contains(where: { p.code.hasPrefix($0) }) { sectorValue += value }
        }
        guard total > 0 else { return nil }
        let ratio = NextNum.double(sectorValue / total) * 100
        let value: String
        if ratio >= 50 { value = "高（行业占比 \(NextNum.percent(ratio, digits: 0))%）" }
        else if ratio >= 25 { value = "中等（行业占比 \(NextNum.percent(ratio, digits: 0))%）" }
        else { value = "低（行业占比 \(NextNum.percent(ratio, digits: 0))%）" }
        return ProfileFact(key: "risk.sectorETF", title: "行业ETF风险承受", value: value, confidence: 0.6,
                           source: .learned, sampleSize: book.positions.count, updatedAt: now, locked: false,
                           reason: "按行业类 ETF 在总资产中的占比推断（代码前缀 159/516/512/560/588 视为行业类）。",
                           evidence: ["行业类 ETF 市值占总资产 \(NextNum.percent(ratio, digits: 1))%。"])
    }

    private static func cashflowFact(book: NextBook, quotes: [String: NextQuote], now: Date) -> ProfileFact? {
        let inflows = book.cashMovements.filter { $0.amount > 0 }
        guard !inflows.isEmpty else { return nil }
        let recent = inflows.filter { now.timeIntervalSince($0.date) <= 90 * 86_400 }
        let value: String
        if recent.count >= 3 { value = "持续注入（近90天 \(recent.count) 笔）" }
        else { value = "偶有注入" }
        return ProfileFact(key: "risk.cashflow", title: "现金流压力", value: value, confidence: 0.5,
                           source: .learned, sampleSize: inflows.count, updatedAt: now, locked: false,
                           reason: "按真实入金流水推断：持续注入说明现金流压力较小。",
                           evidence: ["累计入金 \(inflows.count) 笔，近90天 \(recent.count) 笔。"])
    }

    private static func buildStyleTags(behavior: TradeBehavior, profile: InvestorProfile, goal: NextGoal) -> [String] {
        var tags: [String] = []
        if goal.years >= 10 { tags.append("长期配置") }
        let limitPlans = profile.facts["limitPatience"]?.sampleSize ?? 0
        if limitPlans > 0 { tags.append("耐心限价") }
        if behavior.fillsPerMonth > 0 && behavior.fillsPerMonth < 1.2 { tags.append("低频择机") }
        if let below = behavior.buyBelowCostRatio, below >= 0.5 { tags.append("主动降本") }
        if let t = behavior.takeProfitRatio, t >= 0.6 { tags.append("盈利了结") }
        if goal.concentrationLimit >= 40 { tags.append("容忍集中") }
        if tags.isEmpty { tags.append("样本积累中") }
        return Array(NSOrderedSet(array: tags).compactMap { $0 as? String })
    }

    // MARK: 偏好参数学习（直接供做T / 网格引擎使用）

    /// 根据真实执行记录更新做T门槛：长期只执行大价差 → 自动提高门槛，减少打扰。
    static func updateTSessionPreference(_ pref: inout TSessionPreference, profile: InvestorProfile) {
        let items = profile.observations.filter { $0.kind == "tsession" }
        let executed = items.filter { $0.reallyExecuted }
        guard executed.count >= 3 else { return }
        let profits = executed.compactMap { NextNum.double($0.proposedNetProfit ?? 0) }.sorted()
        guard let medianProfit = profits.isEmpty ? nil : Optional(profits[profits.count / 2]) else { return }
        // 门槛取实际执行净收益中位数的 80%：低于这个水平的机会不再主动提醒。
        let learned = max(1, medianProfit * 0.8)
        pref.minNetProfit = NextNum.decimal(learned)

        let spreads = executed.compactMap { $0.proposedSpreadPercent }.sorted()
        if let medianSpread = spreads.isEmpty ? nil : Optional(spreads[spreads.count / 2]) {
            pref.minSpreadPercent = max(0.2, medianSpread * 0.8)
        }
        // 执行率低 → 说明用户不喜欢频繁做T
        let rate = Double(executed.count) / Double(items.count)
        if rate < 0.3 { pref.maxPerDay = 1 }
        // 反馈「价差太小」直接抬高门槛
        let smallSpreadVotes = items.filter { $0.feedback == ProfileFeedback.spreadTooSmall.rawValue }.count
        if smallSpreadVotes >= 2 {
            pref.minSpreadPercent *= 1.25
            pref.minNetProfit *= Decimal(string: "1.25")!
        }
        // 反馈「风险太高」→ 降低单次份额
        let riskVotes = items.filter { $0.feedback == ProfileFeedback.riskTooHigh.rawValue }.count
        if riskVotes >= 2, let current = pref.maxUnitsPerSession {
            pref.maxUnitsPerSession = Int(Double(current) * 0.7)
        }
        pref.enabled = rate > 0
    }

    /// 网格偏好：频繁取消 → 减少档数与资金占用。
    static func updateGridPreference(_ pref: inout GridPreference, profile: InvestorProfile) {
        let items = profile.observations.filter { $0.kind == "grid" }
        guard items.count >= 3 else { return }
        let executed = items.filter { $0.reallyExecuted }
        let cancelled = items.filter { $0.outcome == "cancelled" }
        pref.enabled = !executed.isEmpty
        if cancelled.count >= 2 {
            pref.maxRungs = max(3, pref.maxRungs - 1)
            pref.maxCapitalRatio = max(0.2, pref.maxCapitalRatio - 0.1)
        }
        let riskVotes = items.filter { $0.feedback == ProfileFeedback.riskTooHigh.rawValue }.count
        if riskVotes >= 2 { pref.maxCapitalRatio = max(0.2, pref.maxCapitalRatio - 0.1) }
    }

    // MARK: 机会排序（画像参与，但不改市场事实）

    /// 排序不是按净收益简单降序，而是结合成交概率、踏空风险与用户习惯。
    static func rank(_ candidates: [OpportunityCandidate], profile: InvestorProfile) -> [RankedOpportunity] {
        guard !candidates.isEmpty else { return [] }
        let profits = candidates.map { NextNum.double($0.netProfit) }
        let maxProfit = max(profits.max() ?? 0, 1e-9)
        let freq = profile.facts["tradeFrequency"]?.value ?? "正常"
        // 低频用户更看重成交概率与不打扰；积极用户可以更看重收益。
        let wProfit: Double = freq == "低频择机" ? 0.35 : (freq == "积极" ? 0.6 : 0.5)
        let wFill: Double = freq == "低频择机" ? 0.4 : 0.3
        let gapTolerance = profile.tsession.gapRiskTolerance
        let wGap: Double = 0.25 * (1 - gapTolerance) + 0.1

        var ranked: [RankedOpportunity] = candidates.map { c in
            let normProfit = NextNum.double(c.netProfit) / maxProfit
            let score = normProfit * wProfit + c.fillProbability * wFill - c.gapRisk * wGap
            return RankedOpportunity(candidate: c, score: score, explanation: "")
        }.sorted { $0.score > $1.score }

        // 解释：与纯收益排序的差异要说清楚
        let byProfit = candidates.sorted { NextNum.double($0.netProfit) > NextNum.double($1.netProfit) }
        let topByProfitID = byProfit.first?.id
        let topRankedID = ranked.first?.candidate.id
        for index in ranked.indices {
            let c = ranked[index].candidate
            var lines: [String] = []
            lines.append("预计净收益 ¥\(NextMoney.text(c.netProfit, digits: 2)) · 成交概率 \(NextNum.percent(c.fillProbability * 100, digits: 0)) · 踏空风险 \(NextNum.percent(c.gapRisk * 100, digits: 0))")
            if c.id == topRankedID, let profitTop = topByProfitID, profitTop != topRankedID,
               let profitTopItem = byProfit.first {
                lines.append("纯理论收益最高的是「\(profitTopItem.title)」（¥\(NextMoney.text(profitTopItem.netProfit, digits: 2))），但本项成交概率更高、踏空风险更低，更符合你「\(freq)」的历史习惯，因此排在第一。")
            }
            if profile.tsession.minNetProfit > 0 && c.netProfit < profile.tsession.minNetProfit {
                lines.append("该机会净收益低于你历史执行门槛 ¥\(NextMoney.text(profile.tsession.minNetProfit, digits: 2))，仅列出供参考，不主动提醒。")
            }
            ranked[index].explanation = lines.joined(separator: "；")
        }
        return ranked
    }

    // MARK: 在线 AI 的最小上下文（隐私：只给完成当前分析必需的结构化内容）

    static func minimalContext(profile: InvestorProfile) -> String {
        var lines: [String] = []
        lines.append("【用户画像（结构化，最小化）】")
        for key in ["horizon", "tradeFrequency", "limitPatience", "tsession", "grid", "cashStyle", "execution"] {
            guard let fact = profile.facts[key] else { continue }
            let sourceTag = fact.source == .explicit ? "用户明确设置，不得修改" : (fact.source == .temporary ? "短期状态，仅参考" : "AI 学习")
            lines.append("- \(fact.title)：\(fact.value)（置信度 \(Int((fact.confidence * 100).rounded()))%，\(sourceTag)）")
        }
        if !profile.styleTags.isEmpty { lines.append("- 风格标签：\(profile.styleTags.joined(separator: "、"))") }
        lines.append("- 做T门槛：最低净收益 ¥\(NextMoney.text(profile.tsession.minNetProfit, digits: 2))，最低价差 \(NextNum.percent(profile.tsession.minSpreadPercent, digits: 2))")
        lines.append("- 网格上限：最多 \(profile.grid.maxRungs) 档，资金占用不超过 \(NextNum.percent(profile.grid.maxCapitalRatio * 100, digits: 0))")
        let core = profile.isCoreAssetLocked
        if !core.isEmpty { lines.append("- 长期核心仓（不得改作机动交易）：\(core.joined(separator: "、"))") }
        lines.append("约束：画像只影响个性化程度与推荐优先级，不得修改市场事实、不得降低风险控制与数据质量要求。")
        return lines.joined(separator: "\n")
    }
}
