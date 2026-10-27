import Foundation

// MARK: - JSON

/// longbridge serve 返回的是原始 OpenAPI 结构，用一个宽松的 JSON 类型按需取值即可
nonisolated enum JSON: Sendable, Codable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): if let i = Int(exactly: v) { try c.encode(i) } else { try c.encode(v) }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { o[key] } else { nil }
    }

    var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): Int(exactly: n).map(String.init) ?? String(n)
        default: nil
        }
    }

    /// 价格以字符串传输（"448.600"）
    var double: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }

    /// 非整数或越界时返回 nil，避免 Int() 崩溃
    var int: Int? { double.flatMap { Int(exactly: $0) } }

    /// 秒级时间戳或 ISO 8601 字符串
    var date: Date? {
        if let n = double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        if let s = string { return try? Date(s, strategy: .iso8601) }
        return nil
    }

    /// 结果可能直接是数组，也可能包在某个 key 里
    func list(_ keys: String...) -> [JSON] {
        if case .array(let a) = self { return a }
        for key in keys { if case .array(let a)? = self[key] { return a } }
        return []
    }

    static func strings(_ values: some Sequence<String>) -> JSON { .array(values.sorted().map(JSON.string)) }
}

nonisolated extension JSON: ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(.init(uniqueKeysWithValues: elements)) }
}

nonisolated extension JSON {
    /// GET 一个 JSON 接口，在后台解码；网络或格式出错时返回 nil
    @concurrent
    static func fetch(_ url: URL?, headers: [String: String] = [:]) async -> JSON? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(JSON.self, from: data)
    }
}

// MARK: - 自选

nonisolated struct Stock: Identifiable, Equatable, Codable, Sendable {
    let symbol: String   // 700.HK / AAPL.US / 600660.SH / BTC/USDT
    var name: String
    /// 用户起的名字；可选字段，旧数据里没有也能解码
    var alias: String?
    var id: String { symbol }

    var displayName: String { alias ?? name }

    var code: String { Self.code(symbol) }
    /// 去掉市场后缀：700.HK → 700，BRK.B.US → BRK.B
    static func code(_ symbol: String) -> String { String(symbol[..<(symbol.lastIndex(of: ".") ?? symbol.endIndex)]) }

    var isCrypto: Bool { Self.isCrypto(symbol) }
    static func isCrypto(_ symbol: String) -> Bool { symbol.contains("/") }

    var market: Market? { Market(symbol) }

    /// 名称下面那行：700 · 港股
    var subtitle: String { [code, market?.name].compactMap { $0 }.joined(separator: " · ") }
}

/// 市场由代码后缀决定（700.HK / AAPL.US / 600660.SH / 000001.SZ），加密货币是交易对（BTC/USDT）。
/// 各市场的差异都集中在这里
nonisolated enum Market: Sendable {
    case hk, us, sh, sz, crypto

    init?(_ symbol: String) {
        if Stock.isCrypto(symbol) { self = .crypto; return }
        switch symbol.split(separator: ".").last {
        case "HK": self = .hk
        case "US": self = .us
        case "SH": self = .sh
        case "SZ": self = .sz
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .hk: "港股"
        case .us: "美股"
        case .sh: "沪市"
        case .sz: "深市"
        case .crypto: "加密"
        }
    }

    /// 市值的币种符号；加密货币没有市值
    var currency: String? {
        switch self {
        case .hk: "HK$"
        case .us: "$"
        case .sh, .sz: "¥"
        case .crypto: nil
        }
    }

    /// 加密货币分时：最近 24 小时的 5 分钟 K 线
    static let cryptoSlots = 288

    /// 分时图横轴的总点数：股票为常规时段每天的分钟数（每分钟一个点，不含午休）
    var sparkSlots: Int {
        switch self {
        case .us: 390       // 9:30–16:00
        case .hk: 330       // 9:30–12:00, 13:00–16:00
        case .sh, .sz: 240  // 9:30–11:30, 13:00–15:00
        case .crypto: Self.cryptoSlots
        }
    }

    /// 常规时段的开盘、收盘时间（交易所当地时间），标在详情页分时图下方；加密货币全天交易，没有
    var session: (open: String, close: String)? {
        switch self {
        case .us, .hk: ("09:30", "16:00")
        case .sh, .sz: ("09:30", "15:00")
        case .crypto: nil
        }
    }

    /// 交易所时区的公历，免费行情按它解析时间、合并年 K；Binance 按 UTC 划分
    var calendar: Calendar {
        switch self {
        case .us: .newYork
        case .hk: .hongKong
        case .sh, .sz: .shanghai
        case .crypto: .utc
        }
    }
}

