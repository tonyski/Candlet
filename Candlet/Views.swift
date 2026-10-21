import SwiftUI

struct WatchlistView: View {
    @Environment(Store.self) private var store
    @Environment(Updater.self) private var updater
    @Environment(\.openURL) private var openURL
    @AppStorage("redUp") private var redUp = true
    @State private var adding = false
    @State private var input = ""
    @State private var suggestions: [Stock] = []
    /// suggestions 对应的输入
    @State private var suggestionsFor = ""
    @FocusState private var focused: Bool
    @AppStorage("group") private var groupID = ""
    @State private var naming: Naming?
    @State private var groupName = ""
    @FocusState private var nameFocused: Bool
    /// 也可能在系统设置里改，面板打开时重新读取
    @State private var launchAtLogin = LoginItem.isEnabled

    /// 重命名时记下目标分组，保存时不依赖当前选中的是哪个
    private enum Naming: Equatable { case new, rename(StockGroup.ID) }

    /// 当前分组；记住的分组被删掉时回到第一个
    private var group: StockGroup { store.groups.first { $0.id.uuidString == groupID } ?? store.groups[0] }

    private let rowHeight: CGFloat = 44
    /// 面板内容左右边距。List 自带约 8pt 行内边距，行内再补 8pt 对齐到这里
    private let margin: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.groups.count > 1 || naming == .new { groupTabs }
            if adding { addField }
            if case .offline(let reason, let needsLogin) = store.status, store.needsLongbridge {
                if needsLogin { loginCard } else { offlineNotice(reason) }
            }
            Divider()
            list
        }
        .frame(width: 360)
        .onAppear(perform: store.panelOpened)
        // 某些系统版本上 MenuBarExtra 的 onAppear 只在首次打开时触发，用面板成为 key window 兜底
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.panelOpened()
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Candlet")
                .font(.system(size: 12, weight: .semibold))
            statusIcon
            Spacer()
            let addTitle = adding ? "取消" : "添加"
            Button(addTitle, systemImage: adding ? "xmark" : "plus") {
                adding ? closeAddField() : openAddField()
            }
            .help(addTitle)
            if case .available(let version, _) = updater.state {
                Circle().fill(.tint).frame(width: 6, height: 6).help("有新版本 \(version)")   // 用强调色，不用红色，免得像涨跌或报错
            }
            Menu {
                Button("新建分组…") { startNaming(.new, "") }
                if store.groups.count > 1 {
                    Button("重命名分组…") { startNaming(.rename(group.id), group.name) }
                    Button(group.stocks.isEmpty ? "删除分组" : "删除分组…", role: .destructive) { confirmDelete(group) }
                }
                Divider()
                if case .offline(_, needsLogin: true) = store.status {
                    Button("登录长桥…", action: store.logIn)   // 只看币时不显示登录卡片，从这里登录
                }
                Button("重新连接", action: store.reconnect)
                Toggle("登录时打开", isOn: Binding(get: { launchAtLogin }) {
                    LoginItem.set($0)
                    launchAtLogin = LoginItem.isEnabled
                })
                Toggle("红涨绿跌", isOn: $redUp)
                Divider()
                updateItem
                Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, margin)
        .frame(height: 36)
    }

    /// 两个以上分组、或正在新建分组时显示；当前分组加粗
    private var groupTabs: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(store.groups) { item in
                        let selected = item.id == group.id
                        if naming == .rename(item.id) {
                            nameTab
                        } else {
                            let active = selected && naming != .new   // 新建时高亮让给正在编辑的标签
                            Button(item.name) { groupID = item.id.uuidString }
                                .buttonStyle(.plain)
                                .foregroundStyle(active ? .primary : .secondary)
                                .groupTab(active: active)
                        }
                    }
                    if naming == .new { nameTab }
                }
                .padding(.horizontal, margin - 8)   // 标签自带 8pt 内边距，文字与标题对齐
            }
            .scrollIndicators(.never)
            .onChange(of: naming) { if naming != nil { withAnimation { scroller.scrollTo("naming") } } }
        }
        .padding(.bottom, 6)
    }

    /// 新建、重命名都直接在标签上编辑：回车或点别处保存，Esc 取消
    private var nameTab: some View {
        // 无边框输入框的提示文字会跟随正文颜色，自己画一个浅色占位；它也撑起最小宽度
        ZStack(alignment: .leading) {
            Text("分组名称").foregroundStyle(.tertiary).opacity(groupName.isEmpty ? 1 : 0)
            TextField("分组名称", text: $groupName, prompt: Text(""))
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
                .fixedSize()
                .focused($nameFocused)
                .onAppear { nameFocused = true }
                .onSubmit(commitGroupName)
                .onExitCommand { naming = nil }
                .onChange(of: nameFocused) { _, focused in if !focused { commitGroupName() } }
        }
        .groupTab(active: true)
        .id("naming")
    }

    private func startNaming(_ mode: Naming, _ name: String) {
        closeAddField()
        groupName = name
        naming = mode
    }

    private func commitGroupName() {
        guard naming != nil else { return }   // 回车保存后失焦还会再调用一次
        let name = groupName.trimmingCharacters(in: .whitespaces)
        switch naming {
        case .new where !name.isEmpty: groupID = store.createGroup(name).uuidString
        case .rename(let id) where !name.isEmpty: store.renameGroup(id, to: name)
        default: break
        }
        naming = nil
    }

    /// 空分组直接删；有股票时先确认，因为不能撤销。菜单栏面板里的 SwiftUI 弹窗不可靠，用系统提醒框
    private func confirmDelete(_ target: StockGroup) {
        guard !target.stocks.isEmpty else { return store.deleteGroup(target.id) }
        let alert = NSAlert()
        alert.messageText = "删除「\(target.name)」？"
        alert.informativeText = "其中 \(target.stocks.count) 只自选会一并删除。"
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { store.deleteGroup(target.id) }
    }

    @ViewBuilder
    private var updateItem: some View {
        switch updater.state {
        case .checking: Button("正在检查更新…") {}.disabled(true)
        case .upToDate: Button("已是最新版本（\(updater.current)）", action: updater.check)
        case .failed: Button("检查更新失败，点击重试", action: updater.check)
        case .available(let version, let url): Button("下载新版本（\(version)）") { openURL(url) }
        }
    }

    /// 断线会自动重连，这里只给一个立即重连的入口
    private func offlineNotice(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(reason)
                .foregroundStyle(Color.warning)
            Spacer()
            Button("立即重连", action: store.reconnect)
                .buttonStyle(.link)
        }
        .font(.caption2)
        .padding(.horizontal, margin)
        .padding(.bottom, 8)
    }

    /// 未登录或登录失效：在面板里直接登录，授权在浏览器中完成
    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.login {
            case .idle, .failed:
                Text("登录长桥，查看股票行情")
                    .font(.system(size: 12, weight: .semibold))
                Text("需要开通 OpenAPI 的长桥账户，加密货币无需登录。")
                    .foregroundStyle(.secondary)
                if case .failed(let message) = store.login {
                    Text(message).foregroundStyle(Color.warning)
                }
                Button("在浏览器中登录", action: store.logIn)
                    .buttonStyle(.borderedProminent)
            case .waiting(let url):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("请在浏览器中完成授权…")
                }
                HStack(spacing: 12) {
                    if let url { Button("重新打开") { openURL(url) } }
                    Button("取消", action: store.cancelLogIn)
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
        .padding(.horizontal, margin)
        .padding(.bottom, 10)
    }

    /// 只在异常时出现，靠形状而不只是颜色区分；绿点会和「红涨绿跌」里的跌混淆，正常连接时不显示。
    /// 只看加密货币时长桥的状态与用户无关，也不显示
    @ViewBuilder
    private var statusIcon: some View {
        switch store.status {
        case .live: EmptyView()
        case .connecting:
            ProgressView()
                .controlSize(.mini)
                .help("正在连接长桥…")
                .accessibilityLabel("正在连接长桥")
        case .offline(_, let needsLogin) where store.needsLongbridge:
            let text = needsLogin ? "未登录长桥" : "长桥已断开"
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.warning)
                .help(text)
                .accessibilityLabel(text)
        case .offline: EmptyView()
        }
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchField
            // 没连上长桥时只有加密货币目录，说明一下为什么搜不到股票
            if !input.isEmpty, !store.stocksSearchable, store.status != .live {
                Text("连上长桥后可搜索股票")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, margin)
        .padding(.bottom, 10)
        .onAppear(perform: store.loadCatalog)
        .onChange(of: input) { _, text in
            if let stock = suggestions.first(where: { $0.symbol == text }) { add(stock) }
        }
        .task(id: "\(input)|\(store.catalogSize)|\(groupID)") {
            let query = input
            let found = await store.suggestions(for: query, in: group.id)
            if !Task.isCancelled { (suggestions, suggestionsFor) = (found, query) }
        }
    }

    /// 回车添加第一条建议；建议还没跟上输入时不添加，免得加错
    private func addFirstSuggestion() {
        guard !input.isEmpty, suggestionsFor == input,
              let stock = suggestions.first(where: { $0.symbol == input }) ?? suggestions.first else { return }
        add(stock)
    }

    private func add(_ stock: Stock) {
        store.add(stock, to: group.id)
        input = ""
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("代码或名称", text: $input)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused)
                .onExitCommand(perform: closeAddField)
                .onSubmit(addFirstSuggestion)
                // 系统补全菜单：选中后代码会填进输入框，这时直接添加
                .textInputSuggestions {
                    ForEach(suggestions, id: \.symbol) { stock in
                        HStack {
                            Text(stock.name)
                            Spacer()
                            Text(stock.subtitle)
                                .foregroundStyle(.secondary)
                        }
                        .textInputCompletion(stock.symbol)
                    }
                }
            if !input.isEmpty, store.catalogLoading {
                ProgressView().controlSize(.mini)   // 已输入但证券目录还没加载完
            }
        }
    }

    private func openAddField() {
        naming = nil
        input = ""
        adding = true
        focused = true
    }

    private func closeAddField() {
        adding = false
        input = ""
        focused = false
    }

    @ViewBuilder
    private var list: some View {
        let shown = group.stocks
        if shown.isEmpty {
            Text("点 + 添加自选")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 80)
        } else {
            List {
                ForEach(shown) { stock in
                    StockRow(stock: stock, quote: store.quotes[stock.symbol],
                             spark: store.sparks[stock.symbol] ?? [], redUp: redUp,
                             stale: stock.isCrypto ? !store.cryptoLive : store.status != .live,
                             marketCap: store.marketCap(for: stock.symbol))
                        .modifier(HoverHighlight())
                        .frame(height: rowHeight)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .contextMenu { rowMenu(stock) }
                }
                .onMove { store.move(from: $0, to: $1, in: group.id) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(shown.count) * rowHeight, 480))
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func rowMenu(_ stock: Stock) -> some View {
        let others = store.groups.filter { $0.id != group.id }
        if !others.isEmpty {
            Menu("移到") {
                ForEach(others) { target in
                    Button(target.name) { store.move(stock, from: group.id, to: target.id) }
                }
            }
        }
        Button("删除", role: .destructive) { store.remove(stock, from: group.id) }
    }
}

