import Foundation
import Security

enum NextCredentialStore {
    private static let service = "com.guanpan.next.ios"
    private static let account = "nas-token-v1"
    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw NextError.invalid("NAS 凭据无法保存到系统钥匙串（\(result)）") }
        } else if status != errSecSuccess { throw NextError.invalid("NAS 凭据无法更新到系统钥匙串（\(status)）") }
    }
    static func load() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw NextError.invalid("请先保存 NAS 访问口令") }
        return value
    }
}

struct NextNASStatus {
    let revision: Int
    let hasBook: Bool
}

enum NextNASService {
    static func validateURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")),
              url.host != nil, url.path.isEmpty || url.path == "/", url.query == nil, url.user == nil, url.password == nil else {
            throw NextError.invalid("请输入不含口令、查询参数或路径的 NAS 根地址")
        }
        return url
    }

    static func readStatus(baseURL: String, token: String, session: URLSession = .shared) async throws -> NextNASStatus {
        let url = try endpoint(baseURL)
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS 没有返回 HTTP 状态") }
        guard http.statusCode == 200 else { throw NextError.invalid(http.statusCode == 401 ? "NAS 访问口令无效" : "NAS 状态读取失败（HTTP \(http.statusCode)）") }
        let value = try JSONDecoder().decode(RemoteBook.self, from: data)
        if let json = value.bookJSON { _ = try JSONDecoder().decode(NextBook.self, from: Data(json.utf8)).validated() }
        return NextNASStatus(revision: value.revision, hasBook: value.bookJSON != nil)
    }

    static func pushBook(_ book: NextBook, expectedRevision: Int, baseURL: String, token: String, session: URLSession = .shared) async throws -> Int {
        let url = try endpoint(baseURL)
        let bookData = try JSONEncoder().encode(book)
        let bookJSON = String(decoding: bookData, as: UTF8.self)
        let body = try JSONSerialization.data(withJSONObject: ["mode": "manual-confirmed", "expectedRevision": expectedRevision, "bookJSON": bookJSON])
        var request = URLRequest(url: url, timeoutInterval: 15); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS 没有返回 HTTP 状态") }
        if http.statusCode == 409 { throw NextError.invalid("NAS 账本版本已变化；没有覆盖任何数据。请检查服务端版本并重新比较。") }
        guard http.statusCode == 200 else { throw NextError.invalid("NAS 保存失败（HTTP \(http.statusCode)），本机账本未修改") }
        return try JSONDecoder().decode(RevisionResponse.self, from: data).revision
    }

    static func fetchQuotes(codes: [String], baseURL: String, token: String, session: URLSession = .shared) async throws -> [NextQuote] {
        var components = URLComponents(url: try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("quotes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "codes", value: codes.joined(separator: ","))]
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 行情读取失败；尝试直连行情源或使用本机缓存") }
        let payload = try JSONDecoder().decode(QuoteResponse.self, from: data)
        let values = try payload.quotes.map { try $0.quote() }
        guard values.count == codes.count, Set(values.map(\.code)) == Set(codes) else { throw NextError.invalid("NAS 行情代码集合与请求不一致") }
        return values
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
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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

private extension NextBook {
    func validated() throws -> NextBook { try validate(); return self }
}
