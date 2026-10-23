import Foundation
import SwiftUI

struct LocalPreferences: Codable {
    var goal = NextGoal()
    var watch = ["159941", "563020", "159545", "159352"]
    var navigation = NextNavigationState()
    var theme = GPTheme.light
    /// 字号档位 / 字体族 / 自定义文字·卡片·背景色。
    var appearance = GPAppearance()
    var notifications = NextNotificationCenter()
    var nasBaseURL = ""
    var legacyWebBaseURL = ""
    var nasRevision: Int?
    /// 上次成功上传到 NAS 时本机账本的指纹；和当前账本不一致就说明「有改动没上传」。
    var nasSyncedFingerprint: String?
    /// 上次成功上传的时间，用来在界面上说清"到底什么时候同步过"。
    var nasSyncedAt: Date?
    /// 自动上传本机账本（默认开）。关掉后只保留手动上传。
    var nasAutoUpload = true
    enum CodingKeys: String, CodingKey { case goal, watch, navigation, theme, appearance, notifications, nasBaseURL, legacyWebBaseURL, nasRevision, nasSyncedFingerprint, nasSyncedAt, nasAutoUpload }
    init(goal: NextGoal = NextGoal(), watch: [String] = ["159941", "563020", "159545", "159352"], navigation: NextNavigationState = NextNavigationState(), theme: GPTheme = .light, appearance: GPAppearance = GPAppearance(), notifications: NextNotificationCenter = NextNotificationCenter(), nasBaseURL: String = "", legacyWebBaseURL: String = "", nasRevision: Int? = nil, nasSyncedFingerprint: String? = nil, nasSyncedAt: Date? = nil, nasAutoUpload: Bool = true) {
        self.goal = goal; self.watch = watch; self.navigation = navigation; self.theme = theme; self.appearance = appearance; self.notifications = notifications
        self.nasBaseURL = nasBaseURL; self.legacyWebBaseURL = legacyWebBaseURL; self.nasRevision = nasRevision
        self.nasSyncedFingerprint = nasSyncedFingerprint; self.nasSyncedAt = nasSyncedAt; self.nasAutoUpload = nasAutoUpload
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        goal = try values.decodeIfPresent(NextGoal.self, forKey: .goal) ?? NextGoal()
        watch = try values.decodeIfPresent([String].self, forKey: .watch) ?? ["159941", "563020", "159545", "159352"]
        navigation = try values.decodeIfPresent(NextNavigationState.self, forKey: .navigation) ?? NextNavigationState()
        theme = try values.decodeIfPresent(GPTheme.self, forKey: .theme) ?? .light
        appearance = try values.decodeIfPresent(GPAppearance.self, forKey: .appearance) ?? GPAppearance()
        notifications = try values.decodeIfPresent(NextNotificationCenter.self, forKey: .notifications) ?? NextNotificationCenter()
        nasBaseURL = try values.decodeIfPresent(String.self, forKey: .nasBaseURL) ?? ""
        legacyWebBaseURL = try values.decodeIfPresent(String.self, forKey: .legacyWebBaseURL) ?? ""
        nasRevision = try values.decodeIfPresent(Int.self, forKey: .nasRevision)
        nasSyncedFingerprint = try values.decodeIfPresent(String.self, forKey: .nasSyncedFingerprint)
        nasSyncedAt = try values.decodeIfPresent(Date.self, forKey: .nasSyncedAt)
        nasAutoUpload = try values.decodeIfPresent(Bool.self, forKey: .nasAutoUpload) ?? true
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
            ("preferences-v1.json", try encoder.encode(LocalPreferences(goal: archive.goal, watch: archive.watch, navigation: archive.navigation, theme: GPTheme(rawValue: archive.theme.rawValue) ?? .light, notifications: archive.notifications))),
            ("cached-quotes-v1.json", try encoder.encode(archive.cachedQuotes)),
            ("chart-history-v1.json", try encoder.encode(archive.chartData)),
            ("instrument-rules-v1.json", try encoder.encode(archive.instrumentRules)),
            ("order-books-v1.json", try encoder.encode(archive.orderBooks)),
            ("decision-history-v1.json", try encoder.encode(archive.decisionHistory)),
            ("nas-research-v1.json", try encoder.encode(archive.nasResearch)),
            ("dividend-history-v1.json", try encoder.encode(archive.dividendEvents)),
            ("patient-limit-plans-v1.json", try encoder.encode(archive.patientLimitPlans)),
            ("twin-backtests-v1.json", try encoder.encode(archive.twinBacktests))
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
    @Published var researchStatus: [String: String] = [:]
    @Published var dividendEvents: [String: [NextETFDividendEvent]] { didSet { reportSave(repository.save(dividendEvents, filename: "dividend-history-v1.json")) } }
    @Published var patientLimitPlans: [NextPatientLimitPlan] { didSet { reportSave(repository.save(patientLimitPlans, filename: "patient-limit-plans-v1.json")) } }
    /// 动态投资者画像：只由真实持仓、真实成交与真实反馈学习，不使用任何模拟交易。
    @Published var profile: InvestorProfile { didSet { reportSave(repository.save(profile, filename: "investor-profile-v1.json")) } }
    @Published var twinBacktests: [String: NextTwinBacktest] { didSet { reportSave(repository.save(twinBacktests, filename: "twin-backtests-v1.json")) } }
    @Published var backtestStatus = "尚无本机策略回测"
    @Published var nasGAccount: NextNASGAccount?
    @Published var nasGRevision: Int?
    @Published var nasGStatus = "尚未读取 NAS G 模拟账户"
    @Published var gridStatus: NextNASGridStatus?
    @Published var gridStatusMessage = "尚未读取 NAS 网格状态"
    @Published var status = "行情尚未刷新 · 缓存可离线查看"
    @Published var syncStatus = "NAS 未连接"
    @Published var aiProviderStatus: NextAIProviderStatus?
    @Published var legacyImportPreview: NextLegacyBookPreview?
    @Published var dailyErrors: [String: String] = [:]
    @Published var notificationStatus = "尚未检查系统通知权限"
    @Published var errorMessage: String?
    @Published var showSearch = false
    @Published var searchText = ""
    @Published var notice = ""
    @Published var requestedTab: NextTab?
    @Published var requestedRoute: GPRoute?
    @Published var routeRequestID = UUID()
    private let repository: NextLocalRepository
    /// 合并自动上传用的延迟任务；连点几次"录入"只发一次。
    private var autoUploadTask: Task<Void, Never>?

    var book: NextBook { ledger.current }
    var goal: NextGoal { preferences.goal }
    var watch: [String] { preferences.watch }
    var monitoredCodes: [String] {
        Array(Set(watch + book.positions.map(\.code) + preferences.notifications.priceRules.filter(\.enabled).map(\.code)
                  + patientLimitPlans.filter { $0.state == "等待价格提醒" }.map(\.code))).sorted()
    }
    var theme: GPTheme { preferences.theme }

    /// 模拟/回测用的标的池：**有真实持仓就用持仓**（按份额从大到小），没有才退回自选。
    /// 以前一律用自选，等于让策略去跑一堆自己没买的标的。
    var simulationUniverse: [String] {
        let held = book.positions.filter { $0.units > 0 }.sorted { $0.units > $1.units }.map(\.code)
        return held.isEmpty ? watch : held
    }

    /// 真实账本口径的总资产 = 现金 + 持仓市值（缺报价的按成本兜底，并保证不漏算）。
    var realBookEquity: Decimal {
        var total = book.cash
        for position in book.positions where position.units > 0 {
            if let quote = quotes[position.code]?.quote, quote.price > 0 {
                total += quote.price * Decimal(position.units)
            } else {
                total += position.bookCost
            }
        }
        return total
    }

    /// 把真实账本的当前状态复制成 A–H 的起点：同样的份额、同样的成本、同样的现金。
    /// 只填充**还空着**的账户（没有订单也没有持仓），不会覆盖已经在跑的模拟。
    @discardableResult
    func seedTwinsFromRealBook() -> String {
        let holdings = book.positions.filter { $0.units > 0 }
        guard !holdings.isEmpty else { return "真实账本还没有持仓，先录入再复制为模拟起点" }
        var next = twins
        var seeded = 0
        let source = "真实账本 · \(holdings.count) 只持仓 + 现金 ¥\(NextMoney.text(book.cash))"
        for strategy in NextTwinStrategy.allCases {
            guard var account = next.accounts[strategy.rawValue] else { continue }
            guard account.simulation.orders.isEmpty, account.simulation.positions.isEmpty else { continue }
            account.simulation.positions = holdings
            account.simulation.cash = book.cash
            account.seedSource = source
            next.accounts[strategy.rawValue] = account
            seeded += 1
        }
        guard seeded > 0 else { return "A–H 都已有模拟记录，未覆盖；要重新开始请在对应策略里先清空" }
        twins = next
        return "已把 \(holdings.count) 只持仓 + 现金 ¥\(NextMoney.text(book.cash)) 复制为 \(seeded) 个策略的起点"
    }

    /// 名称解析统一入口：账本里存的名称 > 报价里的 > 名称簿（跨启动）> 内置目录 > 代码本身。
    /// 以前界面上到处是裸代码或"场内证券"，就是因为每个地方各自取一次、取不到就没人兜底。
    func name(for code: String) -> String {
        let stored = book.positions.first(where: { $0.code == code })?.name
        if let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty, stored != code { return stored }
        if let quoted = quotes[code]?.quote.name, !quoted.isEmpty, quoted != code { return quoted }
        return NextNameBook.resolve(code)
    }

    /// 把账本/自选/提醒里出现过、但还不知道名字的代码补齐。
    /// 只读一次行情并把名称记进名称簿，**不改账本字段**，所以不会产生审计噪音。
    func backfillNamesIfNeeded() async {
        let codes = Set(book.positions.map(\.code) + watch + book.fills.map(\.code)
                        + preferences.notifications.priceRules.map(\.code) + book.dividendEvents.map(\.code))
        let missing = codes.filter { code in
            let stored = book.positions.first(where: { $0.code == code })?.name ?? ""
            guard stored.isEmpty || stored == code else { return false }
            let quoted = quotes[code]?.quote.name ?? ""
            guard quoted.isEmpty || quoted == code else { return false }
            return !NextNameBook.isResolved(code)
        }
        guard !missing.isEmpty else { return }
        await refreshQuotes(codes: missing.sorted())
    }
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
        self.dividendEvents = repository.load([String: [NextETFDividendEvent]].self, filename: "dividend-history-v1.json", fallback: [:])
        self.patientLimitPlans = repository.load([NextPatientLimitPlan].self, filename: "patient-limit-plans-v1.json", fallback: [])
        self.twinBacktests = repository.load([String: NextTwinBacktest].self, filename: "twin-backtests-v1.json", fallback: [:])
        self.profile = repository.load(InvestorProfile.self, filename: "investor-profile-v1.json", fallback: InvestorProfile.empty())
        self.errorMessage = repository.integrityWarning
        // 启动时用真实持仓与真实成交刷新一次画像（内部有最小样本量门槛，样本不足不会硬推结论）。
        refreshProfile()
        // 启动时把「只有代码、没有名字」的标的补一次：账本里的旧数据、旧自选都能认出来。
        Task { await backfillNamesIfNeeded() }
    }
    // MARK: - 动态投资者画像（只用真实持仓 / 真实成交 / 真实反馈）

