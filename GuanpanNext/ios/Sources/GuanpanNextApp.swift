import SwiftUI
import UniformTypeIdentifiers

@main struct GuanpanNextApp: App {
    @StateObject private var model = NextAppModel()
    var body: some Scene { WindowGroup { RootView().environmentObject(model) } }
}

enum GPRoute: Hashable { case instrument(String), chart(String), decision(String?), settings, alerts, fills, history, backups, twin(NextTwinStrategy) }
private extension GPRoute {
    var persisted: NextRoute {
        switch self {
        case .instrument(let code): .instrument(code)
        case .chart(let code): .chart(code)
        case .decision(let code): .intent("decision", code ?? "")
        case .settings: .settings
        case .alerts: .alerts
        case .fills: .fills
        case .history: .history
        case .backups: .backups
        case .twin(let strategy): .twin(strategy.rawValue)
        }
    }
    static func restore(_ route: NextRoute) -> GPRoute? {
        switch route {
        case .instrument(let code): .instrument(code)
        case .chart(let code): .chart(code)
        case .intent(let action, let code): action == "decision" ? .decision(code.isEmpty ? nil : code) : nil
        case .settings: .settings
        case .alerts: .alerts
        case .fills: .fills
        case .history: .history
        case .backups: .backups
        case .twin(let raw): NextTwinStrategy(rawValue: raw).map { .twin($0) }
        case .portfolio(_), .replay(_): nil
        }
    }
}
enum GPMainTab: String, CaseIterable, Identifiable {
    case overview, market, decision, laboratory, assets
    var id: String { rawValue }
    var title: String { switch self { case .overview: "总览"; case .market: "行情"; case .decision: "AI 决策"; case .laboratory: "量化"; case .assets: "资产" } }
    var icon: String { switch self { case .overview: "sun.horizon"; case .market: "chart.xyaxis.line"; case .decision: "sparkles"; case .laboratory: "waveform.path.ecg.rectangle"; case .assets: "circle.hexagongrid" } }
    var core: NextTab { switch self { case .overview: .overview; case .market: .market; case .decision: .decision; case .laboratory: .laboratory; case .assets: .assets } }
}

struct RootView: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.colorScheme) private var systemScheme
    private var tabSelection: Binding<NextTab> { Binding(get: { model.preferences.navigation.selectedTab }, set: { model.preferences.navigation.selectedTab = $0; model.preferences = model.preferences }) }
    var body: some View {
        TabView(selection: tabSelection) {
            PrimaryNavigation(title: "总览", tab: .overview) { OverviewScreen() }.tabItem { Label("总览", systemImage: "sun.horizon") }.tag(NextTab.overview)
            PrimaryNavigation(title: "行情", tab: .market) { MarketScreen() }.tabItem { Label("行情", systemImage: "chart.xyaxis.line") }.tag(NextTab.market)
            PrimaryNavigation(title: "AI 决策", tab: .decision) { DecisionScreen(code: nil) }.tabItem { Label("AI 决策", systemImage: "sparkles") }.tag(NextTab.decision)
            PrimaryNavigation(title: "量化实验室", tab: .laboratory) { LaboratoryScreen() }.tabItem { Label("量化", systemImage: "waveform.path.ecg.rectangle") }.tag(NextTab.laboratory)
            PrimaryNavigation(title: "资产", tab: .assets) { AssetsScreen() }.tabItem { Label("资产", systemImage: "circle.hexagongrid") }.tag(NextTab.assets)
        }
        .tint(GPPalette(scheme: effectiveScheme, comfort: model.theme == .comfort).forest)
        .environment(\.gp, GPPalette(scheme: effectiveScheme, comfort: model.theme == .comfort))
        .preferredColorScheme(model.theme.colorScheme)
        .sheet(isPresented: $model.showSearch) { SearchSheet() }
        .alert("观盘 Pro", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    // Comfort mode is an intentionally warm light palette. Do not let a dark
    // system appearance pair its ivory canvas with the dark palette's light ink.
    private var effectiveScheme: ColorScheme { model.theme == .system ? systemScheme : model.theme == .dark ? .dark : .light }
}

private struct PrimaryNavigation<Content: View>: View {
    @EnvironmentObject private var model: NextAppModel
    let title: String
    let tab: NextTab
    @State private var path: [GPRoute] = []
    @ViewBuilder var content: Content
    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(title).navigationBarTitleDisplayMode(.large)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { model.showSearch = true } label: {
                            Image(systemName: "magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("全局搜索证券")
                        .accessibilityIdentifier("search.open")
                        .accessibilityAddTraits(.isButton)
                        NavigationLink(value: GPRoute.settings) {
                            Label("设置", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("设置")
                        .accessibilityIdentifier("settings.open")
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .navigationDestination(for: GPRoute.self) { route in RouteDestination(route: route) }
        }
        .onAppear { path = (model.preferences.navigation.tabRoutes[tab.rawValue] ?? []).compactMap(GPRoute.restore) }
        .onChange(of: path) { _, value in model.saveNavigationPath(value.map(\.persisted), for: tab) }
        .onChange(of: model.routeRequestID) { _, _ in
            guard model.requestedTab == tab, let route = model.requestedRoute else { return }
            path.append(route)
        }
    }
}

private struct RouteDestination: View {
    let route: GPRoute
    @ViewBuilder var body: some View {
        switch route {
        case .instrument(let code): InstrumentDetailScreen(code: code)
        case .chart(let code): FullscreenChartScreen(code: code)
        case .decision(let code): DecisionScreen(code: code)
        case .settings: SettingsScreen()
        case .alerts: AlertCenterScreen()
        case .fills: LedgerHistoryScreen()
        case .history: DecisionHistoryScreen()
        case .backups: BackupRestoreScreen()
        case .twin(let strategy): TwinDetailScreen(strategy: strategy)
        }
    }
}

private struct OverviewScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    private var valuation: NextAssetValuation { book.valuation(using: model.quotes, at: Date()) }
    private var book: NextBook { model.book }
    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(Date.now.formatted(.dateTime.month(.abbreviated).day().weekday(.wide))).font(.subheadline).foregroundStyle(p.muted)
                        Text("今天，先看组合状态").font(.system(.title2, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
                        Text("场内资产 · 本机优先 · 数据有出处").font(.caption).foregroundStyle(p.muted)
                    }
                    Spacer()
                    NavigationLink(value: GPRoute.alerts) { Image(systemName: "bell.badge").font(.system(size: 19)).foregroundStyle(p.forest).frame(width: 44, height: 44).background(p.tint, in: Circle()) }.accessibilityLabel("通知中心")
                }.padding(.top, 8).padding(.bottom, 20)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("真实场内资产").font(.caption.weight(.medium)).foregroundStyle(p.muted); Spacer(); Text("仅账本与新鲜行情").font(.caption2).foregroundStyle(p.muted) }
                    if let total = valuation.total { Text("¥\(NextMoney.text(total))").gpFont(size: 36, relativeTo: .largeTitle, weight: .medium, design: .rounded).monospacedDigit().foregroundStyle(p.ink).minimumScaleFactor(0.75).lineLimit(1) }
                    else { Text("行情待连接").font(.system(.title, design: .serif).weight(.medium)).foregroundStyle(p.muted) }
                    HStack(spacing: 7) { Circle().fill(valuation.quality == .stale ? p.terracotta : p.jade).frame(width: 6, height: 6); Text(valuation.total == nil ? "仅 \(valuation.pricedPositions)/\(valuation.totalPositions) 只持仓有缓存估值；不将部分估值标作总资产" : valuation.quality.map { "\($0 == .live ? "新鲜" : "缓存")估值 · 报价截至 \(valuation.earliestQuote?.formatted(date: .omitted, time: .shortened) ?? "—")" } ?? "当前仅账本现金").font(.caption).foregroundStyle(p.muted).lineLimit(2) }
                    Rectangle().fill(p.line).frame(height: 0.7).padding(.vertical, 3)
                    HStack(spacing: 26) {
                        GPValue(label: "账本现金", value: "¥\(NextMoney.text(book.cash))")
                        GPValue(label: "持仓成本", value: "¥\(NextMoney.text(book.positions.reduce(0) { $0 + $1.bookCost }))")
                        GPValue(label: "今日变化", value: valuation.dailyChange.map { "\($0 >= 0 ? "+" : "")¥\(NextMoney.text($0))" } ?? "—", footnote: valuation.dailyChangePercent.map { "昨收对比 \(NextMoney.text($0))%" } ?? "需全部新鲜行情", emphasis: valuation.dailyChange.map { $0 >= 0 ? p.risk : p.jade })
                    }
                }.padding(17).background(p.paper, in: RoundedRectangle(cornerRadius: 20, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 20).stroke(p.line, lineWidth: 0.7))
                EditorialSection(title: "需要你留意", trailing: "\(model.preferences.notifications.unreadCount) 条未读") {
                    if model.preferences.notifications.alerts.isEmpty {
                        HStack(spacing: 10) { Image(systemName: "checkmark.seal").foregroundStyle(p.forest); Text("暂无待处理提醒").font(.subheadline).foregroundStyle(p.ink); Spacer(); NavigationLink(value: GPRoute.alerts) { Image(systemName: "arrow.up.right").foregroundStyle(p.muted) } }
                    } else {
                        ForEach(model.preferences.notifications.alerts.prefix(3)) { alert in VStack(alignment: .leading, spacing: 4) { Text(alert.title).font(.subheadline.weight(.semibold)); Text(alert.detail).font(.caption).foregroundStyle(p.muted); Text(alert.stamp.label(now: Date())).font(.caption2.monospaced()).foregroundStyle(p.muted) }.padding(.vertical, 5) }
                        NavigationLink("查看通知记录", value: GPRoute.alerts).font(.caption.weight(.medium)).foregroundStyle(p.forest)
                    }
                }
                EditorialSection(title: "持仓速览", trailing: "\(book.positions.count) 只") {
                    if book.positions.isEmpty { GPStatus(title: "场内账本从空白开始", detail: "添加你确认的证券持仓；没有验证的备份不会被覆盖。", symbol: "tray") }
                    else { ForEach(book.positions.prefix(5)) { position in InstrumentRow(code: position.code, name: position.name, units: position.units, quote: model.quotes[position.code]) } }
                    NavigationLink(value: GPRoute.instrument(model.watch.first ?? "159941")) { Label("浏览关注证券", systemImage: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(p.forest) }.padding(.top, 3)
                }
                EditorialSection(title: "接着做") {
                    NavigationLink(value: GPRoute.decision(nil)) { IntentRow(icon: "sparkles", title: "分析买入机会", detail: "先组织行情、持仓、预算与风险") }
                    NavigationLink(value: GPRoute.twin(.G)) { IntentRow(icon: "waveform.path.ecg", title: "查看 G 自主模拟", detail: "独立账户 · A–G 与 H 方案比较") }
                }
            }
        }.safeAreaInset(edge: .bottom) { Color.clear.frame(height: 4) }
    }
}

