import Foundation

/// 全球指数看板：上证指数、纳斯达克100、日经225、韩国KOSPI、恒生科技。
///
/// ## 数据源口径（2026-10-20 实测，三源交叉验证过）
///
/// | 指数 | 采用 | 实测值 | 说明 |
/// |---|---|---|---|
/// | 上证指数 | 新浪 `s_sh000001` | 3727.75 | 与腾讯 `sh000001` 3726.56 一致（盘中时点差） |
/// | 日经225 | 新浪 `b_NKY` | 64056.28 -1.33% | `int_nikkei` 是陈旧错值，**禁用** |
/// | 韩国KOSPI | 新浪 `b_KOSPI` | 5522.80 -4.25% | 实时 |
/// | 恒生科技 | 新浪 `rt_hkHSTECH` | 4055.52 -1.21% | 实时 |
/// | 纳斯达克100 | 新浪 `gb_$ndx` | 29529.34 +1.17% | 与腾讯 `usNDX` 完全一致 |
///
/// 两个坑写在这里，防止以后又踩：
/// 1. **新浪 `b_NDX` 返回的是 2025-09-26 的陈旧值**（24503.85），不是纳指 100 的现值；
/// 2. **东财 `100.NDX` 的 26430.89 实际是纳斯达克综合指数**（与新浪 `gb_ixic` 完全相等），
///    拿它当纳指 100 会差 10% 以上。
///
/// 这几个源都只提供快照，没有分钟序列 —— 所以指数只做看板，不画分时，不伪造历史。
struct GlobalIndexQuote: Identifiable, Equatable {
    let symbol: String
    let name: String
    let price: Double
    let changePercent: Double
    let previousClose: Double?
    let observedAt: Date?
    let isStale: Bool
    var id: String { symbol }
}

enum GlobalIndexFeed {
    /// 固定 5 个，按用户指定顺序，不加不减。
    static let catalog: [(symbol: String, name: String, short: String)] = [
        ("s_sh000001", "上证指数", "上证"),
        ("gb_$ndx", "纳斯达克100", "纳指100"),
        ("b_NKY", "日经225", "日经"),
        ("b_KOSPI", "韩国KOSPI", "韩国"),
        ("rt_hkHSTECH", "恒生科技", "恒科")
    ]

    static let endpoint = "https://hq.sinajs.cn/list="

    static func displayName(_ symbol: String) -> String {
        catalog.first { $0.symbol == symbol }?.name ?? symbol
    }

    static func shortName(_ symbol: String) -> String {
        catalog.first { $0.symbol == symbol }?.short ?? symbol
    }

    /// 解析新浪的多行响应。只取数字字段，名称用本地目录 ——
    /// 新浪返回是 GB18030，取中文会冒乱码风险，而名称我们本来就固定。
    static func parse(_ body: String, now: Date = Date()) -> [GlobalIndexQuote] {
        var result: [GlobalIndexQuote] = []
        for line in body.split(separator: "\n") {
            let text = String(line)
            guard let keyStart = text.range(of: "hq_str_"),
                  let equals = text.range(of: "=\""),
                  let end = text.range(of: "\";") else { continue }
            let symbol = String(text[keyStart.upperBound..<equals.lowerBound])
            let payload = String(text[equals.upperBound..<end.lowerBound])
            let fields = payload.components(separatedBy: ",")
            guard fields.count >= 4 else { continue }
            guard let quote = parseFields(symbol: symbol, fields: fields, now: now) else { continue }
            result.append(quote)
        }
        // 按 catalog 顺序输出，源里缺哪个就少哪个，不补造。
        return catalog.compactMap { item in result.first { $0.symbol == item.symbol } }
    }

    private static func parseFields(symbol: String, fields: [String], now: Date) -> GlobalIndexQuote? {
        let name = displayName(symbol)
        func number(_ index: Int) -> Double? {
            guard fields.indices.contains(index) else { return nil }
            let text = fields[index].trimmingCharacters(in: .whitespaces)
            guard let value = Double(text), value.isFinite else { return nil }
            return value
        }
        var price: Double?
        var changePercent: Double?
        var previousClose: Double?
        var stamp: Date?

        if symbol.hasPrefix("gb_") {
            // 名称, 现价, 涨跌幅%, 时间, 涨跌额, ...
            price = number(1)
            changePercent = number(2)
            stamp = date(from: fields.indices.contains(3) ? fields[3] : "", formats: ["yyyy-MM-dd HH:mm:ss"])
        } else if symbol.hasPrefix("rt_hk") {
            // 代码, 名称, 今开, 昨收, 最高, 最低, 现价, 涨跌, 涨跌%, ..., 日期, 时间
            previousClose = number(3)
            price = number(6)
            changePercent = number(8)
            if fields.count >= 18 {
                stamp = date(from: "\(fields[16]) \(fields[17])", formats: ["yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"])
            }
        } else if symbol.hasPrefix("b_") {
            // 名称, 现价, 涨跌, 涨跌%, 上下午标记, 时间, 日期, ...
            price = number(1)
            changePercent = number(3)
            if fields.count >= 7 {
                stamp = date(from: "\(fields[6]) \(fields[5])", formats: ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"])
            }
        } else {
            // s_ 前缀：名称, 现价, 涨跌, 涨跌%, 成交量, 成交额 —— 不带时点
            price = number(1)
            changePercent = number(3)
        }
        guard let price, price > 0 else { return nil }
        // 陈旧判定：美股/港股收盘价可能隔夜，给 96 小时宽限；超过就标注陈旧。
        let stale = stamp.map { now.timeIntervalSince($0) > 96 * 3600 } ?? false
        return GlobalIndexQuote(symbol: symbol, name: name, price: price,
                                changePercent: changePercent ?? 0,
                                previousClose: previousClose, observedAt: stamp, isStale: stale)
    }

    private static func date(from text: String, formats: [String]) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for format in formats {
            formatter.dateFormat = format
            if let value = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return value }
        }
        return nil
    }

    /// 拉取一次快照。新浪要求带 Referer，否则返回空。
    static func fetch(session: URLSession = .shared) async throws -> [GlobalIndexQuote] {
        let list = catalog.map { $0.symbol }.joined(separator: ",")
        guard let url = URL(string: endpoint + list) else { throw NextError.invalid("指数行情地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("https://finance.sina.com.cn/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NextError.invalid("指数行情源返回异常（\((response as? HTTPURLResponse).map { String($0.statusCode) } ?? "无响应")）")
        }
        // 只解析数字字段，中文名称用本地目录，所以按 UTF-8 宽松解码即可。
        let body = String(decoding: data, as: UTF8.self)
        let quotes = parse(body)
        guard !quotes.isEmpty else { throw NextError.invalid("指数行情源没有返回可解析的数据") }
        return quotes
    }
}