/// 纯数据 + Equatable：一只股票的推送不会让其他行重算
struct StockRow: View, Equatable {
    let stock: Stock
    let quote: Quote?
    let spark: [SparkPoint]
    let redUp: Bool
    /// 离线时价格不再更新，调淡以免被当成实时价
    let stale: Bool
    let marketCap: Double?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(stock.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(stock.subtitle)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Self.detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                Sparkline(points: spark, slots: stock.sparkSlots, baseline: quote?.prevClose, color: direction.line)
                    .frame(width: 56, height: 24)

                // 两列对齐：价格在价格下方，涨跌幅在胶囊下方（参考富途）
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Text(Self.price(quote?.last))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(direction.price)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)   // 小价格币的有效数字较长
                            .frame(width: Self.priceWidth, alignment: .trailing)
                        Badge(change: quote?.change, marketCap: marketCap, currency: stock.currency, fill: direction.fill, text: direction.text)
                    }
                    if let extended = quote?.latestExtended {
                        HStack(spacing: 8) {
                            Text(Self.price(extended.last))
                                .frame(width: Self.priceWidth, alignment: .trailing)
                            HStack(spacing: 3) {
                                Text(Self.percent(extended.change))
                                Image(systemName: extended.session.icon)
                                    .font(.system(size: 8.5, weight: .medium))
                                    .help(extended.session.name)
                                    .accessibilityLabel(extended.session.name)
                            }
                            .frame(width: Self.badgeWidth, alignment: .trailing)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(Self.detail)   // 参考富途：整行统一灰色，红绿只留给主行
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                }
            }
            .monospacedDigit()
            .opacity(stale ? 0.45 : 1)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .help(tooltip)
    }

    /// 收盘后、断线时价格不再跳动，悬停能看到是什么时候的价格
    private var tooltip: String {
        // 加密货币的涨跌是 24 小时滚动的，和股票的当日涨跌不同
        let prefix = stock.isCrypto ? "24 小时涨跌幅，" : ""
        guard let time = quote?.latestExtended?.time ?? quote?.time, time > .distantPast else { return prefix + "暂无行情" }
        let shown = Calendar.current.isDateInToday(time) ? time.formatted(date: .omitted, time: .standard)
                                                         : time.formatted(.dateTime.month().day().hour().minute())
        return "\(prefix)更新于 \(shown)"
    }

    /// 第二排文字（代码、市场、延长时段）统一用的灰色
    static let detail = Color.primary.opacity(0.6)
    /// 价格列与胶囊列，第二行按这两列对齐
    static let priceWidth: CGFloat = 72
    static let badgeWidth: CGFloat = 62

    /// 1 以下按有效数字显示，PEPE 之类的小价格币不会变成 0.00
    /// 五位数以上加千分位（BTC 108,234.56），四位数以内不加，和行情软件习惯一致
    static func price(_ value: Double?) -> String {
        guard let value else { return "--" }
        return value.formatted(.number.precision(value < 1 ? .significantDigits(2...4) : .fractionLength(2...3))
            .grouping(value >= 10_000 ? .automatic : .never))
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(2)).sign(strategy: .always()))
    }

    /// 涨跌幅用实心胶囊，不受背后壁纸影响
    private var direction: (line: Color, price: Color, fill: Color, text: Color) {
        guard let change = quote?.change, change != 0 else { return (.secondary, .primary, .secondary.opacity(0.2), .secondary) }
        return (change > 0) == redUp ? (.quoteRed, .quoteRed, .badgeRed, .white)
                                     : (.quoteGreen, .quoteGreen, .badgeGreen, .white)
    }
}