private struct MarketScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var entry = ""
    @State private var selectedFilter = "全部"
    private var visibleCodes: [String] {
        switch selectedFilter {
        case "持仓": return model.book.positions.map(\.code)
        case "自选": return model.watch
        default: return model.watch + model.book.positions.map(\.code).filter { !model.watch.contains($0) }
        }
    }
    var body: some View {
        List {
            Section {
                HStack(alignment: .top) { Text("用熟悉的证券代码开始，详情里再展开行情、图表与研究。").font(.subheadline).foregroundStyle(p.muted); Spacer(); Button { Task { await model.refreshQuotes(codes: visibleCodes) } } label: { Label("刷新", systemImage: "arrow.clockwise").font(.caption.weight(.semibold)) }.disabled(visibleCodes.isEmpty) }
                    .listRowBackground(p.canvas)
                HStack(spacing: 8) { TextField("添加 6 位证券代码", text: $entry).keyboardType(.numberPad).textFieldStyle(.roundedBorder).submitLabel(.done).onSubmit(add); Button("添加", action: add).buttonStyle(.borderedProminent).tint(p.forest) }
                    .listRowBackground(p.canvas)
                Picker("证券筛选", selection: $selectedFilter) { ForEach(["全部", "自选", "持仓"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                    .listRowBackground(p.canvas)
                HStack { Text("证券").frame(maxWidth: .infinity, alignment: .leading); Text("最新").frame(width: 78, alignment: .trailing); Text("涨跌").frame(width: 58, alignment: .trailing) }.font(.caption2.weight(.medium)).foregroundStyle(p.muted).listRowBackground(p.canvas)
            }
            if visibleCodes.isEmpty {
                GPStatus(title: "这个列表还没有证券", detail: "搜索并添加一只场内 ETF，点入可查看详情。", symbol: "magnifyingglass").listRowBackground(p.canvas).listRowSeparator(.hidden)
            }
            ForEach(visibleCodes, id: \.self) { code in
                NavigationLink(value: GPRoute.instrument(code)) {
                    InstrumentRow(code: code, name: model.book.positions.first(where: { $0.code == code })?.name ?? model.quotes[code]?.quote.name ?? knownName(code), units: model.book.positions.first(where: { $0.code == code })?.units, quote: model.quotes[code])
                }.accessibilityIdentifier("instrument.row.\(code)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if model.watch.contains(code) { Button("移除", systemImage: "star.slash", role: .destructive) { model.removeWatch(code) } }
                        Button("分析", systemImage: "sparkles") { model.openInstrumentIntent(code) }.tint(p.forest)
                    }
                    .listRowBackground(p.paper)
                    .contextMenu { Button("分析买入机会", systemImage: "sparkles") { model.openInstrumentIntent(code) }; if model.watch.contains(code) { Button("移出自选", systemImage: "star.slash", role: .destructive) { model.removeWatch(code) } } }
            }
            Section("行情连接状态") {
                VStack(alignment: .leading, spacing: 6) { Text(model.status).font(.subheadline.weight(.medium)); Text("来源：Tencent 公共报价接口。失败时保留本地缓存；ETF 属性、交易规则、五档盘口及 IOPV 不从报价接口推断。").font(.caption).foregroundStyle(p.muted); Button("重试") { Task { await model.refreshQuotes(codes: visibleCodes) } }.font(.caption.weight(.semibold)).tint(p.forest) }
                    .listRowBackground(p.canvas)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(p.canvas).scrollDismissesKeyboard(.interactively)
        .navigationTitle("行情").navigationBarTitleDisplayMode(.large)
        .onAppear { selectedFilter = model.preferences.navigation.listFilters["market"] ?? "全部" }
        .onChange(of: selectedFilter) { _, value in model.preferences.navigation.listFilters["market"] = value; model.preferences = model.preferences }
    }
    private func add() { do { try model.addWatch(entry); entry = "" } catch { model.errorMessage = error.localizedDescription } }
}

private struct InstrumentRow: View {
    @Environment(\.gp) private var p
    let code: String; let name: String; var units: Int?; let quote: NextCachedQuote?
    private var validQuote: NextQuote? { guard let quote, quote.usableForDisplay(at: Date()) else { return nil }; return quote.quote }
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) { Text(name).gpFont(size: 14, relativeTo: .body, weight: .semibold).foregroundStyle(p.ink); Text("\(code)\(units.map { " · \($0) 份" } ?? "")").gpFont(size: 10, relativeTo: .caption, design: .monospaced).foregroundStyle(p.muted) }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 4) { Text(validQuote.map { "¥\(NextMoney.text($0.price, digits: 4))" } ?? "—").gpFont(size: 13, relativeTo: .subheadline, weight: .semibold, design: .rounded).monospacedDigit().foregroundStyle(p.ink); if let validQuote, let change = validQuote.changePercent { Text("\(change >= 0 ? "+" : "")\(NextMoney.text(change, digits: 2))%").gpFont(size: 10, relativeTo: .caption, design: .monospaced).foregroundStyle(change >= 0 ? p.risk : p.jade) }; Text(quote?.stamp.label(now: Date()) ?? "暂无行情").gpFont(size: 8, relativeTo: .caption2).foregroundStyle(quote?.stamp.quality == .stale ? p.terracotta : p.muted).lineLimit(1) }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted).padding(.leading, 2)
        }.padding(.vertical, 10).contentShape(Rectangle())
    }
}

