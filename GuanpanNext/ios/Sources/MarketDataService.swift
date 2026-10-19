import Foundation

/// Internet quotes are optional: the app remains usable from its local cache.
/// This provider only returns parsed quote fields; it does not infer ETF rules,
/// IOPV, order-book depth, or executable prices.
enum NextMarketDataService {
    static func fetchQuotes(codes: [String], session: URLSession = .shared) async throws -> [NextQuote] {
        let symbols = codes.compactMap(NextTencentQuoteParser.symbol(for:))
        guard !symbols.isEmpty, symbols.count == codes.count else { throw NextError.invalid("证券代码无效或交易所来源尚未支持") }
        let url = URL(string: "https://qt.gtimg.cn/q=\(symbols.joined(separator: ","))&_t=\(Int(Date().timeIntervalSince1970))")!
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NextError.invalid("行情服务暂不可用") }
        let receivedAt = Date()
        let quotes = codes.compactMap { NextTencentQuoteParser.parse(data, code: $0, receivedAt: receivedAt) }
        guard !quotes.isEmpty else { throw NextError.invalid("行情响应未通过代码、价格或时间校验") }
        return quotes
    }

    static func fetchIntraday(code: String, session: URLSession = .shared) async throws -> NextChartDataset {
        guard let symbol = NextTencentQuoteParser.symbol(for: code),
              var components = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query") else {
            throw NextError.invalid("证券代码无效")
        }
        components.queryItems = [URLQueryItem(name: "code", value: symbol), URLQueryItem(name: "_var", value: "min_data_\(symbol)")]
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let chart = NextTencentMinuteParser.parse(data, code: code) else {
            throw NextError.invalid("分时数据没有通过响应、时间或价格校验")
        }
        return chart
    }
}
