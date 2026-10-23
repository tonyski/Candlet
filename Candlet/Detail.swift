import SwiftUI

/// 点开一只自选后的详情：现价、分时或 K 线、当日行情
struct StockDetail: View {
    let stock: Stock
    let close: () -> Void
    @Environment(Store.self) private var store
    @AppStorage("redUp") private var redUp = true
    /// nil 为分时
    @State private var period: KPeriod?
    @State private var candles: [KPeriod: [Candle]] = [:]
    /// 分时等了几秒还没有，才显示「暂无数据」，刚添加的股票不会先闪一下
    @State private var sparksWaited = false

    private var quote: Quote? { store.quotes[stock.symbol] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            title
            price
            // 和分组标签同一种样式，不用系统分段控件，免得在半透明面板上显得突兀
            HStack(spacing: 2) {
                ForEach([nil] + KPeriod.allCases.map(Optional.some), id: \.self) { item in
                    Button(item?.title ?? "分时") { period = item }
                        .buttonStyle(.plain)
                        .foregroundStyle(period == item ? .primary : .secondary)
                        .groupTab(active: period == item)
                }
            }
            .padding(.leading, -8)   // 标签自带 8pt 内边距，文字与上面对齐
            chart
                .frame(height: 180)
            stats
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        // 先加载正在看的图；股票的当日开高低和成交量取最新一根日 K，所以日 K 总要加载（加密货币用推送里的 24 小时统计）。
        // 每次打开详情都重新拉；没拉到（比如长桥还在连接）的，切换标签时再试
        .task(id: period) {
            var wanted = [period].compactMap { $0 }
            if !stock.isCrypto, period != .day { wanted.append(.day) }
            for item in wanted where candles[item]?.isEmpty ?? true {
                candles[item] = await store.candles(stock.symbol, item)
            }
        }
    }