private struct InstrumentDetailScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let code: String
    @State private var interval: NextChartInterval = .intraday
    @State private var selectedTime: Date?
    private var position: NextPosition? { model.book.positions.first { $0.code == code } }
    private var quote: NextQuote? { model.quotes[code]?.quote }
    private var name: String { position?.name ?? quote?.name ?? knownName(code) }
    private var cost: Decimal? { position?.costPerUnit }
    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 0) {
                HStack { VStack(alignment: .leading, spacing: 5) { Text("\(code) · \(quote.map { $0.source } ?? "数据源待接入")").font(.caption.monospaced()).foregroundStyle(p.muted); Text(quote.map { "¥\(NextMoney.text($0.price, digits: 4))" } ?? "暂无有效报价").gpFont(size: 34, relativeTo: .largeTitle, weight: .medium, design: .rounded).monospacedDigit().foregroundStyle(p.ink); if let quote, let change = quote.changePercent { Text("\(change >= 0 ? "+" : "")\(NextMoney.text(change, digits: 2))%　·　\(quote.time.formatted(date: .omitted, time: .shortened))").font(.caption.monospaced()).foregroundStyle(change >= 0 ? p.risk : p.jade) } else { Text(model.quotes[code]?.stamp.label(now: Date()) ?? "无数据 · 不计算涨跌").font(.caption).foregroundStyle(p.muted) } }; Spacer(); Button { Task { await model.refreshInstrument(code) } } label: { Image(systemName: "arrow.clockwise").foregroundStyle(p.forest).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("刷新行情"); Button { if model.watch.contains(code) { model.removeWatch(code) } else { try? model.addWatch(code) } } label: { Image(systemName: model.watch.contains(code) ? "star.fill" : "star").foregroundStyle(p.terracotta).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel(model.watch.contains(code) ? "取消关注" : "关注") }
                    .padding(.top, 5).padding(.bottom, 14)
                if let quote, let iopv = quote.iopv { Text("当前 IOPV ¥\(NextMoney.text(iopv, digits: 4)) · 溢折价 \(NextMoney.text((quote.price / iopv - 1) * 100, digits: 2))% · 同源时点 \(quote.time.formatted(date: .omitted, time: .shortened))").font(.caption2.monospaced()).foregroundStyle(p.terracotta).padding(.bottom, 8) }
                if let stamp = model.quotes[code]?.stamp { Text(stamp.label(now: Date())).font(.caption2).foregroundStyle(p.muted).padding(.bottom, 8) }
                DataPanel(title: "行情图表", caption: model.chartData[code].map { "\($0.priceSource) · \($0.observedAt.formatted(date: .omitted, time: .shortened))" } ?? "暂无本机历史") {
                    UnifiedChartView(dataset: model.chartData[code], interval: $interval, costPerUnit: cost, selectedTime: $selectedTime, securityCode: code)
                    HStack { Button { Task { await model.refreshInstrument(code) } } label: { Label("刷新行情与分时", systemImage: "arrow.clockwise").font(.caption.weight(.semibold)) }; Spacer(); NavigationLink(value: GPRoute.chart(code)) { Label("全屏分析", systemImage: "arrow.up.left.and.arrow.down.right").font(.caption.weight(.semibold)) }.accessibilityIdentifier("chart.fullscreen") }.tint(p.forest)
                }
                EditorialSection(title: "交易盘口", trailing: model.rules[code]?.isVerified == true ? "规则已验证" : "规则待验证") {
                    if model.orderBooks[code] == nil { GPStatus(title: "盘口数据尚未连接", detail: "五档报价未到达前不展示模拟档位或推测成交。", symbol: "rectangle.split.3x1") }
                    else if model.rules[code]?.isVerified != true { GPStatus(title: "交易规则尚未验证", detail: "不会假设 ETF 是 T+0，也不会固定推断手数或费用。", symbol: "checkmark.shield") }
                    else { OrderBookView(snapshot: model.orderBooks[code]!) }
                }
                EditorialSection(title: "账户与规则") {
                    if let position { GPDataRow(title: "持有数量", value: "\(position.units) 份"); GPDataRow(title: "账本成本", value: "¥\(NextMoney.text(position.costPerUnit, digits: 4))"); GPDataRow(title: "来源", value: "本机真实账本") }
                    else { Text("尚未录入真实账本；研究与模拟不会读取真实现金作为下单资金。").font(.caption).foregroundStyle(p.muted) }
                    if let rules = model.rules[code] { GPDataRow(title: "结算规则", value: rules.settlement == .unknown ? "未知" : rules.settlement.rawValue.uppercased(), note: rules.source); if let lot = rules.lotSize { GPDataRow(title: "交易单位", value: "\(lot) 份") } }
                    else { GPDataRow(title: "ETF 交易规则", value: "未接入来源") }
                }
                EditorialSection(title: "下一步") {
                    NavigationLink(value: GPRoute.decision(code)) { IntentRow(icon: "sparkles", title: "分析买入机会", detail: "组织行情、持仓、资金、限价计划与风险") }.accessibilityIdentifier("instrument.analyze-buy")
                    NavigationLink(value: GPRoute.twin(.G)) { IntentRow(icon: "waveform.path.ecg", title: "在数字孪生中观察", detail: "只影响 G 模拟账户，不触碰真实账本") }
                }
                if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(p.muted).padding(.vertical, 8) }
            }
        }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .onAppear { model.preferences.navigation.selectedSecurity = code; model.preferences = model.preferences }
    }
}

private struct OrderBookView: View {
    @Environment(\.gp) private var p
    let snapshot: NextOrderBookSnapshot
    private var isFresh: Bool { snapshot.observedAt <= Date() && Date().timeIntervalSince(snapshot.observedAt) <= 5 }
    var body: some View {
        VStack(spacing: 3) {
            HStack { Text("委卖").foregroundStyle(p.muted); Spacer(); Text("价格").foregroundStyle(p.muted); Spacer(); Text("数量").foregroundStyle(p.muted) }.font(.caption2)
            ForEach(Array(snapshot.asks.reversed().enumerated()), id: \.offset) { index, level in orderRow("卖\(5-index)", level: level, color: p.risk) }
            Rectangle().fill(p.line).frame(height: 1).padding(.vertical, 3)
            ForEach(Array(snapshot.bids.enumerated()), id: \.offset) { index, level in orderRow("买\(index+1)", level: level, color: p.jade) }
            Text("\(snapshot.source) · \(snapshot.observedAt.formatted(date: .omitted, time: .standard)) · \(isFresh ? "数据新鲜" : "数据已过期")").font(.system(size: 9, design: .monospaced)).foregroundStyle(isFresh ? p.muted : p.terracotta).frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 5)
        }.accessibilityElement(children: .combine).accessibilityLabel("\(snapshot.code) 五档买卖盘口，\(isFresh ? "数据新鲜" : "数据已过期")")
    }
    private func orderRow(_ title: String, level: NextBookLevel, color: Color) -> some View {
        HStack { Text(title).foregroundStyle(p.muted); Spacer(); Text(NextMoney.text(level.price, digits: 4)).foregroundStyle(color); Spacer(); Text("\(level.units)").foregroundStyle(p.ink) }
            .font(.system(size: 11, design: .monospaced)).padding(.vertical, 4)
    }
}

