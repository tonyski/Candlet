import SwiftUI

/// 自选列表（存在本机）+ 行情状态。价格靠推送更新，不轮询。
@Observable
final class Store {
    enum Status: Equatable {
        case connecting, live
        case offline(String, needsLogin: Bool)
    }

    private(set) var status: Status = .connecting
    private(set) var quotes: [String: Quote] = [:]
    private(set) var sparks: [String: [SparkPoint]] = [:]
    private(set) var stocks: [Stock] = Store.load() {
        didSet {
            Self.save(stocks)
            if Set(stocks.map(\.symbol)) != Set(oldValue.map(\.symbol)) { sync() }
        }
    }

    @ObservationIgnored private let serve = Serve()
    @ObservationIgnored private var subscribed: Set<String> = []
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay = Store.minRetryDelay
    /// 每次 connect() 自增；被新连接取代的旧连接，失败时不再改状态
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastRefresh = Date.distantPast

    private static let minRetryDelay = Duration.seconds(5)
    private static let maxRetryDelay = Duration.seconds(300)

    init() {
        Task {
            for await event in serve.events {
                switch event {
                case .push(let tick): apply(tick)
                case .exited(let error): fail(error)
                }
            }
        }
        Task { await connect() }
    }

    // MARK: - 编辑自选

    /// 支持 AAPL / 700 / 600660 / 700.HK；在线时先向长桥校验并取中文名
    func add(_ input: String) async throws {
        guard let symbol = Stock.normalize(input) else { return }
        guard !stocks.contains(where: { $0.symbol == symbol }) else { throw AppError("\(symbol) 已在自选里") }

        var name = symbol
        if status == .live {
            let info: JSON
            do {
                info = try await serve.call("quote.static_info", ["symbols": .strings([symbol])])
            } catch is RPCError {
                throw AppError("找不到 \(symbol)")
            } catch {
                throw AppError("校验 \(symbol) 失败，请稍后再试")
            }
            guard let found = Self.names(info)[symbol] else { throw AppError("找不到 \(symbol)") }
            name = found
        }
        if !stocks.contains(where: { $0.symbol == symbol }) {
            stocks.append(Stock(symbol: symbol, name: name))
        }
    }

    func remove(_ stock: Stock) {
        stocks.removeAll { $0 == stock }
    }

    func move(from source: IndexSet, to destination: Int) {
        stocks.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - 连接

    func reconnect() {
        retryTask?.cancel()
        retryTask = nil
        retryDelay = Self.minRetryDelay
        generation += 1          // 作废进行中的旧连接，它被 stop() 打断时不再报错
        status = .connecting     // 同步切状态，面板 onAppear 和 didBecomeKey 同时触发时不会重连两次
        Task {
            await serve.stop()
            await connect()
        }
    }

    /// 面板打开时校正昨收和分时（跨夜后都会变），30 秒内不重复；
    /// 离线且在退避等待中的话，直接重连，不用等到下一次重试
    func panelOpened() {
        switch status {
        case .connecting:
            return
        case .offline(_, let needsLogin):
            if !needsLogin { reconnect() }
        case .live:
            guard Date.now.timeIntervalSince(lastRefresh) > 30 else { return }
            lastRefresh = .now
            let symbols = Set(stocks.map(\.symbol))
            Task { await reload(symbols) }
        }
    }

    private func connect() async {
        generation += 1
        let current = generation
        status = .connecting
        do {
            try await serve.start()
            subscribed = []
            try await subscribe(Set(stocks.map(\.symbol)))
            guard current == generation else { return }
            status = .live
            retryDelay = Self.minRetryDelay
            lastRefresh = .now
            sync()   // 连接期间增删的自选在这里补上
            await refreshNames()
        } catch {
            guard current == generation else { return }
            fail(error)
        }
    }

    /// 断线后指数退避重试（5 秒起，最长 5 分钟）；未登录时不自动重试，等用户登录后手动重连
    private func fail(_ error: any Error) {
        let needsLogin = (error as? Disconnected)?.needsLogin ?? false
        subscribed = []
        status = .offline(error.localizedDescription, needsLogin: needsLogin)
        if needsLogin {
            retryTask?.cancel()
            retryTask = nil
        }
        guard !needsLogin, retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        retryTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            retryTask = nil
            if case .offline = status { await connect() }
        }
    }

    // MARK: - 订阅与行情

