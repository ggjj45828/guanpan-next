import Foundation

struct NextNASStatus {
    let revision: Int
    let hasBook: Bool
    let book: NextBook?
}
struct NextNASHealth: Decodable {
    let service: String
    let schemaVersion: Int
    let aiProvider: NextAIProviderStatus?
}
struct NextNASAIAnalysis: Decodable {
    let code: String
    let provider: String
    let model: String
    let content: String
    let realOrder: Bool
    let createdAt: String
}
struct NextNASGEnvelope: Decodable {
    let strategy: String
    let revision: Int
    let account: NextNASGAccount?
}
enum NextJSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: NextJSONValue]), array([NextJSONValue]), null
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: NextJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([NextJSONValue].self)) }
    }
}
struct NextNASGAccount: Decodable {
    struct Order: Decodable, Identifiable {
        let id: String
        let code: String
        let side: String
        let units: Int
        let remainingUnits: Int?
        let status: String
        let executionSession: String?
    }
    struct CurvePoint: Decodable, Identifiable {
        var id: String { date }
        let date: String
        let equity: String
        let nav: String?
        let drawdown: String?
    }
    let strategy: String
    let status: String
    let realOrder: Bool
    let cash: String
    let positions: [String: Int]
    let orders: [Order]
    let fills: [NextJSONValue]
    let decisions: [NextJSONValue]
    let aiRuns: [NextJSONValue]
    let curve: [CurvePoint]

    func equityChartDataset() -> NextChartDataset? {
        guard let code = positions.keys.sorted().first, curve.count >= 2 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        var byDay: [String: CurvePoint] = [:]
        for point in curve { byDay[String(point.date.prefix(10))] = point }
        let samples = byDay.keys.sorted().compactMap { day -> NextChartSample? in
            guard let point = byDay[day] else { return nil }
            guard let timestamp = formatter.date(from: day), let equity = Decimal(string: point.equity), equity > 0 else { return nil }
            return NextChartSample(timestamp: timestamp, open: nil, high: nil, low: nil, close: equity, iopv: nil, volume: nil)
        }
        guard samples.count >= 2 else { return nil }
        let dataset = NextChartDataset(code: code, interval: .day, samples: samples, costPerUnit: nil,
            costObservedAt: nil, priceSource: "NAS G 虚拟账户权益曲线 · 日 K 开盘代理撮合", iopvSource: nil, observedAt: Date())
        do { try dataset.validate(); return dataset } catch { return nil }
    }
}
struct NextAIProviderStatus: Decodable {
    let state: String
    let configured: Bool
    let profile: String?
    let model: String?
    let message: String

    enum CodingKeys: String, CodingKey { case state, configured, profile, model, message }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        configured = try values.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        profile = try values.decodeIfPresent(String.self, forKey: .profile)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? "NAS 未返回 AI 配置状态"
    }
}
struct NextLegacyBookSummary: Decodable {
    let positions: Int
    let fills: Int
    let cashMovements: Int
    let history: Int
    let cash: Decimal?
    let watchCodes: [String]?
    let skippedPositions: Int
    let skippedTrades: Int
    let ignoredOTCFunds: Int
    let dividendEvents: Int?
}
struct NextLegacyBookPreview: Decodable {
    let revision: Int
    let book: NextBook?
    let summary: NextLegacyBookSummary?
}