private struct FullscreenChartScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let code: String
    @State private var interval: NextChartInterval = .intraday
    @State private var crosshair: Date?
    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 14) {
                HStack { VStack(alignment: .leading) { Text(knownName(code)).font(.headline); Text("\(code) · \(model.quotes[code]?.stamp.label(now: Date()) ?? "暂无行情")").font(.caption).foregroundStyle(p.muted) }; Spacer(); NavigationLink(value: GPRoute.decision(code)) { Label("分析", systemImage: "sparkles").font(.caption.weight(.semibold)) } }
                DataPanel(title: "价格与 IOPV", caption: geo.size.width > geo.size.height ? "横屏 · 拖动/双指缩放" : "竖屏") {
                    UnifiedChartView(dataset: model.chartData[code], interval: $interval, costPerUnit: model.book.positions.first(where: { $0.code == code })?.costPerUnit, selectedTime: $crosshair, securityCode: code, expanded: true)
                    if let dataset = model.chartData[code] { Text("图表来源：\(dataset.priceSource) · 观测 \(dataset.observedAt.formatted(date: .numeric, time: .shortened)) · IOPV 历史\(dataset.iopvSource == nil ? "不可用" : "可用")").font(.caption2).foregroundStyle(p.muted) }
                }
                DataPanel(title: "十字光标数据") { if let crosshair { GPDataRow(title: "时间", value: crosshair.formatted(date: .numeric, time: .shortened)) } else { Text("拖动图表定位历史时点；返回详情后周期和光标状态继续保留。").font(.caption).foregroundStyle(p.muted) } }
                Spacer(minLength: 0)
            }.padding(16).background(p.canvas).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.navigationTitle("全屏行情分析").navigationBarTitleDisplayMode(.inline)
    }
}

private struct DecisionScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let code: String?
    @State private var years: String = "10"
    @State private var budget: String = "1000"
    @State private var limit: String = "40"
    @State private var analyzed = false
    @State private var result: NextDecision?
    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) { Image(systemName: "sparkles").foregroundStyle(p.forest); Text("私人投资顾问").font(.caption.weight(.semibold)).foregroundStyle(p.forest); Spacer(); Text("规则模式 · AI 未连接").font(.caption2).foregroundStyle(p.muted) }.padding(.top, 7)
                Text(code.map { "围绕 \(knownName($0))，把已知信息整理成下一步" } ?? "先说你想完成什么").font(.system(.title2, design: .serif).weight(.semibold)).foregroundStyle(p.ink).padding(.top, 10)
                Text("分析会结合本机账本、有效行情、预算和风险限制。没有来源的数据会明确标为缺口。").font(.subheadline).foregroundStyle(p.muted).padding(.top, 5)
                EditorialSection(title: "你的目标与资金") {
                    HStack(spacing: 10) { compactField("期限（年）", text: $years); compactField("每月新增预算", text: $budget); compactField("集中度线 %", text: $limit) }
                    Button("保存目标") { do { try model.saveGoal(years: Int(years) ?? 0, monthlyBudget: try NextMoney.parse(budget), concentration: try NextMoney.parse(limit)) } catch { model.errorMessage = error.localizedDescription } }.font(.caption.weight(.semibold)).tint(p.forest)
                    GPDataRow(title: "资金边界", value: "不动用真实现金", note: "计划和真实账本分开")
                }
                GPActionButton(title: "分析买入机会", systemImage: "sparkles") {
                    result = model.research(for: code)
                    if let result { model.recordDecision(result) }
                    analyzed = true
                }.padding(.vertical, 10)
                if analyzed {
                    EditorialSection(title: "结论") {
                        Text(result?.title ?? "先补齐行情和证据").font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
                        Text(result?.origin == "本地规则检查" ? "当前结果由本地规则整理，不是 AI 生成建议。" : "待接入 AI 服务，并为每项结论保存可追溯来源。")
                            .font(.caption).foregroundStyle(p.muted)
                    }
                    EditorialSection(title: "依据与风险") {
                        if let result { ForEach(result.evidence) { item in VStack(alignment: .leading, spacing: 4) { GPDataRow(title: item.title, value: item.level); Text(item.detail).font(.caption).foregroundStyle(p.muted) }.padding(.vertical, 4) } }
                        else { GPStatus(title: "证据暂不完整", detail: "补充有效行情或持仓后，才会展开可核实的依据。", symbol: "doc.text.magnifyingglass") }
                    }
                    EditorialSection(title: "耐心限价计划") { GPStatus(title: "暂不猜测合理价格", detail: "需先接入可验证的行情和价格研究依据。计划只会保存在本机，不会提交券商订单。", symbol: "hourglass") }
                    EditorialSection(title: "后续跟踪") { NavigationLink(value: GPRoute.alerts) { IntentRow(icon: "bell", title: "设置价格与风险提醒", detail: "触发时检查数据时间和来源") } }
                    EditorialSection(title: "历史决策成绩") { NavigationLink(value: GPRoute.history) { IntentRow(icon: "clock.arrow.circlepath", title: "查看决策复盘", detail: "保留当时结论和证据快照") } }
                    if let result {
                        ForEach(result.options) { option in
                            Button {
                                do { try model.chooseDecision(result.id, optionID: option.id); self.result?.selectedOption = option.id; self.result?.status = "已记录选择" }
                                catch { model.errorMessage = error.localizedDescription }
                            } label: {
                                DataPanel(title: option.title, caption: result.selectedOption == option.id ? "已选择" : "") {
                                    Text(option.rationale).font(.subheadline).foregroundStyle(p.ink)
                                    Text("需要考虑：\(option.tradeoff)").font(.caption).foregroundStyle(p.muted)
                                    if result.selectedOption == option.id { Label("已保存到决策记录", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(p.forest) }
                                }
                            }.buttonStyle(.plain).accessibilityHint("选择此研究方案并保存到历史记录")
                        }
                    }
                } else {
                    EditorialSection(title: "你可以直接从证券详情发起") { NavigationLink(value: GPRoute.instrument(model.watch.first ?? "159941")) { IntentRow(icon: "chart.xyaxis.line", title: "从 ETF 行情开始", detail: "自动携带证券上下文") } }
                }
            }
        }.onAppear {
            years = String(model.goal.years)
            budget = NSDecimalNumber(decimal: model.goal.monthlyBudget).stringValue
            limit = NSDecimalNumber(decimal: model.goal.concentrationLimit).stringValue
        }
    }
}