/// 自选由若干分组组成，默认只有一个
nonisolated struct StockGroup: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var name: String
    var stocks: [Stock] = []
}

// MARK: - 搜索

/// 证券目录里的一条。代码、名称、英文名转成小写后存进同一块字节数组，几万条只占很少内存，匹配时只做字节比较
nonisolated struct SearchEntry: Sendable {
    let stock: Stock
    private let text: [UInt8]          // 代码 \0 名称 \0 英文名
    private let name: Range<Int>

    init(symbol: String, name: String, english: String = "") {
        stock = Stock(symbol: symbol, name: name)
        let code = Array(stock.code.lowercased().utf8)
        let lowered = Array(name.lowercased().utf8)
        let english = Array(english.lowercased().utf8)
        text = code + [0] + lowered + [0] + (english == lowered ? [] : english)
        self.name = code.count + 1 ..< code.count + 1 + lowered.count
    }

    /// 越小越靠前：代码相同 > 代码前缀 > 名称前缀 > 名称包含 > 名称按顺序包含这些字（福玻 → 福耀玻璃）
    func score(_ query: Query) -> Int? {
        let code = text[..<(name.lowerBound - 1)], name = text[name], english = text[(self.name.upperBound + 1)...]
        let q = query.bytes
        if code.elementsEqual(q) { return 0 }
        if code.starts(with: q) { return 1 }
        if name.starts(with: q) || english.starts(with: q) { return 2 }
        if Self.find(q, in: name) != nil || Self.find(q, in: english) != nil { return 3 }
        // 逐字查找；UTF-8 里完整字符的字节只会从字符边界开始匹配
        var rest = name
        for character in query.characters {
            guard let found = Self.find(character, in: rest) else { return nil }
            rest = rest[(found + character.count)...]
        }
        return 4
    }

    struct Query {
        let bytes: [UInt8]
        let characters: [[UInt8]]
        init(_ text: String) { (bytes, characters) = (Array(text.utf8), text.unicodeScalars.map { Array(String($0).utf8) }) }
    }

    private static func find(_ part: [UInt8], in text: ArraySlice<UInt8>) -> Int? {
        guard let first = part.first, part.count <= text.count else { return nil }
        for i in text.startIndex...(text.endIndex - part.count) where text[i] == first && text[i..<i + part.count].elementsEqual(part) {
            return i
        }
        return nil
    }
}

// MARK: - 报价