    /// 用真实持仓 + 真实成交 + 真实反馈刷新画像。样本不足的维度只记为短期状态，不会硬推结论。
    func refreshProfile() {
        var updated = profile
        InvestorProfileEngine.learn(profile: &updated,
                                    book: book,
                                    quotes: quotes.mapValues { $0.quote },
                                    goal: goal,
                                    plans: patientLimitPlans,
                                    now: Date())
        InvestorProfileEngine.updateTSessionPreference(&updated.tsession, profile: updated)
        InvestorProfileEngine.updateGridPreference(&updated.grid, profile: updated)
        profile = updated
    }

    /// 记录一次 AI 建议的用户反应。画像学习的真实素材之一（另一部分是成交流水）。
    func recordObservation(kind: String, code: String, proposedNetProfit: Decimal?,
                           proposedSpreadPercent: Double?, outcome: String,
                           feedback: ProfileFeedback?, reallyExecuted: Bool) {
        var updated = profile
        updated.observations.append(ProfileObservation(at: Date(), kind: kind, code: code,
                                                       proposedNetProfit: proposedNetProfit,
                                                       proposedSpreadPercent: proposedSpreadPercent,
                                                       outcome: outcome,
                                                       feedback: feedback?.rawValue,
                                                       reallyExecuted: reallyExecuted))
        if updated.observations.count > 500 { updated.observations = Array(updated.observations.suffix(500)) }
        profile = updated
        refreshProfile()
    }

    /// 用户在建议卡上点了一键反馈（不是问卷）。
    func recordFeedback(_ feedback: ProfileFeedback, kind: String, code: String,
                        proposedNetProfit: Decimal? = nil, proposedSpreadPercent: Double? = nil) {
        let isPositive = feedback == .suitsMe
        recordObservation(kind: kind, code: code, proposedNetProfit: proposedNetProfit,
                          proposedSpreadPercent: proposedSpreadPercent,
                          outcome: isPositive ? "accepted" : "ignored",
                          feedback: feedback, reallyExecuted: isPositive)
        notice = "已记录：\(feedback.title)。\(feedback.implication)"
    }

    /// 用户手动修改画像属性 → 变为 explicit 并锁定，AI 不得再改。
    func setProfileFact(_ key: String, value: String, locked: Bool = true) {
        var updated = profile
        guard var fact = updated.facts[key] else { return }
        fact.value = value
        fact.source = .explicit
        fact.locked = locked
        fact.confidence = 1.0
        fact.updatedAt = Date()
        fact.reason = "你在「AI 对我的了解」中手动设置；AI 不会自行修改。"
        updated.facts[key] = fact
        profile = updated
    }

    /// 用户标记「这个判断不准确」→ 清空该维度并重新学习。
    func resetProfileFact(_ key: String) {
        var updated = profile
        guard let existing = updated.facts[key] else { return }
        updated.facts[key] = ProfileFact(key: key, title: existing.title, value: "已重置，重新学习中",
                                         confidence: 0, source: .learned, sampleSize: 0, updatedAt: Date(),
                                         locked: false,
                                         reason: "你标记该判断不准确，已清除原有结论，将按之后的真实行为重新积累。",
                                         evidence: [])
        let kind: String? = key == "tsession" ? "tsession" : (key == "grid" ? "grid" : nil)
        if let kind { updated.observations.removeAll { $0.kind == kind } }
        profile = updated
        refreshProfile()
        notice = "已重置「\(existing.title)」，AI 会按你之后的真实行为重新学习。"
    }

    /// 设置资产角色（长期核心仓 / 行业机动仓）。用户设置 = explicit，AI 不得改回。
    func setAssetRole(code: String, role: String) {
        var updated = profile
        updated.assetRoles[code] = AssetRole(
            code: code, role: role, source: .explicit, updatedAt: Date(),
            note: role == "core"
                ? "你指定为长期核心仓：允许较大波动、不轻易卖出，主要靠新增资金调整，不因短期技术信号改变长期计划。"
                : "你指定为行业机动仓：可做T、可网格、可主动降本，可按趋势与行业变化减仓。")
        profile = updated
        notice = role == "core"
            ? "已将 \(name(for: code)) 设为长期核心仓；AI 不会再把它当机动交易仓位。"
            : "已将 \(name(for: code)) 设为行业机动仓。"
    }