private struct LaboratoryScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var selected: NextTwinStrategy = .G
    @State private var funding = "1000"
    @State private var reason = "统一追加模拟资金"
    @State private var showFundingConfirm = false
    @State private var message = ""
    private var account: NextTwinAccount? { model.twins.accounts[selected.rawValue] }
    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 0) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text("数字孪生").font(.system(.title2, design: .serif).weight(.semibold)); Text("每个策略独立虚拟账户；真实账本无写入通道").font(.caption).foregroundStyle(p.muted) }; Spacer(); Image(systemName: "lock.shield").foregroundStyle(p.forest) }.padding(.top, 6)
                EditorialSection(title: "策略组 · A–G + H") {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 7) { ForEach(NextTwinStrategy.allCases) { strategy in Button { selected = strategy } label: { VStack(spacing: 3) { Text(strategy.rawValue).font(.system(.headline, design: .rounded).weight(.bold)); Text(shortTitle(strategy)).font(.system(size: 9)).lineLimit(1) }.frame(width: 65, height: 49).foregroundStyle(selected == strategy ? Color.white : p.ink).background(selected == strategy ? p.forestDeep : p.raised, in: RoundedRectangle(cornerRadius: 11)) }.buttonStyle(.plain).accessibilityLabel("\(strategy.rawValue) \(strategy.title)") } } }
                    NavigationLink(value: GPRoute.twin(selected)) { Label("策略假设与运行记录", systemImage: "arrow.up.right").font(.caption.weight(.medium)) }.tint(p.forest)
                }
                DataPanel(title: "\(selected.rawValue) · \(selected.title)", caption: account?.isPaused == true ? "已暂停" : "等待行情") {
                    Text(strategyDescription(selected)).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 22) { GPValue(label: "模拟现金", value: "¥\(NextMoney.text(account?.simulation.cash ?? 0))"); GPValue(label: "虚拟可用", value: "¥\(NextMoney.text(account?.simulation.available ?? 0))"); GPValue(label: "持仓数", value: "\(account?.simulation.positions.count ?? 0)") }
                    Text("收益、回撤、手续费和资金曲线会在有效历史行情及撮合结果可用后计算；此处不显示演示收益。").font(.caption2).foregroundStyle(p.muted)
                    Button(account?.isPaused == true ? "恢复该策略" : "暂停该策略") { do { try model.twins.setPaused(!(account?.isPaused ?? false), strategy: selected) } catch { model.errorMessage = error.localizedDescription } }.font(.caption.weight(.semibold)).tint(p.forest)
                }
                EditorialSection(title: "资金流") {
                    HStack { compactField("追加虚拟资金", text: $funding); compactField("用途", text: $reason) }
                    Button("向 A–H 同步注资") { showFundingConfirm = true }.font(.caption.weight(.semibold)).tint(p.forest)
                    if model.twins.funding.isEmpty { Text("尚无注资记录。仅明确确认的虚拟资金变动会同步到所有对照策略。").font(.caption).foregroundStyle(p.muted) }
                    ForEach(model.twins.funding.suffix(4).reversed()) { flow in GPDataRow(title: flow.reason, value: "+¥\(NextMoney.text(flow.amount))", note: flow.date.formatted(date: .numeric, time: .shortened)) }
                }
                EditorialSection(title: "统一数据图表") { UnifiedChartView(dataset: nil, interval: .constant(.year), costPerUnit: nil, selectedTime: .constant(nil)) }
                EditorialSection(title: "盘口回放与费用") { GPStatus(title: "撮合规则待行情源验证", detail: "ETF 模拟交易固定每笔 ¥0.10；未验证的证券手数、结算和市场状态不会自动推断。未成交订单单独列示，不计入收益。", symbol: "list.bullet.rectangle") }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(p.muted) }
            }
        }.confirmationDialog("确认向所有数字孪生账户注资？", isPresented: $showFundingConfirm, titleVisibility: .visible) {
            Button("确认同步注资", role: .destructive) { do { try model.addTwinFunding(try NextMoney.parse(funding), reason: reason); message = "已向 A–H 模拟账户记录相同金额与时点" } catch { model.errorMessage = error.localizedDescription } }
            Button("取消", role: .cancel) { }
        } message: { Text("仅改变 A–H 虚拟账户的资金流；不会读取或修改真实资产。") }
    }
}

private struct AssetsScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var addPosition = false
    @State private var cashAmount = ""
    @State private var cashReason = "用户记录的场内现金变动"
    @State private var cashDirection: Decimal = 1
    @State private var confirmCash = false
    @State private var confirmUndo = false
    @State private var pendingDelete: String?
    private var valuation: NextAssetValuation { model.book.valuation(using: model.quotes, at: Date()) }
    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 0) {
                Text("真实资产").font(.system(.title2, design: .serif).weight(.semibold)).padding(.top, 6)
                DataPanel(title: "场内资产总值", caption: "本机真实账本") {
                    Text(valuation.total.map { "¥\(NextMoney.text($0))" } ?? "行情数据不足").gpFont(size: 32, relativeTo: .largeTitle, weight: .medium, design: .rounded).monospacedDigit().foregroundStyle(p.ink)
                    Text(valuation.isComplete ? "现金 + 持仓估值 · \(valuation.quality.map { $0 == .live ? "新鲜行情" : "\($0.rawValue)缓存行情" } ?? "仅账本现金")" : "\(valuation.pricedPositions)/\(valuation.totalPositions) 只持仓有报价；不将部分估值标为总资产").font(.caption).foregroundStyle(p.muted)
                    HStack(spacing: 24) {
                        GPValue(label: "账本现金", value: "¥\(NextMoney.text(model.book.cash))")
                        GPValue(label: "持仓成本", value: "¥\(NextMoney.text(model.book.positions.reduce(0) { $0 + $1.bookCost }))")
                        GPValue(label: "当日盈亏", value: valuation.dailyChange.map { "\($0 >= 0 ? "+" : "")¥\(NextMoney.text($0))" } ?? "—", footnote: valuation.dailyChangePercent.map { "昨收 \(NextMoney.text($0))%" } ?? "需新鲜报价", emphasis: valuation.dailyChange.map { $0 >= 0 ? p.risk : p.jade })
                    }.padding(.top, 3)
                }.padding(.top, 15)
                EditorialSection(title: "持仓明细", trailing: "\(model.book.positions.count) 项") {
                    HStack { Button { addPosition = true } label: { Label("录入已确认持仓", systemImage: "plus") }.font(.caption.weight(.semibold)); Spacer(); NavigationLink(value: GPRoute.fills) { Label("资产流水", systemImage: "list.bullet.rectangle") }.font(.caption) }.tint(p.forest)
                    if model.book.positions.isEmpty { GPStatus(title: "账本为空", detail: "只录入你确认的场内证券，不自动导入旧账本或场外基金。", symbol: "tray") }
                    ForEach(model.book.positions) { position in
                        HStack(spacing: 4) {
                            NavigationLink(value: GPRoute.instrument(position.code)) { InstrumentRow(code: position.code, name: position.name, units: position.units, quote: model.quotes[position.code]) }.buttonStyle(.plain)
                            Menu { Button("删除持仓", systemImage: "trash", role: .destructive) { pendingDelete = position.code } } label: { Image(systemName: "ellipsis").foregroundStyle(p.muted).frame(width: 38, height: 44).contentShape(Rectangle()) }.accessibilityLabel("\(position.name) 更多操作")
                        }
                    }
                }
                EditorialSection(title: "现金变动") {
                    HStack { Button("转入") { cashDirection = 1 }; Button("转出") { cashDirection = -1 }.foregroundStyle(p.risk) }.buttonStyle(.bordered)
                    compactField("金额", text: $cashAmount); compactField("用途/备注", text: $cashReason)
                    GPActionButton(title: "审核并记录现金变动", secondary: true) { confirmCash = true }
                    if let latest = model.book.cashMovements.last { GPDataRow(title: latest.reason, value: "\(latest.amount >= 0 ? "+" : "")¥\(NextMoney.text(latest.amount))", note: latest.date.formatted(date: .numeric, time: .shortened)) }
                }
                EditorialSection(title: "安全与数据") {
                    NavigationLink(value: GPRoute.fills) { IntentRow(icon: "clock.arrow.circlepath", title: "审计与撤销", detail: "查看真实账本修改记录") }
                    NavigationLink(value: GPRoute.backups) { IntentRow(icon: "externaldrive.badge.timemachine", title: "备份与恢复", detail: "先校验备份，再确认恢复") }
                    Button { confirmUndo = true } label: { IntentRow(icon: "arrow.uturn.backward", title: "撤销最近账本变更", detail: "仅当账本仍匹配该审计版本时可撤销") }.buttonStyle(.plain)
                }
            }
        }.sheet(isPresented: $addPosition) { AddPositionSheet { code, name, units, cost in do { try model.addPosition(code: code, name: name, units: units, cost: cost) } catch { model.errorMessage = error.localizedDescription } } }
        .confirmationDialog("确认真实账本变更？", isPresented: $confirmCash, titleVisibility: .visible) { Button("确认记录", role: .destructive) { do { try model.adjustRealCash(cashDirection * NextMoney.parse(cashAmount), reason: cashReason); cashAmount = "" } catch { model.errorMessage = error.localizedDescription } }; Button("取消", role: .cancel) { } } message: { Text("本操作会改变真实场内账本，写入审计记录；不会向券商下单。") }
        .confirmationDialog("撤销最近账本变更？", isPresented: $confirmUndo, titleVisibility: .visible) { Button("确认撤销", role: .destructive) { do { try model.undoLatestLedgerChange() } catch { model.errorMessage = error.localizedDescription } }; Button("取消", role: .cancel) { } } message: { Text("撤销前会检查当前账本版本。") }
        .confirmationDialog("确认删除这条持仓？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("确认删除", role: .destructive) { if let code = pendingDelete { var updated = model.book; updated.positions.removeAll { $0.code == code }; do { try model.commitRealLedger(updated, action: "删除场内持仓", reason: "用户确认删除") } catch { model.errorMessage = error.localizedDescription }; pendingDelete = nil } }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { Text("变更会写入账本审计记录，可在记录有效时撤销。") }
    }
}

