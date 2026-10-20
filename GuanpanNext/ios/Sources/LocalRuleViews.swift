import SwiftUI

/// 三块本机规则面板：值不值得买 / 标的体检 / 账户诊断。
///
/// 全部做成**文件级 struct**，不要塞回 GuanpanNextApp.swift 的页面 body 里 ——
/// 那个文件里的页面已经足够深，再嵌一层闭包会触发 SwiftUI 的类型检查超时，
/// 甚至让运行期的视图类型嵌套过深而闪退。

private enum RuleDateText {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    static func today() -> String { day.string(from: Date()) }
}

// MARK: - 值不值得买

struct WorthBuyPanel: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let code: String
    @State private var assessment: NextWorthBuyAssessment?

    private var dataset: NextChartDataset? { model.chartData["\(code):day"] }
    private var quote: NextQuote? { model.quotes[code]?.quote }
    private var position: NextPosition? { model.book.positions.first { $0.code == code } }

    private var annualPerShare: Decimal {
        let events = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[code] ?? []))
        let today = RuleDateText.today()
        let recent = NextDividendAnalytics.recentVerifiedPerShare(code: code, events: events, today: today)
        if recent > 0 { return recent }
        return NextDividendAnalytics.projectedAnnualPerShare(code: code, events: events, today: today)?.amount ?? 0
    }

    var body: some View {
        EditorialSection(title: "值不值得买", trailing: "本机规则打分", accent: p.terracotta) {
            if let assessment {
                WorthBuyScoreHeader(assessment: assessment)
                WorthBuyBreakdown(assessment: assessment)
                if let yield = assessment.dividendYieldPercent {
                    GPDataRow(title: "股息率（近 12 个月）",
                              value: NextNum.percent(yield),
                              note: "每份 ¥\(NextMoney.text(assessment.dividendPerShare ?? 0, digits: 4)) · " + (NextDividendRules.isOnExchangeETF(code) ? "ETF 按 IOPV 优先计算" : "按现价计算"))
                } else {
                    GPDataRow(title: "股息率", value: "无可用派息记录", note: "没有可核实的近 12 个月派息；本项按 0 分处理，不代表标的好坏")
                }
                if let position, let gap = assessment.costGapPercent {
                    GPDataRow(title: "相对账面成本", value: "\(NextNum.signed(gap))%",
                              note: "成本 ¥\(NextMoney.text(position.costPerUnit, digits: 4)) · 只作参考，不参与打分", valueColor: gap >= 0 ? p.risk : p.jade)
                }
                ForEach(assessment.notes, id: \.self) { note in
                    Text(note).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                GPStatus(title: "日 K 不足，暂不打分",
                         detail: "本机已归档 \(dataset?.orderedSamples.count ?? 0) 根日 K，打分至少需要 20 根。切到「日K」会触发 NAS 拉取；离线时不会用分时数据冒充日线。",
                         symbol: "chart.bar.doc.horizontal")
            }
        }
        .onAppear { recompute() }
        .onChange(of: dataset?.observedAt) { _, _ in recompute() }
        .onChange(of: quote?.price) { _, _ in recompute() }
        .onChange(of: model.book.positions.count) { _, _ in recompute() }
    }

    private func recompute() {
        guard let quote, quote.price > 0, let dataset else { assessment = nil; return }
        let total = NextNum.double(model.book.cash) + model.book.positions.reduce(0.0) { sum, item in
            guard let price = model.quotes[item.code]?.quote.price, price > 0 else { return sum }
            return sum + NextNum.double(price) * Double(item.units)
        }
        var weight: Double?
        if total > 0, let position {
            weight = NextNum.double(quote.price) * Double(position.units) / total * 100
        }
        assessment = NextWorthBuyEngine.evaluate(
            code: code, price: quote.price, previousClose: quote.previousClose,
            samples: dataset.orderedSamples, dividendPerShare: annualPerShare,
            iopv: quote.iopv, costPerUnit: position?.costPerUnit,
            weightPercent: weight, positionLimitPercent: NextNum.double(model.goal.concentrationLimit))
    }
}