/// 涨跌幅 / 市值胶囊，点击切换所有行。自己读取设置，切换时不必重算整行
struct Badge: View {
    let change: Double?
    let marketCap: Double?
    /// 市值的币种符号；nil 表示加密货币，没有市值，始终显示 24 小时涨跌幅
    let currency: String?
    let fill: Color
    let text: Color
    @AppStorage("showMarketCap") private var showMarketCap = false

    var body: some View {
        label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(text)
            .frame(width: StockRow.badgeWidth, height: 22)
            .background(fill, in: .rect(cornerRadius: 5))
            .contentShape(.rect)
            .onTapGesture { showMarketCap.toggle() }
            .help(showMarketCap ? "市值，点击显示涨跌幅" : "涨跌幅，点击显示市值")
            .allowsHitTesting(currency != nil)   // 加密货币没有市值，点击不切换
    }

    /// 币种符号缩小一号，HK$ 这类长符号不会把数字挤小
    private var label: Text {
        guard showMarketCap, let currency else { return Text(change.map(StockRow.percent) ?? "--") }
        guard let marketCap else { return Text("--") }
        return Text("\(Text(currency).font(.system(size: 9.5, weight: .semibold)))\(Self.compact(marketCap))")
    }

    /// 4.94万亿、1334亿、12.3亿
    private static func compact(_ value: Double) -> String {
        let (scaled, unit) = switch value {
        case 1e12...: (value / 1e12, "万亿")
        case 1e8...: (value / 1e8, "亿")
        case 1e4...: (value / 1e4, "万")
        default: (value, "")
        }
        let digits = scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2
        return scaled.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) + unit
    }
}

