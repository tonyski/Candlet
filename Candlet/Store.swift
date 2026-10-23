import SwiftUI

/// 自选与行情状态：股票默认走免费行情，连接长桥后改用长桥推送（长桥不可用时退回免费行情），加密货币走 Binance
@Observable
final class Store {
    enum Status: Equatable {
        /// 没连接长桥
        case off
        case connecting, live
        case offline(String, needsLogin: Bool)
    }

    /// 用户主动连接了长桥；没连接时不启动长桥 CLI
    var longbridge = UserDefaults.standard.bool(forKey: "longbridge") {
        didSet {
            guard longbridge != oldValue else { return }
            UserDefaults.standard.set(longbridge, forKey: "longbridge")
            loginIfNeeded = longbridge
            if longbridge { reconnect() } else { cancelLogIn(); disconnect() }
            refreshFreeNow()
        }
    }

    /// 正在用免费行情：没连接长桥，或长桥不可用（刚启动连接中时不算）
    var usingFree: Bool { status != .live && status != .connecting }
    /// 股票价格是否在更新：长桥已连上，或免费行情最近一次拉取成功
    var stocksLive: Bool { status == .live || (usingFree && freeLive == true) }
    /// 免费行情一只也没取到（接口失效或断网），面板里给个说明
    var freeFailed: Bool { usingFree && freeLive == false }

    private(set) var status = Status.off
    private(set) var cryptoLive = false
    private(set) var quotes: [String: Quote] = [:]
    private(set) var sparks: [String: [SparkPoint]] = [:]
    /// 总股本，乘以最新价得到市值；免费行情给的是总市值，反推成股本存进来
    private(set) var shares: [String: Double] = [:]

