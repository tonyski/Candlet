import SwiftUI

/// 列表和详情页共用的数字、时间格式
enum Format {
    /// 更新于 15:42:39
    static func updated(_ time: Date) -> String { "更新于 " + Self.time(time) }

    /// 15:42:39；不是今天的带上日期，免得把昨天的收盘价当成刚更新的
    static func time(_ time: Date, seconds: Bool = true) -> String {
        guard Calendar.current.isDateInToday(time) else { return time.formatted(.dateTime.month().day().hour().minute()) }
        return time.formatted(date: .omitted, time: seconds ? .standard : .shortened)
    }

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

    /// 4.94万亿、1334亿、12.3亿
    static func compact(_ value: Double) -> String {
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
                Text(stock.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(stock.subtitle)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Self.detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                Sparkline(points: spark, slots: stock.market?.sparkSlots ?? 0, baseline: quote?.prevClose, color: direction.line)
                    .frame(width: 56, height: 24)

                // 两列对齐：价格在价格下方，涨跌幅在胶囊下方（参考富途）
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Text(Format.price(quote?.last))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(direction.price)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)   // 小价格币的有效数字较长
                            .frame(width: Self.priceWidth, alignment: .trailing)
                        Badge(change: quote?.change, marketCap: marketCap, currency: stock.market?.currency, fill: direction.fill, text: direction.text)
                    }
                    if let extended = quote?.latestExtended {
                        HStack(spacing: 8) {
                            Text(Format.price(extended.last))
                                .frame(width: Self.priceWidth, alignment: .trailing)
                            HStack(spacing: 3) {
                                Text(Format.percent(extended.change))
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
        }
        .opacity(stale ? 0.45 : 1)   // 整行调淡，名称也一起，一眼看出这行还没更新
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .help(tooltip)
    }

    /// 收盘后、断线时价格不再跳动，悬停能看到是什么时候的价格
    private var tooltip: String {
        // 加密货币的涨跌是 24 小时滚动的，和股票的当日涨跌不同
        let prefix = stock.isCrypto ? "24 小时涨跌幅，" : ""
        guard let time = quote?.latestExtended?.time ?? quote?.time, time > .distantPast else { return prefix + "暂无行情" }
        let original = stock.alias == nil ? "" : "\n原名：\(stock.name)"
        return "\(prefix)\(Format.updated(time))\(original)"
    }

    /// 第二排文字（代码、市场、延长时段）统一用的灰色
    static let detail = Color.primary.opacity(0.6)
    /// 价格列与胶囊列，第二行按这两列对齐
    static let priceWidth: CGFloat = 72
    static let badgeWidth: CGFloat = 62

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
        guard showMarketCap, let currency else { return Text(change.map(Format.percent) ?? "--") }
        guard let marketCap else { return Text("--") }
        return Text("\(Text(currency).font(.system(size: 9.5, weight: .semibold)))\(Format.compact(marketCap))")
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

    /// 图的纵轴范围：价格连同昨收；不到两个点或是一条平线时为 nil，不画
    static func range(_ points: [SparkPoint], baseline: Double?) -> ClosedRange<Double>? {
        let values = points.map(\.price) + [baseline].compactMap { $0 }
        guard points.count > 1, let low = values.min(), let high = values.max(), high > low else { return nil }
        return low...high
    }

    var body: some View {
        let prices = points.map(\.price)
        if let range = Self.range(points, baseline: baseline) {
            let (low, high) = (range.lowerBound, range.upperBound)
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