    /// 顶栏只放返回和数据来源，名称作为标题放到下面
    private var header: some View {
        HStack(spacing: 8) {
            Button("返回", systemImage: "chevron.left", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            Spacer()
            // 数据来源：切换长桥行情时在这里确认
            if let source = quote?.source {
                Text(source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 36)
    }

    /// 名称，下面一行是代码和市场
    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stock.displayName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(stock.subtitle)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, -8)      // 紧贴顶栏
        .padding(.bottom, -4)   // 和现价同属一组，比页面其他间距略紧
    }

    /// 左边是现价和涨跌；右边有更新的盘前盘后成交时并排一个小号报价，否则是更新时间
    private var price: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.price(quote?.last))
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let quote {
                    change(quote.last - quote.prevClose, quote.change)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(tint)
            Spacer(minLength: 12)
            if let extended = quote?.latestExtended {
                VStack(alignment: .trailing, spacing: 2) {
                    // 只到分钟：新浪的盘前盘后时间本来就没有秒
                    Text("\(extended.session.name) \(Format.time(extended.time, seconds: false))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(Format.price(extended.last))
                        .font(.system(size: 14, weight: .semibold))
                    change(extended.last - extended.prevClose, extended.change)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(color(extended.change))
                }
                .lineLimit(1)
            } else if let time = quote?.time, time > .distantPast {
                Text(Format.updated(time))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }

    /// +4.49  +1.32%
    private func change(_ amount: Double, _ percent: Double) -> some View {
        HStack(spacing: 8) {
            Text(amount.formatted(.number.precision(.fractionLength(2...3)).sign(strategy: .always())))
            Text(Format.percent(percent))
        }
    }

    @ViewBuilder
    private var chart: some View {
        if let period {
            if let bars = candles[period] {
                CandleChart(candles: bars, period: period, rising: rising, falling: falling)
                    .id(period)   // 切换周期时回到最新
            } else {
                ChartPlaceholder(loading: true)
            }
        } else if let points = store.sparks[stock.symbol], let range = Sparkline.range(points, baseline: quote?.prevClose) {
            // 股票横轴是整个常规时段，两端标开盘、收盘；加密货币是最近 24 小时，标首尾时间（昨天的带日期，免得像倒过来）
            let session = stock.market?.session
                ?? (Format.time(points[0].time, seconds: false), Format.time(points[points.count - 1].time, seconds: false))
            ChartAxes(high: range.upperBound, low: range.lowerBound, start: session.open, end: session.close) {
                Sparkline(points: points, slots: stock.market?.sparkSlots ?? 0, baseline: quote?.prevClose, color: tint)
            }
        } else if !sparksWaited {
            ChartPlaceholder(loading: true)
                .task {
                    // 切到 K 线时任务被取消，sleep 提前返回，这时不算等过
                    guard (try? await Task.sleep(for: .seconds(5))) != nil else { return }
                    sparksWaited = true
                }
        } else {
            ChartPlaceholder()
        }
    }

    /// 两行三列。加密货币是 24 小时滚动统计，开盘价就是 24 小时前的价格，所以少一格「昨收」
    private var stats: some View {
        let crypto = stock.isCrypto
        let today = crypto ? quote?.rolling : candles[.day]?.last
        let prevClose = quote?.prevClose
        let amplitude = today.flatMap { t in prevClose.flatMap { $0 > 0 ? (t.high - t.low) / $0 : nil } }
        let span = crypto ? "24 小时" : ""
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                stat(crypto ? "24 小时前" : "今开", Format.price(today?.open))
                stat(span + "最高", Format.price(today?.high))
                stat(span + "最低", Format.price(today?.low))
            }
            GridRow {
                if !crypto { stat("昨收", Format.price(prevClose)) }
                stat(span + "成交量", today.map { Format.compact($0.volume) } ?? "--")
                stat("振幅", amplitude.map { $0.formatted(.percent.precision(.fractionLength(2))) } ?? "--")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rising: Color { redUp ? .quoteRed : .quoteGreen }
    private var falling: Color { redUp ? .quoteGreen : .quoteRed }

    private var tint: Color { color(quote?.change ?? 0) }

    private func color(_ change: Double) -> Color {
        change == 0 ? .primary : change > 0 ? rising : falling
    }
}

/// 图表区的占位：加载中转圈，否则「暂无数据」
struct ChartPlaceholder: View {
    var loading = false

    var body: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Text("暂无数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 图表的刻度：右侧标出图上的最高、最低价，下方标出首尾时间。K 线和分时共用；
/// K 线下方还有成交量副图，右上角标出可见区间的最大量
struct ChartAxes<Chart: View, Volume: View>: View {
    let high: Double
    let low: Double
    let start: String
    let end: String
    /// nil 时不显示成交量副图
    let volumeMax: Double?
    let chart: Chart
    let volume: Volume

    init(high: Double, low: Double, start: String, end: String, volumeMax: Double?,
         @ViewBuilder chart: () -> Chart, @ViewBuilder volume: () -> Volume) {
        (self.high, self.low, self.start, self.end, self.volumeMax) = (high, low, start, end, volumeMax)
        (self.chart, self.volume) = (chart(), volume())
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                chart
                gutter {
                    VStack(alignment: .trailing) {
                        Text(Format.price(high))
                        Spacer()
                        Text(Format.price(low))
                    }
                }
            }
            if let volumeMax {
                HStack(spacing: 6) {
                    volume
                    gutter { Text(Format.compact(volumeMax)).frame(maxHeight: .infinity, alignment: .top) }
                }
                .frame(height: 32)
            }
            HStack(spacing: 6) {
                HStack {
                    Text(start)
                    Spacer()
                    Text(end)
                }
                gutter { EmptyView() }
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// 右侧标注栏：每行都按最长的标注取同一宽度，各行的图才能左右对齐
    private func gutter(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack(alignment: .trailing) {
            VStack {
                Text(Format.price(high))
                Text(Format.price(low))
                if let volumeMax { Text(Format.compact(volumeMax)) }
            }
            .hidden()
            .frame(height: 0)
            content()
        }
    }
}

extension ChartAxes where Volume == EmptyView {
    /// 没有成交量的图（分时）
    init(high: Double, low: Double, start: String, end: String, @ViewBuilder chart: () -> Chart) {
        self.init(high: high, low: low, start: start, end: end, volumeMax: nil, chart: chart) { EmptyView() }
    }
}

/// 蜡烛图：一次显示最近 60 根，左右拖动翻看更早的；右侧标出可见区间的最高、最低价，下方是成交量和首尾日期
struct CandleChart: View {
    let candles: [Candle]
    let period: KPeriod
    let rising: Color
    let falling: Color
    /// 从最新一根往回翻了几根，始终在有效范围内
    @State private var offset = 0
    /// 本次拖动已计入 offset 的根数；每次只加新增的部分，拖到头再往回拖能立即响应
    @State private var applied = 0
    @State private var width: CGFloat = 1

    private static let visible = 60
    private var count: Int { min(Self.visible, candles.count) }

    var body: some View {
        let shown = candles[(candles.count - count - offset)..<(candles.count - offset)]
        if let high = shown.map(\.high).max(), let low = shown.map(\.low).min(), high > low {
            // 没有成交量的数据源（全为 0）不画副图
            let volumeMax = shown.map(\.volume).max().flatMap { $0 > 0 ? $0 : nil }
            ChartAxes(high: high, low: low, start: label(shown[shown.startIndex].time), end: label(shown[shown.endIndex - 1].time),
                      volumeMax: volumeMax) {
                Canvas { context, size in
                    let step = size.width / CGFloat(shown.count)
                    func y(_ price: Double) -> CGFloat { size.height * (1 - (price - low) / (high - low)) }
                    for (i, candle) in shown.enumerated() {
                        let x = (CGFloat(i) + 0.5) * step
                        let color = color(candle)
                        var wick = Path()
                        wick.move(to: CGPoint(x: x, y: y(candle.high)))
                        wick.addLine(to: CGPoint(x: x, y: y(candle.low)))
                        context.stroke(wick, with: .color(color), lineWidth: 1)
                        let top = y(max(candle.open, candle.close)), bottom = y(min(candle.open, candle.close))
                        let body = CGRect(x: x - step * 0.35, y: top, width: step * 0.7, height: max(bottom - top, 1))
                        context.fill(Path(body), with: .color(color))
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            } volume: {
                // 和上面的蜡烛逐根对齐，颜色同涨跌，调淡一些
                Canvas { context, size in
                    guard let volumeMax else { return }
                    let step = size.width / CGFloat(shown.count)
                    for (i, candle) in shown.enumerated() where candle.volume > 0 {
                        let height = max(size.height * candle.volume / volumeMax, 1)
                        let bar = CGRect(x: (CGFloat(i) + 0.15) * step, y: size.height - height, width: step * 0.7, height: height)
                        context.fill(Path(bar), with: .color(color(candle).opacity(0.6)))
                    }
                }
            }
            .contentShape(.rect)
            // 向右拖看更早的，松手停在那里；在蜡烛和成交量上拖都可以
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let total = Int((value.translation.width / (width / CGFloat(count))).rounded())
                    offset = min(max(offset + total - applied, 0), candles.count - count)
                    applied = total
                }
                .onEnded { _ in applied = 0 })
        } else {
            ChartPlaceholder()
        }
    }

    private func color(_ candle: Candle) -> Color { candle.close >= candle.open ? rising : falling }

    /// 日 K 约三个月，标月日；周 K、月 K 跨年，标年月；年 K 只标年
    private func label(_ time: Date) -> String {
        switch period {
        case .day: time.formatted(.verbatim("\(month: .twoDigits)/\(day: .twoDigits)", timeZone: .current, calendar: .current))
        case .week, .month: time.formatted(.verbatim("\(year: .defaultDigits)/\(month: .twoDigits)", timeZone: .current, calendar: .current))
        case .year: time.formatted(.verbatim("\(year: .defaultDigits)", timeZone: .current, calendar: .current))
        }
    }
}