private struct AddPositionSheet: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.gp) private var p
    @State private var code = ""; @State private var name = ""; @State private var units = ""; @State private var cost = ""; @State private var confirm = false
    var body: some View {
        NavigationStack {
            Form { Section("证券信息") { TextField("6 位场内代码", text: $code).keyboardType(.numberPad); TextField("名称", text: $name); TextField("数量", text: $units).keyboardType(.numberPad); TextField("持仓总成本", text: $cost).keyboardType(.decimalPad) }; Section { Text("只写入你确认的新场内账本。不会自动导入旧版混合资产。真实交易由你在券商完成。").font(.caption).foregroundStyle(p.muted) } }
                .navigationTitle("录入持仓").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("核对并保存") { confirm = true }.disabled(code.count != 6 || Int(units) == nil || cost.isEmpty) } }
                .confirmationDialog("确认录入真实账本？", isPresented: $confirm, titleVisibility: .visible) { Button("确认保存") { guard let u = Int(units), let c = try? NextMoney.parse(cost) else { return }; onSave(code, name.isEmpty ? code : name, u, c); dismiss() }; Button("取消", role: .cancel) { } } message: { Text("\(code) · \(name.isEmpty ? "场内证券" : name) · \(units) 份 · 成本 ¥\(cost)。保存后会产生可审计记录。") }
        }
    }
    let onSave: (String, String, Int, Decimal) -> Void
}

private struct SettingsScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var dynamicTypeNote = false
    @State private var nasURL = ""
    @State private var nasToken = ""
    @State private var confirmSync = false
    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 0) {
                Text("用舒适的方式查看市场").font(.system(.title2, design: .serif).weight(.semibold)).foregroundStyle(p.ink).padding(.top, 8)
                EditorialSection(title: "外观") { Picker("主题", selection: Binding(get: { model.theme }, set: model.saveTheme)) { ForEach(GPTheme.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("settings.theme"); Text("字体大小跟随 iOS 动态字体设置；减少动态效果跟随系统辅助功能。").font(.caption).foregroundStyle(p.muted) }
                EditorialSection(title: "通知与提醒") { NavigationLink(value: GPRoute.alerts) { IntentRow(icon: "bell.badge", title: "提醒和通知中心", detail: "价格、风险、限价计划与 NAS 状态") } }
                EditorialSection(title: "账本与数据") { NavigationLink(value: GPRoute.fills) { IntentRow(icon: "list.bullet.rectangle", title: "审计记录", detail: "真实资产修改、撤销和版本") }; NavigationLink(value: GPRoute.backups) { IntentRow(icon: "externaldrive", title: "备份与恢复", detail: "数据隔离、校验、确认恢复") } }
                EditorialSection(title: "连接状态") { GPDataRow(title: "行情服务", value: model.status); GPDataRow(title: "NAS 服务", value: model.syncStatus); GPDataRow(title: "同步通道", value: "个人资产手动 · 行情独立 · 研究独立") }
                EditorialSection(title: "新 NAS 连接") {
                    TextField("NAS HTTPS 地址，例如 https://nas.example.com", text: $nasURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder)
                    SecureField("至少 24 字符的新服务口令", text: $nasToken).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    HStack { Button("保存并测试") { do { try model.configureNAS(baseURL: nasURL, token: nasToken); nasToken = ""; Task { await model.probeNAS() } } catch { model.errorMessage = error.localizedDescription } }.font(.caption.weight(.semibold)); Spacer(); Button("重新检查") { Task { await model.probeNAS() } }.font(.caption) }.tint(p.forest)
                    GPActionButton(title: "手动同步真实账本", secondary: true, systemImage: "arrow.triangle.2.circlepath") { confirmSync = true }
                    Text("NAS 使用独立 8790 服务和新数据库；请通过受信任 HTTPS 入口连接，口令保存在系统钥匙串。同步采用修订号比较；服务端版本变化、未关联已有账本或网络异常时停止，不自动覆盖。")
                        .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
                EditorialSection(title: "无障碍") { Button("减少动态效果") { dynamicTypeNote = true }.font(.caption.weight(.medium)); Text("底部导航、表单、列表行和图表均提供可访问标签；页面遵循安全区并避让系统键盘。").font(.caption).foregroundStyle(p.muted) }
                Text("观盘 Pro · 新原生账本结构").font(.caption2).foregroundStyle(p.muted).padding(.vertical, 18)
            }
        }.onAppear { nasURL = model.preferences.nasBaseURL }
            .confirmationDialog("确认把本机真实账本同步到新 NAS？", isPresented: $confirmSync, titleVisibility: .visible) {
                Button("确认同步", role: .destructive) { Task { await model.syncBookManually() } }
                Button("取消", role: .cancel) { }
            } message: { Text("仅当服务端修订与已确认的上次同步一致，或服务端仍为空账本时才会写入。真实资产不自动合并、不连接券商。") }
            .alert("系统动效设置", isPresented: $dynamicTypeNote) { Button("好", role: .cancel) { } } message: { Text("请在 iOS 设置 → 辅助功能 → 动态效果中启用“减少动态效果”。应用会遵循系统设置。") }
    }
}

private struct GPSearchHit: Identifiable {
    let id: String
    let category: String
    let title: String
    let detail: String
    let symbol: String
    let route: GPRoute
    var securityCode: String? = nil
}