/// 悬停高亮。单独成修饰符，hover 状态不进入 StockRow 的 Equatable 比较
struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: .infinity)
            .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}

/// 分时小走势：价格线 + 昨收虚线。
/// 横轴是全天的交易分钟数，每分钟一格：盘中只画到当前进度，午休不会画出斜线
struct Sparkline: View {
    let points: [SparkPoint]
    let slots: Int
    let baseline: Double?
    let color: Color

    var body: some View {
        let prices = points.map(\.price)
        let range = prices + [baseline].compactMap { $0 }
        if prices.count > 1, let low = range.min(), let high = range.max(), high > low {
            Canvas { context, size in
                let inset: CGFloat = 1   // 留出线宽，避免最高最低点被裁掉
                func y(_ price: Double) -> CGFloat {
                    inset + (size.height - inset * 2) * (1 - (price - low) / (high - low))
                }

                if let baseline {
                    var rule = Path()
                    rule.move(to: CGPoint(x: 0, y: y(baseline)))
                    rule.addLine(to: CGPoint(x: size.width, y: y(baseline)))
                    context.stroke(rule, with: .color(.secondary.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                }

                let step = size.width / CGFloat(max(slots, prices.count) - 1)
                var line = Path()
                for (i, price) in prices.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step, y: y(price))
                    i == 0 ? line.move(to: point) : line.addLine(to: point)
                }
                var area = line
                area.addLine(to: CGPoint(x: CGFloat(prices.count - 1) * step, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.22), color.opacity(0)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
        } else {
            Color.clear
        }
    }
}

/// 面板是半透明玻璃：浅色模式用深一档的红、绿、橙保证对比度，深色模式沿用系统色
extension Color {
    /// 涨跌胶囊底色，白字对比度 ≥ 4.4:1，深浅模式通用
    static let badgeGreen = Color(red: 0x18 / 255, green: 0x8A / 255, blue: 0x46 / 255)
    static let badgeRed = Color(red: 0xD1 / 255, green: 0x3A / 255, blue: 0x3A / 255)

    static let quoteGreen = adaptive(light: 0x0E_7C_3A, dark: 0x30_D1_58)
    static let quoteRed = adaptive(light: 0xC8_2B_2B, dark: 0xFF_6B_6B)
    static let warning = adaptive(light: 0x9E_50_00, dark: 0xFF_B3_40)

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension View {
    /// 分组标签：当前分组加粗并带淡色胶囊
    func groupTab(active: Bool) -> some View {
        font(.system(size: 12, weight: active ? .semibold : .regular))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(active ? Color.primary.opacity(0.08) : .clear, in: .capsule)
    }
}