    func commitRealLedger(_ updated: NextBook, action: String, reason: String) throws {
        try updated.validate()
        var copy = ledger
        try copy.apply(updated, action: action, reason: reason, at: Date())
        ledger = copy
        scheduleAutoUpload()
    }
    /// 录入持仓。`acquiredAt` 是建仓日：只把建仓日及之后的派息算作你的，之前发生的除息不算
    /// （你刚录入一只已经持有很久、且早已分红过的票时，不会凭空冒出历史分红待确认）。不传则按录入当天处理。
    func addPosition(code: String, name: String, units: Int, cost: Decimal, acquiredAt: Date? = nil) throws {
        guard !book.positions.contains(where: { $0.code == code }), units > 0, cost > 0 else { throw NextError.invalid("代码、份额或持仓成本无效，或该证券已经存在") }
        var updated = book
        updated.positions.append(NextPosition(code: code, name: name, units: units, bookCost: cost, acquiredAt: acquiredAt ?? Date()))
        NextNameBook.remember(name, code: code)
        try commitRealLedger(updated, action: "录入场内持仓", reason: "用户确认保存")
        if !preferences.nasBaseURL.isEmpty { Task { await registerNASArchive(code) } }
    }
    /// 删除一条持仓。走的是同一条审计通道，可在「资产流水 → 撤销」里回退。
    func deletePosition(_ code: String) throws {
        guard book.positions.contains(where: { $0.code == code }) else { throw NextError.invalid("账本里没有这只持仓") }
        var updated = book
        updated.positions.removeAll { $0.code == code }
        try commitRealLedger(updated, action: "删除场内持仓", reason: "用户确认删除 \(code)")
    }

    /// 一键清空所有持仓与成交流水。现金、现金流水、收息与分红记录保留，避免丢失股息追踪。
    /// 走审计通道，可在「资产流水 → 撤销」里回退。
    func clearHoldingsAndFills() throws {
        guard !book.positions.isEmpty || !book.fills.isEmpty else { throw NextError.invalid("账本里没有持仓或流水可清空") }
        var updated = book
        updated.positions.removeAll()
        updated.fills.removeAll()
        try commitRealLedger(updated, action: "清空持仓与流水", reason: "用户一键清空所有持仓与成交流水")
    }

    /// 删除一条成交流水，并按相反方向回滚它对**持仓与现金**的影响。
    /// 这是必要的：只删流水不回滚，账本就会出现「有持仓无买入记录」的假账，
    /// 摊薄成本和已实现盈亏都会跟着错。
    func deleteFill(_ id: UUID) throws {
        guard let fill = book.fills.first(where: { $0.id == id }) else { throw NextError.invalid("找不到这条流水") }
        var updated = book
        updated.fills.removeAll { $0.id == id }
        let gross = fill.price * Decimal(fill.units)
        let index = updated.positions.firstIndex { $0.code == fill.code }
        if fill.side == "buy" {
            // 回滚买入：现金加回，持仓减份数、减成本。
            updated.cash += gross + fill.fee
            guard let index else { throw NextError.invalid("这只持仓已不存在，无法回滚这笔买入") }
            let newUnits = updated.positions[index].units - fill.units
            guard newUnits >= 0 else { throw NextError.invalid("回滚后份额为负：这笔买入的份额已经卖出，请先删对应的卖出流水") }
            updated.positions[index].bookCost -= gross + fill.fee
            if updated.positions[index].bookCost < 0 { updated.positions[index].bookCost = 0 }
            updated.positions[index].units = newUnits
            if newUnits == 0 { updated.positions.remove(at: index) }
        } else {
            // 回滚卖出：现金扣回，持仓加回份数与当初结转的成本。
            guard updated.cash - (gross - fill.fee) >= 0 else { throw NextError.invalid("回滚后现金为负，请先补足现金再删这笔卖出") }
            updated.cash -= gross - fill.fee
            let restoredCost = max(0, gross - fill.fee - fill.realized)
            if let index {
                updated.positions[index].units += fill.units
                updated.positions[index].bookCost += restoredCost
            } else {
                updated.positions.append(NextPosition(code: fill.code, name: fill.code, units: fill.units, bookCost: restoredCost))
            }
        }
        try commitRealLedger(updated, action: "删除成交流水",
                             reason: "用户删除 \(fill.code) \(fill.side == "buy" ? "买入" : "卖出") \(fill.units) 份 · ¥\(NextMoney.text(fill.price))，已同步回滚持仓与现金")
    }

    /// 修正录入错误的份额或总成本。**不改现金、不虚构成交**，只订正账本里的持仓事实。
    func updatePosition(_ code: String, units: Int, totalCost: Decimal) throws {
        guard units > 0, totalCost > 0, !totalCost.isNaN else { throw NextError.invalid("份额与总成本必须大于 0") }
        guard let index = book.positions.firstIndex(where: { $0.code == code }) else { throw NextError.invalid("账本里没有这只持仓") }
        var updated = book
        let previous = updated.positions[index]
        updated.positions[index].units = units
        updated.positions[index].bookCost = totalCost
        try commitRealLedger(updated, action: "修正持仓份额与成本",
                             reason: "用户订正 \(code)：\(previous.units) 份 / ¥\(NextMoney.text(previous.bookCost)) → \(units) 份 / ¥\(NextMoney.text(totalCost))")
    }