enum NextNASService {
    private struct BacktestRequest: Encodable {
        let strategy: String
        let codes: [String]
        let initialCash: String
        let monthlyContribution: String
        let fee: String
        let weights: [String: String]
        let lotSizes: [String: Int]
        let parameters: [String: Int]
    }
    private struct GAccountRequest: Encodable {
        let action: String
        let userConfirmed: Bool
        let expectedRevision: Int
        let config: GAccountConfig?
    }
    private struct GAccountConfig: Encodable {
        let initialCash: String
        let codes: [String]
        let lotSizes: [String: Int]
        let feesPerFill: [String: String]
        let weights: [String: String]
    }
    static func validateURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              (scheme == "https" || (scheme == "http" && isTrustedLocalHost(host))),
              url.path.isEmpty || url.path == "/", url.query == nil, url.user == nil, url.password == nil else {
            throw NextError.invalid("请输入 NAS 的 HTTPS 地址；家庭局域网可用 http://NAS内网地址:30001")
        }
        return url
    }
    static func readGAccount(baseURL: String, session: URLSession = .shared) async throws -> NextNASGEnvelope {
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("simulations").appendingPathComponent("G")
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS G 模拟账户读取失败") }
        let result = try JSONDecoder().decode(NextNASGEnvelope.self, from: data)
        guard result.strategy == "G", result.revision >= 0,
              result.account.map({ $0.strategy == "G" && !$0.realOrder }) ?? true else {
            throw NextError.invalid("NAS 返回的不是隔离的 G 虚拟账户")
        }
        return result
    }
    static func startGAccount(baseURL: String, expectedRevision: Int, initialCash: Decimal,
                              lotSizes: [String: Int], fees: [String: Decimal], session: URLSession = .shared) async throws -> NextNASGEnvelope {
        let codes = lotSizes.keys.sorted()
        guard !codes.isEmpty, codes.count <= 12, Set(codes) == Set(fees.keys), initialCash > 0 else {
            throw NextError.invalid("G 启动需要 1–12 只已核验证券、交易单位和独立费率")
        }
        let weight = NSDecimalNumber(decimal: Decimal(1) / Decimal(codes.count)).stringValue
        let weights = Dictionary(uniqueKeysWithValues: codes.map { ($0, weight) })
        let feeText = fees.mapValues { NSDecimalNumber(decimal: $0).stringValue }
        let config = GAccountConfig(initialCash: NSDecimalNumber(decimal: initialCash).stringValue,
            codes: codes, lotSizes: lotSizes, feesPerFill: feeText, weights: weights)
        return try await mutateGAccount(baseURL: baseURL, request: GAccountRequest(action: "start", userConfirmed: true,
            expectedRevision: expectedRevision, config: config), session: session)
    }
    static func actOnGAccount(_ action: String, baseURL: String, expectedRevision: Int,
                              amount: Decimal? = nil, session: URLSession = .shared) async throws -> NextNASGEnvelope {
        guard ["pause", "resume", "fund", "withdraw", "reset"].contains(action) else { throw NextError.invalid("G 账户操作无效") }
        // Action payload is sent separately because start config is the only optional body field.
        var body: [String: Any] = ["action": action, "userConfirmed": true, "expectedRevision": expectedRevision]
        if let amount { body["amount"] = NSDecimalNumber(decimal: amount).stringValue }
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("simulations").appendingPathComponent("G")
        var request = URLRequest(url: url, timeoutInterval: 15); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decodeGResponse(request, session: session)
    }
    private static func mutateGAccount(baseURL: String, request body: GAccountRequest, session: URLSession) async throws -> NextNASGEnvelope {
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("simulations").appendingPathComponent("G")
        var request = URLRequest(url: url, timeoutInterval: 20); request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decodeGResponse(request, session: session)
    }
    private static func decodeGResponse(_ request: URLRequest, session: URLSession) async throws -> NextNASGEnvelope {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS G 操作没有 HTTP 响应") }
        guard http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NextError.invalid("NAS G 操作失败：\(message ?? "HTTP \(http.statusCode)")")
        }
        let result = try JSONDecoder().decode(NextNASGEnvelope.self, from: data)
        guard result.strategy == "G", result.revision > 0,
              result.account.map({ $0.strategy == "G" && !$0.realOrder }) ?? false else {
            throw NextError.invalid("NAS G 响应没有返回隔离的模拟账户")
        }
        return result
    }

    static func validateLegacySourceURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              (scheme == "https" || (scheme == "http" && isTrustedLocalHost(host))),
              url.path.isEmpty || url.path == "/", url.query == nil, url.user == nil, url.password == nil else {
            throw NextError.invalid("请输入旧网页根地址；家庭网络可用 http://NAS内网地址:8789，外网请用 HTTPS")
        }
        return url
    }
    static func downloadAndStageLegacyBook(legacyBaseURL: String, newNASBaseURL: String, session: URLSession = .shared) async throws -> Int {
        let oldURL = try validateLegacySourceURL(legacyBaseURL).appendingPathComponent("api").appendingPathComponent("data")
        let (oldData, oldResponse) = try await session.data(for: URLRequest(url: oldURL, timeoutInterval: 20))
        guard let oldHTTP = oldResponse as? HTTPURLResponse, oldHTTP.statusCode == 200 else {
            throw NextError.invalid("旧网页 /api/data 下载失败（HTTP \((oldResponse as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: oldData) as? [String: Any] else { throw NextError.invalid("旧网页返回格式不是 JSON 对象") }
        let source: Any
        if let wrapped = envelope["data"] as? [String: Any] { source = wrapped }
        else if let text = envelope["data"] as? String, let bytes = text.data(using: .utf8) { source = try JSONSerialization.jsonObject(with: bytes) }
        else { source = envelope }
        guard let sourceObject = source as? [String: Any] else { throw NextError.invalid("旧网页账本数据不是对象") }

        // Ask the new NAS to validate and convert before putting anything in its
        // isolated migration inbox. This endpoint has no write side effect.
        let previewURL = try validateURL(newNASBaseURL).appendingPathComponent("v1").appendingPathComponent("legacy").appendingPathComponent("books").appendingPathComponent("main")
        let previewBody = try JSONSerialization.data(withJSONObject: ["data": sourceObject])
        var previewRequest = URLRequest(url: previewURL, timeoutInterval: 20); previewRequest.httpMethod = "POST"; previewRequest.httpBody = previewBody
        previewRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (checkData, checkResponse) = try await session.data(for: previewRequest)
        guard let checkHTTP = checkResponse as? HTTPURLResponse, checkHTTP.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: checkData) as? [String: Any])?["error"] as? String ?? "旧账本无法安全转换"
            throw NextError.invalid(message)
        }
        let stageURL = try validateURL(newNASBaseURL).appendingPathComponent("api").appendingPathComponent("data")
        let (currentData, currentResponse) = try await session.data(for: URLRequest(url: stageURL, timeoutInterval: 10))
        guard let currentHTTP = currentResponse as? HTTPURLResponse, currentHTTP.statusCode == 200,
              let current = try JSONSerialization.jsonObject(with: currentData) as? [String: Any],
              let revision = current["revision"] as? Int else { throw NextError.invalid("新版 NAS 迁移暂存区读取失败") }
        let body = try JSONSerialization.data(withJSONObject: ["mode": "legacy-stage-confirmed", "expectedRevision": revision, "data": sourceObject])
        var stageRequest = URLRequest(url: stageURL, timeoutInterval: 20); stageRequest.httpMethod = "POST"; stageRequest.httpBody = body
        stageRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (savedData, savedResponse) = try await session.data(for: stageRequest)
        guard let savedHTTP = savedResponse as? HTTPURLResponse else { throw NextError.invalid("新版 NAS 没有返回迁移保存状态") }
        if savedHTTP.statusCode == 409 { throw NextError.invalid("新版 NAS 暂存版本已变化，请重新开始下载") }
        guard savedHTTP.statusCode == 200,
              let saved = try JSONSerialization.jsonObject(with: savedData) as? [String: Any],
              let savedRevision = saved["revision"] as? Int else { throw NextError.invalid("新版 NAS 暂存旧账本失败（HTTP \(savedHTTP.statusCode)）") }
        return savedRevision
    }
    static func previewLegacyBook(baseURL: String, session: URLSession = .shared) async throws -> NextLegacyBookPreview {
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("legacy").appendingPathComponent("books").appendingPathComponent("main")
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 15))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("旧网页账本转换预览读取失败") }
        return try JSONDecoder().decode(NextLegacyBookPreview.self, from: data)
    }

    /// Permit cleartext only for loopback/private LAN NAS endpoints. Public hosts
    /// must use HTTPS; this is needed for the documented direct 30001 home-LAN URL.
    private static func isTrustedLocalHost(_ host: String) -> Bool {
        if ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if (host.hasPrefix("fc") || host.hasPrefix("fd")) && host.contains(":") { return true } // IPv6 unique-local
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
    }
    static func checkHealth(baseURL: String, session: URLSession = .shared) async throws -> NextNASHealth {
        let url = try validateURL(baseURL).appendingPathComponent("health")
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 8))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse).map { String($0.statusCode) } ?? "无 HTTP 响应"
            throw NextError.invalid("NAS 健康检查失败（\(status)）")
        }
        let health = try JSONDecoder().decode(NextNASHealth.self, from: data)
        guard health.service == "guanpan-next", health.schemaVersion == 1 else { throw NextError.invalid("连接到的服务不是兼容的 Guanpan Next NAS") }
        return health
    }
    static func readStatus(baseURL: String, session: URLSession = .shared) async throws -> NextNASStatus {
        let (data, response) = try await session.data(for: URLRequest(url: try endpoint(baseURL), timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 账本读取失败") }
        let value = try JSONDecoder().decode(RemoteBook.self, from: data)
        let book = try value.bookJSON.map { try JSONDecoder().decode(NextBook.self, from: Data($0.utf8)).validated() }
        return NextNASStatus(revision: value.revision, hasBook: value.bookJSON != nil, book: book)
    }
    static func pushBook(_ book: NextBook, expectedRevision: Int, baseURL: String, session: URLSession = .shared) async throws -> Int {
        let bookData = try JSONEncoder().encode(book)
        let body = try JSONSerialization.data(withJSONObject: ["mode": "manual-confirmed", "expectedRevision": expectedRevision, "bookJSON": String(decoding: bookData, as: UTF8.self)])
        var request = URLRequest(url: try endpoint(baseURL), timeoutInterval: 15); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS 没有返回 HTTP 状态") }
        if http.statusCode == 409 { throw NextError.invalid("NAS 账本版本已变化；没有覆盖数据，请重新下载核对。") }
        guard http.statusCode == 200 else { throw NextError.invalid("NAS 保存失败（HTTP \(http.statusCode)），本机账本未修改") }
        return try JSONDecoder().decode(RevisionResponse.self, from: data).revision
    }
    static func fetchMinute(code: String, day: Date, baseURL: String, session: URLSession = .shared) async throws -> NextChartDataset {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        var parts = URLComponents(url: try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("minute").appendingPathComponent(code), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "day", value: formatter.string(from: day))]
        let (data, response) = try await session.data(for: URLRequest(url: parts.url!, timeoutInterval: 12))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 分时档案读取失败") }
        let payload = try JSONDecoder().decode(MinuteWire.self, from: data)
        guard payload.code == code, !payload.rows.isEmpty else { throw NextError.invalid("该日期还没有 NAS 分时档案") }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let samples = try payload.rows.map { row -> NextChartSample in
            guard let stamp = iso.date(from: row.timestamp), let price = Decimal(string: row.price), price > 0,
                  (row.volume.flatMap({ Decimal(string: $0) }).map({ $0 >= 0 }) ?? true) else {
                throw NextError.invalid("NAS 分时档案时间、价格或成交量无效")
            }
            let iopv = row.iopv.flatMap { Decimal(string: $0) }
            guard iopv.map({ $0 > 0 }) ?? true else { throw NextError.invalid("NAS 分时 IOPV 无效") }
            return NextChartSample(timestamp: stamp, open: nil, high: nil, low: nil, close: price, iopv: iopv, volume: row.volume.flatMap({ Decimal(string: $0) }))
        }
        let dataset = NextChartDataset(code: code, interval: .intraday, samples: samples, costPerUnit: nil, costObservedAt: nil,
                                       priceSource: "NAS 永久分时档案 · \(payload.day)",
                                       iopvSource: samples.contains(where: { $0.iopv != nil }) ? "NAS 分钟采样核验 · Tencent ETF IOPV" : nil,
                                       observedAt: Date())
        try dataset.validate()
        return dataset
    }
    private struct MinuteWire: Decodable { let code: String; let day: String; let source: String; let rows: [MinuteRow] }
    private struct MinuteRow: Decodable { let timestamp: String; let price: String; let volume: String?; let iopv: String? }

    static func fetchDividendEvents(code: String, baseURL: String, session: URLSession = .shared) async throws -> [NextETFDividendEvent] {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("dividends").appendingPathComponent(code)
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 25))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 分红历史暂不可用") }
        let wire = try JSONDecoder().decode(DividendWire.self, from: data)
        guard wire.code == code else { throw NextError.invalid("NAS 分红历史证券代码不一致") }
        return try wire.events.map { row in
            guard let amount = Decimal(string: row.amountPerShare, locale: Locale(identifier: "en_US_POSIX")) else { throw NextError.invalid("NAS 分红金额格式无效") }
            let event = NextETFDividendEvent(code: row.code, date: row.date, amountPerShare: amount, isEstimated: row.isEstimated,
                                             recordDate: row.recordDate, payDate: row.payDate)
            try event.validate(); return event
        }
    }

    static func runBacktest(strategy: NextTwinStrategy, codes: [String], initialCash: Decimal,
                            baseURL: String, rules: [String: NextInstrumentRules],
                            monthlyContribution: Decimal = 0,
                            fastWindow: Int = 20, slowWindow: Int = 60,
                            session: URLSession = .shared) async throws -> NextTwinBacktest {
        guard 2 <= fastWindow, fastWindow < slowWindow, slowWindow <= 250 else {
            throw NextError.invalid("H 策略窗口必须满足 2 ≤ 快线 < 慢线 ≤ 250")
        }
        guard !codes.isEmpty, codes.count <= 12, Set(codes).count == codes.count,
              initialCash > 0, monthlyContribution >= 0, codes.allSatisfy({ rules[$0]?.isHistoricalBacktestEligible == true }) else {
            throw NextError.invalid("回测需要 1–12 只 ETF，且每只 ETF 的类别、交易单位和 ¥0.10 手续费规则都必须可核验")
        }
        let portion = Decimal(1) / Decimal(codes.count)
        let weights = Dictionary(uniqueKeysWithValues: codes.map { ($0, NSDecimalNumber(decimal: portion).stringValue) })
        let lotSizes = Dictionary(uniqueKeysWithValues: codes.compactMap { code in rules[code]?.lotSize.map { (code, $0) } })
        let body = BacktestRequest(strategy: strategy.rawValue, codes: codes, initialCash: NSDecimalNumber(decimal: initialCash).stringValue,
            monthlyContribution: NSDecimalNumber(decimal: monthlyContribution).stringValue, fee: "0.10", weights: weights, lotSizes: lotSizes, parameters: ["fastWindow": fastWindow, "slowWindow": slowWindow])
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("backtests").appendingPathComponent(strategy.rawValue)
        var request = URLRequest(url: url, timeoutInterval: 120); request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS 回测请求没有收到 HTTP 状态") }
        guard http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NextError.invalid("NAS 历史回测失败：\(message ?? "HTTP \(http.statusCode)")")
        }
        let result = try JSONDecoder().decode(NextTwinBacktest.self, from: data)
        try result.validate()
        guard result.strategy == strategy.rawValue, result.codes == codes else { throw NextError.invalid("NAS 回测证券或策略与请求不一致") }
        return result
    }
    static func analyzeETF(context: [String: Any], baseURL: String, session: URLSession = .shared) async throws -> NextNASAIAnalysis {
        guard let security = context["security"] as? [String: Any],
              let code = security["code"] as? String, code.count == 6, code.allSatisfy(\.isNumber) else {
            throw NextError.invalid("AI 研究证券上下文无效")
        }
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("ai").appendingPathComponent("analyze")
        var request = URLRequest(url: url, timeoutInterval: 55); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userConfirmed": true, "context": context], options: [.fragmentsAllowed])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS AI 没有返回 HTTP 状态") }
        guard http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NextError.invalid("NAS AI 分析失败：\(message ?? "HTTP \(http.statusCode)")")
        }
        let result = try JSONDecoder().decode(NextNASAIAnalysis.self, from: data)
        guard result.code == code, result.realOrder == false, !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NextError.invalid("NAS AI 返回内容未通过证券和真实交易安全校验")
        }
        return result
    }
    private struct DividendWire: Decodable {
        let code: String; let source: String; let fetchedAt: String?; let events: [Event]
        struct Event: Decodable { let code: String; let date: String; let amountPerShare: String; let isEstimated: Bool?; let recordDate: String?; let payDate: String? }
    }

    static func fetchResearch(code: String, baseURL: String, session: URLSession = .shared) async throws -> NextNASResearch {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("research").appendingPathComponent(code)
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 研究记录暂不可用") }
        let report = try JSONDecoder().decode(NextNASResearch.self, from: data)
        guard report.ai.map({ $0.code == code && !$0.realOrder }) ?? true,
              report.factors.map({ $0.code == code }) ?? true else { throw NextError.invalid("NAS 研究记录与证券不符") }
        return report
    }

    static func fetchDaily(code: String, baseURL: String, session: URLSession = .shared) async throws -> NextChartDataset {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("daily").appendingPathComponent(code)
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 15))
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS 日 K 请求没有收到 HTTP 响应") }
        guard http.statusCode == 200 else {
            let reason = http.statusCode == 404 ? "NAS 服务没有日 K 接口，请更新 NAS 服务包" : http.statusCode == 503 ? "NAS 无缓存且上游日 K 数据源暂不可用" : "HTTP \(http.statusCode)"
            throw NextError.invalid("NAS 日 K 暂不可用：\(reason)")
        }
        let wire = try JSONDecoder().decode(DailyWire.self, from: data)
        guard wire.code == code, !wire.bars.isEmpty else { throw NextError.invalid("NAS 日 K 代码或数据无效") }
        let dayFormat = DateFormatter(); dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.timeZone = TimeZone(identifier: "Asia/Shanghai"); dayFormat.dateFormat = "yyyy-MM-dd"
        let samples = try wire.bars.map { row -> NextChartSample in
            guard let date = dayFormat.date(from: row.date), let open = Decimal(string: row.open),
                  let high = Decimal(string: row.high), let low = Decimal(string: row.low),
                  let close = Decimal(string: row.close), let volume = Decimal(string: row.volume),
                  low <= min(open, close), high >= max(open, close) else { throw NextError.invalid("NAS 日 K 数据校验失败") }
            return NextChartSample(timestamp: date, open: open, high: high, low: low, close: close, iopv: nil, volume: volume)
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observed = iso.date(from: wire.fetchedAt) ?? ISO8601DateFormatter().date(from: wire.fetchedAt) ?? Date()
        let dataset = NextChartDataset(code: code, interval: .day, samples: samples, costPerUnit: nil, costObservedAt: nil,
                                       priceSource: wire.source + " · 前复权", iopvSource: nil, observedAt: observed)
        try dataset.validate()
        return dataset
    }
    private struct DailyWire: Decodable { let code: String; let source: String; let fetchedAt: String; let bars: [DailyRow] }
    private struct DailyRow: Decodable { let date: String; let open: String; let high: String; let low: String; let close: String; let volume: String }

    static func fetchQuotes(codes: [String], baseURL: String, session: URLSession = .shared) async throws -> [NextQuote] {
        var components = URLComponents(url: try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("quotes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "codes", value: codes.joined(separator: ","))]
        let (data, response) = try await session.data(for: URLRequest(url: components.url!, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 行情读取失败；尝试直连行情源或使用本机缓存") }
        let payload = try JSONDecoder().decode(QuoteResponse.self, from: data)
        let values = try payload.quotes.map { try $0.quote() }
        guard values.count == codes.count, Set(values.map(\.code)) == Set(codes) else { throw NextError.invalid("NAS 行情代码集合与请求不一致") }
        return values
    }
    static func trackInstrument(code: String, baseURL: String, session: URLSession = .shared) async throws {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let data = try JSONSerialization.data(withJSONObject: ["mode": "track-confirmed"])
        var request = URLRequest(url: try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("track").appendingPathComponent(code), timeoutInterval: 10)
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 未能登记该证券的后台归档") }
    }
    private struct RemoteBook: Decodable { let revision: Int; let bookJSON: String? }
    private struct RevisionResponse: Decodable { let revision: Int }
    private struct QuoteResponse: Decodable { let quotes: [QuoteWire] }
    private struct QuoteWire: Decodable {
        let code: String; let name: String; let price: String; let previousClose: String
        let time: String; let source: String; let iopv: String?; let providerInstrumentType: String?
        func quote() throws -> NextQuote {
            guard let price = Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")), price > 0,
                  let previous = Decimal(string: previousClose, locale: Locale(identifier: "en_US_POSIX")), previous > 0,
                  !source.isEmpty, !name.isEmpty else { throw NextError.invalid("NAS 行情数值或来源无效") }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: time) ?? ISO8601DateFormatter().date(from: time)
            guard let date, date <= Date().addingTimeInterval(60) else { throw NextError.invalid("NAS 行情源时间无效或超前") }
            let parsedIOPV = iopv.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
            guard parsedIOPV.map({ $0 > 0 && providerInstrumentType == "ETF" }) ?? true else { throw NextError.invalid("NAS IOPV 与证券类别校验失败") }
            return NextQuote(code: code, name: name, price: price, previousClose: previous, time: date, source: source, iopv: parsedIOPV, providerInstrumentType: providerInstrumentType)
        }
    }
    private static func endpoint(_ baseURL: String) throws -> URL {
        try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("real").appendingPathComponent("books").appendingPathComponent("main")
    }
}
private extension NextBook { func validated() throws -> NextBook { try validate(); return self } }