    func marketCap(for symbol: String) -> Double? {
        guard let total = shares[symbol], let quote = quotes[symbol] else { return nil }
        return total * quote.last
    }
    /// 至少一个分组；旧版的单一列表迁移为第一个分组
    private(set) var groups: [StockGroup] = Store.load("watchlist").flatMap { $0.isEmpty ? nil : $0 }
        ?? [StockGroup(name: "自选", stocks: Store.load("stocks") ?? [])] {
        didSet {
            Self.save(groups, "watchlist")
            if Set(stocks.map(\.symbol)) != Set(oldValue.flatMap(\.stocks).map(\.symbol)) { sync(); watchCrypto(); refreshFreeNow() }
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
    /// 免费行情没有推送，只在面板打开期间轮询
    @ObservationIgnored private var panelVisible = false
    /// 免费行情的上一轮刷新、整天分时重拉的时间。lastFree 清零（切到免费行情时）就全部重拉
    @ObservationIgnored private var lastFree = Date.distantPast
    @ObservationIgnored private var lastFreeSparks = Date.distantPast
    /// 同一时间只跑一轮免费刷新
    @ObservationIgnored private var freeTask: Task<Void, Never>?
    /// 最近一轮免费行情是否取到了；nil 表示还没取过，或数据已经旧了（刚切过来、面板关了一阵）
    private var freeLive: Bool?
    /// 用户刚打开长桥开关：连接时发现没登录，直接打开授权页，不用再点一次
    @ObservationIgnored private var loginIfNeeded = false
    /// 搜索用的证券目录，首次打开添加框时加载。币与股票分开加载，没连上长桥也能搜币
    private var stockCatalog: [SearchEntry] = []
    private var cryptoCatalog: [SearchEntry] = []
    private var stockCatalogTask: Task<Void, Never>?
    private var cryptoCatalogTask: Task<Void, Never>?
    @ObservationIgnored private var catalogWanted = false
    var catalogLoading: Bool { stockCatalogTask != nil || cryptoCatalogTask != nil }
    var stocksSearchable: Bool { !stockCatalog.isEmpty }
    /// 目录变化时搜索建议要重算
    var catalogSize: Int { stockCatalog.count + cryptoCatalog.count }

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
        if longbridge { Task { await connect() } }
        Task {
            while true {
                refreshFreeNow()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var stockSymbols: Set<String> { Set(stocks.map(\.symbol).filter { !Stock.isCrypto($0) }) }
    private var cryptoSymbols: Set<String> { Set(stocks.map(\.symbol).filter(Stock.isCrypto)) }

    // MARK: - 编辑自选

    /// 建议都来自证券目录，无需再校验；其他分组里改过名的，沿用那个名字
    func add(_ stock: Stock, to group: StockGroup.ID) {
        var stock = stock
        stock.alias = stock.alias ?? stocks.first { $0.symbol == stock.symbol }?.alias
        update(group) { if !$0.stocks.contains(where: { $0.symbol == stock.symbol }) { $0.stocks.append(stock) } }
    }

    /// 同一只股票在所有分组里一起改名；空名称或与原名相同时恢复原名
    func renameStock(_ symbol: String, to name: String) {
        var updated = groups   // 改完一次性写回，只存盘一次
        for g in updated.indices {
            for s in updated[g].stocks.indices where updated[g].stocks[s].symbol == symbol {
                let original = updated[g].stocks[s].name
                updated[g].stocks[s].alias = name.isEmpty || name == original ? nil : name
            }
        }
        groups = updated
    }

    /// Binance USDT 交易对随时可加载；A 股、港股、美股证券列表要等长桥连上，连上后自动补上。失败的部分下次再试
    func loadCatalog() {
        catalogWanted = true
        if cryptoCatalog.isEmpty, cryptoCatalogTask == nil {
            cryptoCatalogTask = Task {
                cryptoCatalog = await Binance.usdtPairs()
                cryptoCatalogTask = nil
            }
        }
        if stockCatalog.isEmpty, stockCatalogTask == nil, status == .live {
            stockCatalogTask = Task {
                defer { stockCatalogTask = nil }
                var entries: [SearchEntry] = []
                for market in ["CN", "HK", "US"] {
                    guard let list = try? await serve.call("quote.security_list", ["market": .string(market)]) else { return }
                    entries += list.list().compactMap { item in
                        // 5 位港股代码是窝轮、牛熊证和人民币 / 美元柜台，搜索里用不到
                        guard let symbol = item["symbol"]?.string, !(market == "HK" && symbol.count == 8) else { return nil }
                        let name = [item["name_cn"], item["name_hk"], item["name_en"]].compactMap { $0?.string }.first { !$0.isEmpty }
                        return SearchEntry(symbol: symbol, name: name ?? symbol, english: item["name_en"]?.string ?? "")
                    }
                }
                stockCatalog = entries
            }
        }
    }

    /// 搜索建议，排除已在自选里的；在后台线程计算
    func suggestions(for input: String, in group: StockGroup.ID) async -> [Stock] {
        let query = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let owned = Set(groups.first { $0.id == group }?.stocks.map(\.symbol) ?? [])
        let local = catalogSize > 0 ? await Self.rank([stockCatalog, cryptoCatalog], query: query, excluding: owned) : []
        guard !stocksSearchable else { return local }
        // 没有长桥的证券目录时，股票改用腾讯在线搜索；停顿一下再查，连续输入时不每个字都发请求
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return [] }
        let remote = await Free.search(query).filter { !owned.contains($0.symbol) }
        return Array((remote + local).prefix(6))
    }

    /// 同档内名称、代码短者优先，衍生品自然靠后；只保留前几条，不全量排序
    @concurrent
    private static func rank(_ catalogs: [[SearchEntry]], query: String, excluding owned: Set<String>, limit: Int = 6) async -> [Stock] {
        let matcher = SearchEntry.Query(query)
        var best: [(rank: (Int, Int, Int), stock: Stock)] = []
        for (index, entry) in catalogs.joined().enumerated() {
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

    func move(from source: IndexSet, to destination: Int, in group: StockGroup.ID) {
        update(group) { $0.stocks.move(fromOffsets: source, toOffset: destination) }
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

    /// 把分组挪到目标分组所在的位置
    func moveGroup(_ id: StockGroup.ID, to target: StockGroup.ID) {
        guard let from = groups.firstIndex(where: { $0.id == id }),
              let to = groups.firstIndex(where: { $0.id == target }), from != to else { return }
        groups.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    }

    /// 连同其中的股票一起删除，至少保留一个分组
    func deleteGroup(_ id: StockGroup.ID) {
        guard groups.count > 1 else { return }
        groups.removeAll { $0.id == id }
    }

    private func update(_ id: StockGroup.ID, _ change: (inout StockGroup) -> Void) {
        if let index = groups.firstIndex(where: { $0.id == id }) { change(&groups[index]) }
    }

    // MARK: - 登录

    /// App 内登录：waiting 带着授权页链接（拿到之前为 nil），浏览器没自动打开时给用户点
    enum Login { case idle, waiting(URL?), failed(String) }
    private(set) var login = Login.idle
    @ObservationIgnored private var loginTask: Task<Void, Never>?

    /// 授权在浏览器里完成，面板关掉也会继续等；成功后重连
    func logIn() {
        loginTask?.cancel()
        login = .waiting(nil)
        loginTask = Task {
            do {
                // 取消后旧进程可能还会吐出链接，不能把状态改回等待
                try await Serve.login { url in if !Task.isCancelled { login = .waiting(url) } }
                login = .idle
                reconnect()
            } catch is CancellationError {
            } catch {
                login = .failed(error.localizedDescription)
            }
        }
    }

    func cancelLogIn() {
        loginTask?.cancel()
        loginTask = nil
        login = .idle
    }

    // MARK: - 连接

    func reconnect() {
        guard longbridge else { return }
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
        panelVisible = true
        refreshFreeNow()
        if case .offline(_, let needsLogin) = status, !needsLogin { reconnect() }
        guard Date.now.timeIntervalSince(lastRefresh) > 30 else { return }
        lastRefresh = .now
        let (stocks, crypto) = (stockSymbols, cryptoSymbols)
        Task {
            await loadCryptoSparks(crypto)
            if status == .live { await reload(stocks) }
        }
    }

    func panelClosed() { panelVisible = false }

    private func connect() async {
        guard longbridge else { return }
        generation += 1
        let current = generation
        status = .connecting
        do {
            try await serve.start()
            subscribed = []
            try await subscribe(stockSymbols)
            guard current == generation else { return }
            status = .live
            loginIfNeeded = false
            retryDelay = Self.minRetryDelay
            lastRefresh = .now
            sync()   // 连接期间增删的自选在这里补上
            if catalogWanted { loadCatalog() }   // 打开过添加框，补上股票目录
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
        lastFree = .distantPast   // 长桥的报价和分时都要换掉
        refreshFreeNow()
        if needsLogin {
            retryTask?.cancel()
            retryTask = nil
            if loginIfNeeded, case .idle = login { logIn() }
        }
        loginIfNeeded = false
        guard !needsLogin, retryTask == nil, longbridge else { return }
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
                removed.forEach(forget)
            }
            try? await subscribe(wanted.subtracting(subscribed))
        }
    }

    /// 移出自选的，行情、分时和股本一起清掉
    private func forget(_ symbol: String) {
        (quotes[symbol], sparks[symbol], shares[symbol]) = (nil, nil, nil)
    }

    private func subscribe(_ symbols: Set<String>) async throws {
        guard !symbols.isEmpty else { return }
        let result = try await serve.call("quote.subscribe", ["symbols": .strings(symbols), "fields": ["quote"]])
        subscribed.formUnion(symbols)
        // 订阅结果里自带一份快照；拿不到时用 quote.quote 补
        let snapshots = result.list("quotes")
        if snapshots.isEmpty { await refresh(symbols) } else { store(snapshots) }
        // 分时和股本互不依赖，一起拉
        async let sparksLoaded: Void = loadSparks(symbols)
        if let info = try? await serve.call("quote.static_info", ["symbols": .strings(symbols)]) {
            for item in info.list("secu_static_info") {
                if let symbol = item["symbol"]?.string, let total = item["total_shares"]?.double, total > 0 {
                    shares[symbol] = total
                }
            }
        }
        await sparksLoaded
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
        if Quote.Session(tick["trade_session"]?.string) == nil { appendSpark(symbol, quote) }
    }

    /// 常规时段的价格接到分时线末尾，同一分钟内只更新最后一个点；跨日则从新的一天重新开始
    private func appendSpark(_ symbol: String, _ quote: Quote) {
        guard var points = sparks[symbol], let last = points.last else { return }
        if !Calendar.utc.isDate(quote.time, inSameDayAs: last.time) {   // 各市场常规时段都落在同一个 UTC 日内
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

    /// 详情页的 K 线：加密货币走 Binance，股票走长桥，用免费行情时走腾讯、Yahoo
    func candles(_ symbol: String, _ period: KPeriod) async -> [Candle] {
        if Stock.isCrypto(symbol) { return await Binance.candles(symbol, period) }
        if usingFree { return await Free.candles(symbol, period) }
        let params: JSON = ["symbol": .string(symbol), "period": .string(period.rawValue), "count": .number(Double(Candle.loadCount))]
        return (try? await serve.call("quote.candlesticks", params))?.list().compactMap(Candle.init(json:)) ?? []
    }

    // MARK: - 免费行情

    /// 断开长桥连接：停掉 CLI，不再重试
    private func disconnect() {
        retryTask?.cancel()
        retryTask = nil
        generation += 1          // 进行中的连接作废
        subscribed = []
        status = .off
        lastFree = .distantPast
        Task { await serve.stop() }
    }

    /// 同一时间只跑一轮；跑的期间自选变了，跑完再补一轮。也是失败提示里「立即重试」的入口
    func refreshFreeNow() {
        guard usingFree, panelVisible, freeTask == nil else { return }
        if Date.now.timeIntervalSince(lastFree) > 60 { freeLive = nil }   // 旧数据先调淡，新数据到了再恢复
        freeTask = Task {
            var symbols: Set<String>
            repeat {
                symbols = stockSymbols
                await refreshFree(symbols)
            } while usingFree && panelVisible && symbols != stockSymbols
            freeTask = nil
        }
    }

    /// 报价每 10 秒拉一次。
    /// 分时由报价接到末尾，只在首次、面板关过一阵后重新打开、以及每 10 分钟整天重拉校正
    private func refreshFree(_ symbols: Set<String>) async {
        guard !symbols.isEmpty else { return }
        let now = Date.now
        let reload = now.timeIntervalSince(lastFree) > 60 || now.timeIntervalSince(lastFreeSparks) > 600
        let found = await Free.quotes(symbols)
        guard usingFree else { return }   // 期间连上了长桥，别用免费数据覆盖
        lastFree = now
        if reload { lastFreeSparks = now }
        freeLive = !found.isEmpty
        // 整天重拉分时的，报价就不必再接到末尾。
        // 价格没变不接：收盘后腾讯的报价时间还在走，接上去会多出一段平线
        let wanted = symbols.filter { reload || sparks[$0] == nil }
        for (symbol, snapshot) in found {
            let moved = quotes[symbol]?.last != snapshot.quote.last
            quotes[symbol] = snapshot.quote
            if let cap = snapshot.marketCap { shares[symbol] = cap / snapshot.quote.last }
            if moved, !wanted.contains(symbol) { appendSpark(symbol, snapshot.quote) }
        }
        await withTaskGroup { group in
            for symbol in wanted { group.addTask { (symbol, await Free.sparks(symbol)) } }
            for await (symbol, points) in group where usingFree && !points.isEmpty { sparks[symbol] = points }
        }
    }

    // MARK: - 加密货币

    /// 自选里的交易对变化时更新 Binance 订阅，新加的拉一次分时
    private func watchCrypto() {
        let wanted = cryptoSymbols
        let previous = binance.symbols
        binance.watch(wanted)
        previous.subtracting(wanted).forEach(forget)
        let added = wanted.subtracting(previous)
        if !added.isEmpty { Task { await loadCryptoSparks(added) } }
    }

    private func loadCryptoSparks(_ symbols: Set<String>) async {
        await withTaskGroup { group in
            for symbol in symbols { group.addTask { (symbol, await Binance.sparks(symbol)) } }
            for await (symbol, points) in group where !points.isEmpty { sparks[symbol] = points }
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
            points.removeFirst(max(0, points.count - Market.cryptoSlots))
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