    /// 现金变动统一入口：转入/转出都走这里，写账本并留审计。
    /// 买卖会自己联动现金，这个方法只用于「券商那边真的划了钱进/出」。
    func addCash(_ amount: Decimal, reason: String) throws {
        guard !amount.isNaN, amount != 0 else { throw NextError.invalid("现金变动金额不能为零") }
        let note = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw NextError.invalid("现金变动需要写明来源") }
        var updated = book
        guard updated.cash + amount >= 0 else { throw NextError.invalid("转出超过可用现金 ¥\(NextMoney.text(updated.cash))") }
        updated.cash += amount
        updated.cashMovements.append(NextCashMovement(date: Date(), amount: amount, reason: note))
        try commitRealLedger(updated, action: amount > 0 ? "记录现金转入" : "记录现金转出",
                             reason: "\(note)；金额 ¥\(NextMoney.text(abs(amount)))")
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
            guard updated.cash >= gross + fee else {
                let shortfall = gross + fee - updated.cash
                throw NextError.invalid("现金不足：本笔需要 ¥\(NextMoney.text(gross + fee))（含手续费 ¥\(NextMoney.text(fee))），可用 ¥\(NextMoney.text(updated.cash))，还差 ¥\(NextMoney.text(shortfall))。请点「先补充现金」记录一笔转入；若只是补录已有持仓，用「录入持仓」不会动现金。")
            }
            updated.cash -= gross + fee
            if let positionIndex {
                updated.positions[positionIndex].units += units
                updated.positions[positionIndex].bookCost += gross + fee
            } else {
                updated.positions.append(NextPosition(code: code, name: name, units: units, bookCost: gross + fee, acquiredAt: Date()))
            }
        } else {
            guard let positionIndex, updated.positions[positionIndex].units >= units else { throw NextError.invalid("卖出份额超过真实账本持有份额") }
            // T+1：今天买入的份额当天不能卖。券商显示「持仓 700 / 可用 400」就是这个意思。
            let available = updated.availableUnits(for: code, at: Date())
            guard units <= available else {
                let locked = updated.lockedUnits(for: code, at: Date())
                throw NextError.invalid("可卖份额不足：持有 \(updated.positions[positionIndex].units) 份，其中今天买入的 \(locked) 份要等下一个交易日才能卖，当前可卖 \(available) 份。")
            }
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
    func addIncomeEvent(_ event: NextIncomeEvent) throws {
        try event.validate()
        var updated = book
        updated.incomeEvents.append(event)
        try commitRealLedger(updated, action: "新增收益到账计划", reason: "\(event.kind.title) · \(event.name) · 预计净额 ¥\(NextMoney.text(event.netAmount))")
    }
    func receiveIncomeEvent(_ id: UUID) throws {
        guard var event = book.incomeEvents.first(where: { $0.id == id }), event.status == .expected else {
            throw NextError.invalid("这笔收息记录已处理，不能重复入账")
        }
        guard book.cash + event.netAmount >= 0 else { throw NextError.invalid("到账金额无效") }
        let now = Date()
        event.status = .received; event.receivedAt = now
        var updated = book
        guard let index = updated.incomeEvents.firstIndex(where: { $0.id == id }) else { throw NextError.invalid("找不到这笔收息计划") }
        updated.incomeEvents[index] = event
        updated.cash += event.netAmount
        if event.kind == .etfDistribution, let code = event.code, let perUnit = event.perUnit, perUnit > 0 {
            let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); dateFormatter.dateFormat = "yyyy-MM-dd"
            let dividend = NextETFDividendEvent(code: code, date: dateFormatter.string(from: event.exDate ?? now), amountPerShare: perUnit, isEstimated: false)
            updated.dividendEvents.removeAll { $0.id == dividend.id }
            updated.dividendEvents.append(dividend)
        }
        updated.cashMovements.append(NextCashMovement(date: now, amount: event.netAmount, reason: "\(event.kind.title)到账 · \(event.name)"))
        try commitRealLedger(updated, action: "确认收益到账", reason: "\(event.kind.title) · \(event.name) · 税前 ¥\(NextMoney.text(event.grossAmount)) · 税费 ¥\(NextMoney.text(event.tax)) · 净入账 ¥\(NextMoney.text(event.netAmount))")
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
    func saveGoal(years: Int, monthlyBudget: Decimal, concentration: Decimal, targetWeights: [String: Decimal] = [:], targetCashWeight: Decimal? = nil) throws {
        var updated = goal; updated.years = years; updated.monthlyBudget = monthlyBudget; updated.concentrationLimit = concentration; updated.targetWeights = targetWeights; updated.targetCashWeight = targetCashWeight
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
    func saveAppearance(_ appearance: GPAppearance) { preferences.appearance = appearance }
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
    func addPriceAlert(code: String, price: Decimal, direction: NextPriceAlertDirection,
                       metric: NextAlertMetric = .price) throws {
        let duplicated = preferences.notifications.priceRules.contains {
            $0.code == code && $0.price == price && $0.direction == direction && $0.resolvedMetric == metric
        }
        guard code.count == 6, code.allSatisfy(\.isNumber), !duplicated else {
            throw NextError.invalid("提醒代码无效，或相同条件的提醒已存在")
        }
        let rule = NextPriceAlertRule(code: code, name: name(for: code),
                                      price: price, direction: direction, metric: metric)
        try rule.validate()
        preferences.notifications.priceRules.append(rule); preferences = preferences
    }
    func createPatientLimitPlan(code: String, price: Decimal, units: Int, expiresAt: Date) throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), expiresAt > Date(), price > 0, units > 0,
              !patientLimitPlans.contains(where: { $0.code == code && $0.state == "等待价格提醒" && $0.limitPrice == price && $0.units == units }) else {
            throw NextError.invalid("限价计划代码、有效期、价格或份额无效，或相同计划已经存在")
        }
        var plan = NextPatientLimitPlan(id: UUID(), code: code, name: name(for: code),
                                        limitPrice: price, units: units, createdAt: Date(), expiresAt: expiresAt)
        try plan.validate()
        patientLimitPlans.insert(plan, at: 0)
        notice = "耐心限价计划已保存。它只是提醒和研究意图，不会占用现金、模拟成交或提交券商订单。"
    }
    func pausePatientLimitPlan(_ id: UUID) {
        guard let index = patientLimitPlans.firstIndex(where: { $0.id == id && $0.state == "等待价格提醒" }) else { return }
        patientLimitPlans[index].state = "已暂停"
    }
    func resumePatientLimitPlan(_ id: UUID) {
        guard let index = patientLimitPlans.firstIndex(where: { $0.id == id && $0.state == "已暂停" && $0.expiresAt > Date() }) else { return }
        patientLimitPlans[index].state = "等待价格提醒"
    }
    func cancelPatientLimitPlan(_ id: UUID) {
        guard let index = patientLimitPlans.firstIndex(where: { $0.id == id && ["等待价格提醒", "已暂停"].contains($0.state) }) else { return }
        patientLimitPlans[index].state = "已撤销"
    }
    private func evaluatePatientLimitPlans(_ values: [NextQuote], now: Date = Date()) {
        var triggered: [(NextPatientLimitPlan, NextQuote)] = []
        var expired: [NextPatientLimitPlan] = []
        for index in patientLimitPlans.indices where patientLimitPlans[index].state == "等待价格提醒" {
            if patientLimitPlans[index].expiresAt <= now {
                patientLimitPlans[index].state = "已过期"
                expired.append(patientLimitPlans[index])
                continue
            }
            guard let quote = values.first(where: { $0.code == patientLimitPlans[index].code }),
                  patientLimitPlans[index].shouldTrigger(with: quote, at: now) else { continue }
            patientLimitPlans[index].state = "价格已触发"
            patientLimitPlans[index].triggeredAt = now
            triggered.append((patientLimitPlans[index], quote))
        }
        for (plan, quote) in triggered {
            postLocalAlert(level: "限价计划", fingerprint: "patient-limit-\(plan.id.uuidString)", title: "\(plan.name) 达到你的观察价",
                           detail: "最新价 ¥\(NextMoney.text(quote.price, digits: 4))，目标 ¥\(NextMoney.text(plan.limitPrice, digits: 4))，计划数量 \(plan.units) 份。仅为提醒，未下单。",
                           stamp: NextDataStamp(source: quote.source, observedAt: quote.time, quality: .live, detail: "用户耐心限价计划触发"))
        }
        for plan in expired {
            postLocalAlert(level: "限价计划", fingerprint: "patient-limit-expired-\(plan.id.uuidString)", title: "\(plan.name) 观察计划已到期",
                           detail: "目标价 ¥\(NextMoney.text(plan.limitPrice, digits: 4))，计划 \(plan.units) 份。计划已停止，不会下单。",
                           stamp: NextDataStamp(source: "本机计划时钟", observedAt: now, quality: .live, detail: "耐心限价计划到期"))
        }
    }
    func removePriceAlert(_ id: UUID) { preferences.notifications.priceRules.removeAll { $0.id == id }; preferences = preferences }
    private func evaluatePriceAlerts(_ values: [NextQuote]) {
        var rules = preferences.notifications.priceRules
        var triggered: [(NextPriceAlertRule, NextQuote)] = []
        for quote in values where quote.isFresh(at: Date()) {
            for index in rules.indices where rules[index].enabled && rules[index].code == quote.code {
                guard let current = rules[index].value(for: quote) else { continue }
                let match = rules[index].direction == .atOrAbove ? current >= rules[index].price : current <= rules[index].price
                if match && !rules[index].isInsideTrigger { triggered.append((rules[index], quote)) }
                rules[index].isInsideTrigger = match
            }
        }
        preferences.notifications.priceRules = rules; preferences = preferences
        for (rule, quote) in triggered {
            let relation = rule.direction == .atOrAbove ? "达到或高于" : "达到或低于"
            let metric = rule.resolvedMetric
            let current = rule.value(for: quote) ?? quote.price
            let currentText = metric == .price ? "¥\(NextMoney.text(current, digits: 4))" : "\(NextNum.signed(NextNum.double(current)))%"
            let thresholdText = metric == .price ? "¥\(NextMoney.text(rule.price, digits: 4))" : "\(NextNum.signed(NextNum.double(rule.price)))%"
            let title = metric == .price ? "\(rule.name) 价格提醒" : "\(rule.name) \(metric.title)提醒"
            postLocalAlert(level: metric.title, fingerprint: "price-rule-\(rule.id.uuidString)", title: title,
                           detail: "当前\(metric.title) \(currentText)，已\(relation)你设置的 \(thresholdText)。",
                           stamp: NextDataStamp(source: quote.source, observedAt: quote.time, quality: .live, detail: "\(metric.title)规则触发"))
        }
    }
    func configureNAS(baseURL: String) throws {
        let normalized = try NextNASService.validateURL(baseURL).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if preferences.nasBaseURL != normalized { preferences.nasRevision = nil }
        preferences.nasBaseURL = normalized; preferences = preferences
        syncStatus = "NAS 地址已保存；请测试连接"
    }
    func configureLegacyWeb(baseURL: String) throws {
        let normalized = try NextNASService.validateLegacySourceURL(baseURL).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        preferences.legacyWebBaseURL = normalized; preferences = preferences
    }
    private func requireEmptyNativeLedger() throws {
        guard book.cash == 0, book.positions.isEmpty, book.fills.isEmpty, book.cashMovements.isEmpty,
              book.incomeEvents.isEmpty, book.dividendEvents.isEmpty, book.history.isEmpty else {
            throw NextError.invalid("本机真实账本已有资产或流水。旧账本迁移只允许初始化空账本，不会覆盖或合并现有真实数据。")
        }
    }
    func downloadLegacyWebToPhone() async {
        do {
            try requireEmptyNativeLedger()
            let destination = try await NextNASService.readStatus(baseURL: preferences.nasBaseURL)
            guard !destination.hasBook && destination.revision == 0 else { throw NextError.invalid("新版 NAS 已有真实账本；迁移只允许用于初始化，不会覆盖现有账本。") }
            guard repository.integrityWarning == nil else { throw NextError.invalid("本机数据完整性待恢复；迁移已停止") }
            let stagedRevision = try await NextNASService.downloadAndStageLegacyBook(legacyBaseURL: preferences.legacyWebBaseURL, newNASBaseURL: preferences.nasBaseURL)
            let preview = try await NextNASService.previewLegacyBook(baseURL: preferences.nasBaseURL)
            guard preview.revision == stagedRevision, let book = preview.book else { throw NextError.invalid("迁移暂存版本与预览不一致") }
            try book.validate()
            legacyImportPreview = preview
            syncStatus = "旧网页数据已下载并转换预览 · 暂存修订 \(preview.revision) · 尚未导入真实账本"
        } catch { legacyImportPreview = nil; syncStatus = "旧网页下载/转换失败 · \(error.localizedDescription)" }
    }
    func confirmLegacyWebImport() async {
        guard let preview = legacyImportPreview, let incoming = preview.book else { return }
        let originalBook = book
        let baseURL = preferences.nasBaseURL
        do {
            try requireEmptyNativeLedger()
            let latest = try await NextNASService.previewLegacyBook(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址在迁移确认期间发生变化；请重新连接并下载预览") }
            guard latest.revision == preview.revision else { throw NextError.invalid("迁移预览版本已变化；请重新下载核对") }
            let destination = try await NextNASService.readStatus(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址在迁移确认期间发生变化；未导入本机账本") }
            guard !destination.hasBook && destination.revision == 0 else { throw NextError.invalid("新版 NAS 已有真实账本；为避免覆盖，导入已取消") }
            guard book == originalBook else { throw NextError.invalid("预览期间本机账本发生变化；迁移已停止，请重新核对") }
            guard repository.integrityWarning == nil else { throw NextError.invalid("本机数据完整性待恢复；导入已停止") }
            try repository.writeSafetyCopy(try makeBackup())
            try commitRealLedger(incoming, action: "从旧网页转换导入", reason: "用户确认旧账本迁移修订 \(preview.revision)；导入前已备份")
            if let watchCodes = preview.summary?.watchCodes {
                var seen = Set<String>()
                let valid = watchCodes.filter { $0.count == 6 && $0.allSatisfy(\.isNumber) && seen.insert($0).inserted }
                if !valid.isEmpty { preferences.watch = valid }
            }
            let revision = try await NextNASService.pushBook(incoming, expectedRevision: destination.revision, baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else {
                legacyImportPreview = nil
                syncStatus = "手机已完成导入；原 NAS 已初始化为修订 \(revision)，设置地址随后发生改变，请重新检查新 NAS。"
                return
            }
            preferences.nasRevision = revision; preferences = preferences
            legacyImportPreview = nil
            syncStatus = "旧账本已导入手机并初始化新版 NAS · NAS 修订 \(revision) · \(preview.summary?.positions ?? 0) 只持仓、\(preview.summary?.fills ?? 0) 条流水"
        } catch {
            syncStatus = "迁移未完成 · \(error.localizedDescription)"
            errorMessage = "若本机账本已导入而 NAS 上传失败，手机数据保留且有恢复副本；连接恢复后可手动上传本机账本。"
        }
    }
    func cancelLegacyWebImport() { legacyImportPreview = nil }
    func probeNAS() async {
        do {
            let health = try await NextNASService.checkHealth(baseURL: preferences.nasBaseURL)
            aiProviderStatus = health.aiProvider
        } catch {
            aiProviderStatus = nil
            syncStatus = "NAS 离线或健康检查失败 · \(error.localizedDescription)"
            postLocalAlert(level: "NAS", fingerprint: "nas-connectivity", title: "NAS 连接不可用", detail: "\(error.localizedDescription)。本机账本和缓存仍可使用。", stamp: NextDataStamp(source: "NAS 连通性检查", observedAt: Date(), quality: .stale, detail: "用户触发检查"))
            return
        }
        do {
            let remote = try await NextNASService.readStatus(baseURL: preferences.nasBaseURL)
            syncStatus = "NAS 可连接 · 修订 \(remote.revision) · \(remote.hasBook ? "已有数据，可下载" : "空账本")"
        } catch {
            syncStatus = "NAS 在线 · 账本接口读取失败：\(error.localizedDescription)"
        }
    }
    func downloadBookManually() async {
        let originalBook = book
        let baseURL = preferences.nasBaseURL
        do {
            let remote = try await NextNASService.readStatus(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址在下载过程中发生变化；未写入本机账本") }
            guard book == originalBook else { throw NextError.invalid("本机账本在下载过程中发生变化；为避免覆盖，下载已取消") }
            guard let incoming = remote.book else { throw NextError.invalid("NAS 上还没有可下载的新账本") }
            guard repository.integrityWarning == nil else { throw NextError.invalid("本机数据完整性待恢复；下载已停止") }
            try repository.writeSafetyCopy(try makeBackup())
            try commitRealLedger(incoming, action: "从 NAS 下载真实账本", reason: "用户确认下载 NAS 修订 \(remote.revision)；原账本已备份")
            preferences.nasRevision = remote.revision
            preferences.nasSyncedFingerprint = incoming.syncFingerprint
            preferences.nasSyncedAt = Date()
            preferences = preferences
            syncStatus = "已从 NAS 下载账本 · 修订 \(remote.revision)"
        } catch { syncStatus = "下载停止 · \(error.localizedDescription)" }
    }
    /// 手动上传。`force = true` 时跳过"本机记录的修订必须等于 NAS 修订"的检查，
    /// 直接用刚读到的远端修订号覆盖 —— 这是修订号走岔（恢复过备份、换过手机、
    /// NAS 被网页端写过）之后唯一的出路，否则会永远卡在"请先下载核对"。
    func syncBookManually(force: Bool = false) async {
        let snapshot = book
        let baseURL = preferences.nasBaseURL
        let knownRevision = preferences.nasRevision
        do {
            let remote = try await NextNASService.readStatus(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址在同步过程中发生变化；本次未上传") }
            guard book == snapshot, preferences.nasRevision == knownRevision else { throw NextError.invalid("本机账本或同步修订在连接期间发生变化；请重新核对后同步") }
            if !force {
                if let knownRevision {
                    guard remote.revision == knownRevision else { throw NextError.invalid("NAS 修订已变为 \(remote.revision)（本机记录 \(knownRevision)）；请先下载核对，或用「强制覆盖」") }
                } else {
                    guard remote.revision == 0 && !remote.hasBook else { throw NextError.invalid("NAS 已有账本但本机没有同步记录；请先下载核对，或用「强制覆盖」") }
                }
            }
            let revision = try await NextNASService.pushBook(snapshot, expectedRevision: remote.revision, baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else {
                syncStatus = "已写入原 NAS 修订 \(revision)，但设置中的 NAS 地址已更改；新地址修订未修改，请重新检查连接。"
                return
            }
            preferences.nasRevision = revision
            preferences.nasSyncedFingerprint = snapshot.syncFingerprint
            preferences.nasSyncedAt = Date()
            preferences = preferences
            syncStatus = book == snapshot ? "用户确认上传完成 · 修订 \(revision)" : "NAS 已保存快照修订 \(revision)；上传期间本机账本有新变化，请再次同步。"
        } catch { syncStatus = "上传停止 · \(error.localizedDescription)" }
    }
    // MARK: - 账本上传状态

    /// 本机账本是否有改动还没上传到 NAS。按内容指纹判断，而不是"上次点没点过上传"。
    var hasPendingUpload: Bool {
        guard !preferences.nasBaseURL.isEmpty else { return false }
        return preferences.nasSyncedFingerprint != book.syncFingerprint
    }

    /// 给界面用的一句话状态：到底同步过没有、什么时候、修订几。
    var syncStateText: String {
        guard !preferences.nasBaseURL.isEmpty else { return "未配置 NAS" }
        if hasPendingUpload { return "有改动待上传" }
        if let revision = preferences.nasRevision, let at = preferences.nasSyncedAt {
            return "已同步 · 修订 \(revision) · \(at.formatted(date: .omitted, time: .shortened))"
        }
        if let revision = preferences.nasRevision { return "已同步 · 修订 \(revision)" }
        return "尚无同步记录"
    }

    /// 改账本后延迟 3 秒合并上传：连续录入不会每敲一下就打一次 NAS。
    private func scheduleAutoUpload() {
        guard preferences.nasAutoUpload, !preferences.nasBaseURL.isEmpty else { return }
        autoUploadTask?.cancel()
        autoUploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.autoUploadBookIfNeeded()
        }
    }

    /// 自动上传。三条硬规矩：
    /// 1. 只在有未上传改动时才发；
    /// 2. 修订号对不上（NAS 被别人写了）**不覆盖**，只把状态说清楚；
    /// 3. 上传成功后把内容指纹记下来，界面才能显示"已同步"。
    func autoUploadBookIfNeeded() async {
        guard preferences.nasAutoUpload, !preferences.nasBaseURL.isEmpty else { return }
        guard hasPendingUpload else { return }
        let snapshot = book
        let fingerprint = snapshot.syncFingerprint
        let baseURL = preferences.nasBaseURL
        do {
            let remote = try await NextNASService.readStatus(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL, book.syncFingerprint == fingerprint else { return }
            if let known = preferences.nasRevision {
                guard remote.revision == known else {
                    syncStatus = "未自动上传 · NAS 修订已变为 \(remote.revision)（本机记录 \(known)）；请先下载核对，不覆盖"
                    return
                }
            } else {
                guard remote.revision == 0 && !remote.hasBook else {
                    syncStatus = "未自动上传 · NAS 上已有账本但本机没有同步记录；请先下载核对"
                    return
                }
            }
            let revision = try await NextNASService.pushBook(snapshot, expectedRevision: remote.revision, baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { return }
            preferences.nasRevision = revision
            preferences.nasSyncedFingerprint = fingerprint
            preferences.nasSyncedAt = Date()
            preferences = preferences
            syncStatus = book.syncFingerprint == fingerprint
                ? "已自动上传 · 修订 \(revision) · \(Date.now.formatted(date: .omitted, time: .shortened))"
                : "已上传修订 \(revision)；之后又有新改动，稍后自动再传"
        } catch {
            syncStatus = "自动上传失败 · \(error.localizedDescription)（本机账本未受影响）"
        }
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
    func runTwinBacktest(_ strategy: NextTwinStrategy, fastWindow: Int = 20, slowWindow: Int = 60,
                        monthlyContribution: Decimal = 0) async {
        guard !preferences.nasBaseURL.isEmpty else { backtestStatus = "回测未运行 · 请先连接 NAS"; return }
        let eligible = simulationUniverse.filter { rules[$0]?.isHistoricalBacktestEligible == true }
        guard !eligible.isEmpty else { backtestStatus = "回测未运行 · 持仓/自选里缺少已核验 ETF 交易单位与费率；未猜测手数"; return }
        let virtualCash = twins.accounts[strategy.rawValue]?.simulation.cash ?? 0
        // 起点资金优先用真实总资产：以前固定一万，和账户规模完全不搭。
        let capital = realBookEquity > 0 ? realBookEquity : virtualCash
        guard capital > 0 else { backtestStatus = "回测未运行 · 没有可用的起始资金"; return }
        backtestStatus = "NAS 正在读取日 K 并回放 \(strategy.rawValue) 策略…"
        do {
            let result = try await NextNASService.runBacktest(strategy: strategy, codes: eligible, initialCash: capital,
                baseURL: preferences.nasBaseURL, rules: rules, monthlyContribution: monthlyContribution,
                fastWindow: fastWindow, slowWindow: slowWindow)
            twinBacktests[strategy.rawValue] = result
            backtestStatus = "历史回测完成 · \(result.sessions) 个交易日 · 数据截至 \(result.endDate)"
        } catch {
            backtestStatus = "回测未完成 · \(error.localizedDescription)"
        }
    }
    func refreshNASGAccount() async {
        guard !preferences.nasBaseURL.isEmpty else { nasGStatus = "请先连接 NAS"; return }
        let baseURL = preferences.nasBaseURL
        nasGStatus = "正在读取 NAS G 模拟账户…"
        do {
            let result = try await NextNASService.readGAccount(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址已变化；未采用旧连接结果") }
            nasGRevision = result.revision; nasGAccount = result.account
            nasGStatus = result.account.map { "NAS G · 修订 \(result.revision) · \($0.status)" } ?? "NAS G 尚未启动；真实账本未受影响"
        } catch { nasGStatus = "NAS G 读取失败 · \(error.localizedDescription)" }
    }
    /// 拉取 NAS 网格引擎状态与「明日挂单表」。网格不预测涨跌，只给出现价附近的买卖档位与可达成数量。
    func refreshGridStatus() async {
        guard !preferences.nasBaseURL.isEmpty else { gridStatusMessage = "请先在「我的」里连接 NAS"; return }
        let baseURL = preferences.nasBaseURL
        gridStatusMessage = "正在读取 NAS 网格状态…"
        do {
            let result = try await NextNASService.fetchGridStatus(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址已变化；未采用旧连接结果") }
            gridStatus = result
            if !result.initialized {
                gridStatusMessage = "NAS 网格尚未初始化；首次启动后由后台按持仓自动建网格"
            } else if let summary = result.summary {
                gridStatusMessage = "网格运行中 · 账户权益 ¥\(NextMoney.text(Decimal(string: summary.equity) ?? 0)) · 已运行 \(summary.days) 天 · 待办挂单 \(result.ladder.reduce(0) { $0 + $1.rungs.count }) 档"
            } else {
                gridStatusMessage = "NAS 网格已连接，但无汇总数据"
            }
        } catch { gridStatusMessage = "NAS 网格读取失败 · \(error.localizedDescription)" }
    }
    func startNASGAccount(initialCash: Decimal) async {
        guard !preferences.nasBaseURL.isEmpty else { nasGStatus = "启动失败 · 请先连接 NAS"; return }
        guard initialCash > 0 else { nasGStatus = "启动失败 · 虚拟初始资金必须大于零"; return }
        let eligible = simulationUniverse.filter { rules[$0]?.isHistoricalBacktestEligible == true }
        guard !eligible.isEmpty, eligible.count <= 12 else {
            nasGStatus = "启动失败 · 自选中需要 1–12 只已核验的 ETF、交易单位和 ¥0.10 手续费规则"; return
        }
        let lotSizes = Dictionary(uniqueKeysWithValues: eligible.compactMap { code in rules[code]?.lotSize.map { (code, $0) } })
        let fees = Dictionary(uniqueKeysWithValues: eligible.compactMap { code in rules[code]?.feePerTrade.map { (code, $0) } })
        let baseURL = preferences.nasBaseURL
        nasGStatus = "正在确认 NAS G 版本并创建独立虚拟账户…"
        do {
            let current = try await NextNASService.readGAccount(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL, current.account.map({ $0.status == "reset" }) ?? true else { throw NextError.invalid("NAS G 已有账户；请先暂停或确认重置") }
            let created = try await NextNASService.startGAccount(baseURL: baseURL, expectedRevision: current.revision,
                initialCash: initialCash, lotSizes: lotSizes, fees: fees)
            nasGRevision = created.revision; nasGAccount = created.account
            nasGStatus = "NAS G 已启动 · \(eligible.count) 只核验 ETF · 仅模拟，不会向券商下单"
        } catch { nasGStatus = "NAS G 启动失败 · \(error.localizedDescription)" }
    }
    func setNASGPaused(_ paused: Bool) async {
        await mutateNASG(paused ? "pause" : "resume")
    }
    func mutateNASG(_ action: String, amount: Decimal? = nil) async {
        guard !preferences.nasBaseURL.isEmpty, let revision = nasGRevision else { nasGStatus = "请先读取 NAS G 账户"; return }
        let baseURL = preferences.nasBaseURL
        do {
            let result = try await NextNASService.actOnGAccount(action, baseURL: baseURL, expectedRevision: revision, amount: amount)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址已变化；请刷新账户") }
            nasGRevision = result.revision; nasGAccount = result.account
            nasGStatus = "NAS G · 修订 \(result.revision) · \(result.account?.status ?? "未知")"
        } catch { nasGStatus = "NAS G 操作失败 · \(error.localizedDescription)" }
    }
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
            var updatedRules = rules
            for quote in fetched {
                let quality: NextDataQuality = quote.isFresh(at: Date()) ? .live : .delayed
                let cached = NextCachedQuote(quote: quote, stamp: NextDataStamp(source: quote.source, observedAt: quote.time, quality: quality, detail: "按行情源时间标记；未补造 IOPV"))
                try validateQuote(cached)
                updated[quote.code] = cached
                if quote.providerInstrumentType == "ETF" {
                    let market = quote.code.hasPrefix("15") ? "SZSE" : "SSE"
                    if let rule = NextInstrumentRules.verifiedETFMarketRule(code: quote.code, market: market) {
                        updatedRules[quote.code] = rule
                    }
                }
            }
            quotes = updated
            rules = updatedRules
            // 名称随报价一起收进名称簿：这样流水、提醒、分红里只存了代码的位置也能显示名字。
            recordDailySnapshotIfNeeded()
            NextNameBook.remember(pairs: fetched.compactMap { quote in
                let name = quote.name.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : (code: quote.code, name: name)
            })
            evaluatePriceAlerts(fetched)
            evaluatePatientLimitPlans(fetched)
            status = "行情已更新 · \(sourceNote) · \(fetched.count)/\(unique.count) · \(Date.now.formatted(date: .omitted, time: .shortened))"
        } catch {
            status = "行情连接失败 · 显示本地缓存"
            errorMessage = "\(error.localizedDescription)。本地账本和历史缓存仍可查看。"
            postLocalAlert(level: "行情", fingerprint: "market-refresh-unavailable", title: "行情刷新失败", detail: "\(error.localizedDescription)。当前显示本机缓存，不据此生成新的价格计划。", stamp: NextDataStamp(source: "行情刷新", observedAt: Date(), quality: .stale, detail: "请求失败"))
        }
    }
    /// 每个「收盘后」留一条资产快照。
    ///
    /// 之前 `book.history` 没有任何写入路径 —— 界面上有「区间收益 / 年化 / 基准对比」，
    /// 但永远显示"快照不足"，因为从来没人写。这里按天补齐：同一天只留一条，
    /// 取收盘后的总资产，出入金单独记在 externalFlow 里供区间收益剔除。
    func recordDailySnapshotIfNeeded() {
        guard !book.positions.isEmpty else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        // 盘中不记：总资产每 10 秒都在变，记下来只是噪音；收盘后再落一条。
        if NextMarketClock.isRegularSession(now) { return }
        if let last = book.history.last, calendar.isDate(last.date, inSameDayAs: now) { return }
        let summary = NextPortfolioCalculator.summary(book: book, quotes: quotes, at: now, mode: .diluted)
        guard summary.isComplete, summary.totalValue > 0 else { return }
        let flow = book.cashMovements
            .filter { calendar.isDate($0.date, inSameDayAs: now) }
            .reduce(Decimal.zero) { $0 + $1.amount }
        var updated = book
        updated.history.append(NextAssetPoint(date: calendar.startOfDay(for: now), total: summary.totalValue, externalFlow: flow))
        if updated.history.count > 750 { updated.history.removeFirst(updated.history.count - 750) }
        try? commitRealLedger(updated, action: "记录当日资产快照", reason: "收盘后总资产，用于区间收益")
    }

    /// 只刷新分时（不碰日 K 与 NAS 档案注册），用于盘中每隔一分钟补一次曲线。
    /// 失败就静默保留现有曲线 —— 自动刷新不该弹窗打断人。
    func refreshIntraday(_ code: String) async {
        do {
            let raw = try await NextMarketDataService.fetchIntraday(code: code)
            let dataset = quotes[code].map { raw.attachingVerifiedIOPV($0.quote) } ?? raw
            try dataset.validate()
            chartData[code] = dataset
        } catch { }
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
    func refreshDividendHistory(_ code: String) async {
        guard !preferences.nasBaseURL.isEmpty else { return }
        do {
            let events = try await NextNASService.fetchDividendEvents(code: code, baseURL: preferences.nasBaseURL)
            dividendEvents[code] = events
        } catch {
            // The last verified local cache remains visible when NAS or upstream is offline.
            if dividendEvents[code] == nil && book.dividendEvents.filter({ $0.code == code }).isEmpty {
                notice = "分红历史暂不可更新；本机已有记录仍可查看，推算事件不会计入已收现金。"
            }
        }
    }
    /// 派息自动化：批量拉取派息历史，并按已确认派息自动登记「待收」记录。
    ///
    /// 只登记：已实施（isEstimated != true）、除息日已过且在近 400 天内、
    /// 且本机尚未登记过的派息。登记出来的是 `status == .expected` 的待确认记录，
    /// **不会自动往现金里加钱** —— 实际到账金额以券商为准，仍需点一次确认；
    /// 这样既有自动记录，又不会把「估算的派息」冒充成「已到账的现金」。
    func syncAllDividendHistory() async {
        let codes = Array(Set(book.positions.map(\.code) + preferences.watch)).sorted()
        guard !codes.isEmpty else { return }
        if !preferences.nasBaseURL.isEmpty {
            for code in codes { await refreshDividendHistory(code) }
        }
        registerAutomaticDividendDrafts()
    }

    /// 自动按持仓份额登记「派息待收」。
    /// 关键规则：只登记**建仓日（acquiredAt）及之后**的派息。建仓日之前的除息不算你的——
    /// 你录入一只早已分红过的票时，不该凭空冒出历史分红待确认。没有建仓日的老持仓会先用
    /// 「最早流水日 / 迁移日」兜底一次（幂等、结果稳定，不会每天重写）。
    func registerAutomaticDividendDrafts() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = Date()
        let todayText = formatter.string(from: today)
        guard let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -400, to: today) else { return }
        let cutoffText = formatter.string(from: cutoff)

        var updated = book

        // 1) 一次性迁移：没有建仓日的持仓，用「最早流水日」或「迁移日」兜底。
        var migratedCount = 0
        for idx in updated.positions.indices where updated.positions[idx].units > 0 && updated.positions[idx].acquiredAt == nil {
            let code = updated.positions[idx].code
            let earliestFill = updated.fills.filter { $0.code == code }.map { $0.date }.min()
            if let anchor = earliestFill ?? book.importedAt {
                updated.positions[idx].acquiredAt = anchor
                migratedCount += 1
            }
        }

        // 2) 每只持仓的分红门槛：建仓日；没有则用今天（只看未来，符合「以后的只是以后的」）。
        var thresholdByCode: [String: String] = [:]
        for p in updated.positions where p.units > 0 {
            thresholdByCode[p.code] = p.acquiredAt.map { formatter.string(from: $0) } ?? todayText
        }

        // 3) 清理门槛之前的自动登记草稿，避免历史分红伪待收。
        var removed: [String] = []
        updated.incomeEvents.removeAll { ev in
            guard ev.status == .expected, ev.note.hasPrefix("自动登记|"), let code = ev.code,
                  let threshold = thresholdByCode[code] else { return false }
            let parts = ev.note.split(separator: "|")
            guard parts.count >= 3 else { return false }
            let evDate = String(parts[2])
            if evDate < threshold { removed.append("\(ev.name) \(evDate)"); return true }
            return false
        }

        // 4) 登记门槛之后、cutoff 之前已实施的派息。
        var added: [String] = []
        for position in updated.positions where position.units > 0 {
            guard let threshold = thresholdByCode[position.code] else { continue }
            let events = NextDividendAnalytics.merged(book.dividendEvents + (dividendEvents[position.code] ?? []))
            for event in events where event.code == position.code && event.isEstimated != true
                && event.date <= todayText && event.date >= cutoffText && event.date >= threshold {
                let marker = "自动登记|\(event.code)|\(event.date)"
                if updated.incomeEvents.contains(where: { $0.note.hasPrefix(marker) }) { continue }
                let gross = event.amountPerShare * Decimal(position.units)
                guard gross > 0 else { continue }
                let exDate = formatter.date(from: event.date)
                let payDate = formatter.date(from: event.payDate ?? event.date) ?? exDate ?? today
                let draft = NextIncomeEvent(kind: .etfDistribution, code: event.code, name: position.name,
                                            exDate: exDate, payDate: payDate, units: position.units,
                                            perUnit: event.amountPerShare, grossAmount: gross, tax: 0,
                                            note: "\(marker)|\(position.units) 份")
                guard (try? draft.validate()) != nil else { continue }
                updated.incomeEvents.append(draft)
                added.append("\(position.name) \(event.date) ¥\(NextMoney.text(gross))")
            }
        }
        guard !added.isEmpty || migratedCount > 0 || !removed.isEmpty else { return }
        var reason = "按持仓份额与已实施派息自动登记 \(added.count) 笔"
        if migratedCount > 0 { reason += "；补全 \(migratedCount) 只持仓建仓日" }
        if !removed.isEmpty { reason += "；清理 \(removed.count) 笔历史分红伪待收" }
        do {
            try commitRealLedger(updated, action: "自动登记派息待收", reason: reason)
            notice = "已按持仓自动登记 \(added.count) 笔派息待收；确认到账后再计入现金。"
        } catch {
            notice = "派息自动登记未写入：\(error.localizedDescription)"
        }
    }

    func refreshNASResearch(_ code: String) async {        guard !preferences.nasBaseURL.isEmpty else {
            researchStatus[code] = "未配置 NAS · 显示本机研究缓存"
            return
        }
        let baseURL = preferences.nasBaseURL
        do {
            let report = try await NextNASService.fetchResearch(code: code, baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else {
                researchStatus[code] = "NAS 地址已变更 · 保留原缓存，未混用新旧服务"
                return
            }
            nasResearch[code] = report
            researchStatus[code] = "已从 NAS 刷新研究状态"
        } catch {
            researchStatus[code] = nasResearch[code] == nil
                ? "NAS 研究不可用 · 暂无本机缓存"
                : "NAS 刷新失败 · 当前显示本机缓存"
        }
    }
    func registerNASArchive(_ code: String) async {
        guard !preferences.nasBaseURL.isEmpty else { return }
        do { try await NextNASService.trackInstrument(code: code, baseURL: preferences.nasBaseURL) }
        catch { status = "NAS 后台归档登记失败 · 本机行情和缓存仍可用" }
    }
    @discardableResult func loadNASMinute(code: String, day: Date) async -> Bool {
        guard !preferences.nasBaseURL.isEmpty else { errorMessage = "先连接 NAS 才能读取归档日期"; return false }
        do {
            let dataset = try await NextNASService.fetchMinute(code: code, day: day, baseURL: preferences.nasBaseURL)
            chartData[code] = dataset
            status = "已载入 NAS 分时档案 · \(dataset.priceSource) · \(dataset.samples.count) 点"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func refreshDaily(_ code: String, required: Bool = false) async {
        guard !preferences.nasBaseURL.isEmpty else {
            if required { dailyErrors[code] = "请先在设置中配置 NAS 地址；连接成功后可读取 NAS 日 K，分时仍可独立使用。" }
            return
        }
        do {
            let dataset = try await NextNASService.fetchDaily(code: code, baseURL: preferences.nasBaseURL)
            chartData["\(code):day"] = dataset
            dailyErrors.removeValue(forKey: code)
        } catch {
            dailyErrors[code] = error.localizedDescription
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
        preferences = LocalPreferences(goal: incoming.goal, watch: incoming.watch, navigation: incoming.navigation, theme: GPTheme(rawValue: incoming.theme.rawValue) ?? .light, appearance: preferences.appearance, notifications: incoming.notifications, nasBaseURL: preferences.nasBaseURL, legacyWebBaseURL: preferences.legacyWebBaseURL, nasRevision: nil)
        quotes = incoming.cachedQuotes; chartData = incoming.chartData; rules = incoming.instrumentRules; orderBooks = incoming.orderBooks
        decisions = incoming.decisionHistory
        nasResearch = incoming.nasResearch
        dividendEvents = incoming.dividendEvents
        patientLimitPlans = incoming.patientLimitPlans
        twinBacktests = incoming.twinBacktests
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
        archive.dividendEvents = dividendEvents
        archive.patientLimitPlans = patientLimitPlans
        archive.twinBacktests = twinBacktests
        archive.theme = NextTheme(rawValue: theme.rawValue) ?? .light
        return archive
    }
}
