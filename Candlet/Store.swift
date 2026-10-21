import SwiftUI

/// 自选与行情状态：股票走长桥，加密货币走 Binance，都靠推送更新
@Observable
final class Store {
    enum Status: Equatable {
        case connecting, live
        case offline(String, needsLogin: Bool)
    }

    private(set) var status: Status = .connecting
    private(set) var cryptoLive = false
    private(set) var quotes: [String: Quote] = [:]
    private(set) var sparks: [String: [SparkPoint]] = [:]
    /// 总股本，乘以最新价得到市值
    private(set) var shares: [String: Double] = [:]
    /// 至少一个分组；旧版的单一列表迁移为第一个分组
    private(set) var groups: [StockGroup] = Store.load("watchlist") ?? [StockGroup(name: "自选", stocks: Store.load("stocks") ?? [])] {
        didSet {
            Self.save(groups, "watchlist")
            if Set(stocks.map(\.symbol)) != Set(oldValue.flatMap(\.stocks).map(\.symbol)) { sync(); watchCrypto() }
        }
    }
    /// 所有分组的股票，用于订阅
    var stocks: [Stock] { groups.flatMap(\.stocks) }

    @ObservationIgnored private let serve = Serve()
    @ObservationIgnored private let binance = Binance()
    @ObservationIgnored private var subscribed: Set<String> = []
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay = Store.minRetryDelay
    /// 每次 connect() 自增；被新连接取代的旧连接，失败时不再改状态
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastRefresh = Date.distantPast
    /// 搜索用的证券目录，首次打开添加框时加载
    private(set) var catalogReady = false
    @ObservationIgnored private var catalog: [SearchEntry] = []
    @ObservationIgnored private var catalogTask: Task<Void, Never>?

