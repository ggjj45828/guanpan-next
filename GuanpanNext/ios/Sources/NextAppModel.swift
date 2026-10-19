import Foundation
import SwiftUI

struct LocalPreferences: Codable {
    var goal = NextGoal()
    var watch = ["159941", "563020", "159545", "159352"]
    var navigation = NextNavigationState()
    var theme = GPTheme.system
    var notifications = NextNotificationCenter()
    var nasBaseURL = ""
    var nasRevision: Int?
    enum CodingKeys: String, CodingKey { case goal, watch, navigation, theme, notifications, nasBaseURL, nasRevision }
    init(goal: NextGoal = NextGoal(), watch: [String] = ["159941", "563020", "159545", "159352"], navigation: NextNavigationState = NextNavigationState(), theme: GPTheme = .system, notifications: NextNotificationCenter = NextNotificationCenter(), nasBaseURL: String = "", nasRevision: Int? = nil) {
        self.goal = goal; self.watch = watch; self.navigation = navigation; self.theme = theme; self.notifications = notifications
        self.nasBaseURL = nasBaseURL; self.nasRevision = nasRevision
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        goal = try values.decodeIfPresent(NextGoal.self, forKey: .goal) ?? NextGoal()
        watch = try values.decodeIfPresent([String].self, forKey: .watch) ?? ["159941", "563020", "159545", "159352"]
        navigation = try values.decodeIfPresent(NextNavigationState.self, forKey: .navigation) ?? NextNavigationState()
        theme = try values.decodeIfPresent(GPTheme.self, forKey: .theme) ?? .system
        notifications = try values.decodeIfPresent(NextNotificationCenter.self, forKey: .notifications) ?? NextNotificationCenter()
        nasBaseURL = try values.decodeIfPresent(String.self, forKey: .nasBaseURL) ?? ""
        nasRevision = try values.decodeIfPresent(Int.self, forKey: .nasRevision)
    }
}

