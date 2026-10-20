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

    /// 秒级时间戳或 ISO 8601 字符串
    /// 请求 id；非整数或越界时返回 nil，而不是让 Int() 直接崩溃
    var int: Int? { double.flatMap { Int(exactly: $0) } }

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
    let symbol: String   // 700.HK / AAPL.US / 600660.SH
    var name: String
    var id: String { symbol }

    var code: String { String(symbol[..<(symbol.lastIndex(of: ".") ?? symbol.endIndex)]) }

    var market: String {
        switch symbol.split(separator: ".").last {
        case "HK": "港股"
        case "US": "美股"
        case "SH": "沪市"
        case "SZ": "深市"
        case "SG": "新加坡"
        default: ""
        }
    }

    /// AAPL → AAPL.US，700 / 00700 → 700.HK，600660 → 600660.SH，000001 → 000001.SZ
    static func normalize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !text.isEmpty else { return nil }
        if let suffix = text.split(separator: ".").last, ["HK", "US", "SH", "SZ", "SG"].contains(suffix), text.contains(".") {
            guard suffix == "HK" else { return text }
            let code = text.dropLast(3).drop { $0 == "0" }
            return "\(code.isEmpty ? "0" : code).HK"
        }
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return "\(text).US" }
        if text.count == 6 { return "\(text).\("659".contains(text.first!) ? "SH" : "SZ")" }
        let trimmed = text.drop { $0 == "0" }
        return "\(trimmed.isEmpty ? "0" : trimmed).HK"
    }

    static let defaults: [Stock] = [
        .init(symbol: "3355.HK", name: "飞速创新"),
        .init(symbol: "588950.SH", name: "科创综指ETF"),
        .init(symbol: "600660.SH", name: "福耀玻璃"),
        .init(symbol: "DECK.US", name: "德克斯户外"),
        .init(symbol: "IREN.US", name: "IREN"),
        .init(symbol: "QQQ.US", name: "纳指100 ETF"),
        .init(symbol: "SOXX.US", name: "半导体 ETF"),
        .init(symbol: "FIG.US", name: "Figma"),
        .init(symbol: "NBIS.US", name: "Nebius"),
    ]
}

// MARK: - 报价

nonisolated struct Quote: Sendable, Equatable {
    var last: Double
    var prevClose: Double
    var time: Date
    /// nil 为正常交易时段，否则是「盘前 / 盘后 / 夜盘」
    var session: String?
    /// 走势图的昨收虚线
    var baseline: Double

    var change: Double { prevClose == 0 ? 0 : last / prevClose - 1 }

    /// 快照里有正常时段和盘前 / 盘后 / 夜盘几组价格，取最新成交的那组
    init?(snapshot j: JSON) {
        guard let regularClose = j["last_done"]?.double else { return nil }
        let legs: [(String?, JSON?)] = [(nil, j), ("盘前", j["pre_market_quote"]),
                                        ("盘后", j["post_market_quote"]), ("夜盘", j["over_night_quote"])]
        let latest = legs
            .compactMap { label, leg -> (String?, Double, Double?, Date)? in
                guard let leg, let last = leg["last_done"]?.double,
                      let time = leg["timestamp"]?.date ?? (label == nil ? Date.distantPast : nil) else { return nil }
                return (label, last, leg["prev_close"]?.double, time)
            }
            .max { $0.3 < $1.3 }
        guard let (label, last, prev, time) = latest else { return nil }

        self.last = last
        self.time = time
        self.session = label
        self.baseline = j["prev_close"]?.double ?? regularClose
        // 盘前盘后相对上一个收盘价
        self.prevClose = prev ?? (label == nil ? baseline : regularClose)
    }

    /// 合并一条 quote.updated 推送；返回 true 表示进入了新时段，需要重新拉快照校正昨收
    mutating func apply(_ tick: JSON) -> Bool {
        guard let price = tick["last_done"]?.double else { return false }
        let tickTime = tick["timestamp"]?.date ?? .now
        guard tickTime >= time else { return false }   // 推送可能比快照旧
        let tickSession = Self.label(tick["trade_session"]?.string)
        defer { last = price; time = tickTime; session = tickSession }
        return tickSession != session
    }

    private static func label(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case let s? where s.hasPrefix("pre"): "盘前"
        case let s? where s.hasPrefix("post"): "盘后"
        case let s? where s.hasPrefix("over") || s.hasPrefix("night"): "夜盘"
        default: nil
        }
    }
}

nonisolated struct SparkPoint: Equatable, Sendable {
    var time: Date
    var price: Double
}
