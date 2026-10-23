import SwiftUI

/// AI 决策记忆与复盘：看每条建议当时依据什么、后来有没有真实成交、结果如何，
/// 以及 AI 改变判断时「到底什么发生了变化」。
struct DecisionMemoryScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var expanded: UUID?

    private var ordered: [DecisionSnapshot] {
        model.decisionSnapshots.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        GPPageBackground {
            header
            hitRateBlock
            ForEach(ordered) { snap in
                snapshotCard(snap)
            }
            changeBlock
        }
        .navigationTitle("决策记忆与复盘")
        .onAppear { model.reconcileDecisions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 决策记忆").font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
            Text("每条建议都留下当时的行情、持仓、市场状态、NAS 研究与画像快照。是否成交只认真实成交流水，不用价格猜测。")
                .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                GPActionButton(title: "用真实流水回填", secondary: true, systemImage: "arrow.triangle.2.circlepath") {
                    model.reconcileDecisions()
                    model.notice = "已按真实成交流水回填决策结果。"
                }
            }.padding(.top, 4)
        }
        .padding(.vertical, 10)
    }

    private var hitRateBlock: some View {
        let stat = DecisionMemoryStore.hitRate(model.decisionSnapshots)
        return VStack(alignment: .leading, spacing: 6) {
            Text("执行结果").font(.caption.weight(.semibold)).foregroundStyle(p.muted)
            if let rate = stat.rate {
                GPDataRow(title: "已真实成交的建议", value: "\(stat.total) 条", note: "其中 \(stat.wins) 条实际为正")
                GPDataRow(title: "命中率", value: NextNum.percent(rate * 100, digits: 0),
                          note: "按真实成交价与最新价计算，样本少时仅供参考")
            } else {
                Text("还没有真实成交的建议。成交后这里会出现命中率，不会用未成交的建议凑数。")
                    .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
    }

    private func snapshotCard(_ snap: DecisionSnapshot) -> some View {
        let isOpen = expanded == snap.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(snap.name) · \(snap.code)").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                    Text(snap.summaryLine).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(snap.status).font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor(snap.status))
                    Text(snap.createdAt.formatted(date: .numeric, time: .shortened))
                        .font(.caption2).foregroundStyle(p.muted)
                }
            }
            HStack(spacing: 6) {
                chip(snap.regime, tone: p.chartBlue)
                chip(snap.assetRole, tone: p.forest)
                chip("当时 ¥\(NextMoney.text(snap.priceAtDecision, digits: 3))", tone: p.muted)
            }
            if isOpen { detail(snap) }
            Button(isOpen ? "收起" : "查看当时的依据与结果") {
                withAnimation(.easeInOut(duration: 0.18)) { expanded = isOpen ? nil : snap.id }
            }.font(.caption2.weight(.semibold)).tint(p.forest)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.paper))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.line, lineWidth: 0.9))
        .padding(.top, 8)
    }

    private func detail(_ snap: DecisionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("当时的判断").font(.caption2.weight(.semibold)).foregroundStyle(p.forest)
            Text(snap.headline).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)

            Text("当时的数据").font(.caption2.weight(.semibold)).foregroundStyle(p.forest)
            GPDataRow(title: "行情", value: "¥\(NextMoney.text(snap.priceAtDecision, digits: 3))",
                      note: "昨收 ¥\(NextMoney.text(snap.previousClose, digits: 3)) · \(snap.quoteSource)")
            GPDataRow(title: "持仓", value: "\(snap.unitsAtDecision) 份",
                      note: "成本 ¥\(NextMoney.text(snap.costPerUnitAtDecision, digits: 3)) · 现金 ¥\(NextMoney.text(snap.cashAtDecision, digits: 2))")
            GPDataRow(title: "市场状态", value: snap.regime, note: "置信度 \(Int((snap.regimeConfidence * 100).rounded()))%")
            if let amp = snap.amplitude20Percent {
                GPDataRow(title: "近20日振幅", value: NextNum.percent(amp, digits: 2), note: "本机日K统计")
            }
            if let s = snap.support, let r = snap.resistance {
                GPDataRow(title: "支撑压力", value: "¥\(NextMoney.text(NextNum.decimal(s), digits: 3)) – ¥\(NextMoney.text(NextNum.decimal(r), digits: 3))", note: "近60日极值聚类")
            }
            GPDataRow(title: "NAS 研究", value: snap.nasResearchAsOf ?? "无", note: snap.nasResearchState ?? "未取到")

            if !snap.profileDigest.isEmpty {
                Text("当时的画像").font(.caption2.weight(.semibold)).foregroundStyle(p.forest)
                ForEach(snap.profileDigest.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    Text("· \(key)：\(value)").font(.caption2).foregroundStyle(p.muted)
                }
                Text("· 做T门槛 ¥\(NextMoney.text(snap.tsessionMinNetProfit, digits: 2)) · 网格最多 \(snap.gridMaxRungs) 档")
                    .font(.caption2).foregroundStyle(p.muted)
            }

            if let price = snap.suggestedPrice {
                GPDataRow(title: "建议价", value: "¥\(NextMoney.text(price, digits: 3))",
                          note: snap.suggestedUnits.map { "\($0) 份" } ?? "—")
            }
            if let net = snap.expectedNetProfit {
                GPDataRow(title: "预计净收益", value: "¥\(NextMoney.text(net, digits: 2))", note: "扣手续费后")
            }

            Text("有效期与失效条件").font(.caption2.weight(.semibold)).foregroundStyle(p.risk)
            Text("· 有效期至 \(snap.validUntil.formatted(date: .numeric, time: .shortened))")
                .font(.caption2).foregroundStyle(p.muted)
            ForEach(snap.invalidation, id: \.self) { line in
                Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }

            if !snap.risks.isEmpty {
                Text("风险").font(.caption2.weight(.semibold)).foregroundStyle(p.risk)
                ForEach(snap.risks, id: \.self) { line in
                    Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("依据").font(.caption2.weight(.semibold)).foregroundStyle(p.forest)
            ForEach(snap.evidence, id: \.self) { line in
                Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }

            Text("后续结果").font(.caption2.weight(.semibold)).foregroundStyle(p.forest)
            if let at = snap.executedAt, let price = snap.executedPrice {
                Text("· 真实成交 \(at.formatted(date: .numeric, time: .shortened)) · ¥\(NextMoney.text(price, digits: 3)) · \(snap.executedUnits ?? 0) 份")
                    .font(.caption2).foregroundStyle(p.jade)
            } else {
                Text("· 截至当前没有匹配到真实成交；不会用价格走势冒充成交。")
                    .font(.caption2).foregroundStyle(p.muted)
            }
            if let pnl = snap.actualPnL {
                GPDataRow(title: "实际盈亏", value: "¥\(NextMoney.text(pnl, digits: 2))",
                          note: "按成交价与最新价计算", valueColor: p.changeTone(NextNum.double(pnl)))
            }
            if let note = snap.outcomeNote {
                Text("· \(note)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 「什么发生了变化」：对同一标的有多条快照时，展示最近两条的差异。
    private var changeBlock: some View {
        var blocks: [(String, [String])] = []
        let byCode = Dictionary(grouping: ordered, by: \.code)
        for (code, list) in byCode where list.count >= 2 {
            let sorted = list.sorted { $0.createdAt > $1.createdAt }
            blocks.append((model.name(for: code), DecisionMemoryStore.whatChanged(before: sorted[1], after: sorted[0])))
        }
        return VStack(alignment: .leading, spacing: 6) {
            if !blocks.isEmpty {
                Text("什么发生了变化").font(.caption.weight(.semibold)).foregroundStyle(p.muted)
                    .padding(.top, 16).padding(.bottom, 2)
                ForEach(blocks, id: \.0) { name, changes in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.caption2.weight(.semibold)).foregroundStyle(p.ink)
                        ForEach(changes, id: \.self) { line in
                            Text("· \(line)").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.tint.opacity(0.5)))
                }
            }
        }
    }

    private func chip(_ text: String, tone: Color) -> some View {
        Text(text).font(.caption2).foregroundStyle(tone)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tone.opacity(0.12)))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "已成交": return p.jade
        case "已失效", "已作废": return p.muted
        default: return p.chartGold
        }
    }
}