    /// 各市场常规时段都落在同一个 UTC 日内，用它判断分时是否跨日
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

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
        binance.onQuote = { [weak self] in self?.applyCrypto($0, $1) }
        binance.onLive = { [weak self] in self?.cryptoLive = $0 }
        watchCrypto()
        Task { await connect() }
    }

    private var stockSymbols: Set<String> { Set(stocks.map(\.symbol).filter { !Stock.isCrypto($0) }) }
    private var cryptoSymbols: Set<String> { Set(stocks.map(\.symbol).filter(Stock.isCrypto)) }

    // MARK: - 编辑自选

    /// 建议都来自证券目录，无需再校验
    func add(_ stock: Stock, to group: StockGroup.ID) {
        update(group) { if !$0.stocks.contains(where: { $0.symbol == stock.symbol }) { $0.stocks.append(stock) } }
    }

    /// A 股、港股、美股、新加坡证券列表 + Binance USDT 交易对；长桥未连上时下次再试
    func loadCatalog() {
        guard catalog.isEmpty, catalogTask == nil else { return }
        catalogTask = Task {
            defer { catalogTask = nil }
            guard status == .live else { return }
            async let crypto = Binance.usdtPairs()
            var entries: [SearchEntry] = []
            for market in ["CN", "HK", "US", "SG"] {
                guard let list = try? await serve.call("quote.security_list", ["market": .string(market)]) else { return }
                entries += list.list().compactMap { item in
                    guard let symbol = item["symbol"]?.string else { return nil }
                    let name = [item["name_cn"], item["name_hk"], item["name_en"]].compactMap { $0?.string }.first { !$0.isEmpty }
                    return SearchEntry(symbol: symbol, name: name ?? symbol, english: item["name_en"]?.string ?? "")
                }
            }
            catalog = entries + (await crypto)
            catalogReady = true
        }
    }

    /// 搜索建议，排除已在自选里的；在后台线程计算
    func suggestions(for input: String, in group: StockGroup.ID) async -> [Stock] {
        let query = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, catalogReady else { return [] }
        let owned = groups.first { $0.id == group }?.stocks.map(\.symbol) ?? []
        return await Self.rank(catalog, query: query, excluding: Set(owned))
    }

    /// 同档内名称、代码短者优先，衍生品自然靠后；只保留前几条，不全量排序
    @concurrent
    private static func rank(_ catalog: [SearchEntry], query: String, excluding owned: Set<String>, limit: Int = 6) async -> [Stock] {
        let matcher = SearchEntry.Query(query)
        var best: [(rank: (Int, Int, Int), stock: Stock)] = []
        for (index, entry) in catalog.enumerated() {
            if index % 2000 == 0, Task.isCancelled { return [] }   // 继续输入时放弃这一轮
            guard let score = entry.score(matcher), !owned.contains(entry.stock.symbol) else { continue }
            let rank = (score, entry.stock.name.utf8.count, entry.stock.symbol.utf8.count)
            guard best.count < limit || rank < best[best.count - 1].rank else { continue }
            best.insert((rank, entry.stock), at: best.firstIndex { rank < $0.rank } ?? best.endIndex)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.stock)
    }

    func remove(_ stock: Stock, from group: StockGroup.ID) {
        update(group) { $0.stocks.removeAll { $0.symbol == stock.symbol } }
    }

    /// 拖到某一行上：往下拖放在它后面，往上拖放在它前面
    func reorder(_ symbol: String, onto target: String, in group: StockGroup.ID) {
        update(group) { group in
            guard let from = group.stocks.firstIndex(where: { $0.symbol == symbol }),
                  let to = group.stocks.firstIndex(where: { $0.symbol == target }), from != to else { return }
            group.stocks.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        }
    }

    func move(_ stock: Stock, from source: StockGroup.ID, to target: StockGroup.ID) {
        remove(stock, from: source)
        add(stock, to: target)
    }

    // MARK: - 分组

    func createGroup(_ name: String) -> StockGroup.ID {
        let group = StockGroup(name: name)
        groups.append(group)
        return group.id
    }

    func renameGroup(_ id: StockGroup.ID, to name: String) { update(id) { $0.name = name } }

    /// 连同其中的股票一起删除，至少保留一个分组
    func deleteGroup(_ id: StockGroup.ID) {
        guard groups.count > 1 else { return }
        groups.removeAll { $0.id == id }
    }

    private func update(_ id: StockGroup.ID, _ change: (inout StockGroup) -> Void) {
        if let index = groups.firstIndex(where: { $0.id == id }) { change(&groups[index]) }
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

    /// 面板打开时刷新昨收和分时（30 秒内不重复）；离线时立即重连
    func panelOpened() {
        if case .offline(_, let needsLogin) = status, !needsLogin { reconnect() }
        guard Date.now.timeIntervalSince(lastRefresh) > 30 else { return }
        lastRefresh = .now
        let (stocks, crypto) = (stockSymbols, cryptoSymbols)
        Task {
            await loadCryptoSparks(crypto)
            if status == .live { await reload(stocks) }
        }
    }

    private func connect() async {
        generation += 1
        let current = generation
        status = .connecting
        do {
            try await serve.start()
            subscribed = []
            try await subscribe(stockSymbols)
            guard current == generation else { return }
            status = .live
            retryDelay = Self.minRetryDelay
            lastRefresh = .now
            sync()   // 连接期间增删的自选在这里补上
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
            let wanted = stockSymbols
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
        if let info = try? await serve.call("quote.static_info", ["symbols": .strings(symbols)]) {
            for item in info.list("secu_static_info") {
                if let symbol = item["symbol"]?.string, let total = item["total_shares"]?.double, total > 0 {
                    shares[symbol] = total
                }
            }
        }
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

        // 正常时段的成交接到分时线末尾，同一分钟内只更新最后一个点；跨日则从新的一天重新开始
        guard quote.session == nil, var points = sparks[symbol], let last = points.last else { return }
        if !Self.utc.isDate(quote.time, inSameDayAs: last.time) {
            points = [SparkPoint(time: quote.time, price: quote.last)]
        } else if quote.time.timeIntervalSince(last.time) < 60 {
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

    // MARK: - 加密货币

    /// 自选里的交易对变化时更新 Binance 订阅，新加的拉一次分时
    private func watchCrypto() {
        let wanted = cryptoSymbols
        let previous = binance.symbols
        binance.watch(wanted)
        for symbol in previous.subtracting(wanted) { quotes[symbol] = nil; sparks[symbol] = nil }
        let added = wanted.subtracting(previous)
        if !added.isEmpty { Task { await loadCryptoSparks(added) } }
    }

    private func loadCryptoSparks(_ symbols: Set<String>) async {
        for symbol in symbols {
            let points = await Binance.sparks(symbol)
            if !points.isEmpty { sparks[symbol] = points }
        }
    }

    /// 每秒一条 24 小时滚动价格：同一根 5 分钟 K 线内更新最后一个点，否则追加并只保留最近 24 小时
    private func applyCrypto(_ symbol: String, _ quote: Quote) {
        quotes[symbol] = quote
        guard var points = sparks[symbol], let last = points.last else { return }
        if quote.time.timeIntervalSince(last.time) < 300 {
            points[points.count - 1].price = quote.last
        } else {
            points.append(SparkPoint(time: quote.time, price: quote.last))
            points.removeFirst(max(0, points.count - Stock.cryptoSlots))
        }
        sparks[symbol] = points
    }

    // MARK: - 本地存储

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save(_ value: some Encodable, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
