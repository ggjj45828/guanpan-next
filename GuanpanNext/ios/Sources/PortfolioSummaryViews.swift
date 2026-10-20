import SwiftUI

/// 资产页的「持仓盈亏」面板：一屏看全每只持仓的市值、当日盈亏、浮盈与占比，
/// 并可在「摊薄成本 / 买入均价」两种券商口径之间切换。
///
/// 之所以单独做成文件级视图：资产页本身已经嵌得很深，再往里塞 ForEach + 计算属性
/// 很容易触发 SwiftUI 的类型检查超时。
struct HoldingsBreakdownPanel: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @AppStorage("guanpan.next.costMode") private var modeRaw = NextCostDisplayMode.diluted.rawValue

    private var mode: NextCostDisplayMode { NextCostDisplayMode(rawValue: modeRaw) ?? .diluted }
    private var summary: NextPortfolioSummary {
        NextPortfolioCalculator.summary(book: model.book, quotes: model.quotes, at: Date(), mode: mode)
    }

    var body: some View {
        let data = summary
        EditorialSection(title: "持仓盈亏", trailing: mode.title, accent: p.jade) {
            HStack(alignment: .top, spacing: 14) {
                GPValue(label: "总资产", value: "¥\(NextMoney.text(data.totalValue))",
                        footnote: data.isComplete ? "现金 + 持仓市值" : "部分持仓缺报价")
                GPValue(label: "今日盈亏", value: data.dailyChange.map { "\($0 >= 0 ? "+" : "")¥\(NextMoney.text($0))" } ?? "—",
                        footnote: data.dailyChange == nil ? "需完整新鲜行情" : "昨仓按昨收、今买按买入价",
                        emphasis: data.dailyChange.map { $0 >= 0 ? p.risk : p.jade })
                GPValue(label: "浮动盈亏", value: "\(data.floatingProfit >= 0 ? "+" : "")¥\(NextMoney.text(data.floatingProfit))",
                        footnote: "\(NextNum.signed(NextNum.double(data.floatingPercent)))% · \(mode.title)",
                        emphasis: data.floatingProfit >= 0 ? p.risk : p.jade)
            }
            HStack(spacing: 6) {
                ForEach(NextCostDisplayMode.allCases) { item in
                    Button { modeRaw = item.rawValue } label: {
                        Text(item.title).font(.system(size: 10, weight: mode == item ? .semibold : .regular))
                            .foregroundStyle(mode == item ? p.forest : p.muted)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(mode == item ? p.tint : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("成本口径 \(item.title)")
                }
                Spacer(minLength: 0)
            }
            Text(mode.detail).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            if let performance = NextPerformanceCalculator.summary(points: model.book.history) {
                PerformanceBlock(summary: performance, sampleCount: model.book.history.count)
            } else {
                Text("还没有足够的资产快照，暂不计算区间收益（至少需要 2 个）。")
                    .font(.caption2).foregroundStyle(p.muted)
            }

            if data.positions.isEmpty {
                GPStatus(title: "还没有可估算的持仓", detail: "录入持仓并且拿到报价后，这里会给出每只的市值、当日盈亏和浮动盈亏。", symbol: "chart.pie")
            } else {
                ForEach(data.positions) { item in
                    HoldingsSummaryRow(item: item, palette: p)
                }
            }

            if data.realizedTotal != 0 || !data.recentSells.isEmpty {
                Divider().overlay(p.line.opacity(0.7)).padding(.vertical, 4)
                GPDataRow(title: "累计已实现盈亏",
                          value: "\(data.realizedTotal >= 0 ? "+" : "")¥\(NextMoney.text(data.realizedTotal))",
                          note: "按每笔卖出的成本还原，未计分红",
                          valueColor: data.realizedTotal >= 0 ? p.risk : p.jade)
                ForEach(data.realizedByCode.prefix(3)) { item in
                    GPDataRow(title: "已实现 · \(item.name)",
                              value: "\(item.amount >= 0 ? "+" : "")¥\(NextMoney.text(item.amount))",
                              valueColor: item.amount >= 0 ? p.risk : p.jade)
                }
                ForEach(data.recentSells) { fill in
                    GPDataRow(title: "卖出 \(fill.code) · \(fill.date.formatted(date: .numeric, time: .omitted))",
                              value: "\(fill.units) 份 × ¥\(NextMoney.text(fill.price, digits: 4))",
                              note: "已实现 \(fill.realized >= 0 ? "+" : "")¥\(NextMoney.text(fill.realized)) · 手续费 ¥\(NextMoney.text(fill.fee))",
                              valueColor: fill.realized >= 0 ? p.risk : p.jade)
                }
            }
        }
    }
}

private struct HoldingsSummaryRow: View {
    let item: NextPositionSummary
    let palette: GPPalette
    private var p: GPPalette { palette }
    private var dailyTone: Color { item.dailyChange >= 0 ? p.risk : p.jade }
    private var floatingTone: Color { item.floatingProfit >= 0 ? p.risk : p.jade }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(p.ink).lineLimit(1)
                Text(item.code).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.muted)
                Spacer(minLength: 4)
                Text("¥\(NextMoney.text(item.marketValue))").font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(p.ink)
            }
            HStack(spacing: 10) {
                Text("当日 \(item.dailyChange >= 0 ? "+" : "")¥\(NextMoney.text(item.dailyChange))").foregroundStyle(dailyTone)
                Text("浮盈 \(NextNum.signed(NextNum.double(item.floatingPercent)))%").foregroundStyle(floatingTone)
                Spacer(minLength: 4)
                Text("占比 \(NextNum.percent(item.weightPercent, digits: 1))").foregroundStyle(p.muted)
            }
            .font(.system(size: 9.5, design: .monospaced))
            Text("\(item.units) 份 · 成本 ¥\(NextMoney.text(item.costPerUnit, digits: 4))（\(item.costSource)）")
                .font(.system(size: 9)).foregroundStyle(p.muted.opacity(0.9))
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.65)).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name) 市值 \(NextMoney.text(item.marketValue)) 元，当日 \(NextNum.signed(NextNum.double(item.dailyChange))) 元，浮盈 \(NextNum.signed(NextNum.double(item.floatingPercent)))%")
    }
}

private struct PerformanceBlock: View {
    @Environment(\.gp) private var p
    let summary: NextPerformanceSummary
    let sampleCount: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if summary.hasEnoughSamples {
                HStack(alignment: .top, spacing: 14) {
                    GPValue(label: "区间收益", value: NextNum.signed(summary.cumulativePercent) + "%",
                            footnote: "\(summary.dayCount) 天 · 已剔除出入金",
                            emphasis: summary.cumulativePercent >= 0 ? p.risk : p.jade)
                    GPValue(label: "年化", value: summary.annualizedPercent.map { NextNum.signed($0) + "%" } ?? "不足 90 天",
                            footnote: summary.annualizedPercent == nil ? "样本太短不给年化" : "按区间折算")
                    GPValue(label: "最大回撤", value: "-" + NextNum.percent(summary.maxDrawdownPercent, digits: 1),
                            footnote: "快照净值峰谷", emphasis: p.terracotta)
                }
                Text("自 \(summary.startDate.formatted(date: .numeric, time: .omitted)) 起，共 \(sampleCount) 个资产快照；按日收益连乘（时间加权近似）。")
                    .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("资产快照只有 \(sampleCount) 个，暂不算区间收益（至少 3 个，且需有正的起始资产）。")
                    .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
