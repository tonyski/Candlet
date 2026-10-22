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

    private var quote: Quote? { store.quotes[stock.symbol] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
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
                .frame(height: 150)
            stats
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        // 先加载正在看的图；当日开高低和成交量取最新一根日 K，所以日 K 总要加载。
        // 每次打开详情都重新拉；没拉到（比如长桥还在连接）的，切换标签时再试
        .task(id: period) {
            for item in [period ?? .day, .day] where candles[item]?.isEmpty ?? true {
                candles[item] = await store.candles(stock.symbol, item)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button("返回", systemImage: "chevron.left", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            Text(stock.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(stock.subtitle)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
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

    /// 现价一行，涨跌额和涨跌幅在下面一行，右下角是更新时间
    private var price: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(StockRow.price(quote?.last))
                .font(.system(size: 28, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 10) {
                if let quote {
                    Text((quote.last - quote.prevClose).formatted(.number.precision(.fractionLength(2...3)).sign(strategy: .always())))
                    Text(StockRow.percent(quote.change))
                }
                Spacer()
                if let time = quote?.time, time > .distantPast {
                    Text(StockRow.updated(time))
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(tint)
        .monospacedDigit()
    }

    @ViewBuilder
    private var chart: some View {
        if let period {
            if let bars = candles[period] {
                CandleChart(candles: bars, period: period, rising: rising, falling: falling)
                    .id(period)   // 切换周期时回到最新
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let points = store.sparks[stock.symbol], points.count > 1 {
            Sparkline(points: points, slots: stock.sparkSlots, baseline: quote?.prevClose, color: tint)
        } else {
            Text("暂无数据")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 两行三列；加密货币的「昨收」其实是 24 小时前的价格
    private var stats: some View {
        let today = candles[.day]?.last
        let prevClose = quote?.prevClose
        let amplitude = today.flatMap { t in prevClose.flatMap { $0 > 0 ? (t.high - t.low) / $0 : nil } }
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                stat("今开", StockRow.price(today?.open))
                stat("最高", StockRow.price(today?.high))
                stat("最低", StockRow.price(today?.low))
            }
            GridRow {
                stat(stock.isCrypto ? "24 小时前" : "昨收", StockRow.price(prevClose))
                stat("成交量", today.map { Badge.compact($0.volume) } ?? "--")
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

    private var tint: Color {
        guard let change = quote?.change, change != 0 else { return .primary }
        return change > 0 ? rising : falling
    }
}

/// 蜡烛图：一次显示最近 60 根，左右拖动翻看更早的；右侧标出可见区间的最高、最低价，下方标出首尾日期
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
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Canvas { context, size in
                        let step = size.width / CGFloat(shown.count)
                        func y(_ price: Double) -> CGFloat { size.height * (1 - (price - low) / (high - low)) }
                        for (i, candle) in shown.enumerated() {
                            let x = (CGFloat(i) + 0.5) * step
                            let color = candle.close >= candle.open ? rising : falling
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
                    .contentShape(.rect)
                    // 向右拖看更早的，松手停在那里
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let total = Int((value.translation.width / (width / CGFloat(count))).rounded())
                            offset = min(max(offset + total - applied, 0), candles.count - count)
                            applied = total
                        }
                        .onEnded { _ in applied = 0 })
                    VStack(alignment: .trailing) {
                        Text(StockRow.price(high))
                        Spacer()
                        Text(StockRow.price(low))
                    }
                }
                HStack {
                    Text(label(shown[shown.startIndex].time))
                    Spacer()
                    Text(label(shown[shown.endIndex - 1].time))
                }
                .padding(.trailing, 40)
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        } else {
            Text("暂无数据")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 日 K 约三个月，标月日；周 K、月 K 跨年，标年月；年 K 只标年
    private func label(_ time: Date) -> String {
        switch period {
        case .day: time.formatted(.verbatim("\(month: .twoDigits)/\(day: .twoDigits)", timeZone: .current, calendar: .current))
        case .week, .month: time.formatted(.verbatim("\(year: .defaultDigits)/\(month: .twoDigits)", timeZone: .current, calendar: .current))
        case .year: time.formatted(.verbatim("\(year: .defaultDigits)", timeZone: .current, calendar: .current))
        }
    }
}
