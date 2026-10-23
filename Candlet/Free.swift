import Foundation

/// 免费行情：腾讯（A 股、港股，美股搜索）+ 新浪（美股报价，含盘前盘后）+ Yahoo（美股分时、K 线），
/// 都是非官方的公开接口，无需登录。没有推送，由 Store 在面板打开时轮询；没连接长桥或长桥不可用时使用
enum Free {
    struct Snapshot {
        let quote: Quote
        let marketCap: Double?
    }

    /// 腾讯、新浪各一次请求取回所有支持的股票
    static func quotes(_ symbols: Set<String>) async -> [String: Snapshot] {
        async let us = sina(symbols.filter { Market($0) == .us })
        var found: [String: Snapshot] = [:]
        // 港股要带 r_ 前缀，不带的是 15 分钟延迟行情
        let byWire = Dictionary(symbols.compactMap { symbol in
            tencent(symbol).map { (Market(symbol) == .hk ? "r_" + $0 : $0, symbol) }
        }) { first, _ in first }
        if !byWire.isEmpty, let url = URL(string: "https://qt.gtimg.cn/q=" + byWire.keys.sorted().joined(separator: ",")),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            // 每条形如 v_r_hk00700="100~腾讯控股~00700~393.800~410.400~…"; 名称是 GBK，这里只取数字字段
            for (symbol, f) in entries(data, prefix: "v_", byWire: byWire, separator: "~") {
                guard f.count > 45, let last = Double(f[3]), let prev = Double(f[4]), last > 0,
                      let time = date(String(f[30]), in: calendar(for: symbol)) else { continue }
                found[symbol] = Snapshot(quote: Quote(last: last, prevClose: prev, time: time, source: "腾讯"),
                                         marketCap: Double(f[45]).map { $0 * 1e8 })   // 总市值，单位亿
            }
        }
        return found.merging(await us) { $1 }
    }

    /// 当天的分时：A 股、港股用腾讯，美股用 Yahoo
    static func sparks(_ symbol: String) async -> [SparkPoint] {
        guard let wire = tencent(symbol) else { return await yahooSparks(symbol) }
        // web.ifzq.gtimg.cn 的分时接口会被腾讯防火墙拦截，换用 ifzq.gtimg.cn
        guard let day = await JSON.fetch(URL(string: "https://ifzq.gtimg.cn/appstock/app/minute/query?code=\(wire)"))?["data"]?[wire]?["data"]
        else { return [] }
        // 每个点形如 "0930 412.000 566848 …"；没给日期时按交易所当天算。
        // A 股还带 15:00 后的盘后固定价格交易，和长桥一样只画常规时段
        let calendar = calendar(for: symbol)
        let date = day["date"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? today(in: calendar)
        let close = Market(symbol) == .hk ? "9999" : "1500"
        return day["data"]?.list().compactMap { item in
            let f = item.string?.split(separator: " ") ?? []
            guard f.count > 1, f[0] <= close, let price = Double(f[1]),
                  let time = Self.date(date + f[0] + "00", in: calendar) else { return nil }
            return SparkPoint(time: time, price: price)
        } ?? []
    }

    /// 详情页的日、周、月、年 K 线：A 股、港股用腾讯，美股用 Yahoo
    static func candles(_ symbol: String, _ period: KPeriod) async -> [Candle] {
        guard let wire = tencent(symbol) else { return await yahooCandles(symbol, period) }
        // 腾讯的年 K 只有当年一根，改取月 K 按年合并
        let fetched = period == .year ? KPeriod.month : period
        let url = URL(string: "https://ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(wire),\(fetched.rawValue),,,\(Candle.loadCount),")
        guard let series = await JSON.fetch(url)?["data"]?[wire] else { return [] }
        // 每根形如 ["2026-10-21", 开, 收, 高, 低, 量]。和长桥一样不复权：前复权后分红多的股票早年价格接近 0 甚至为负，年 K 画不出来
        let calendar = calendar(for: symbol)
        let bars = series[fetched.rawValue]?.list().compactMap { bar -> Candle? in
            guard case .array(let f) = bar, f.count > 5, let day = f[0].string, let time = date(day + "000000", in: calendar),
                  let open = f[1].double, let close = f[2].double, let high = f[3].double, let low = f[4].double else { return nil }
            return Candle(time: time, open: open, high: high, low: low, close: close, volume: f[5].double ?? 0)
        } ?? []
        return period == .year ? bars.yearly(in: calendar) : bars
    }

    /// 按代码、名称或拼音搜 A 股、港股、美股（含 ETF）；没有长桥的证券目录时使用
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

    /// 美股：常规时段和盘前盘后一起返回。AAPL.US → gb_aapl，BRK.B.US → gb_brk$b；不带 Referer 会被拒
    private static func sina(_ symbols: Set<String>) async -> [String: Snapshot] {
        let byWire = Dictionary(symbols.map { ("gb_" + $0.dropLast(3).lowercased().replacing(".", with: "$"), $0) }) { first, _ in first }
        guard !byWire.isEmpty, let url = URL(string: "https://hq.sinajs.cn/list=" + byWire.keys.sorted().joined(separator: ",")) else { return [:] }
        var request = URLRequest(url: url)
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [:] }
        var found: [String: Snapshot] = [:]
        // 每条形如 var hq_str_gb_aapl="苹果,343.99,…"：1 最新价，12 总市值，21 盘前盘后价，24 盘前盘后时间，25 常规时段时间，26 昨收
        for (symbol, f) in entries(data, prefix: "var hq_str_", byWire: byWire, separator: ",") {
            guard f.count > 26, let last = Double(f[1]), let prev = Double(f[26]), last > 0, let time = sinaDate(f[25]) else { continue }
            var quote = Quote(last: last, prevClose: prev, time: time, source: "新浪")
            if let price = Double(f[21]), price > 0, let extTime = sinaDate(f[24]), extTime > time {
                // 新浪不分盘前盘后，按美东时间上午、下午区分；没有夜盘。
                // 盘前盘后价带 4 位小数（712.7933），1 美元以上按美股报价习惯取到分
                let session: Quote.Session = Calendar.newYork.component(.hour, from: extTime) < 12 ? .pre : .post
                let cents = price >= 1 ? (price * 100).rounded() / 100 : price
                quote.extended = .init(session: session, last: cents, prevClose: last, time: extTime)
            }
            found[symbol] = Snapshot(quote: quote, marketCap: Double(f[12]))
        }
        return found
    }

    /// 腾讯、新浪的报价都是一条一个 `前缀代码="字段…";`：按代码找回自选，拆出字段
    private static func entries(_ data: Data, prefix: String, byWire: [String: String], separator: Character) -> [(String, [Substring])] {
        String(decoding: data, as: UTF8.self).split(separator: ";").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.hasPrefix(prefix), let symbol = byWire[String(key.dropFirst(prefix.count))] else { return nil }
            return (symbol, parts[1].trimmingCharacters(in: .init(charactersIn: "\"\n ")).split(separator: separator, omittingEmptySubsequences: false))
        }
    }

    /// "Oct 21 07:59PM EDT" 不带年份：先按今年算，落到明天以后就是去年的
    private static func sinaDate(_ text: Substring) -> Date? {
        guard let parsed = sinaFormatter.date(from: String(text.dropLast(4))) else { return nil }
        let calendar = Calendar.newYork
        var components = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
        components.year = calendar.component(.year, from: .now)
        guard let date = calendar.date(from: components) else { return nil }
        return date > .now.addingTimeInterval(86_400) ? calendar.date(byAdding: .year, value: -1, to: date) : date
    }

    private static let sinaFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "MMM d hh:mma"
        return formatter
    }()

    /// 700.HK → hk00700，600519.SH → sh600519。腾讯只用于 A 股、港股：
    /// 美股收盘后分时只剩一个点、K 线要带交易所后缀，改用新浪和 Yahoo
    private static func tencent(_ symbol: String) -> String? {
        let code = symbol.prefix { $0 != "." }
        return switch Market(symbol) {
        case .hk: "hk" + String(repeating: "0", count: max(0, 5 - code.count)) + code
        case .sh: "sh" + code
        case .sz: "sz" + code
        default: nil
        }
    }

    /// Yahoo 图表接口：BRK.B.US → BRK-B
    private static func yahooChart(_ symbol: String, interval: String, range: String) async -> JSON? {
        let code = symbol.dropLast(3).replacing(".", with: "-")
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(code)?interval=\(interval)&range=\(range)")
        return await JSON.fetch(url, headers: yahooHeaders)?["chart"]?["result"]?.list().first
    }

    /// Yahoo 不带浏览器 UA 会被拒
    private static let yahooHeaders = ["User-Agent": "Mozilla/5.0"]

    /// 美股当天的 1 分钟分时
    private static func yahooSparks(_ symbol: String) async -> [SparkPoint] {
        guard let result = await yahooChart(symbol, interval: "1m", range: "1d") else { return [] }
        let times = result["timestamp"]?.list() ?? []
        let closes = result["indicators"]?["quote"]?.list().first?["close"]?.list() ?? []
        return zip(times, closes).compactMap { time, close in   // 没成交的分钟是 null
            time.date.flatMap { t in close.double.map { SparkPoint(time: t, price: $0) } }
        }
    }

    /// Yahoo 按时间范围取，日、周 K 约 250 根，月 K 约 120 根；没有年 K，取 50 年的月 K 按年合并
    /// （range=max 会自动换成季 K，按年合并时会串年）
    private static func yahooCandles(_ symbol: String, _ period: KPeriod) async -> [Candle] {
        let (interval, range) = switch period {
        case .day: ("1d", "1y")
        case .week: ("1wk", "5y")
        case .month: ("1mo", "10y")
        case .year: ("1mo", "50y")
        }
        guard let result = await yahooChart(symbol, interval: interval, range: range),
              let quote = result["indicators"]?["quote"]?.list().first else { return [] }
        // 当天那根还没收盘时收盘价是 null，用最新价补上，否则当日行情会停在前一天
        let latest = result["meta"]?["regularMarketPrice"]?.double
        let times = result["timestamp"]?.list() ?? []
        let (open, high, low, close, volume) = (quote["open"]?.list() ?? [], quote["high"]?.list() ?? [], quote["low"]?.list() ?? [],
                                                quote["close"]?.list() ?? [], quote["volume"]?.list() ?? [])
        guard [open, high, low, close, volume].allSatisfy({ $0.count == times.count }) else { return [] }
        var bars = times.indices.compactMap { i -> Candle? in   // 没成交的那根是 null
            guard let time = times[i].date, let o = open[i].double, let h = high[i].double, let l = low[i].double,
                  let c = close[i].double ?? (i == times.count - 1 ? latest : nil) else { return nil }
            return Candle(time: time, open: o, high: h, low: l, close: c, volume: volume[i].double ?? 0)
        }
        // 周 K、月 K 末尾还会多一根当前快照，落在上一根的周期里：并进那一根
        let calendar = calendar(for: symbol)
        if interval != "1d", bars.count > 1, let tail = bars.last,
           calendar.isDate(bars[bars.count - 2].time, equalTo: tail.time, toGranularity: interval == "1wk" ? .weekOfYear : .month) {
            bars.removeLast()
            let i = bars.count - 1
            (bars[i].high, bars[i].low, bars[i].close) = (max(bars[i].high, tail.high), min(bars[i].low, tail.low), tail.close)
        }
        return period == .year ? bars.yearly(in: calendar) : bars
    }

    /// 按交易所时区解析时间
    private static func calendar(for symbol: String) -> Calendar { Market(symbol)?.calendar ?? .shanghai }

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
