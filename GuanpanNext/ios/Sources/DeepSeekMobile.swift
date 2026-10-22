import Foundation
import Security

enum DeepSeekMobile {
    private static let service = "com.guanpan.next.ios.deepseek"
    private static let account = "api-key"

    static func loadKey() -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        query[kSecAttrSynchronizable as String] = false
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func saveKey(_ key: String) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw DeepSeekError.invalidKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(normalized.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeepSeekError.keychain(status) }
    }

    static func deleteKey() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeepSeekError.keychain(status) }
    }

    static func testConnection(key: String, profile: String, session: URLSession = .shared) async throws -> String {
        let model: String
        switch profile {
        case "flash": model = "deepseek-v4-flash"
        case "pro": model = "deepseek-v4-pro"
        default: throw DeepSeekError.invalidProfile
        }
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else { throw DeepSeekError.network }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw DeepSeekError.invalidKey }
        request.setValue("Bearer \(normalizedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "thinking": ["type": "disabled"],
            "max_tokens": 8,
            "messages": [["role": "user", "content": "Reply with OK only."]]
        ])
        _ = try await send(request, session: session)
        return model
    }

    static func analyze(prompt: String, key: String, profile: String, session: URLSession = .shared) async throws -> (model: String, content: String) {
        let model: String
        switch profile {
        case "flash": model = "deepseek-v4-flash"
        case "pro": model = "deepseek-v4-pro"
        default: throw DeepSeekError.invalidProfile
        }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw DeepSeekError.invalidKey }
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else { throw DeepSeekError.network }
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(normalizedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "thinking": ["type": "disabled"],
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": "你是观盘 Next 的谨慎投资研究员，不是涨跌预测器。分析任何标的都严格遵循三步：①先判断资产本身是否值得长期投资；②再判断当前价格与估值是否合适；③最后结合用户真实持仓、成本、仓位占比与现金需求，判断整个账户是否适合这笔交易。请覆盖七个维度：基本面与估值、技术趋势、资金与流动性、新闻与事件、宏观经济、组合适配性、交易执行条件。输出用中文，并严格按此结构：综合判断（持有/观察/分批买入/暂停加仓/减仓/退出）+ 主要理由 + 关键证据 + 主要风险 + 反方观点 + 数据缺口与置信度 + 失效条件与下次复核触发点。区分长期投资与短期机动交易，承认不确定性，不保证收益、不预测顶底、不把缺失数据当零、不编造 IOPV/费率/盘口，绝不自动下单。"],
                ["role": "user", "content": prompt]
            ]
        ])
        let content = try await send(request, session: session)
        return (model, content)
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> String {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DeepSeekError.network }
            guard http.statusCode == 200 else {
                switch http.statusCode {
                case 401, 403: throw DeepSeekError.unauthorized
                case 429: throw DeepSeekError.rateLimited
                case 500...599: throw DeepSeekError.serviceUnavailable
                default: throw DeepSeekError.http(http.statusCode)
                }
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeepSeekError.invalidResponse
            }
            return content
        } catch let error as DeepSeekError { throw error }
        catch { throw DeepSeekError.network }
    }
}

enum DeepSeekError: LocalizedError {
    case invalidKey, invalidProfile, unauthorized, rateLimited, serviceUnavailable, invalidResponse, network, http(Int), keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidKey: "请输入 DeepSeek API key。"
        case .invalidProfile: "请选择有效的 DeepSeek 模型。"
        case .unauthorized: "API key 无效或没有该模型权限。"
        case .rateLimited: "请求频率或账户额度受限，请检查 DeepSeek 账户。"
        case .serviceUnavailable: "DeepSeek 服务暂时不可用。"
        case .invalidResponse: "DeepSeek 返回格式无效。"
        case .network: "连接 DeepSeek 失败，请检查网络后重试。"
        case .http(let code): "DeepSeek 返回 HTTP \(code)。"
        case .keychain(let status): "iPhone 安全钥匙串保存失败（\(status)）。"
        }
    }
}