    /// 自选变化后增量订阅；串行执行，避免连续增删时状态错乱
    private func sync() {
        let previous = syncTask
        syncTask = Task {
            await previous?.value
            guard status == .live else { return }
            let wanted = Set(stocks.map(\.symbol))
            let removed = subscribed.subtracting(wanted)
            if !removed.isEmpty {
                _ = try? await serve.call("quote.unsubscribe", ["symbols": .strings(removed)])
                subscribed.subtract(removed)
                for symbol in removed { quotes[symbol] = nil; sparks[symbol] = nil }
            }
            try? await subscribe(wanted.subtracting(subscribed))
        }
    }

    private func subscribe(_ symbols: Set<String>) async throws {
        guard !symbols.isEmpty else { return }
        let result = try await serve.call("quote.subscribe", ["symbols": .strings(symbols), "fields": ["quote"]])
        subscribed.formUnion(symbols)
        // 订阅结果里自带一份快照；拿不到时用 quote.quote 补
        let snapshots = result.list("quotes")
        if snapshots.isEmpty { await refresh(symbols) } else { store(snapshots) }
        await loadSparks(symbols)
    }

    /// 重新拉快照和分时：跨日、跨时段后昨收和分时线都要换
    private func reload(_ symbols: Set<String>) async {
        await refresh(symbols)
        await loadSparks(symbols)
    }

    private func refresh(_ symbols: Set<String>) async {
        guard !symbols.isEmpty,
              let result = try? await serve.call("quote.quote", ["symbols": .strings(symbols)]) else { return }
        store(result.list("secu_quote", "quotes"))
    }

    private func store(_ snapshots: [JSON]) {
        for json in snapshots {
            if let symbol = json["symbol"]?.string, let quote = Quote(snapshot: json) {
                quotes[symbol] = quote
            }
        }
    }

    /// 推送只带最新价，折叠到快照上；跨进新时段时重新拉快照校正昨收
    private func apply(_ tick: JSON) {
        guard let symbol = tick["symbol"]?.string, var quote = quotes[symbol] else { return }
        if quote.apply(tick) { Task { await reload([symbol]) } }
        quotes[symbol] = quote

        // 正常时段的成交接到分时线末尾，同一分钟内只更新最后一个点
        guard quote.session == nil, var points = sparks[symbol], let last = points.last else { return }
        if quote.time.timeIntervalSince(last.time) < 60 {
            points[points.count - 1].price = quote.last
        } else {
            points.append(SparkPoint(time: quote.time, price: quote.last))
        }
        sparks[symbol] = points
    }

    private func loadSparks(_ symbols: Set<String>) async {
        await withTaskGroup { group in
            for symbol in symbols {
                group.addTask { [serve] in
                    let result = try? await serve.call("quote.intraday", ["symbol": .string(symbol)])
                    return (symbol, result)
                }
            }
            for await (symbol, result) in group {
                let points = result?.list("lines").compactMap { line -> SparkPoint? in
                    guard let price = line["price"]?.double, let time = line["timestamp"]?.date else { return nil }
                    return SparkPoint(time: time, price: price)
                } ?? []
                if !points.isEmpty { sparks[symbol] = points }
            }
        }
    }

    /// 离线时添加的只有代码，连上后补全名称
    private func refreshNames() async {
        guard let result = try? await serve.call("quote.static_info", ["symbols": .strings(stocks.map(\.symbol))])
        else { return }
        let names = Self.names(result)
        let renamed = stocks.map { Stock(symbol: $0.symbol, name: names[$0.symbol] ?? $0.name) }
        if renamed != stocks { stocks = renamed }
    }

    private static func names(_ result: JSON) -> [String: String] {
        var names: [String: String] = [:]
        for info in result.list("secu_static_info", "infos") {
            guard let symbol = info["symbol"]?.string else { continue }
            names[symbol] = [info["name_cn"], info["name_hk"], info["name_en"]]
                .compactMap { $0?.string }
                .first { !$0.isEmpty }
        }
        return names
    }

    // MARK: - 本地存储

    private static func load() -> [Stock] {
        guard let data = UserDefaults.standard.data(forKey: "stocks"),
              let stocks = try? JSONDecoder().decode([Stock].self, from: data) else { return [] }
        return stocks
    }

    private static func save(_ stocks: [Stock]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(stocks), forKey: "stocks")
    }
}
