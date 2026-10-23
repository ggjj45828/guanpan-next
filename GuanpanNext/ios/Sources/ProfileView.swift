import SwiftUI

/// 一次编辑动作。同一视图只用一个 sheet 驱动，避免多个 sheet 只有最后一个生效。
private enum ProfileSheet: Identifiable {
    case editFact(String)
    case editRole(String)

    var id: String {
        switch self {
        case .editFact(let key): return "fact-\(key)"
        case .editRole(let code): return "role-\(code)"
        }
    }
}

/// 「AI 对我的了解」：一屏看完 AI 形成了哪些判断、依据是什么，并允许逐项纠正。
struct ProfileScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var expanded: String?
    @State private var sheet: ProfileSheet?
    @State private var draftValue = ""
    @State private var draftRole = "flex"

    /// 卡片展示顺序与配色。顺序固定，配色按维度语义区分。
    private let cards: [(String, String)] = [
        ("horizon", "长期目标"),
        ("tradeFrequency", "交易风格"),
        ("limitPatience", "耐心限价"),
        ("tsession", "做T习惯"),
        ("grid", "网格习惯"),
        ("cashStyle", "现金偏好"),
        ("execution", "交易执行")
    ]
    private let riskCards: [(String, String)] = [
        ("risk.drawdown", "账户回撤"),
        ("risk.singleAsset", "单资产回撤"),
        ("risk.sectorETF", "行业ETF风险"),
        ("risk.cashflow", "现金流压力")
    ]

    var body: some View {
        GPPageBackground {
            header
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(cards, id: \.0) { key, title in
                    factCard(key: key, title: title)
                }
            }
            .padding(.top, 6)

            Text("风险承受能力").font(.caption.weight(.semibold)).foregroundStyle(p.muted)
                .padding(.top, 16).padding(.bottom, 2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(riskCards, id: \.0) { key, title in
                    factCard(key: key, title: title)
                }
            }

            styleTagSection
            assetRoleSection
            behaviorSection
            observationSection
        }
        .navigationTitle("AI 对我的了解")
        .sheet(item: $sheet) { item in
            switch item {
            case .editFact(let key): editFactSheet(key: key)
            case .editRole(let code): editRoleSheet(code: code)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 对你的了解").font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
            Text("全部来自真实持仓、真实成交与你的真实反馈。AI 不会用模拟交易学习，也不会自行修改你锁定的规则。")
                .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            if let at = model.profile.lastLearnedAt {
                Text("最近学习 \(at.formatted(date: .abbreviated, time: .shortened)) · 观察记录 \(model.profile.observations.count) 条")
                    .font(.caption2).foregroundStyle(p.muted)
            }
            HStack(spacing: 8) {
                GPActionButton(title: "立即重新学习", secondary: true, systemImage: "arrow.triangle.2.circlepath") {
                    model.refreshProfile()
                    model.notice = "已按当前真实持仓与成交重新学习画像。"
                }
            }.padding(.top, 4)
        }
        .padding(.vertical, 10)
    }

    // MARK: - 画像卡片

    private func factCard(key: String, title: String) -> some View {
        let fact = model.profile.facts[key]
        let tone = color(for: key)
        let isOpen = expanded == key
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(p.muted)
                    Text(fact?.value ?? "—")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.caption2).foregroundStyle(tone)
            }
            confidenceBar(confidence: fact?.confidence ?? 0, tone: tone)
            HStack(spacing: 4) {
                Text(fact?.source.title ?? "—").font(.caption2).foregroundStyle(tone)
                if fact?.locked == true { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(tone) }
            }
            if isOpen, let fact {
                VStack(alignment: .leading, spacing: 5) {
                    Text(fact.reason).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    ForEach(fact.evidence, id: \.self) { line in
                        HStack(alignment: .top, spacing: 5) {
                            Circle().fill(tone.opacity(0.7)).frame(width: 4, height: 4).padding(.top, 5)
                            Text(line).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("样本 \(fact.sampleSize) · 更新 \(fact.updatedAt.formatted(date: .numeric, time: .omitted))")
                        .font(.caption2).foregroundStyle(p.muted)
                    HStack(spacing: 6) {
                        Button("修改") { draftValue = fact.value; sheet = .editFact(key) }
                            .font(.caption2.weight(.semibold)).buttonStyle(.bordered).tint(tone)
                        Button("这个判断不准确") { model.resetProfileFact(key) }
                            .font(.caption2.weight(.semibold)).buttonStyle(.bordered).tint(p.risk)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tone.opacity(0.28), lineWidth: 0.9))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { expanded = isOpen ? nil : key } }
    }

    private func confidenceBar(confidence: Double, tone: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(p.line.opacity(0.9))
                Capsule().fill(tone).frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, confidence)))))
            }
        }.frame(height: 4)
    }

    private func color(for key: String) -> Color {
        switch key {
        case "horizon": return p.chartBlue
        case "tradeFrequency": return p.chartViolet
        case "limitPatience": return p.jade
        case "tsession": return p.chartGold
        case "grid": return p.terracotta
        case "cashStyle": return p.forest
        case "execution": return p.risk
        case "risk.drawdown": return p.risk
        case "risk.singleAsset": return p.terracotta
        case "risk.sectorETF": return p.chartViolet
        case "risk.cashflow": return p.jade
        default: return p.forest
        }
    }

    // MARK: - 风格标签

    private var styleTagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("投资风格标签").font(.caption.weight(.semibold)).foregroundStyle(p.muted)
                .padding(.top, 16).padding(.bottom, 2)
            FlowLayout(spacing: 7) {
                ForEach(model.profile.styleTags, id: \.self) { tag in
                    Text(tag).font(.caption.weight(.semibold)).foregroundStyle(p.forest)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(p.forest.opacity(0.12)))
                }
            }
            Text("标签可同时存在多个，不是只能选一个。").font(.caption2).foregroundStyle(p.muted)
        }
    }

    // MARK: - 资产角色（核心仓 / 机动仓）

    private var assetRoleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("资产角色区分").font(.caption.weight(.semibold)).foregroundStyle(p.muted)
                .padding(.top, 16).padding(.bottom, 2)
            Text("核心仓与机动仓不能用同一套行为规则：核心仓允许波动、不轻易卖出；机动仓可做T与网格。")
                .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(model.book.positions.filter { $0.units > 0 }) { position in
                let role = model.profile.role(for: position.code)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name(for: position.code)).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                        Text("\(position.code) · \(role.roleTitle) · \(role.source.title)")
                            .font(.caption2).foregroundStyle(p.muted)
                    }
                    Spacer(minLength: 6)
                    Button("设置") { draftRole = role.role; sheet = .editRole(position.code) }
                        .font(.caption2.weight(.semibold)).buttonStyle(.bordered).tint(p.forest)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
            }
            if let locked = Optional(model.profile.isCoreAssetLocked), !locked.isEmpty {
                Text("已锁定为核心仓（AI 不得改作机动交易）：\(locked.map { model.name(for: $0) }.joined(separator: "、"))")
                    .font(.caption2).foregroundStyle(p.jade).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 真实行为统计

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("真实交易行为（学习依据）").font(.caption.weight(.semibold)).foregroundStyle(p.muted)
                .padding(.top, 16).padding(.bottom, 2)
            if let behavior = model.profile.lastBehavior, behavior.fillCount > 0 {
                ForEach(behavior.summaryLines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 5) {
                        Circle().fill(p.forest.opacity(0.7)).frame(width: 4, height: 4).padding(.top, 5)
                        Text(line).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("还没有真实成交流水。画像只会在你录入真实成交后逐渐形成，不会凭空推测。")
                    .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 观察记录

    private var observationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 建议反馈记录").font(.caption.weight(.semibold)).foregroundStyle(p.muted)
                .padding(.top, 16).padding(.bottom, 2)
            let recent = Array(model.profile.observations.sorted { $0.at > $1.at }.prefix(12))
            if recent.isEmpty {
                Text("还没有反馈记录。在 AI 建议卡上点反馈后，这里会留下痕迹，并参与画像学习。")
                    .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(recent) { item in
                    HStack(spacing: 8) {
                        Circle().fill(item.reallyExecuted ? p.jade : p.muted).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(kindTitle(item.kind)) · \(model.name(for: item.code))")
                                .font(.caption2.weight(.semibold)).foregroundStyle(p.ink)
                            Text(detail(of: item)).font(.caption2).foregroundStyle(p.muted)
                        }
                        Spacer(minLength: 6)
                        Text(item.at.formatted(date: .numeric, time: .omitted)).font(.caption2).foregroundStyle(p.muted)
                    }
                    .padding(.vertical, 5)
                    .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.6)).frame(height: 0.5) }
                }
            }
        }
    }

    private func kindTitle(_ kind: String) -> String {
        switch kind {
        case "tsession": return "做T"
        case "grid": return "网格"
        case "buy": return "买入"
        case "limit": return "限价"
        default: return kind
        }
    }
    private func detail(of item: ProfileObservation) -> String {
        var parts: [String] = [item.outcome == "accepted" ? "接受" : (item.outcome == "executed" ? "已成交" : "未执行")]
        if let profit = item.proposedNetProfit { parts.append("建议净收益 ¥\(NextMoney.text(profit, digits: 2))") }
        if let fb = item.feedback, let f = ProfileFeedback(rawValue: fb) { parts.append("反馈：\(f.title)") }
        if item.reallyExecuted { parts.append("真实成交") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 编辑弹窗

    private func editFactSheet(key: String) -> some View {
        let fact = model.profile.facts[key]
        let options = options(for: key)
        return NavigationStack {
            Form {
                Section("当前值") {
                    TextField("值", text: $draftValue)
                }
                if !options.isEmpty {
                    Section("或选择") {
                        ForEach(options, id: \.self) { option in
                            Button(option) { draftValue = option }
                                .foregroundStyle(draftValue == option ? p.forest : p.ink)
                        }
                    }
                }
                Section {
                    Button("保存（AI 不再自行修改）") {
                        let value = draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        model.setProfileFact(key, value: value)
                        sheet = nil
                    }.tint(p.forest)
                    Button("清除锁定，交回 AI 学习", role: .destructive) {
                        model.resetProfileFact(key)
                        sheet = nil
                    }
                }
            }
            .navigationTitle(fact?.title ?? "修改")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { sheet = nil } } }
        }
    }

    private func editRoleSheet(code: String) -> some View {
        NavigationStack {
            Form {
                Section("\(model.name(for: code)) · \(code)") {
                    Picker("角色", selection: $draftRole) {
                        Text("长期核心仓").tag("core")
                        Text("行业机动仓").tag("flex")
                    }.pickerStyle(.segmented)
                    Text(draftRole == "core"
                         ? "核心仓：允许较大波动、不轻易卖出，主要靠新增资金调整；AI 不会因短期信号建议交易它。"
                         : "机动仓：可做T、可网格、可主动降本，可按趋势与行业变化减仓。")
                        .font(.caption).foregroundStyle(p.muted)
                }
                Section {
                    Button("保存（AI 不得自行改回）") {
                        model.setAssetRole(code: code, role: draftRole)
                        sheet = nil
                    }.tint(p.forest)
                }
            }
            .navigationTitle("设置资产角色")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { sheet = nil } } }
        }
    }

    private func options(for key: String) -> [String] {
        switch key {
        case "tradeFrequency": return ["低频择机", "正常", "积极"]
        case "limitPatience": return ["愿意长期挂单", "不追求立即成交", "追求较快成交"]
        case "tsession": return ["低频 · 只做高质量机会", "低频 · 很少执行", "择机执行", "积极执行", "不做T"]
        case "grid": return ["震荡行情常用", "偶尔使用", "基本不用"]
        case "cashStyle": return ["愿意等待机会", "保留适度现金", "倾向满仓"]
        case "execution": return ["AI 推荐 / 手工下单", "仅看分析，不接收建议"]
        case "horizon": return ["短期", "中期", "长期", "超长期"]
        default: return []
        }
    }
}

// MARK: - AI 建议卡上的一键反馈条（不是问卷）

struct ProfileFeedbackBar: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let kind: String
    let code: String
    var proposedNetProfit: Decimal? = nil
    var proposedSpreadPercent: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("这条建议适合你吗？").font(.caption2).foregroundStyle(p.muted)
            FlowLayout(spacing: 6) {
                ForEach(ProfileFeedback.allCases) { item in
                    Button(item.title) {
                        model.recordFeedback(item, kind: kind, code: code,
                                             proposedNetProfit: proposedNetProfit,
                                             proposedSpreadPercent: proposedSpreadPercent)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item == .suitsMe ? p.jade : p.muted)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().stroke(item == .suitsMe ? p.jade.opacity(0.6) : p.line, lineWidth: 0.9))
                }
            }
        }
    }
}

// MARK: - 简易流式布局（标签、反馈按钮用）

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
