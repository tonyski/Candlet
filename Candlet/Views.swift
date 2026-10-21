import SwiftUI

struct WatchlistView: View {
    @Environment(Store.self) private var store
    @AppStorage("redUp") private var redUp = true
    @State private var adding = false
    @State private var input = ""
    @State private var suggestions: [Stock] = []
    @FocusState private var focused: Bool
    @AppStorage("group") private var groupID = ""
    @State private var naming: Naming?
    @State private var groupName = ""
    @FocusState private var nameFocused: Bool

    private enum Naming { case new, rename }

    /// 当前分组；记住的分组被删掉时回到第一个
    private var group: StockGroup { store.groups.first { $0.id.uuidString == groupID } ?? store.groups[0] }

    private let rowHeight: CGFloat = 44
    /// 面板内容左右边距。List 自带约 8pt 行内边距，行内再补 8pt 对齐到这里
    private let margin: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.groups.count > 1 { groupTabs }
            if adding { addField }
            if naming != nil { nameField }
            if case .offline(let reason, _) = store.status {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(Color.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, margin)
                    .padding(.bottom, 8)
            }
            Divider()
            list
        }
        .frame(width: 360)
        .onAppear(perform: store.panelOpened)
        // 某些系统版本上 MenuBarExtra 的 onAppear 只在首次打开时触发，用面板成为 key window 兜底
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.panelOpened()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            let (color, text) = statusLight
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .help(text)
                .accessibilityLabel(text)
            Text("Candlet")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            let addTitle = adding ? "取消" : "添加"
            Button(addTitle, systemImage: adding ? "xmark" : "plus") {
                adding ? closeAddField() : openAddField()
            }
            .help(addTitle)
            Menu {
                Button("新建分组…") { startNaming(.new, "") }
                if store.groups.count > 1 {
                    Button("重命名分组…") { startNaming(.rename, group.name) }
                    Button("删除分组", role: .destructive) { store.deleteGroup(group.id) }
                }
                Divider()
                Button("重新连接", action: store.reconnect)
                Toggle("红涨绿跌", isOn: $redUp)
                Divider()
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

    /// 两个以上分组时显示；文字标签，当前分组加粗
    private var groupTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(store.groups) { item in
                    let selected = item.id == group.id
                    Button(item.name) { groupID = item.id.uuidString }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(selected ? Color.primary.opacity(0.08) : .clear, in: .capsule)
                }
            }
            .padding(.horizontal, margin - 8)   // 标签自带 8pt 内边距，文字与标题对齐
        }
        .scrollIndicators(.never)
        .padding(.bottom, 6)
    }

    /// 与搜索框同一位置的一行输入：回车确认，Esc 取消
    private var nameField: some View {
        TextField(naming == .new ? "新分组名称" : "分组名称", text: $groupName)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .focused($nameFocused)
            .onAppear { nameFocused = true }
            .onSubmit(commitGroupName)
            .onExitCommand { naming = nil }
            .padding(.horizontal, margin)
            .padding(.bottom, 10)
    }

    private func startNaming(_ mode: Naming, _ name: String) {
        closeAddField()
        groupName = name
        naming = mode
    }

    private func commitGroupName() {
        let name = groupName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            if naming == .new { groupID = store.createGroup(name).uuidString } else { store.renameGroup(group.id, to: name) }
        }
        naming = nil
    }

    private var statusLight: (Color, String) {
        switch store.status {
        case .live: (.green, "已连接")
        case .connecting: (.orange, "正在连接…")
        case .offline: (.red, "已断开")
        }
    }

    private var addField: some View {
        HStack(spacing: 6) {
            TextField("代码或名称", text: $input)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused)
                .onExitCommand(perform: closeAddField)
                // 系统补全菜单：选中后代码会填进输入框，这时直接添加
                .textInputSuggestions {
                    ForEach(suggestions, id: \.symbol) { stock in
                        HStack {
                            Text(stock.name)
                            Spacer()
                            Text([stock.code, stock.market].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                        .textInputCompletion(stock.symbol)
                    }
                }
            if !input.isEmpty, !store.catalogReady {
                ProgressView().controlSize(.mini)   // 已输入但证券目录还没加载完
            }
        }
        .padding(.horizontal, margin)
        .padding(.bottom, 10)
        .onAppear(perform: store.loadCatalog)
        .onChange(of: input) { _, text in
            if let stock = suggestions.first(where: { $0.symbol == text }) {
                store.add(stock, to: group.id)
                input = ""
            }
        }
        .task(id: "\(input)|\(store.catalogReady)|\(groupID)") {
            let found = await store.suggestions(for: input, in: group.id)
            if !Task.isCancelled { suggestions = found }
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
                Text([stock.code, stock.market].compactMap { $0 }.joined(separator: " · "))
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
                        Badge(change: quote?.change, marketCap: marketCap, fill: direction.fill, text: direction.text)
                    }
                    if let extended = quote?.latestExtended {
                        HStack(spacing: 8) {
                            Text(Self.price(extended.last))
                                .frame(width: Self.priceWidth, alignment: .trailing)
                            HStack(spacing: 3) {
                                Image(systemName: extended.session.icon)
                                    .font(.system(size: 8.5, weight: .medium))
                                Text(Self.percent(extended.change))
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
    }

    /// 第二排文字（代码、市场、延长时段）统一用的灰色
    static let detail = Color.primary.opacity(0.6)
    /// 价格列与胶囊列，第二行按这两列对齐
    static let priceWidth: CGFloat = 64
    static let badgeWidth: CGFloat = 62

    /// 1 以下按有效数字显示，PEPE 之类的小价格币不会变成 0.00
    static func price(_ value: Double?) -> String {
        guard let value else { return "--" }
        return value.formatted(.number.precision(value < 1 ? .significantDigits(2...4) : .fractionLength(2...3)).grouping(.never))
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
    let fill: Color
    let text: Color
    @AppStorage("showMarketCap") private var showMarketCap = false

    var body: some View {
        Text((showMarketCap ? marketCap.map(Self.compact) : change.map(StockRow.percent)) ?? "--")
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(text)
            .frame(width: StockRow.badgeWidth, height: 22)
            .background(fill, in: .rect(cornerRadius: 5))
            .contentShape(.rect)
            .onTapGesture { showMarketCap.toggle() }
            .help(showMarketCap ? "市值，点击显示涨跌幅" : "涨跌幅，点击显示市值")
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
