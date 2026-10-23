import Foundation

/// Binance 现货公开行情，无需 API Key：WebSocket 推送 24 小时滚动行情，5 分钟 K 线画分时
final class Binance {
    var onQuote: (String, Quote) -> Void = { _, _ in }
    var onLive: (Bool) -> Void = { _ in }
    private(set) var symbols: Set<String> = []
    private var feed: Task<Void, Never>?
    private var live = false {
        didSet { if live != oldValue { onLive(live) } }
    }

    private static let rest = "https://data-api.binance.vision/api/v3/"
    private static let stream = "wss://data-stream.binance.vision/stream?streams="

    /// 交易对变化时重建连接（合并流，一条即可）；断线 5 秒后重连
    func watch(_ symbols: Set<String>) {
        guard symbols != self.symbols else { return }
        self.symbols = symbols
        feed?.cancel()
        guard !symbols.isEmpty else { live = false; return }

        let byWire = Dictionary(symbols.map { (Self.wire($0), $0) }) { first, _ in first }
        let url = URL(string: Self.stream + byWire.keys.sorted().map { $0.lowercased() + "@miniTicker" }.joined(separator: "/"))!
        feed = Task { [weak self] in
            while !Task.isCancelled {
                let socket = URLSession.shared.webSocketTask(with: url)
                socket.resume()
                await withTaskCancellationHandler {
                    while let message = try? await socket.receive() {
                        guard case .string(let text) = message,
                              let data = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8))["data"],
                              let symbol = data["s"]?.string.flatMap({ byWire[$0] }),
                              let quote = Quote(miniTicker: data)
                        else { continue }
                        guard !Task.isCancelled else { return }   // 已切换订阅，旧连接的消息不再回调
                        self?.live = true
                        self?.onQuote(symbol, quote)
                    }
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
                guard !Task.isCancelled else { return }
                self?.live = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// 最近 24 小时的 5 分钟 K 线收盘价
    static func sparks(_ symbol: String) async -> [SparkPoint] {
        await klines(symbol, interval: "5m", limit: Market.cryptoSlots).map { SparkPoint(time: $0.time, price: $0.close) }
    }

    /// 详情页的日、周、月、年 K 线；Binance 没有年 K，用月 K 按年（UTC）合并
    static func candles(_ symbol: String, _ period: KPeriod) async -> [Candle] {
        let interval = switch period {
        case .day: "1d"
        case .week: "1w"
        case .month, .year: "1M"
        }
        let bars = await klines(symbol, interval: interval, limit: Candle.loadCount)
        return period == .year ? bars.yearly(in: .utc) : bars
    }

    /// 每根形如 [开盘时间, 开, 高, 低, 收, 量, …]
    private static func klines(_ symbol: String, interval: String, limit: Int) async -> [Candle] {
        guard case .array(let bars)? = await JSON.fetch(URL(string: rest + "klines?symbol=\(wire(symbol))&interval=\(interval)&limit=\(limit)"))
        else { return [] }
        return bars.compactMap { bar in
            guard case .array(let k) = bar, k.count > 5, let time = k[0].date, let open = k[1].double,
                  let high = k[2].double, let low = k[3].double, let close = k[4].double else { return nil }
            return Candle(time: time, open: open, high: high, low: low, close: close, volume: k[5].double ?? 0)
        }
    }

    /// 所有 USDT 交易对，供搜索建议使用
    static func usdtPairs() async -> [SearchEntry] {
        guard case .array(let tickers)? = await JSON.fetch(URL(string: rest + "ticker/price")) else { return [] }
        return tickers.compactMap { ticker in
            guard let wire = ticker["symbol"]?.string, wire.hasSuffix("USDT"), wire.count > 4 else { return nil }
            let base = String(wire.dropLast(4))
            return SearchEntry(symbol: base + "/USDT", name: base)
        }
    }

    /// BTC/USDT → BTCUSDT
    private static func wire(_ symbol: String) -> String { symbol.replacing("/", with: "") }
}
