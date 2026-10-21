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

// MARK: - 自选

nonisolated struct Stock: Identifiable, Equatable, Codable, Sendable {
    let symbol: String   // 700.HK / AAPL.US / 600660.SH / BTC/USDT
    var name: String
    var id: String { symbol }

    var code: String { String(symbol[..<(symbol.lastIndex(of: ".") ?? symbol.endIndex)]) }

    var isCrypto: Bool { Self.isCrypto(symbol) }
    static func isCrypto(_ symbol: String) -> Bool { symbol.contains("/") }

    var market: String? {
        if isCrypto { return "加密" }
        return switch symbol.split(separator: ".").last {
        case "HK": "港股"
        case "US": "美股"
        case "SH": "沪市"
        case "SZ": "深市"
        case "SG": "新加坡"
        default: nil
        }
    }

    /// 加密货币分时：最近 24 小时的 5 分钟 K 线
    static let cryptoSlots = 288

    /// 分时图横轴的总点数：股票为常规时段每天的分钟数（每分钟一个点，不含午休）
    var sparkSlots: Int {
        if isCrypto { return Self.cryptoSlots }
        return switch symbol.split(separator: ".").last {
        case "US": 390     // 9:30–16:00
        case "HK": 330     // 9:30–12:00, 13:00–16:00
        case "SG": 420     // 9:00–12:00, 13:00–17:00
        default: 240       // A 股 9:30–11:30, 13:00–15:00
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

    struct Extended: Sendable, Equatable {
        var label: String          // 前 / 后 / 夜
        var last: Double
        var prevClose: Double
        var time: Date
        var change: Double { prevClose == 0 ? 0 : last / prevClose - 1 }
    }

    var change: Double { prevClose == 0 ? 0 : last / prevClose - 1 }

    /// 比常规时段更新的延长时段成交，用于第二行显示
    var latestExtended: Extended? { extended.flatMap { $0.time > time ? $0 : nil } }

    /// 加密货币：相对 24 小时前的开盘价
    init?(last: Double?, open: Double?, time: Date?) {
        guard let last, let open, let time else { return nil }
        (self.last, prevClose, self.time, extended) = (last, open, time, nil)
    }

    init?(snapshot j: JSON) {
        guard let last = j["last_done"]?.double else { return nil }
        self.last = last
        prevClose = j["prev_close"]?.double ?? last
        time = j["timestamp"]?.date ?? .distantPast
        extended = [("前", j["pre_market_quote"]), ("后", j["post_market_quote"]), ("夜", j["overnight_quote"] ?? j["over_night_quote"])]
            .compactMap { label, leg in
                guard let leg, let price = leg["last_done"]?.double, let time = leg["timestamp"]?.date else { return nil }
                return Extended(label: label, last: price, prevClose: leg["prev_close"]?.double ?? last, time: time)
            }
            .max { $0.time < $1.time }
    }

    /// 合并一条 quote.updated 推送；返回 true 表示进入了新时段，需要重新拉快照校正昨收
    mutating func apply(_ tick: JSON) -> Bool {
        guard let price = tick["last_done"]?.double else { return false }
        let tickTime = tick["timestamp"]?.date ?? .now
        guard let label = Self.label(tick["trade_session"]?.string) else {
            guard tickTime >= time else { return false }   // 推送可能比快照旧
            let resumed = latestExtended != nil            // 从延长时段回到常规时段，说明是新的交易日
            (last, time) = (price, tickTime)
            return resumed
        }
        if var current = extended, current.label == label {
            guard tickTime >= current.time else { return false }
            (current.last, current.time) = (price, tickTime)
            extended = current
            return false
        }
        // 进入新的延长时段：先以常规收盘为参照，再由快照校正
        extended = Extended(label: label, last: price, prevClose: last, time: tickTime)
        return true
    }

    /// 推送里的交易时段；nil 为常规时段
    static func label(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case let s? where s.hasPrefix("pre"): "前"
        case let s? where s.hasPrefix("post"): "后"
        case let s? where s.hasPrefix("over") || s.hasPrefix("night"): "夜"
        default: nil
        }
    }
}

nonisolated struct SparkPoint: Equatable, Sendable {
    var time: Date
    var price: Double
}
