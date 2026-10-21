import SwiftUI

struct WatchlistView: View {
    @Environment(Store.self) private var store
    @AppStorage("redUp") private var redUp = true
    @State private var adding = false
    @State private var checking = false
    @State private var input = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private let rowHeight: CGFloat = 40
    /// 面板内容左右边距。List 自带约 8pt 行内边距，行内再补 8pt 对齐到这里
    private let margin: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
            if adding { addField }
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
            let addTitle = adding ? "取消添加" : "添加自选"
            Button(addTitle, systemImage: adding ? "xmark" : "plus") {
                adding ? closeAddField() : openAddField()
            }
            .help(addTitle)
            Menu {
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

    private var statusLight: (Color, String) {
        switch store.status {
        case .live: (.green, "实时行情已连接")
        case .connecting: (.orange, "正在连接…")
        case .offline: (.red, "已断开")
        }
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TextField("AAPL、700、600660、BTC/USDT…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($focused)
                    .disabled(checking)
                    .onSubmit(submit)
                    .onExitCommand(perform: closeAddField)
                if checking {
                    ProgressView().controlSize(.mini)
                }
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(Color.quoteRed)
            }
        }
        .padding(.horizontal, margin)
        .padding(.bottom, 10)
    }

    private func openAddField() {
        input = ""
        error = nil
        adding = true
        focused = true
    }

    private func closeAddField() {
        adding = false
        input = ""
        error = nil
        focused = false
    }

    private func submit() {
        let text = input
        guard !checking, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        checking = true
        Task {
            do {
                try await store.add(text)
                input = ""
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            checking = false
            focused = true   // 校验期间输入框被禁用会丢焦点
        }
    }

    @ViewBuilder
    private var list: some View {
        if store.stocks.isEmpty {
            Text("点右上角 + 添加自选")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 80)
        } else {
            List {
                ForEach(store.stocks) { stock in
                    StockRow(stock: stock, quote: store.quotes[stock.symbol],
                             spark: store.sparks[stock.symbol] ?? [], redUp: redUp,
                             stale: stock.isCrypto ? !store.cryptoLive : store.status != .live)
                        .modifier(HoverHighlight())
                        .frame(height: rowHeight)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button("删除", role: .destructive) { store.remove(stock) }
                        }
                }
                .onMove(perform: store.move)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(store.stocks.count) * rowHeight, 480))
            .padding(.vertical, 6)
        }
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

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(stock.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text([stock.code, stock.market, quote?.session].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                Sparkline(points: spark, slots: stock.sparkSlots, baseline: quote?.baseline, color: direction.line)
                    .frame(width: 56, height: 24)

                Text(quote?.last.formatted(.number.precision(.fractionLength(2...3)).grouping(.never)) ?? "--")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(direction.price)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 64, alignment: .trailing)

                Text(quote?.change.formatted(.percent.precision(.fractionLength(2)).sign(strategy: .always())) ?? "--")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(direction.text)
                    .frame(width: 62, height: 22)
                    .background(direction.fill, in: .rect(cornerRadius: 5))
            }
            .monospacedDigit()
            .opacity(stale ? 0.45 : 1)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    /// 涨跌幅放在实心胶囊里，背后的壁纸再花也看得清
    private var direction: (line: Color, price: Color, fill: Color, text: Color) {
        guard let change = quote?.change, change != 0 else { return (.secondary, .primary, .secondary.opacity(0.2), .secondary) }
        return (change > 0) == redUp ? (.quoteRed, .quoteRed, .badgeRed, .white)
                                     : (.quoteGreen, .quoteGreen, .badgeGreen, .white)
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

/// 面板是半透明玻璃，浅色模式下背后多为浅灰：系统的亮绿、亮红、橙色对比度不足，换成深一档的颜色；深色模式沿用系统色
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