/// 常规时段价格，外加最近一次延长时段（盘前 / 盘后 / 夜盘）的价格
nonisolated struct Quote: Sendable, Equatable {
    var last: Double
    /// 昨收，也是分时图的虚线
    var prevClose: Double
    var time: Date
    var extended: Extended?
    /// 数据来源，显示在详情页右上角：长桥、腾讯、新浪、Yahoo、Binance
    var source: String
    /// 加密货币的 24 小时滚动开高低量，和涨跌幅同一口径；股票为 nil，详情页改取当天日 K
    var rolling: Candle?

    enum Session: Sendable {
        case pre, post, overnight

        /// 推送里的 trade_session；常规时段返回 nil
        init?(_ raw: String?) {
            switch raw?.lowercased() {
            case let s? where s.hasPrefix("pre"): self = .pre
            case let s? where s.hasPrefix("post"): self = .post
            case let s? where s.hasPrefix("over") || s.hasPrefix("night"): self = .overnight
            default: return nil
            }
        }

        var icon: String {
            switch self {
            case .pre: "sunrise"
            case .post: "sunset"
            case .overnight: "moon"
            }
        }

        /// 图标的悬停提示与读屏文字
        var name: String {
            switch self {
            case .pre: "盘前"
            case .post: "盘后"
            case .overnight: "夜盘"
            }
        }
    }

    struct Extended: Sendable, Equatable {
        var session: Session
        var last: Double
        var prevClose: Double
        var time: Date
        var change: Double { Quote.change(from: prevClose, to: last) }
    }

    var change: Double { Self.change(from: prevClose, to: last) }

    /// 涨跌幅；没有参照价时算作 0
    static func change(from prevClose: Double, to last: Double) -> Double { prevClose == 0 ? 0 : last / prevClose - 1 }

    /// 比常规时段更新的延长时段成交，用于第二行显示
    var latestExtended: Extended? { extended.flatMap { $0.time > time ? $0 : nil } }

    /// 只有常规时段价格，用于免费行情
    init(last: Double, prevClose: Double, time: Date, source: String) {
        (self.last, self.prevClose, self.time, extended, self.source) = (last, prevClose, time, nil, source)
    }

    /// 加密货币：Binance miniTicker 推送，涨跌相对 24 小时前的开盘价
    init?(miniTicker j: JSON) {
        guard let last = j["c"]?.double, let open = j["o"]?.double, let time = j["E"]?.date else { return nil }
        self.init(last: last, prevClose: open, time: time, source: "Binance")
        if let high = j["h"]?.double, let low = j["l"]?.double {
            rolling = Candle(time: time, open: open, high: high, low: low, close: last, volume: j["v"]?.double ?? 0)
        }
    }

    init?(snapshot j: JSON) {
        guard let last = j["last_done"]?.double else { return nil }
        self.last = last
        prevClose = j["prev_close"]?.double ?? last
        time = j["timestamp"]?.date ?? .distantPast
        source = "长桥"
        extended = [(Session.pre, j["pre_market_quote"]), (.post, j["post_market_quote"]), (.overnight, j["overnight_quote"] ?? j["over_night_quote"])]
            .compactMap { session, leg in
                guard let leg, let price = leg["last_done"]?.double, let time = leg["timestamp"]?.date else { return nil }
                return Extended(session: session, last: price, prevClose: leg["prev_close"]?.double ?? last, time: time)
            }
            .max { $0.time < $1.time }
    }

    /// 合并一条 quote.updated 推送；返回 true 表示进入了新时段，需要重新拉快照校正昨收
    mutating func apply(_ tick: JSON) -> Bool {
        guard let price = tick["last_done"]?.double else { return false }
        let tickTime = tick["timestamp"]?.date ?? .now
        guard let session = Session(tick["trade_session"]?.string) else {
            guard tickTime >= time else { return false }   // 推送可能比快照旧
            let resumed = latestExtended != nil            // 从延长时段回到常规时段，说明是新的交易日
            (last, time) = (price, tickTime)
            return resumed
        }
        if var current = extended, current.session == session {
            guard tickTime >= current.time else { return false }
            (current.last, current.time) = (price, tickTime)
            extended = current
            return false
        }
        // 进入新的延长时段：先以常规收盘为参照，再由快照校正
        extended = Extended(session: session, last: price, prevClose: last, time: tickTime)
        return true
    }
}

nonisolated struct SparkPoint: Equatable, Sendable {
    var time: Date
    var price: Double
}

// MARK: - K 线

nonisolated extension Calendar {
    /// 公历 + UTC：Binance 的 K 线按 UTC 划分，分时跨日也按 UTC 判断
    static let utc = gregorian(.gmt)
    static let newYork = gregorian(TimeZone(identifier: "America/New_York")!)
    static let hongKong = gregorian(TimeZone(identifier: "Asia/Hong_Kong")!)
    static let shanghai = gregorian(TimeZone(identifier: "Asia/Shanghai")!)

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

nonisolated enum KPeriod: String, CaseIterable, Sendable {
    case day, week, month, year

    var title: String {
        switch self {
        case .day: "日K"
        case .week: "周K"
        case .month: "月K"
        case .year: "年K"
        }
    }
}

nonisolated struct Candle: Sendable, Equatable {
    var time: Date
    var open, high, low, close, volume: Double

    /// 详情页每个周期加载的根数，图上显示其中一段，拖动翻看
    static let loadCount = 200
}

nonisolated extension [Candle] {
    /// 把月 K 按年合并成年 K，供没有年 K 的数据源使用；calendar 用交易所时区，月初、月末的时间不会算到相邻年份
    func yearly(in calendar: Calendar) -> [Candle] {
        var years: [Candle] = []
        for bar in self {
            guard var year = years.last, calendar.isDate(year.time, equalTo: bar.time, toGranularity: .year) else {
                years.append(bar)
                continue
            }
            (year.high, year.low, year.close) = (Swift.max(year.high, bar.high), Swift.min(year.low, bar.low), bar.close)
            year.volume += bar.volume
            years[years.count - 1] = year
        }
        return years
    }
}

nonisolated extension Candle {
    /// 长桥 quote.candlesticks 的一根
    init?(json j: JSON) {
        guard let time = j["timestamp"]?.date, let open = j["open"]?.double, let high = j["high"]?.double,
              let low = j["low"]?.double, let close = j["close"]?.double else { return nil }
        self.init(time: time, open: open, high: high, low: low, close: close, volume: j["volume"]?.double ?? 0)
    }
}