private struct WorthBuyScoreHeader: View {
    @Environment(\.gp) private var p
    let assessment: NextWorthBuyAssessment
    private var tone: Color {
        switch assessment.action {
        case "可考虑": return p.risk
        case "等确认": return p.terracotta
        default: return p.jade
        }
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(assessment.score)").font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tone)
            VStack(alignment: .leading, spacing: 4) {
                Text(assessment.action).font(.subheadline.weight(.semibold)).foregroundStyle(tone)
                Text("技术面基准 \(assessment.base) 分 · 加减 \(NextNum.signed(Double(assessment.totalAdjustment), digits: 0)) 分 · 日 K \(assessment.barCount) 根")
                    .font(.caption2).foregroundStyle(p.muted)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WorthBuyBreakdown: View {
    @Environment(\.gp) private var p
    let assessment: NextWorthBuyAssessment
    var body: some View {
        VStack(spacing: 0) {
            ForEach(assessment.lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.points == 0 ? "0" : NextNum.signed(Double(line.points), digits: 0))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(line.points > 0 ? p.risk : line.points < 0 ? p.jade : p.muted)
                        .frame(width: 26, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.caption.weight(.medium)).foregroundStyle(p.ink)
                        Text(line.detail).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
            }
            HStack(spacing: 5) {
                Text("技术面").font(.caption.weight(.medium)).foregroundStyle(p.ink)
                Text("\(assessment.base)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(p.muted)
                Spacer(minLength: 0)
                ForEach(assessment.lines.prefix(3)) { line in
                    if line.points != 0 {
                        Text("\(line.title) \(NextNum.signed(Double(line.points), digits: 0))").font(.system(size: 9)).foregroundStyle(p.muted)
                    }
                }
            }
            .padding(.top, 7)
        }
    }
}

// MARK: - 标的体检

struct GridCheckPanel: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var checks: [NextGridCheck] = []
    @State private var expanded: String?

    private var codes: [String] {
        var seen = Set<String>()
        let ordered = model.book.positions.map(\.code) + model.watch
        return ordered.filter { seen.insert($0).inserted && NextGridCheckEngine.isTradableCode($0) }.prefix(10).map { $0 }
    }

    var body: some View {
        EditorialSection(title: "标的体检 · 网格适合度", trailing: "\(checks.count) 只", accent: p.chartViolet) {
            Text("按流动性、年化波动率、日均振幅、震荡性四条公开口径打分；只评价「价格结构适不适合网格/波段」，不判断涨跌方向。")
                .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            if checks.isEmpty {
                GPStatus(title: "还没有可体检的标的", detail: "自选或持仓里的场内证券会自动出现在这里；需要本机至少 60 根日 K 才能给结论。", symbol: "stethoscope")
            }
            ForEach(checks) { check in
                GridCheckRow(check: check, isExpanded: expanded == check.code,
                             name: displayName(check.code)) {
                    expanded = expanded == check.code ? nil : check.code
                }
            }
            Button { recompute() } label: { Label("重新体检", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold)) }
                .tint(p.forest)
        }
        .onAppear { recompute() }
        .onChange(of: model.chartData.count) { _, _ in recompute() }
        .onChange(of: model.book.positions.count) { _, _ in recompute() }
    }

    private func displayName(_ code: String) -> String {
        model.book.positions.first(where: { $0.code == code })?.name
            ?? model.quotes[code]?.quote.name ?? code
    }

    private func recompute() {
        checks = codes.compactMap { code in
            guard let dataset = model.chartData["\(code):day"] else { return nil }
            return NextGridCheckEngine.evaluate(code: code, name: displayName(code),
                                               samples: dataset.orderedSamples, isOnExchange: true)
        }
        .sorted { lhs, rhs in lhs.score == rhs.score ? lhs.code < rhs.code : lhs.score > rhs.score }
    }
}

private struct GridCheckRow: View {
    @Environment(\.gp) private var p
    let check: NextGridCheck
    let isExpanded: Bool
    let name: String
    let toggle: () -> Void
    private var tone: Color {
        switch check.grade {
        case .suitable: return p.risk
        case .consider: return p.terracotta
        case .avoid: return p.jade
        }
    }
    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.subheadline.weight(.medium)).foregroundStyle(p.ink).lineLimit(1)
                    Text(check.code).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.muted)
                    Spacer(minLength: 4)
                    Text("\(check.score)").font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tone)
                    Text(check.grade.rawValue).font(.system(size: 9, weight: .semibold)).foregroundStyle(tone)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(tone.opacity(0.12), in: Capsule())
                }
                Text(metricLine).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                if isExpanded {
                    ForEach(check.reasons, id: \.self) { reason in
                        Label(reason, systemImage: "checkmark.circle").font(.caption2).foregroundStyle(p.jade)
                    }
                    ForEach(check.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(p.terracotta)
                    }
                    Text("数据：本机 \(check.barCount) 根日 K · 成交额按「量×100×收盘价」估算").font(.caption2).foregroundStyle(p.muted.opacity(0.8))
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
        .accessibilityLabel("\(name) 网格适合度 \(check.score) 分，\(check.grade.rawValue)")
    }
    private var metricLine: String {
        let volatility = check.annualVolatilityPercent.map { String(format: "波动 %.0f%%", $0) } ?? "波动 —"
        let amplitude = check.avgAmplitudePercent.map { String(format: "振幅 %.2f%%", $0) } ?? "振幅 —"
        let turnover = check.avgTurnoverYi.map { String(format: "成交 %.2f亿", $0) } ?? "成交 —"
        let range = check.rangeBoundRatio.map { String(format: "震荡 %.0f%%", $0 * 100) } ?? "震荡 —"
        return "\(volatility) · \(amplitude) · \(turnover) · \(range)"
    }
}

