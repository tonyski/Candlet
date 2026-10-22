import Foundation

/// 免费延迟行情：腾讯（A 股、港股、美股）+ Yahoo（新加坡），都是非官方的公开接口，无需登录。
/// 没有推送，由 Store 在面板打开时轮询；长桥不可用或用户手动选择时才用
enum Free {
    struct Snapshot {
        let quote: Quote
        let marketCap: Double?
    }

    /// 腾讯一次请求取回所有支持的股票；新加坡股逐只问 Yahoo
    static func quotes(_ symbols: Set<String>) async -> [String: Snapshot] {
        var found: [String: Snapshot] = [:]
        let byWire = Dictionary(symbols.compactMap { symbol in tencent(symbol).map { ($0, symbol) } }) { first, _ in first }
        if !byWire.isEmpty, let url = URL(string: "https://qt.gtimg.cn/q=" + byWire.keys.sorted().joined(separator: ",")),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            // 每条形如 v_hk00700="100~腾讯控股~00700~393.800~410.400~…"; 名称是 GBK，这里只取数字字段
            for line in String(decoding: data, as: UTF8.self).split(separator: ";") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let wire = parts[0].split(separator: "_").last.map(String.init),
                      let symbol = byWire[wire] else { continue }
                let f = parts[1].trimmingCharacters(in: .init(charactersIn: "\"\n ")).split(separator: "~", omittingEmptySubsequences: false)
                guard f.count > 45, let last = Double(f[3]), let prev = Double(f[4]), last > 0,
                      let time = date(String(f[30]), in: calendar(for: symbol)) else { continue }
                found[symbol] = Snapshot(quote: Quote(last: last, prevClose: prev, time: time),
                                         marketCap: Double(f[45]).map { $0 * 1e8 })   // 总市值，单位亿
            }
        }
        for symbol in symbols where symbol.hasSuffix(".SG") {
            if let (snapshot, _) = await yahoo(symbol) { found[symbol] = snapshot }
        }
        return found
    }

    /// 当天的分时
    static func sparks(_ symbol: String) async -> [SparkPoint] {
        if symbol.hasSuffix(".SG") { return await yahoo(symbol)?.1 ?? [] }
        guard let wire = tencent(symbol),
              let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(wire)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let day = (try? JSONDecoder().decode(JSON.self, from: data))?["data"]?[wire]?["data"] else { return [] }
        // 每个点形如 "0930 412.000 566848 …"；没给日期时按交易所当天算。
        // A 股还带 15:00 后的盘后固定价格交易，和长桥一样只画常规时段
        let calendar = calendar(for: symbol)
        let date = day["date"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? today(in: calendar)
        let close = symbol.hasSuffix(".SH") || symbol.hasSuffix(".SZ") ? "1500" : "9999"
        return day["data"]?.list().compactMap { item in
            let f = item.string?.split(separator: " ") ?? []
            guard f.count > 1, f[0] <= close, let price = Double(f[1]),
                  let time = Self.date(date + f[0] + "00", in: calendar) else { return nil }
            return SparkPoint(time: time, price: price)
        } ?? []
    }

    /// 详情页的日、周、月 K 线：A 股、港股用腾讯；美股用 Yahoo（腾讯的美股 K 线要带交易所后缀，而代码里没有），新加坡股也是
    static func candles(_ symbol: String, _ period: KPeriod) async -> [Candle] {
        guard let wire = tencent(symbol), !symbol.hasSuffix(".US") else { return await yahooCandles(symbol, period) }
        guard let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(wire),\(period.rawValue),,,\(Candle.loadCount),qfq"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let series = (try? JSONDecoder().decode(JSON.self, from: data))?["data"]?[wire] else { return [] }
        // 每根形如 ["2026-10-21", 开, 收, 高, 低, 量]；前复权的键名带 qfq 前缀，港股没有
        let calendar = calendar(for: symbol)
        return (series["qfq" + period.rawValue] ?? series[period.rawValue])?.list().compactMap { bar in
            guard case .array(let f) = bar, f.count > 5, let day = f[0].string, let time = date(day + "000000", in: calendar),
                  let open = f[1].double, let close = f[2].double, let high = f[3].double, let low = f[4].double else { return nil }
            return Candle(time: time, open: open, high: high, low: low, close: close, volume: f[5].double ?? 0)
        } ?? []
    }

    /// 按代码、名称或拼音搜 A 股、港股、美股（含 ETF），没有长桥的证券目录时使用
    static func search(_ query: String) async -> [Stock] {
        var components = URLComponents(string: "https://smartbox.gtimg.cn/s3/")!
        components.queryItems = [.init(name: "v", value: "2"), .init(name: "q", value: query), .init(name: "t", value: "all")]
        guard let url = components.url, let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        // v_hint="sh~600519~贵…~gzmt~GP-A^hk~00700~…"：名称是 \u 转义，借 JSON 解码还原
        let raw = String(decoding: data, as: UTF8.self).split(separator: "\"", omittingEmptySubsequences: false)
        guard raw.count > 1, let text = try? JSONDecoder().decode(String.self, from: Data("\"\(raw[1])\"".utf8)) else { return [] }
        return text.split(separator: "^").compactMap { item in
            let f = item.split(separator: "~", omittingEmptySubsequences: false)
            guard f.count > 4, f[4].hasPrefix("GP") || f[4].contains("ETF") else { return nil }   // 跳过基金、指数
            let code = String(f[1]), name = String(f[2])
            switch f[0] {
            case "sh", "sz": return Stock(symbol: "\(code).\(f[0].uppercased())", name: name)
            case "hk":
                let trimmed = String(code.drop { $0 == "0" })
                // 5 位港股代码是窝轮、牛熊证和人民币柜台，和长桥目录的过滤一致
                return trimmed.count < 5 ? Stock(symbol: "\(trimmed).HK", name: name) : nil
            case "us":   // aapl.oq、brk.b.n：只去掉最后一段交易所后缀
                let base = code.lastIndex(of: ".").map { code[..<$0] } ?? Substring(code)
                return Stock(symbol: "\(base.uppercased()).US", name: name)
            default: return nil
            }
        }
    }

    // MARK: - 内部

    /// 700.HK → hk00700，AAPL.US → usAAPL，600519.SH → sh600519；新加坡股腾讯没有
    private static func tencent(_ symbol: String) -> String? {
        guard let dot = symbol.lastIndex(of: ".") else { return nil }
        let code = symbol[..<dot]
        return switch symbol[symbol.index(after: dot)...] {
        case "HK": "hk" + String(repeating: "0", count: max(0, 5 - code.count)) + code
        case "US": "us" + code
        case "SH": "sh" + code
        case "SZ": "sz" + code
        default: nil
        }
    }

    /// Yahoo 图表接口：D05.SG → D05.SI，BRK.B.US → BRK-B；不带浏览器 UA 会被拒
    private static func yahooChart(_ symbol: String, interval: String, range: String) async -> JSON? {
        let code = symbol.hasSuffix(".SG") ? symbol.dropLast(3) + ".SI" : symbol.dropLast(3).replacing(".", with: "-")
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(code)?interval=\(interval)&range=\(range)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONDecoder().decode(JSON.self, from: data))?["chart"]?["result"]?.list().first
    }

    /// 新加坡股：一次返回报价和当天分时
    private static func yahoo(_ symbol: String) async -> (Snapshot, [SparkPoint])? {
        guard let result = await yahooChart(symbol, interval: "1m", range: "1d"),
              let meta = result["meta"], let last = meta["regularMarketPrice"]?.double,
              let prev = meta["chartPreviousClose"]?.double ?? meta["previousClose"]?.double,
              let time = meta["regularMarketTime"]?.date else { return nil }
        let times = result["timestamp"]?.list() ?? []
        let closes = result["indicators"]?["quote"]?.list().first?["close"]?.list() ?? []
        let points = zip(times, closes).compactMap { time, close in   // 没成交的分钟是 null
            time.date.flatMap { t in close.double.map { SparkPoint(time: t, price: $0) } }
        }
        return (Snapshot(quote: Quote(last: last, prevClose: prev, time: time), marketCap: nil), points)
    }

    /// Yahoo 按时间范围取，日、周 K 约 250 根，月 K 约 120 根
    private static func yahooCandles(_ symbol: String, _ period: KPeriod) async -> [Candle] {
        let (interval, range) = switch period {
        case .day: ("1d", "1y")
        case .week: ("1wk", "5y")
        case .month: ("1mo", "10y")
        }
        guard let result = await yahooChart(symbol, interval: interval, range: range),
              let quote = result["indicators"]?["quote"]?.list().first else { return [] }
        let times = result["timestamp"]?.list() ?? []
        let (open, high, low, close, volume) = (quote["open"]?.list() ?? [], quote["high"]?.list() ?? [], quote["low"]?.list() ?? [],
                                                quote["close"]?.list() ?? [], quote["volume"]?.list() ?? [])
        guard [open, high, low, close, volume].allSatisfy({ $0.count == times.count }) else { return [] }
        return times.indices.compactMap { i in   // 没成交的那根是 null
            guard let time = times[i].date, let o = open[i].double, let h = high[i].double,
                  let l = low[i].double, let c = close[i].double else { return nil }
            return Candle(time: time, open: o, high: h, low: l, close: c, volume: volume[i].double ?? 0)
        }
    }

    /// 按交易所时区解析时间：美股纽约，港股香港，其余上海
    private static func calendar(for symbol: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: symbol.hasSuffix(".US") ? "America/New_York" : symbol.hasSuffix(".HK") ? "Asia/Hong_Kong" : "Asia/Shanghai")!
        return calendar
    }

    /// "2026/10/21 16:08:21"、"2026-10-20 16:00:01"、"20261021161453" 都取出 14 位数字再解析
    private static func date(_ text: String, in calendar: Calendar) -> Date? {
        let digits = Array(text.filter(\.isNumber))
        guard digits.count >= 14 else { return nil }
        func part(_ range: Range<Int>) -> Int? { Int(String(digits[range])) }
        return calendar.date(from: DateComponents(year: part(0..<4), month: part(4..<6), day: part(6..<8),
                                                  hour: part(8..<10), minute: part(10..<12), second: part(12..<14)))
    }

    private static func today(in calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