private struct SearchSheet: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @Environment(\.dismiss) private var dismiss
    private var query: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private func matches(_ values: String...) -> Bool {
        query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
    private var results: [GPSearchHit] {
        var hits = [GPSearchHit]()
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let known = Set(model.watch + model.book.positions.map(\.code) + model.quotes.keys)
        let candidates = known.union(query.count == 6 && query.allSatisfy(\.isNumber) ? [query] : [])
        for code in candidates.sorted() {
            let name = model.book.positions.first(where: { $0.code == code })?.name ?? model.quotes[code]?.quote.name ?? knownName(code)
            guard matches(code, name) else { continue }
            let position = model.book.positions.first(where: { $0.code == code })
            hits.append(GPSearchHit(id: "security-\(code)", category: "证券", title: name, detail: "\(code)\(position.map { " · 持有 \($0.units) 份" } ?? (model.watch.contains(code) ? " · 自选" : ""))", symbol: "chart.xyaxis.line", route: .instrument(code), securityCode: code))
        }
        for fill in model.book.fills.reversed() where !query.isEmpty && matches(fill.code, fill.side, NextMoney.text(fill.price), fill.date.formatted(date: .numeric, time: .shortened)) {
            hits.append(GPSearchHit(id: "fill-\(fill.id)", category: "交易流水", title: "\(fill.code) · \(fill.side) \(fill.units) 份", detail: "成交价 ¥\(NextMoney.text(fill.price, digits: 4)) · 手续费 ¥\(NextMoney.text(fill.fee)) · \(fill.date.formatted(date: .numeric, time: .shortened))", symbol: "arrow.left.arrow.right", route: .fills))
        }
        for movement in model.book.cashMovements.reversed() where !query.isEmpty && matches(movement.reason, NextMoney.text(movement.amount), movement.date.formatted(date: .numeric, time: .shortened)) {
            hits.append(GPSearchHit(id: "cash-\(movement.id)", category: "交易流水", title: movement.reason, detail: "\(movement.amount >= 0 ? "+" : "−")¥\(NextMoney.text(movement.amount >= 0 ? movement.amount : -movement.amount)) · \(movement.date.formatted(date: .numeric, time: .shortened))", symbol: "yensign.circle", route: .fills))
        }
        for decision in model.decisions where !query.isEmpty && matches(decision.title, decision.status, decision.origin) {
            hits.append(GPSearchHit(id: "decision-\(decision.id)", category: "历史决策", title: decision.title, detail: "\(decision.status) · \(decision.createdAt.formatted(date: .numeric, time: .shortened))", symbol: "sparkles", route: .history))
        }
        for alert in model.preferences.notifications.alerts where !query.isEmpty && matches(alert.title, alert.detail, alert.level) {
            hits.append(GPSearchHit(id: "alert-\(alert.id)", category: "提醒", title: alert.title, detail: "\(alert.level) · \(alert.stamp.label(now: Date()))", symbol: "bell.badge", route: .alerts))
        }
        for strategy in NextTwinStrategy.allCases where !query.isEmpty && matches(strategy.rawValue, strategy.title) {
            hits.append(GPSearchHit(id: "strategy-\(strategy.rawValue)", category: "数字孪生", title: "\(strategy.rawValue) · \(strategy.title)", detail: strategyDescription(strategy), symbol: "waveform.path.ecg", route: .twin(strategy)))
        }
        return Array(hits.prefix(250))
    }
    private var categories: [String] { ["证券", "交易流水", "历史决策", "提醒", "数字孪生"] }
    private func results(in category: String) -> [GPSearchHit] { results.filter { $0.category == category } }
    @ViewBuilder private func hitRow(_ hit: GPSearchHit) -> some View {
        HStack(spacing: 8) {
            NavigationLink(value: hit.route) {
                HStack(spacing: 10) {
                    Image(systemName: hit.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(p.forest).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) { Text(hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink); Text(hit.detail).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true) }
                    Spacer(minLength: 2); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.muted)
                }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("search.hit.\(hit.id)")
            if let code = hit.securityCode {
                Button { model.openInstrumentIntent(code); dismiss() } label: { Image(systemName: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(p.forest).frame(width: 38, height: 42).background(p.tint, in: RoundedRectangle(cornerRadius: 11)) }
                    .accessibilityLabel("分析 \(hit.title) 买入机会")
            }
        }
    }
    var body: some View {
        NavigationStack {
            GPPageBackground {
                HStack(spacing: 8) {
                    TextField("输入代码或名称", text: $model.searchText).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    if !query.isEmpty {
                        Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(p.muted).frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .accessibilityLabel("清除搜索")
                            .accessibilityIdentifier("search.clear")
                    }
                }.padding(.top, 8)
                if results.isEmpty { GPStatus(title: query.isEmpty ? "搜索证券、流水、决策、提醒或策略" : "没有找到匹配内容", detail: query.isEmpty ? "输入代码或关键词；证券结果也可一键进入买入机会分析。" : "可搜索本机证券、交易流水、历史决策、通知记录和 A–H 数字孪生。", symbol: "magnifyingglass") }
                ForEach(categories, id: \.self) { category in
                    let rows = results(in: category)
                    if !rows.isEmpty {
                        EditorialSection(title: category, trailing: "\(rows.count)") {
                            ForEach(rows) { hit in hitRow(hit) }
                        }
                    }
                }
            }.navigationTitle("全局搜索").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear { model.searchText = model.preferences.navigation.searchQuery }
                .onChange(of: model.searchText) { _, query in model.preferences.navigation.searchQuery = query; model.preferences = model.preferences }
                .navigationDestination(for: GPRoute.self) { RouteDestination(route: $0) }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

private struct AlertCenterScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    var body: some View {
        GPPageBackground {
            EditorialSection(title: "通知记录", trailing: "去重与静默时段") {
                Text("支持价格、均线、组合风险、限价计划、模拟结果和 NAS 数据异常。实际推送需在通知授权与服务端配置后启用。").font(.caption).foregroundStyle(p.muted)
                if model.preferences.notifications.alerts.isEmpty { GPStatus(title: "暂无通知记录", detail: "网络或 NAS 未连接时仍可查看本机已有提醒。", symbol: "bell.slash") }
                ForEach(model.preferences.notifications.alerts) { alert in DataPanel(title: alert.title, caption: alert.level) { Text(alert.detail).font(.subheadline); Text(alert.stamp.label(now: Date())).font(.caption2.monospaced()).foregroundStyle(p.muted) } }
            }
            EditorialSection(title: "静默时段") { Text("\(model.preferences.notifications.quietHours.startMinute / 60):00 – \(model.preferences.notifications.quietHours.endMinute / 60):00").font(.subheadline); Text("静默期间通知保留在记录中，不重复弹出。").font(.caption).foregroundStyle(p.muted) }
        }.navigationTitle("通知中心").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LedgerHistoryScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    var body: some View {
        GPPageBackground {
            EditorialSection(title: "账本修改审计", trailing: "\(model.ledger.events.count) 条") {
                if model.ledger.events.isEmpty { GPStatus(title: "暂无变更记录", detail: "每次真实账本写入都将记录前后版本和原因。", symbol: "checkmark.shield") }
                ForEach(model.ledger.events.reversed()) { event in DataPanel(title: event.action, caption: event.at.formatted(date: .numeric, time: .shortened)) { Text(event.reason).font(.caption); GPDataRow(title: "账前现金", value: "¥\(NextMoney.text(event.before.cash))"); GPDataRow(title: "账后现金", value: "¥\(NextMoney.text(event.after.cash))"); if event.undoneAt != nil { Text("已撤销").font(.caption).foregroundStyle(p.terracotta) } } }
            }
            EditorialSection(title: "真实资产流水") {
                ForEach(model.book.cashMovements.reversed()) { flow in GPDataRow(title: flow.reason, value: "\(flow.amount >= 0 ? "+" : "")¥\(NextMoney.text(flow.amount))", note: flow.date.formatted(date: .numeric, time: .shortened)) }
                ForEach(model.book.fills.reversed()) { fill in GPDataRow(title: "\(fill.code) · \(fill.side)", value: "\(fill.units) 份 × ¥\(NextMoney.text(fill.price, digits: 4))", note: "手续费 ¥\(NextMoney.text(fill.fee)) · \(fill.date.formatted(date: .numeric, time: .shortened))") }
            }
        }.navigationTitle("资产流水与审计").navigationBarTitleDisplayMode(.inline)
    }
}

private struct DecisionHistoryScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var reviewNotes: [UUID: String] = [:]
    var body: some View {
        GPPageBackground {
            if model.decisions.isEmpty { GPStatus(title: "尚无已留存的历史决策", detail: "分析后会保存当时行情、来源、风险和你的选择；未持久化前不显示虚构成绩。", symbol: "clock.arrow.circlepath") }
            ForEach(model.decisions) { decision in
                EditorialSection(title: decision.title, trailing: decision.createdAt.formatted(date: .numeric, time: .shortened)) {
                    GPDataRow(title: "研究来源", value: decision.origin, note: decision.status)
                    if let selected = decision.selectedOption, let option = decision.options.first(where: { $0.id == selected }) {
                        GPDataRow(title: "已选方案", value: option.title)
                    }
                    ForEach(decision.evidence) { evidence in VStack(alignment: .leading, spacing: 3) { GPDataRow(title: evidence.title, value: evidence.level); Text(evidence.detail).font(.caption).foregroundStyle(p.muted) } }
                    if !decision.review.isEmpty { Text("复盘：\(decision.review)").font(.caption).foregroundStyle(p.muted) }
                    if decision.review.isEmpty {
                        TextField("复盘：后来发生了什么？", text: Binding(get: { reviewNotes[decision.id] ?? "" }, set: { reviewNotes[decision.id] = $0 }), axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                        Button("保存复盘") { do { try model.reviewDecision(decision.id, note: reviewNotes[decision.id] ?? ""); reviewNotes[decision.id] = "" } catch { model.errorMessage = error.localizedDescription } }.font(.caption.weight(.semibold)).tint(p.forest)
                    }
                }
            }
        }.navigationTitle("历史决策").navigationBarTitleDisplayMode(.inline)
    }
}

private struct BackupRestoreScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var document = GuanpanBackupDocument()
    @State private var pending: NextArchiveEnvelope?
    @State private var restoreSummary = ""
    @State private var confirmRestore = false
    var body: some View {
        GPPageBackground {
            GPStatus(title: "本机备份与可验证恢复", detail: "导出文件包含独立账本、A–H 模拟账户、行情缓存、图表、交易规则和审计记录，并带 SHA-256 校验。", symbol: "externaldrive")
            DataPanel(title: "操作前保护") { GPDataRow(title: "真实账本", value: "独立文件 · iOS 文件保护"); GPDataRow(title: "模拟账户", value: "独立文件与账户模型"); GPDataRow(title: "恢复前副本", value: "自动保存到本机恢复目录"); GPDataRow(title: "旧版资产", value: "不自动迁移或覆盖") }
            GPActionButton(title: "导出完整备份", secondary: true, systemImage: "square.and.arrow.up") {
                do { document = GuanpanBackupDocument(data: try JSONEncoder().encode(model.makeBackup())); isExporting = true }
                catch { model.errorMessage = error.localizedDescription }
            }
            GPActionButton(title: "选择备份并校验", secondary: true, systemImage: "square.and.arrow.down") { isImporting = true }
            Text("恢复前会检查版本、结构和校验值，再显示数据数量供你确认。若安全副本写入失败，恢复会停止。")
                .font(.caption).foregroundStyle(p.muted).padding(.vertical, 8)
        }.navigationTitle("备份与恢复").navigationBarTitleDisplayMode(.inline)
            .fileExporter(isPresented: $isExporting, document: document, contentType: .json, defaultFilename: "观盘Pro-安全备份") { result in
                if case .failure(let error) = result { model.errorMessage = "导出失败：\(error.localizedDescription)" }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let envelope = try JSONDecoder().decode(NextArchiveEnvelope.self, from: Data(contentsOf: url))
                    let archive = try envelope.archive(); pending = envelope
                    restoreSummary = "\(archive.book.positions.count) 只持仓 · \(archive.book.fills.count + archive.book.cashMovements.count) 条资产流水 · \(archive.twins.accounts.count) 个模拟账户 · \(archive.audits.count) 条审计记录"
                    confirmRestore = true
                } catch { model.errorMessage = "备份没有通过校验，未修改账本：\(error.localizedDescription)" }
            }
            .confirmationDialog("确认恢复此备份？", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("备份当前数据并恢复", role: .destructive) {
                    guard let pending else { return }
                    do { try model.restoreBackup(pending); self.pending = nil }
                    catch { model.errorMessage = "恢复已停止，当前数据仍保留：\(error.localizedDescription)" }
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: { Text("\(restoreSummary)。恢复前状态会生成独立本机安全副本。") }
    }
}

private struct TwinDetailScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let strategy: NextTwinStrategy
    var body: some View {
        GPPageBackground {
            DataPanel(title: "\(strategy.rawValue) · \(strategy.title)", caption: "独立模拟账户") {
                Text(strategyDescription(strategy)).font(.subheadline).foregroundStyle(p.muted)
                GPDataRow(title: "模拟现金", value: "¥\(NextMoney.text(model.twins.accounts[strategy.rawValue]?.simulation.cash ?? 0))")
                GPDataRow(title: "可用资金", value: "¥\(NextMoney.text(model.twins.accounts[strategy.rawValue]?.simulation.available ?? 0))")
                GPDataRow(title: "账户来源", value: model.twins.accounts[strategy.rawValue]?.seedSource ?? "空白模拟账户")
                Text("未接入历史行情，收益曲线、回撤、夏普、逐笔成交与未成交单均不会显示估算数值。").font(.caption).foregroundStyle(p.muted)
            }
            EditorialSection(title: "研究任务状态") { GPStatus(title: "NAS 自主研究尚未连接", detail: "该策略不会依赖 NAS 打开应用；NAS 离线时仍可读取本机缓存结果。", symbol: "externaldrive.badge.questionmark") }
        }.navigationTitle("策略详情").navigationBarTitleDisplayMode(.inline)
    }
}

private struct IntentRow: View {
    @Environment(\.gp) private var p
    let icon: String; let title: String; let detail: String
    var body: some View { HStack(spacing: 12) { Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(p.forest).frame(width: 34); VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink); Text(detail).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true) }; Spacer(minLength: 6); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(p.muted) }.padding(.vertical, 10).contentShape(Rectangle()) }
}