// MARK: - 账户诊断

struct AccountReviewPanel: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var review: NextAccountReview?

    var body: some View {
        EditorialSection(title: "账户诊断", trailing: "本机规则 · 不联网", accent: p.jade) {
            if let review {
                Text(review.headline).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(review.findings) { finding in
                    AccountFindingRow(finding: finding)
                }
                ForEach(review.footnotes, id: \.self) { note in
                    Text(note).font(.caption2).foregroundStyle(p.muted.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
                Button { recompute() } label: { Label("重新诊断", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold)) }
                    .tint(p.forest)
            } else {
                GPStatus(title: "账本里还没有可分析的资产",
                         detail: "先录入持仓或现金，再生成账户诊断；诊断只看本机账本，不读取新闻和基本面。",
                         symbol: "doc.text.magnifyingglass")
            }
        }
        .onAppear { recompute() }
        .onChange(of: model.book.cash) { _, _ in recompute() }
        .onChange(of: model.book.positions.count) { _, _ in recompute() }
    }

    private func recompute() {
        let realized = model.book.fills.reduce(Decimal.zero) { $0 + $1.realized }
        review = NextAccountAdvisor.review(
            book: model.book, quotes: model.quotes.mapValues { $0.quote },
            concentrationLimitPercent: model.goal.concentrationLimit,
            targetWeights: model.goal.targetWeights,
            realizedTotal: realized)
    }
}

private struct AccountFindingRow: View {
    @Environment(\.gp) private var p
    let finding: NextAccountFinding
    private var tone: Color {
        switch finding.severity {
        case .act: return p.risk
        case .watch: return p.terracotta
        case .info: return p.forest
        }
    }
    private var symbol: String {
        switch finding.severity {
        case .act: return "exclamationmark.circle"
        case .watch: return "eye"
        case .info: return "info.circle"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tone).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.caption.weight(.semibold)).foregroundStyle(p.ink)
                Text(finding.detail).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
    }
}

// MARK: - 全球指数看板

/// 行情页顶部的指数条：上证、纳指100、日经、韩国、恒生科技。
/// 数据源与坑位说明见 `GlobalIndices.swift`；这里只负责显示，
/// 失败时如实写「取不到」，不拿缓存假装实时。
struct GlobalIndexStrip: View {
    @Environment(\.gp) private var p
    @State private var quotes: [GlobalIndexQuote] = []
    @State private var message = ""
    @State private var loading = false

    private var shown: [GlobalIndexQuote] {
        if !quotes.isEmpty { return quotes }
        return GlobalIndexFeed.catalog.map {
            GlobalIndexQuote(symbol: $0.symbol, name: $0.name, price: 0, changePercent: 0,
                             previousClose: nil, observedAt: nil, isStale: false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Capsule().fill(p.chartViolet.opacity(0.85)).frame(width: 3, height: 12)
                Text("全球指数").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 4)
                if loading { ProgressView().scaleEffect(0.55).frame(width: 14, height: 14) }
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.forest)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("刷新全球指数")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(shown) { quote in GlobalIndexCard(quote: quote) }
                }
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 9)).foregroundStyle(p.muted)
            }
        }
        .padding(.vertical, 6)
        .task { if quotes.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let fresh = try await GlobalIndexFeed.fetch()
            quotes = fresh
            message = fresh.contains(where: \.isStale) ? "有指数为上一交易时段收盘价（已标注）" : ""
        } catch {
            message = "指数暂时取不到：\(error.localizedDescription)"
        }
    }
}

private struct GlobalIndexCard: View {
    @Environment(\.gp) private var p
    let quote: GlobalIndexQuote
    private var tone: Color {
        if quote.price <= 0 { return p.muted }
        return quote.changePercent >= 0 ? p.risk : p.jade
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(GlobalIndexFeed.shortName(quote.symbol)).font(.system(size: 10, weight: .medium)).foregroundStyle(p.ink).lineLimit(1)
                if quote.isStale { Text("旧").font(.system(size: 7, weight: .bold)).foregroundStyle(p.terracotta) }
            }
            Text(quote.price > 0 ? NextNum.text(quote.price) : "—")
                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(quote.price > 0 ? p.ink : p.muted)
            Text(quote.price > 0 ? "\(NextNum.signed(quote.changePercent))%" : "点击刷新")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(tone)
        }
        .frame(width: 78, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(
            LinearGradient(colors: [p.paper, tone.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tone.opacity(0.22), lineWidth: 0.8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(quote.name) \(quote.price > 0 ? NextNum.text(quote.price) : "无数据") \(quote.price > 0 ? NextNum.signed(quote.changePercent) + "%" : "")")
    }
}
