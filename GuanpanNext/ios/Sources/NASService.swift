import Foundation

struct NextNASStatus {
    let revision: Int
    let hasBook: Bool
    let book: NextBook?
}

enum NextNASService {
    static func validateURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")),
              url.host != nil, url.path.isEmpty || url.path == "/", url.query == nil, url.user == nil, url.password == nil else {
            throw NextError.invalid("请输入 NAS 的 HTTPS 根地址；本机调试可用 localhost")
        }
        return url
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 日 K 暂不可用，请稍后重试") }
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
