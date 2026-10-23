import SwiftUI

/// 一条标的的完整指导链路结果。
struct GuidanceItem: Identifiable {
    var id: String { code }
    let code: String
    let name: String
    let regime: MarketRegimeResult
    /// tsession / grid / hold / none
    let choice: String
    let choiceReason: String
    let tsession: TSessionPlan?
    let grid: SmartGridPlan?
    /// 画像是否放行（不放行时不主动推荐，但仍展示计算过程）。
    let profileAllows: Bool
    let profileNote: String

    var choiceTitle: String {
        switch choice {
        case "tsession": return "做T"
        case "grid": return "网格"
        case "hold": return "持有"
        default: return "不交易"
        }
    }
}

/// 核心链路总控页：
/// 真实持仓 → 市场状态识别 → 做T/网格/持有/不交易 自动选择 → 具体限价与份额 →
/// 预计净收益/等效降本 → 画像判断 → 用户确认真实成交 → 更新真实持仓 → 反馈进入画像。
struct TradeGuidanceScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var items: [GuidanceItem] = []
    @State private var computed = false
    @State private var tradeRequest: GPTradeRequest?

    var body: some View {
        GPPageBackground {
            header
            if !computed {
                GPStatus(title: "正在按真实数据计算", detail: "读取真实持仓、本机日K与最新行情，识别市场状态并计算具体价格与份额。",
                         symbol: "hourglass")
            } else if items.isEmpty {
                GPStatus(title: "暂无可计算的标的", detail: "需要至少一只真实持仓，且本机存有该标的的日K历史。先录入持仓并刷新行情。",
                         symbol: "tray", actionTitle: "去录入持仓") { model.requestedTab = .assets }
            } else {
                ForEach(items) { item in
                    guidanceCard(item)
                }
            }
            disclaimer
        }
        .navigationTitle("今日交易指导")
        .task { if !computed { compute(); computed = true } }
        .sheet(item: $tradeRequest) { request in TradeEntrySheet(request: request) }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("今日交易指导").font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
            Text("每个价格与份额都由真实持仓、真实日K和真实手续费算出，不是大模型凭空生成。数据不足时直接拒绝给价。")
                .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            if let at = model.profile.lastLearnedAt {
                Text("画像：\(model.profile.facts["tradeFrequency"]?.value ?? "尚未学习") · 做T门槛 ¥\(NextMoney.text(model.profile.tsession.minNetProfit, digits: 2)) · 最近学习 \(at.formatted(date: .numeric, time: .shortened))")
                    .font(.caption2).foregroundStyle(p.muted)
            }
            HStack(spacing: 8) {
                GPActionButton(title: "重新计算", secondary: true, systemImage: "arrow.clockwise") { compute() }
                NavigationLink(value: GPRoute.profile) {
                    Label("AI 对我的了解", systemImage: "person.text.rectangle").font(.caption.weight(.semibold))
                }.tint(p.forest)
            }.padding(.top, 4)
        }
        .padding(.vertical, 10)
    }

    private var disclaimer: some View {
        Text("所有方案都是手工挂单参考，不会自动下单，也不会占用你的现金或改动持仓。只有你在成交录入里确认后，真实持仓与现金才会变化。")
            .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
    }

    // MARK: - 单标的卡片

    private func guidanceCard(_ item: GuidanceItem) -> some View {
        let tone = toneFor(item.choice)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                    Text("\(item.code) · \(model.profile.role(for: item.code).roleTitle)")
                        .font(.caption2).foregroundStyle(p.muted)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.choiceTitle).font(.subheadline.weight(.semibold)).foregroundStyle(tone)
                    Text("\(item.regime.regime.title) · \(Int((item.regime.confidence * 100).rounded()))%")
                        .font(.caption2).foregroundStyle(p.muted)
                }
            }

            Text(item.choiceReason).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)

            // 市场状态
            regimeBlock(item.regime)

            // 具体方案
            if let plan = item.tsession, item.choice == "tsession" { tsessionBlock(item: item, plan: plan) }
            if let grid = item.grid, item.choice == "grid" { gridBlock(grid: grid) }

            newsBlock(code: item.code)

            // 画像判断
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: item.profileAllows ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(item.profileAllows ? p.jade : p.chartGold)
                Text(item.profileNote).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }

            if let plan = item.tsession, item.choice == "tsession", let q = plan.quote {
                HStack(spacing: 8) {
                    Button("按卖出价记录成交") { tradeRequest = GPTradeRequest(code: item.code, side: "sell") }
                        .font(.caption2.weight(.semibold)).buttonStyle(.bordered).tint(p.gpUp)
                    Button("按买回价记录成交") { tradeRequest = GPTradeRequest(code: item.code, side: "buy") }
                        .font(.caption2.weight(.semibold)).buttonStyle(.bordered).tint(p.gpDown)
                }
                ProfileFeedbackBar(kind: "tsession", code: item.code, proposedNetProfit: q.net,
                                   proposedSpreadPercent: plan.spreadPercent)
            } else if item.choice == "grid" {
                ProfileFeedbackBar(kind: "grid", code: item.code,
                                   proposedNetProfit: item.grid?.netPerRung, proposedSpreadPercent: item.grid?.stepPercent)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(p.paper))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(tone.opacity(0.30), lineWidth: 0.9))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tone.opacity(0.75)).frame(width: 2.5).padding(.vertical, 14).padding(.leading, 1.2)
        }
        .padding(.top, 10)
    }

    private func regimeBlock(_ regime: MarketRegimeResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("市场状态 · \(regime.regime.title)").font(.caption.weight(.semibold)).foregroundStyle(p.ink)
            Text(regime.regime.strategyHint).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(regime.reasons, id: \.self) { line in
                HStack(alignment: .top, spacing: 5) {
                    Circle().fill(p.chartBlue.opacity(0.7)).frame(width: 4, height: 4).padding(.top, 5)
                    Text(line).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let support = regime.metrics.support, let resistance = regime.metrics.resistance {
                Text("支撑 ¥\(NextMoney.text(NextNum.decimal(support), digits: 3)) · 压力 ¥\(NextMoney.text(NextNum.decimal(resistance), digits: 3)) · 区间位置 \(NextNum.percent((regime.metrics.rangePosition ?? 0) * 100, digits: 0))")
                    .font(.caption2).foregroundStyle(p.muted)
            }
        }
    }

    /// 新闻 → 证券 → 我的真实持仓 → 当前 AI 计划 的关联判定。
    @ViewBuilder
    private func newsBlock(code: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("新闻与持仓关联").font(.caption.weight(.semibold)).foregroundStyle(p.ink)
            if let news = model.nasResearch[code]?.news {
                if news.unavailable == true {
                    Text("NAS 明确报告该标的新闻不可用（\(news.source)）。不会拿过期内容冒充最新情况，也不会因为没有新闻就假定安全。")
                        .font(.caption2).foregroundStyle(p.chartGold).fixedSize(horizontal: false, vertical: true)
                } else if let link = news.link {
                    Text("影响判定：\(link.action)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(link.action.hasPrefix("计划作废") ? p.risk : (link.action.hasPrefix("暂停") ? p.chartGold : p.jade))
                    Text(link.reason).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    Text("共 \(link.newsCount) 条资讯 · 来源 \(news.source) · \(news.asOf)")
                        .font(.caption2).foregroundStyle(p.muted)
                    ForEach(Array(news.items.prefix(5)), id: \.title) { item in
                        Text("· \(item.title)（\(item.media) \(item.date)）")
                            .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("NAS 返回了新闻但未给出影响判定。").font(.caption2).foregroundStyle(p.muted)
                }
            } else {
                Text("尚未从 NAS 取到该标的的新闻。连接 NAS 后会自动拉取真实资讯，并按规则判定对当前计划的影响。")
                    .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tsessionBlock(item: GuidanceItem, plan: TSessionPlan) -> some View {
        guard let q = plan.quote else { return AnyView(EmptyView()) }
        return AnyView(VStack(alignment: .leading, spacing: 6) {
            Text("\(plan.directionTitle) · 计算过程").font(.caption.weight(.semibold)).foregroundStyle(p.ink)
            GPDataRow(title: "卖出参考价", value: "¥\(NextMoney.text(q.sellPrice, digits: 3))", note: "由真实可达涨幅推出")
            GPDataRow(title: "买回参考价", value: "¥\(NextMoney.text(q.buyBackPrice, digits: 3))", note: "按真实回落幅度折让")
            GPDataRow(title: "建议份额", value: "\(q.units) 份", note: plan.direction == "reverse" ? "不超过底仓" : "不超过可用现金")
            GPDataRow(title: "毛价差", value: "¥\(NextMoney.text(q.gross, digits: 2))", note: "（卖出价 − 买回价）× 份额")
            GPDataRow(title: "手续费", value: "¥\(NextMoney.text(q.fees, digits: 2))", note: "买卖两笔合计")
            GPDataRow(title: "预计净收益", value: "¥\(NextMoney.text(q.net, digits: 2))",
                      note: "毛价差 − 手续费", valueColor: p.changeTone(NextNum.double(q.net)))
            GPDataRow(title: "等效降本", value: "每份 ¥\(NextMoney.text(q.costReductionPerUnit, digits: 4))",
                      note: "占持仓成本 \(NextNum.text(q.costReductionPercent, digits: 3))%")
            if let hit = plan.hitRate {
                GPDataRow(title: "历史触及", value: NextNum.percent(hit * 100, digits: 0),
                          note: "过去 \(plan.hitLookbackDays) 个交易日中同时出现过这两个价格的比例；日K无法判断先后，需盯盘")
            }
            GPDataRow(title: "有效期", value: TSessionEngine.shortDate(plan.validUntil) + " 收盘前", note: "日内方案，收盘失效")
            if !plan.invalidation.isEmpty {
                Text("失效条件").font(.caption2.weight(.semibold)).foregroundStyle(p.risk)
                ForEach(plan.invalidation, id: \.self) { line in
                    Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !plan.risks.isEmpty {
                Text("风险").font(.caption2.weight(.semibold)).foregroundStyle(p.risk)
                ForEach(plan.risks, id: \.self) { line in
                    Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !plan.blockers.isEmpty {
                Text("未达门槛").font(.caption2.weight(.semibold)).foregroundStyle(p.chartGold)
                ForEach(plan.blockers, id: \.self) { line in
                    Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("计算依据").font(.caption2.weight(.semibold)).foregroundStyle(p.forest)
            ForEach(plan.basis, id: \.self) { line in
                Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        })
    }

    private func gridBlock(grid: SmartGridPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("智能网格 · 计算过程").font(.caption.weight(.semibold)).foregroundStyle(p.ink)
            GPDataRow(title: "区间", value: "¥\(NextMoney.text(grid.lower, digits: 3)) – ¥\(NextMoney.text(grid.upper, digits: 3))", note: "近120日收盘 15%/85% 分位")
            GPDataRow(title: "档距", value: NextNum.percent(grid.stepPercent, digits: 2), note: "由真实波幅推出并保证扣费后有净收益")
            GPDataRow(title: "档数", value: "\(grid.rungs.count) 档", note: "买 \(grid.buyRungCount) / 卖 \(grid.sellRungCount)")
            GPDataRow(title: "资金占用", value: "¥\(NextMoney.text(grid.totalCapital, digits: 2))", note: "所有买入档合计")
            GPDataRow(title: "单档净收益", value: "¥\(NextMoney.text(grid.netPerRung, digits: 2))", note: "已扣两笔手续费")
            GPDataRow(title: "全档走完净收益", value: "¥\(NextMoney.text(grid.netIfAllFilled, digits: 2))", note: "每档各走一格的合计")
            if !grid.rungs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(grid.rungs) { rung in
                        HStack(spacing: 6) {
                            Text(rung.side == "buy" ? "买" : "卖")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(rung.side == "buy" ? p.gpDown : p.gpUp)
                                .frame(width: 18)
                            Text("¥\(NextMoney.text(rung.price, digits: 3))").font(.caption2.monospacedDigit()).foregroundStyle(p.ink)
                            Text("\(rung.units) 份").font(.caption2).foregroundStyle(p.muted)
                            Spacer()
                            Text("+¥\(NextMoney.text(rung.netIfFilled, digits: 2))").font(.caption2.monospacedDigit()).foregroundStyle(p.muted)
                        }
                    }
                }
            }
            Text("突破处理").font(.caption2.weight(.semibold)).foregroundStyle(p.forest)
            ForEach(grid.breakoutPolicy, id: \.self) { line in
                Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !grid.blockers.isEmpty {
                Text("未达门槛").font(.caption2.weight(.semibold)).foregroundStyle(p.chartGold)
                ForEach(grid.blockers, id: \.self) { line in
                    Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("计算依据").font(.caption2.weight(.semibold)).foregroundStyle(p.forest)
            ForEach(grid.basis, id: \.self) { line in
                Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choiceTitle(of choice: String) -> String {
        switch choice {
        case "tsession": return "做T"
        case "grid": return "网格"
        case "hold": return "持有"
        default: return "不交易"
        }
    }
    private func gridInvalidation(of plan: SmartGridPlan) -> [String] {
        ["价格突破 ¥\(NextMoney.text(plan.upper, digits: 3)) 或跌破 ¥\(NextMoney.text(plan.lower, digits: 3)) → 区间失效。",
         "最长 \(model.profile.grid.maxDurationDays) 天后重估。"]
    }

    private func toneFor(_ choice: String) -> Color {
        switch choice {
        case "tsession": return p.chartGold
        case "grid": return p.jade
        case "hold": return p.chartBlue
        default: return p.muted
        }
    }

    // MARK: - 计算（核心链路）

    private func compute() {
        var results: [GuidanceItem] = []
        let now = Date()
        for position in model.book.positions where position.units > 0 {
            let code = position.code
            guard let dataset = model.chartData["\(code):day"], dataset.samples.count >= 20 else { continue }
            guard let cached = model.quotes[code] else { continue }
            let quote = cached.quote
            let samples = dataset.samples
            let previousClose = samples.count >= 2 ? samples[samples.count - 2].close : quote.price
            let regime = MarketRegimeEngine.evaluate(samples: samples, now: now)
            let rules = model.rules[code]
            let fee = rules?.feePerTrade
            let lot = rules?.lotSize
            let role = model.profile.role(for: code)

            let tPlan = TSessionEngine.plan(code: code, name: model.name(for: code), position: position,
                                            lastPrice: quote.price, previousClose: previousClose,
                                            samples: samples, regime: regime, cash: model.book.cash,
                                            feePerTrade: fee, lotSize: lot,
                                            preference: model.profile.tsession, now: now)
            let gPlan = SmartGridEngine.plan(code: code, name: model.name(for: code), lastPrice: quote.price,
                                             samples: samples, regime: regime, cash: model.book.cash,
                                             heldUnits: position.units, feePerTrade: fee, lotSize: lot,
                                             preference: model.profile.grid, now: now)

            // ---- 策略自动选择：市场状态 × 真实持仓 × 画像 ----
            var choice = "hold"
            var reason = ""
            if regime.regime == .insufficient || regime.blocksPricePlan {
                choice = "none"
                reason = "日K样本或数据新鲜度不达标（\(regime.regime.title)），不做任何价格或份额计算。"
            } else if role.role == "core" && role.source == .explicit {
                choice = "hold"
                reason = "你已把它设为长期核心仓：允许较大波动、不轻易卖出，主要靠新增资金调整，不因短期技术信号改变长期计划。"
            } else if regime.regime == .abnormal {
                choice = "none"
                reason = "当前处于异常波动，按常规振幅定价不可靠，先观察一天再评估。"
            } else if regime.regime == .uptrend {
                choice = "hold"
                reason = "上涨趋势中做网格容易卖飞、反T容易踏空；继续持有更符合当前状态。"
            } else if regime.regime == .downtrend {
                choice = "hold"
                reason = "下跌趋势中网格买档会一路接跌；先持有观察，等回到震荡再考虑网格。"
            } else if tPlan.suitable {
                choice = "tsession"
                reason = "震荡市中做T方案成立：净收益 ¥\(NextMoney.text(tPlan.netProfit, digits: 2)) 已覆盖手续费并达到你的门槛。"
            } else if gPlan.suitable {
                choice = "grid"
                reason = "震荡市适合网格，做T方案未达门槛（\(tPlan.blockers.first ?? "净收益不足")），改用网格分批挂单。"
            } else {
                choice = "hold"
                let why = tPlan.blockers.first ?? gPlan.blockers.first ?? "当前价差不足以覆盖手续费与你的门槛"
                reason = "做T与网格都不达标：\(why)。继续持有。"
            }

            // ---- 新闻覆盖：重大事件直接让原做T/网格计划失效 ----
            if let link = model.nasResearch[code]?.news?.link {
                if link.action.hasPrefix("计划作废") {
                    let previous = choiceTitle(of: choice)
                    choice = "none"
                    reason = "新闻触发作废（\(link.reason)）。原判断为「\(previous)」，现已按重大事件作废，需重新评估后再议。"
                } else if link.action.hasPrefix("暂停新增买入档") && choice == "grid" {
                    choice = "hold"
                    reason = "新闻提示风险（\(link.reason)）。网格新增买入档暂停，暂不挂新买档，等风险解除再重估。"
                }
            }

            // ---- 画像放行判断：画像只能影响推荐优先级，不得制造机会 ----
            let minNet = model.profile.tsession.minNetProfit
            var allows = true
            var note = "画像未设置限制，方案已按真实数据给出。"
            if choice == "tsession" {
                if model.profile.tsession.enabled == false {
                    allows = false
                    note = "你的历史行为显示基本不做T，因此只展示计算过程，不主动推荐。"
                } else if tPlan.netProfit < minNet {
                    allows = false
                    note = "预计净收益 ¥\(NextMoney.text(tPlan.netProfit, digits: 2)) 低于你历史执行门槛 ¥\(NextMoney.text(minNet, digits: 2))；机会存在，但按你的习惯不主动提醒。"
                } else {
                    note = "达到你历史执行的净收益水平（门槛 ¥\(NextMoney.text(minNet, digits: 2))），主动推荐。"
                }
            } else if choice == "grid" {
                if model.profile.grid.enabled == false {
                    allows = false
                    note = "你的历史行为显示基本不用网格，仅展示计算过程。"
                } else {
                    note = "网格档数与资金占用已按你的偏好上限收敛（最多 \(model.profile.grid.maxRungs) 档，占用不超过 \(NextNum.percent(model.profile.grid.maxCapitalRatio * 100, digits: 0))）。"
                }
            }

            let snapshot = DecisionMemoryStore.make(
                code: code, name: model.name(for: code),
                kind: choice == "tsession" ? "tsession" : (choice == "grid" ? "grid" : "hold"),
                price: quote.price, previousClose: previousClose, quote: cached,
                position: position, cash: model.book.cash,
                regime: regime, research: model.nasResearch[code], profile: model.profile,
                headline: "\(choiceTitle(of: choice))：\(reason)",
                reasoning: reason,
                suggestedPrice: choice == "tsession" ? tPlan.quote?.sellPrice : (choice == "grid" ? gPlan.lower : nil),
                suggestedUnits: choice == "tsession" ? tPlan.quote?.units : (choice == "grid" ? gPlan.rungs.first?.units : nil),
                expectedNetProfit: choice == "tsession" ? tPlan.netProfit : (choice == "grid" ? gPlan.netPerRung : nil),
                risks: choice == "tsession" ? tPlan.risks : gPlan.breakoutPolicy,
                validUntil: choice == "tsession" ? tPlan.validUntil : now.addingTimeInterval(86_400 * Double(model.profile.grid.maxDurationDays)),
                invalidation: choice == "tsession" ? tPlan.invalidation : gridInvalidation(of: gPlan),
                evidence: (choice == "tsession" ? regime.reasons + tPlan.basis : regime.reasons + gPlan.basis),
                now: now)
            // 同一标的同一天只保留一条最新快照，避免刷新时无限堆叠。
            let sameDayExists = model.decisionSnapshots.contains {
                $0.code == code && Calendar.current.isDate($0.createdAt, inSameDayAs: now)
            }
            if !sameDayExists { model.recordDecisionSnapshot(snapshot) }

            results.append(GuidanceItem(code: code, name: model.name(for: code), regime: regime,
                                        choice: choice, choiceReason: reason,
                                        tsession: tPlan, grid: gPlan,
                                        profileAllows: allows, profileNote: note))
        }
        // 净收益高的排前面；被画像拦下的排后面但仍展示
        results.sort { lhs, rhs in
            if lhs.profileAllows != rhs.profileAllows { return lhs.profileAllows }
            return NextNum.double(lhs.tsession?.netProfit ?? 0) > NextNum.double(rhs.tsession?.netProfit ?? 0)
        }
        items = results
    }
}