private func compactField(_ title: String, text: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption2).foregroundStyle(.secondary); TextField(title, text: text).font(.subheadline).textFieldStyle(.roundedBorder).keyboardType(.decimalPad).submitLabel(.done) }.frame(maxWidth: .infinity) }
private func knownName(_ code: String) -> String { ["159941":"纳指 ETF", "563020":"低波红利", "159545":"港股红利", "159352":"A500"][code] ?? "场内证券" }
private func shortTitle(_ strategy: NextTwinStrategy) -> String { switch strategy { case .A: "基准"; case .B: "原权重"; case .C: "目标配"; case .D: "再平衡"; case .E: "价值"; case .F: "风控"; case .G: "AI 多因子"; case .H: "自定义" } }
private func strategyDescription(_ strategy: NextTwinStrategy) -> String { switch strategy { case .A: "完全不操作的对照基准；接受同一注资与分红，不主动买卖。"; case .B: "按初始组合比例进行定投；记录每笔假设与费用。"; case .C: "按用户设定的目标配置模拟定投。"; case .D: "按预设周期检查偏离并模拟再平衡。"; case .E: "基于已验证估值和红利数据进行智能价值调仓研究。"; case .F: "用趋势与风险约束管理模拟仓位。"; case .G: "AI 多因子自主模拟交易，在独立虚拟账户中持续研究与回放。"; case .H: "可配置条件与参数的用户自定义策略，与 A–G 账户分开比较。" } }
