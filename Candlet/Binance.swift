import Foundation

/// Binance 现货公开行情，无需 API Key：WebSocket 推送 24 小时滚动价格，5 分钟 K 线画分时
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
                              let quote = Quote(last: data["c"]?.double, open: data["o"]?.double, time: data["E"]?.date)
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
        guard let url = URL(string: rest + "klines?symbol=\(wire(symbol))&interval=5m&limit=\(Stock.cryptoSlots)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              case .array(let bars)? = try? JSONDecoder().decode(JSON.self, from: data) else { return [] }
        return bars.compactMap { bar in
            guard case .array(let k) = bar, k.count > 4, let time = k[0].date, let price = k[4].double else { return nil }
            return SparkPoint(time: time, price: price)
        }
    }

    /// 所有 USDT 交易对，供搜索建议使用
    static func usdtPairs() async -> [SearchEntry] {
        guard let url = URL(string: rest + "ticker/price"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              case .array(let tickers)? = try? JSONDecoder().decode(JSON.self, from: data) else { return [] }
        return tickers.compactMap { ticker in
            guard let wire = ticker["symbol"]?.string, wire.hasSuffix("USDT"), wire.count > 4 else { return nil }
            let base = String(wire.dropLast(4))
            return SearchEntry(symbol: base + "/USDT", name: base)
        }
    }

    /// BTC/USDT → BTCUSDT
    private static func wire(_ symbol: String) -> String { symbol.replacing("/", with: "") }
}