/// The real ledger, simulations, and app preferences use separate versioned files.
/// No legacy defaults or mixed OTC records are silently imported.
@MainActor final class NextLocalRepository {
    private let directory: URL
    private let recoveryDirectory: URL
    private var blockedFiles = Set<String>()
    private(set) var integrityWarning: String?
    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("GuanpanProNative", isDirectory: true)
        recoveryDirectory = base.appendingPathComponent("GuanpanProNative-Recovery", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        } catch {
            integrityWarning = "本机安全存储无法初始化：\(error.localizedDescription)；真实账本写入已停止。"
        }
    }
    func load<T: Decodable>(_ type: T.Type, filename: String, fallback: T) -> T {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch {
            blockedFiles.insert(filename)
            integrityWarning = "本机数据文件 \(filename) 无法读取或校验；原文件已保留，相关写入已停止。请先导出/恢复经过验证的备份。"
            return fallback
        }
    }
    func save<T: Encodable>(_ value: T, filename: String) -> String? {
        if let integrityWarning { return integrityWarning }
        if blockedFiles.contains(filename) { return "\(filename) 校验失败；为避免覆盖原始数据，保存已停止" }
        let url = directory.appendingPathComponent(filename)
        guard let data = try? JSONEncoder().encode(value) else { return "本机数据无法编码" }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            return nil
        } catch { return error.localizedDescription }
    }
    func writeSafetyCopy(_ archive: NextArchiveEnvelope) throws -> URL {
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let url = recoveryDirectory.appendingPathComponent("before-restore-\(UUID().uuidString).guanpanbackup")
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return url
    }
    func writeRawSafetyCopy() throws -> URL {
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let url = recoveryDirectory.appendingPathComponent("before-restore-raw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: directory, to: url)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return url
    }
    func replaceAll(with archive: NextAppArchive) throws {
        try archive.validate()
        let encoder = JSONEncoder()
        let files: [(String, Data)] = [
            ("real-ledger-v1.json", try encoder.encode(NextAuditedBook(current: archive.book, events: archive.audits))),
            ("simulation-ledger-v1.json", try encoder.encode(archive.experiment)),
            ("digital-twins-v1.json", try encoder.encode(archive.twins)),
            ("preferences-v1.json", try encoder.encode(LocalPreferences(goal: archive.goal, watch: archive.watch, navigation: archive.navigation, theme: GPTheme(rawValue: archive.theme.rawValue) ?? .system, notifications: archive.notifications))),
            ("cached-quotes-v1.json", try encoder.encode(archive.cachedQuotes)),
            ("chart-history-v1.json", try encoder.encode(archive.chartData)),
            ("instrument-rules-v1.json", try encoder.encode(archive.instrumentRules)),
            ("order-books-v1.json", try encoder.encode(archive.orderBooks)),
            ("decision-history-v1.json", try encoder.encode(archive.decisionHistory)),
            ("nas-research-v1.json", try encoder.encode(archive.nasResearch))
        ]
        let parent = directory.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("GuanpanProNative-staging-\(UUID().uuidString)", isDirectory: true)
        let prior = recoveryDirectory.appendingPathComponent("pre-restore-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for (name, data) in files {
                let url = staging.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.moveItem(at: directory, to: prior) }
            do { try FileManager.default.moveItem(at: staging, to: directory) }
            catch {
                if FileManager.default.fileExists(atPath: prior.path) { try? FileManager.default.moveItem(at: prior, to: directory) }
                throw error
            }
            blockedFiles.removeAll()
            integrityWarning = nil
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}

@MainActor final class NextAppModel: ObservableObject {
    @Published var ledger: NextAuditedBook { didSet { reportSave(repository.save(ledger, filename: "real-ledger-v1.json")) } }
    @Published var experiment: NextExperiment { didSet { reportSave(repository.save(experiment, filename: "simulation-ledger-v1.json")) } }
    @Published var twins: NextTwinLedger { didSet { reportSave(repository.save(twins, filename: "digital-twins-v1.json")) } }
    @Published var preferences: LocalPreferences { didSet { reportSave(repository.save(preferences, filename: "preferences-v1.json")) } }
    @Published var quotes: [String: NextCachedQuote] { didSet { reportSave(repository.save(quotes, filename: "cached-quotes-v1.json")) } }
    @Published var chartData: [String: NextChartDataset] { didSet { reportSave(repository.save(chartData, filename: "chart-history-v1.json")) } }
    @Published var rules: [String: NextInstrumentRules] { didSet { reportSave(repository.save(rules, filename: "instrument-rules-v1.json")) } }
    @Published var orderBooks: [String: NextOrderBookSnapshot] { didSet { reportSave(repository.save(orderBooks, filename: "order-books-v1.json")) } }
    @Published var decisions: [NextDecision] { didSet { reportSave(repository.save(decisions, filename: "decision-history-v1.json")) } }
    @Published var nasResearch: [String: NextNASResearch] { didSet { reportSave(repository.save(nasResearch, filename: "nas-research-v1.json")) } }
    @Published var status = "行情尚未刷新 · 缓存可离线查看"
    @Published var syncStatus = "NAS 未连接"
    @Published var notificationStatus = "尚未检查系统通知权限"
    @Published var errorMessage: String?
    @Published var showSearch = false
    @Published var searchText = ""
    @Published var notice = ""
    @Published var requestedTab: NextTab?
    @Published var requestedRoute: GPRoute?
    @Published var routeRequestID = UUID()
    private let repository: NextLocalRepository

    var book: NextBook { ledger.current }
    var goal: NextGoal { preferences.goal }
    var watch: [String] { preferences.watch }
    var theme: GPTheme { preferences.theme }
    var selectedTab: NextTab {
        get { preferences.navigation.selectedTab }
        set { preferences.navigation.selectedTab = newValue; preferences = preferences }
    }
    init(repository: NextLocalRepository? = nil) {
        let repository = repository ?? NextLocalRepository()
        self.repository = repository
        let real = repository.load(NextAuditedBook.self, filename: "real-ledger-v1.json", fallback: NextAuditedBook(current: NextBook()))
        self.ledger = real
        self.experiment = repository.load(NextExperiment.self, filename: "simulation-ledger-v1.json", fallback: NextExperiment())
        self.twins = repository.load(NextTwinLedger.self, filename: "digital-twins-v1.json", fallback: NextTwinLedger())
        self.preferences = repository.load(LocalPreferences.self, filename: "preferences-v1.json", fallback: LocalPreferences())
        self.quotes = repository.load([String: NextCachedQuote].self, filename: "cached-quotes-v1.json", fallback: [:])
        self.chartData = repository.load([String: NextChartDataset].self, filename: "chart-history-v1.json", fallback: [:])
        self.rules = repository.load([String: NextInstrumentRules].self, filename: "instrument-rules-v1.json", fallback: [:])
        self.orderBooks = repository.load([String: NextOrderBookSnapshot].self, filename: "order-books-v1.json", fallback: [:])
        self.decisions = repository.load([NextDecision].self, filename: "decision-history-v1.json", fallback: [])
        self.nasResearch = repository.load([String: NextNASResearch].self, filename: "nas-research-v1.json", fallback: [:])
        self.errorMessage = repository.integrityWarning
    }
    func commitRealLedger(_ updated: NextBook, action: String, reason: String) throws {
        try updated.validate()
        var copy = ledger
        try copy.apply(updated, action: action, reason: reason, at: Date())
        ledger = copy
    }
    func addPosition(code: String, name: String, units: Int, cost: Decimal) throws {
        guard !book.positions.contains(where: { $0.code == code }), units > 0, cost > 0 else { throw NextError.invalid("代码、份额或持仓成本无效，或该证券已经存在") }
        var updated = book
        updated.positions.append(NextPosition(code: code, name: name, units: units, bookCost: cost))
        try commitRealLedger(updated, action: "录入场内持仓", reason: "用户确认保存")
    }
    func recordTrade(code: String, name: String, side: String, units: Int, price: Decimal, fee: Decimal) throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), units > 0, price > 0,
              side == "buy" || side == "sell", fee >= 0, !fee.isNaN else { throw NextError.invalid("成交代码、方向、价格、份额或手续费无效") }
        if rules[code]?.assetClass == .etf || quotes[code]?.quote.providerInstrumentType == "ETF" {
            guard fee == Decimal(string: "0.10")! else { throw NextError.invalid("已核实 ETF 的手续费按每笔 ¥0.10 记录") }
        }
        let gross = price * Decimal(units)
        var updated = book
        let positionIndex = updated.positions.firstIndex { $0.code == code }
        var realized: Decimal = 0
        if side == "buy" {
            guard updated.cash >= gross + fee else { throw NextError.invalid("账本现金不足。请先在资产页记录真实转入；若只是补录已有持仓，可直接从此证券录入持仓。") }
            updated.cash -= gross + fee
            if let positionIndex {
                updated.positions[positionIndex].units += units
                updated.positions[positionIndex].bookCost += gross + fee
            } else {
                updated.positions.append(NextPosition(code: code, name: name, units: units, bookCost: gross + fee))
            }
        } else {
            guard let positionIndex, updated.positions[positionIndex].units >= units else { throw NextError.invalid("卖出份额超过真实账本持有份额") }
            let oldUnits = updated.positions[positionIndex].units
            let cost = updated.positions[positionIndex].bookCost * Decimal(units) / Decimal(oldUnits)
            realized = gross - fee - cost
            updated.positions[positionIndex].units -= units
            updated.positions[positionIndex].bookCost -= cost
            if updated.positions[positionIndex].units == 0 { updated.positions.remove(at: positionIndex) }
            updated.cash += gross - fee
        }
        updated.fills.append(NextFill(date: Date(), code: code, side: side, units: units, price: price, fee: fee, realized: realized))
        try commitRealLedger(updated, action: side == "buy" ? "记录成交买入" : "记录成交卖出", reason: "用户核对成交；本笔手续费 ¥\(NextMoney.text(fee))")
    }
    func adjustRealCash(_ amount: Decimal, reason: String) throws {
        guard !amount.isNaN, amount != 0, book.cash + amount >= 0 else { throw NextError.invalid("变更金额无效或会导致现金为负") }
        var updated = book
        updated.cash += amount
        updated.cashMovements.append(NextCashMovement(date: Date(), amount: amount, reason: reason))
        try commitRealLedger(updated, action: amount > 0 ? "现金转入" : "现金转出", reason: reason)
    }
    func undoLatestLedgerChange() throws {
        guard let id = ledger.events.last?.id else { throw NextError.invalid("没有可撤销的账本变更") }
        var copy = ledger
        try copy.undo(id, at: Date())
        ledger = copy
    }
    func saveGoal(years: Int, monthlyBudget: Decimal, concentration: Decimal) throws {
        var updated = goal; updated.years = years; updated.monthlyBudget = monthlyBudget; updated.concentrationLimit = concentration
        try updated.validate(); preferences.goal = updated
    }
    func addWatch(_ code: String) throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), !watch.contains(code) else { throw NextError.invalid("请输入有效且尚未关注的 6 位证券代码") }
        preferences.watch.insert(code, at: 0)
        if !preferences.nasBaseURL.isEmpty { Task { await registerNASArchive(code) } }
    }
    func removeWatch(_ code: String) { preferences.watch.removeAll { $0 == code } }
    func openInstrumentIntent(_ code: String) {
        preferences.navigation.selectedSecurity = code
        preferences.navigation.routes = [.intent("buy-opportunity", code)]
        preferences.navigation.selectedTab = .decision
        preferences = preferences
        requestedTab = .decision
        requestedRoute = .decision(code)
        routeRequestID = UUID()
    }
    func saveTheme(_ theme: GPTheme) { preferences.theme = theme }
    func refreshNotificationStatus() async { notificationStatus = await NextLocalNotificationService.authorizationStatus() }
    func requestNotificationPermission() async { notificationStatus = await NextLocalNotificationService.requestAuthorization() }
    func postLocalAlert(level: String, fingerprint: String, title: String, detail: String, stamp: NextDataStamp) {
        var center = preferences.notifications
        let quiet = center.quietHours.isQuiet(Date())
        let alert = NextAlert(fingerprint: fingerprint, level: level, title: title, detail: detail, createdAt: Date(), stamp: stamp,
                              delivery: quiet ? "静默记录" : "待本机投递")
        guard center.append(alert, now: Date()) else { return }
        preferences.notifications = center; preferences = preferences
        guard !quiet else { return }
        Task {
            let delivery = await NextLocalNotificationService.deliver(id: alert.id, title: title, detail: detail)
            guard let index = preferences.notifications.alerts.firstIndex(where: { $0.id == alert.id }) else { return }
            preferences.notifications.alerts[index].delivery = delivery
            preferences = preferences
        }
    }
    func addPriceAlert(code: String, price: Decimal, direction: NextPriceAlertDirection) throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), !preferences.notifications.priceRules.contains(where: { $0.code == code && $0.price == price && $0.direction == direction }) else {
            throw NextError.invalid("价格提醒代码无效或已存在")
        }
        let rule = NextPriceAlertRule(code: code, name: quotes[code]?.quote.name ?? code, price: price, direction: direction)
        try rule.validate()
        preferences.notifications.priceRules.append(rule); preferences = preferences
    }
    func removePriceAlert(_ id: UUID) { preferences.notifications.priceRules.removeAll { $0.id == id }; preferences = preferences }
    private func evaluatePriceAlerts(_ values: [NextQuote]) {
        var rules = preferences.notifications.priceRules
        var triggered: [(NextPriceAlertRule, NextQuote)] = []
        for quote in values where quote.isFresh(at: Date()) {
            for index in rules.indices where rules[index].enabled && rules[index].code == quote.code {
                let match = rules[index].direction == .atOrAbove ? quote.price >= rules[index].price : quote.price <= rules[index].price
                if match && !rules[index].isInsideTrigger { triggered.append((rules[index], quote)) }
                rules[index].isInsideTrigger = match
            }
        }
        preferences.notifications.priceRules = rules; preferences = preferences
        for (rule, quote) in triggered {
            let relation = rule.direction == .atOrAbove ? "达到或高于" : "达到或低于"
            postLocalAlert(level: "价格", fingerprint: "price-rule-\(rule.id.uuidString)", title: "\(rule.name) 价格提醒", detail: "最新价 ¥\(NextMoney.text(quote.price, digits: 4))，已\(relation)你设置的 ¥\(NextMoney.text(rule.price, digits: 4))。", stamp: NextDataStamp(source: quote.source, observedAt: quote.time, quality: .live, detail: "价格规则触发"))
        }
    }
    func configureNAS(baseURL: String) throws {
        let normalized = try NextNASService.validateURL(baseURL).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if preferences.nasBaseURL != normalized { preferences.nasRevision = nil }
        preferences.nasBaseURL = normalized; preferences = preferences
        syncStatus = "NAS 地址已保存；请测试连接"
    }
    func probeNAS() async {
        do {
            let remote = try await NextNASService.readStatus(baseURL: preferences.nasBaseURL)
            syncStatus = "NAS 可连接 · 修订 \(remote.revision) · \(remote.hasBook ? "已有数据，可下载" : "空账本")"
        } catch {
            syncStatus = "NAS 离线或读取失败 · \(error.localizedDescription)"
            postLocalAlert(level: "NAS", fingerprint: "nas-connectivity", title: "NAS 连接不可用", detail: "\(error.localizedDescription)。本机账本和缓存仍可使用。", stamp: NextDataStamp(source: "NAS 连通性检查", observedAt: Date(), quality: .stale, detail: "用户触发检查"))
        }
    }
    func downloadBookManually() async {
        do {
            let remote = try await NextNASService.readStatus(baseURL: preferences.nasBaseURL)
            guard let incoming = remote.book else { throw NextError.invalid("NAS 上还没有可下载的新账本") }
            guard repository.integrityWarning == nil else { throw NextError.invalid("本机数据完整性待恢复；下载已停止") }
            try repository.writeSafetyCopy(try makeBackup())
            try commitRealLedger(incoming, action: "从 NAS 下载真实账本", reason: "用户确认下载 NAS 修订 \(remote.revision)；原账本已备份")
            preferences.nasRevision = remote.revision; preferences = preferences
            syncStatus = "已从 NAS 下载账本 · 修订 \(remote.revision)"
        } catch { syncStatus = "下载停止 · \(error.localizedDescription)" }
    }
    func syncBookManually() async {
        do {
            let remote = try await NextNASService.readStatus(baseURL: preferences.nasBaseURL)
            if let knownRevision = preferences.nasRevision {
                guard remote.revision == knownRevision else { throw NextError.invalid("NAS 修订已变化；请先下载核对") }
            } else {
                guard remote.revision == 0 && !remote.hasBook else { throw NextError.invalid("NAS 已有未关联账本；请先下载核对") }
            }
            let revision = try await NextNASService.pushBook(book, expectedRevision: remote.revision, baseURL: preferences.nasBaseURL)
            preferences.nasRevision = revision; preferences = preferences
            syncStatus = "用户确认上传完成 · 修订 \(revision)"
        } catch { syncStatus = "上传停止 · \(error.localizedDescription)" }
    }
    func chartState(for code: String) -> NextChartState { preferences.navigation.chartStates[code] ?? NextChartState() }
    func saveChartState(_ state: NextChartState, for code: String) {
        preferences.navigation.chartStates[code] = state
        preferences.navigation.selectedSecurity = code
        preferences = preferences
    }
    func saveNavigationPath(_ routes: [NextRoute], for tab: NextTab) {
        preferences.navigation.tabRoutes[tab.rawValue] = routes
        preferences.navigation.routes = routes
        preferences = preferences
    }
    func createSimulatedOrder(code: String, price: Decimal, units: Int, expiry: Date) throws {
        guard let rules = rules[code], rules.isVerified, rules.lotSize != nil else { throw NextError.invalid("尚未取得这只证券经核实的交易规则，不能创建模拟委托") }
        guard units % (rules.lotSize ?? 1) == 0 else { throw NextError.invalid("数量不符合该证券经核实的交易单位") }
        try experiment.place(code: code, limit: price, units: units, rules: rules, at: Date(), until: expiry)
    }
    func addTwinFunding(_ amount: Decimal, reason: String) throws { try twins.fundAll(amount, reason: reason, at: Date()) }
    func recordDecision(_ decision: NextDecision) {
        decisions.removeAll { $0.id == decision.id }
        decisions.insert(decision, at: 0)
        if decisions.count > 1000 { decisions.removeLast(decisions.count - 1000) }
    }
    func chooseDecision(_ decisionID: UUID, optionID: String) throws {
        guard let index = decisions.firstIndex(where: { $0.id == decisionID }), decisions[index].options.contains(where: { $0.id == optionID }) else {
            throw NextError.invalid("决策或方案已不存在；没有保存选择")
        }
        decisions[index].selectedOption = optionID
        decisions[index].status = "已记录选择"
    }
    func reviewDecision(_ decisionID: UUID, note: String) throws {
        guard let index = decisions.firstIndex(where: { $0.id == decisionID }), !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NextError.invalid("请选择一条决策并填写复盘记录")
        }
        decisions[index].review = note
        decisions[index].status = "已复盘"
    }
    func acceptQuote(_ quote: NextCachedQuote) throws {
        try validateQuote(quote)
        quotes[quote.quote.code] = quote
    }
    private func validateQuote(_ quote: NextCachedQuote) throws {
        guard quote.quote.price > 0, quote.quote.previousClose > 0, quote.quote.iopv.map({ $0 > 0 && quote.quote.providerInstrumentType == "ETF" }) ?? true,
              quote.quote.time <= Date(), quote.quote.code == quote.quote.id, !quote.quote.source.isEmpty else { throw NextError.invalid("行情时间、价格、IOPV 或来源校验失败") }
    }
    func refreshQuotes(codes: [String]) async {
        let unique = Array(Set(codes)).sorted()
        guard !unique.isEmpty else { status = "先添加自选或持仓证券"; return }
        status = "正在核验行情…"
        do {
            var sourceNote = ""
            let fetched: [NextQuote]
            if !preferences.nasBaseURL.isEmpty {
                do { fetched = try await NextNASService.fetchQuotes(codes: unique, baseURL: preferences.nasBaseURL); sourceNote = "NAS 代理" }
                catch { fetched = try await NextMarketDataService.fetchQuotes(codes: unique); sourceNote = "NAS 离线，已直连" }
            } else {
                fetched = try await NextMarketDataService.fetchQuotes(codes: unique)
                sourceNote = "Tencent 直连"
            }
            var updated = quotes
            for quote in fetched {
                let quality: NextDataQuality = quote.isFresh(at: Date()) ? .live : .delayed
                let cached = NextCachedQuote(quote: quote, stamp: NextDataStamp(source: quote.source, observedAt: quote.time, quality: quality, detail: "按行情源时间标记；未补造 IOPV"))
                try validateQuote(cached)
                updated[quote.code] = cached
            }
            quotes = updated
            evaluatePriceAlerts(fetched)
            status = "行情已更新 · \(sourceNote) · \(fetched.count)/\(unique.count) · \(Date.now.formatted(date: .omitted, time: .shortened))"
        } catch {
            status = "行情连接失败 · 显示本地缓存"
            errorMessage = "\(error.localizedDescription)。本地账本和历史缓存仍可查看。"
            postLocalAlert(level: "行情", fingerprint: "market-refresh-unavailable", title: "行情刷新失败", detail: "\(error.localizedDescription)。当前显示本机缓存，不据此生成新的价格计划。", stamp: NextDataStamp(source: "行情刷新", observedAt: Date(), quality: .stale, detail: "请求失败"))
        }
    }
    func refreshInstrument(_ code: String) async {
        await registerNASArchive(code)
        await refreshQuotes(codes: [code])
        await refreshDaily(code)
        do {
            let raw = try await NextMarketDataService.fetchIntraday(code: code)
            let dataset = quotes[code].map { raw.attachingVerifiedIOPV($0.quote) } ?? raw
            try dataset.validate()
            chartData[code] = dataset
            status = "行情与分时已更新 · \(dataset.samples.count) 点 · \(dataset.observedAt.formatted(date: .omitted, time: .shortened))"
        } catch {
            if !preferences.nasBaseURL.isEmpty {
                await loadNASMinute(code: code, day: Date())
            } else {
                status = "报价缓存可用 · 分时历史暂不可用"
                errorMessage = "\(error.localizedDescription)。不会用报价点补造历史曲线或 IOPV。"
            }
        }
    }
    func refreshNASResearch(_ code: String) async {
        guard !preferences.nasBaseURL.isEmpty else { return }
        do { nasResearch[code] = try await NextNASService.fetchResearch(code: code, baseURL: preferences.nasBaseURL) }
        catch { if nasResearch[code] == nil { errorMessage = "NAS 研究暂不可用：\(error.localizedDescription)" } }
    }
    func registerNASArchive(_ code: String) async {
        guard !preferences.nasBaseURL.isEmpty else { return }
        do { try await NextNASService.trackInstrument(code: code, baseURL: preferences.nasBaseURL) }
        catch { status = "NAS 后台归档登记失败 · 本机行情和缓存仍可用" }
    }
    func loadNASMinute(code: String, day: Date) async {
        guard !preferences.nasBaseURL.isEmpty else { errorMessage = "先连接 NAS 才能读取归档日期"; return }
        do {
            let dataset = try await NextNASService.fetchMinute(code: code, day: day, baseURL: preferences.nasBaseURL)
            chartData[code] = dataset
            status = "已载入 NAS 分时档案 · \(dataset.priceSource) · \(dataset.samples.count) 点"
        } catch { errorMessage = error.localizedDescription }
    }
    func refreshDaily(_ code: String) async {
        guard !preferences.nasBaseURL.isEmpty else { return }
        do {
            let dataset = try await NextNASService.fetchDaily(code: code, baseURL: preferences.nasBaseURL)
            chartData["\(code):day"] = dataset
        } catch {
            if chartData["\(code):day"] == nil { errorMessage = "日 K 暂不可用：\(error.localizedDescription)" }
        }
    }
    func acceptOrderBook(_ snapshot: NextOrderBookSnapshot, marketOpen: Bool) throws {
        try snapshot.validate()
        orderBooks[snapshot.code] = snapshot
        guard let rule = rules[snapshot.code] else { return }
        try experiment.observe(snapshot, rules: rule, now: Date(), marketOpen: marketOpen)
    }
    func makeBackup() throws -> NextArchiveEnvelope {
        guard repository.integrityWarning == nil else { throw NextError.invalid("本机数据完整性待恢复；为避免导出不完整账本，备份导出已停止") }
        return try NextArchiveEnvelope(archive: makeArchive())
    }
    func restoreBackup(_ envelope: NextArchiveEnvelope) throws {
        var incoming = try envelope.archive()
        let event = NextAuditEvent(at: Date(), action: "恢复已校验备份", reason: "用户确认恢复；恢复前状态另存安全副本", before: book, after: incoming.book)
        incoming.audits.append(event)
        if repository.integrityWarning == nil { try repository.writeSafetyCopy(try makeBackup()) }
        else { try repository.writeRawSafetyCopy() }
        try repository.replaceAll(with: incoming)
        ledger = NextAuditedBook(current: incoming.book, events: incoming.audits)
        experiment = incoming.experiment
        twins = incoming.twins
        preferences = LocalPreferences(goal: incoming.goal, watch: incoming.watch, navigation: incoming.navigation, theme: GPTheme(rawValue: incoming.theme.rawValue) ?? .system, notifications: incoming.notifications, nasBaseURL: preferences.nasBaseURL, nasRevision: nil)
        quotes = incoming.cachedQuotes; chartData = incoming.chartData; rules = incoming.instrumentRules; orderBooks = incoming.orderBooks
        decisions = incoming.decisionHistory
        nasResearch = incoming.nasResearch
    }
    func research(for code: String?) -> NextDecision? {
        do {
            var decision = try NextResearch.prepare(book: book, goal: goal, quotes: Dictionary(uniqueKeysWithValues: quotes.map { ($0.key, $0.value.quote) }), now: Date())
            if let code {
                decision.title = "围绕 \(quotes[code]?.quote.name ?? code) 的买入机会"
                let item: NextEvidence
                if let cached = quotes[code], cached.usableForDisplay(at: Date()) {
                    let quote = cached.quote
                    let quality = quote.isFresh(at: Date()) ? "有效报价" : cached.stamp.label(now: Date())
                    item = NextEvidence(id: "security-\(code)", title: "证券行情", detail: "\(quote.name) 最新价 ¥\(NextMoney.text(quote.price, digits: 4))；\(quality)；\(quote.source)；源时间 \(quote.time.formatted(date: .numeric, time: .shortened))。", level: quote.isFresh(at: Date()) ? "事实" : "过期数据", observedAt: quote.time)
                } else {
                    item = NextEvidence(id: "security-\(code)", title: "证券行情待补", detail: "\(code) 当前没有可显示的本机报价缓存；需要刷新后再判断。", level: "缺口", observedAt: Date())
                }
                decision.evidence.append(item)
            }
            return decision
        }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    private func reportSave(_ failure: String?) {
        if let failure { errorMessage = "本机保存失败：\(failure)。请先确认数据安全后再继续修改。" }
    }
    private func makeArchive() -> NextAppArchive {
        var archive = NextAppArchive()
        archive.book = book; archive.experiment = experiment; archive.twins = twins
        archive.goal = goal; archive.watch = watch; archive.navigation = preferences.navigation
        archive.cachedQuotes = quotes; archive.chartData = chartData; archive.instrumentRules = rules; archive.orderBooks = orderBooks
        archive.notifications = preferences.notifications; archive.audits = ledger.events
        archive.decisionHistory = decisions
        archive.nasResearch = nasResearch
        archive.theme = NextTheme(rawValue: theme.rawValue) ?? .system
        return archive
    }
}
