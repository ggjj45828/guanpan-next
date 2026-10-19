import SwiftUI

/// Shared by ETF detail, full-screen chart, asset history, AI evidence and twin lab.
/// The primary y-axis uses trade price only; IOPV is shown as premium/discount on
/// an independent right axis. The cost overlay never changes either axis domain.
struct UnifiedChartView: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let dataset: NextChartDataset?
    let interval: Binding<NextChartInterval>
    let costPerUnit: Decimal?
    @Binding var selectedTime: Date?
    var securityCode: String? = nil
    var expanded = false
    @State private var magnification = 1.0
    @State private var pinchBase: Double?
    @State private var visibleLayers: Set<String> = ["price", "volume", "iopv", "cost"]
    private var activeDataset: NextChartDataset? { dataset?.interval == interval.wrappedValue ? dataset : nil }

    private var samples: [NextChartSample] {
        guard let all = activeDataset?.orderedSamples, !all.isEmpty else { return [] }
        let count = max(2, Int(Double(all.count) / max(1, magnification)))
        return Array(all.suffix(count))
    }
    private var visibleTimeDomain: ClosedRange<Date>? {
        guard let first = samples.first?.timestamp, let last = samples.last?.timestamp else { return nil }
        return first == last ? first.addingTimeInterval(-30)...last.addingTimeInterval(30) : first...last
    }
    private var visiblePriceDomain: ClosedRange<Decimal>? {
        let values = samples.flatMap { [$0.low, $0.high, Optional($0.close)].compactMap { $0 } }
        guard let low = values.min(), let high = values.max() else { return nil }
        let pad = low == high ? max(abs(low) * Decimal(string: "0.01")!, Decimal(string: "0.0001")!) : (high - low) * Decimal(string: "0.06")!
        return (low - pad)...(high + pad)
    }
    private var visiblePremiumDomain: ClosedRange<Decimal>? {
        let values = samples.compactMap { point -> Decimal? in guard let iopv = point.iopv, iopv > 0 else { return nil }; return (point.close / iopv - 1) * 100 }
        guard let low = values.min(), let high = values.max() else { return nil }
        let pad = low == high ? Decimal(string: "0.1")! : (high - low) * Decimal(string: "0.1")!
        return (low - pad)...(high + pad)
    }
    private var displayedCrosshairTime: Date? {
        guard let selectedTime, let visibleTimeDomain else { return nil }
        return min(max(selectedTime, visibleTimeDomain.lowerBound), visibleTimeDomain.upperBound)
    }
    private var selectedSample: NextChartSample? {
        guard let displayedCrosshairTime else { return nil }
        return samples.min { abs($0.timestamp.timeIntervalSince(displayedCrosshairTime)) < abs($1.timestamp.timeIntervalSince(displayedCrosshairTime)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                ForEach(NextChartInterval.allCases, id: \.rawValue) { value in
                    Button { interval.wrappedValue = value; selectedTime = nil } label: {
                        Text(label(value)).font(.system(size: 10, weight: interval.wrappedValue == value ? .semibold : .regular))
                            .foregroundStyle(interval.wrappedValue == value ? p.forest : p.muted)
                            .padding(.vertical, 6).padding(.horizontal, 7)
                            .background(interval.wrappedValue == value ? p.tint : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button { magnification = magnification >= 4 ? 1 : magnification * 1.6; saveChartState() } label: { Image(systemName: "plus.magnifyingglass").font(.system(size: 12)).foregroundStyle(p.forest).frame(minWidth: 30, minHeight: 30) }.accessibilityLabel("缩放图表")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    layerButton("价格", key: "price", available: true)
                    layerButton("成交量", key: "volume", available: samples.contains(where: { $0.volume != nil }))
                    layerButton("IOPV", key: "iopv", available: activeDataset?.iopvSource != nil)
                    layerButton("成本线", key: "cost", available: costPerUnit != nil)
                    layerButton("MA5", key: "ma5", available: samples.count >= 5)
                    layerButton("MA20", key: "ma20", available: samples.count >= 20)
                }
            }
            if samples.isEmpty {
                GPStatus(title: dataset == nil ? "暂无可绘制行情" : "该周期暂无历史数据", detail: dataset == nil ? "接入经过验证的行情源并取得历史数据后，价格、IOPV 和成交量会共用这套图表模型。" : "当前已缓存数据周期为“\(label(dataset!.interval))”。选择对应周期查看；不会把其他周期的数据冒充为本周期。", symbol: "chart.xyaxis.line")
                    .frame(height: expanded ? 430 : 250)
            } else {
                GeometryReader { geometry in
                    Canvas { context, size in draw(context: &context, size: size) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 8).onChanged { value in
                            guard value.startLocation.x > 26, let range = visibleTimeDomain else { return }
                            let rightAxis: CGFloat = dataset?.iopvSource == nil ? 12 : 44
                            let ratio = min(1, max(0, (value.location.x - 43) / max(1, geometry.size.width - 43 - rightAxis)))
                            selectedTime = range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) * ratio)
                        }.onEnded { _ in saveChartState() })
                        .simultaneousGesture(MagnifyGesture().onChanged { value in
                            if pinchBase == nil { pinchBase = magnification }
                            magnification = min(8, max(1, (pinchBase ?? magnification) * Double(value.magnification)))
                        }.onEnded { _ in pinchBase = nil; saveChartState() })
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("chart.plot")
                        .accessibilityLabel("价格、IOPV 溢折价和成交量图表")
                        .accessibilityValue(selectedSample.map { "\($0.timestamp.formatted(date: .numeric, time: .shortened))，价格 ¥\(NextMoney.text($0.close, digits: 4))" } ?? "拖动或使用前后数据点操作查看历史")
                        .accessibilityAction(named: "放大图表") { magnification = min(8, magnification * 1.5); saveChartState() }
                        .accessibilityAction(named: "缩小图表") { magnification = max(1, magnification / 1.5); saveChartState() }
                        .accessibilityAction(named: "上一个数据点") { moveCrosshair(-1) }
                        .accessibilityAction(named: "下一个数据点") { moveCrosshair(1) }
                }.frame(height: expanded ? 430 : 250)
                HStack(spacing: 13) {
                    legend("价格", color: p.forest)
                    if activeDataset?.iopvSource != nil { legend("IOPV 溢折价（右轴）", color: p.terracotta) }
                    if costPerUnit != nil { legend("持仓成本", color: p.muted) }
                    Spacer(minLength: 0)
                    if let point = selectedSample {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("¥\(NextMoney.text(point.close, digits: 4)) · \(point.timestamp.formatted(date: .omitted, time: .shortened))")
                            if let iopv = point.iopv { Text("IOPV ¥\(NextMoney.text(iopv, digits: 4)) · 溢折价 \(NextMoney.text((point.close / iopv - 1) * 100, digits: 2))%") }
                            if let volume = point.volume { Text("成交量 \(NextMoney.text(volume, digits: 0))") }
                        }.font(.system(size: 9, design: .monospaced)).foregroundStyle(p.ink).multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .onAppear { restoreChartState() }
        .onChange(of: interval.wrappedValue) { _, _ in saveChartState() }
        .onChange(of: visibleLayers) { _, _ in saveChartState() }
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        guard let dataset = activeDataset, let domain = visiblePriceDomain, let time = visibleTimeDomain, samples.count > 0 else { return }
        let left: CGFloat = 43, right: CGFloat = dataset.iopvSource == nil ? 12 : 44, top: CGFloat = 9
        let volumeHeight: CGFloat = 34, bottom: CGFloat = 17
        let plot = CGRect(x: left, y: top, width: max(1, size.width - left - right), height: max(1, size.height - top - volumeHeight - bottom))
        for tick in 0...4 {
            let y = plot.minY + plot.height * CGFloat(tick) / 4
            var grid = Path(); grid.move(to: CGPoint(x: plot.minX, y: y)); grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(grid, with: .color(p.line.opacity(0.75)), lineWidth: 0.7)
            let v = domain.upperBound - (domain.upperBound - domain.lowerBound) * Decimal(tick) / 4
            context.draw(Text(NextMoney.text(v, digits: 3)).font(.system(size: 8, design: .monospaced)).foregroundColor(p.muted), at: CGPoint(x: left / 2, y: y))
        }
        if let premiumDomain = visiblePremiumDomain {
            for tick in 0...4 {
                let v = premiumDomain.upperBound - (premiumDomain.upperBound - premiumDomain.lowerBound) * Decimal(tick) / 4
                let y = plot.minY + plot.height * CGFloat(tick) / 4
                context.draw(Text("\(NextMoney.text(v, digits: 2))%").font(.system(size: 8, design: .monospaced)).foregroundColor(p.muted), at: CGPoint(x: size.width - right / 2, y: y))
            }
        }
        func x(_ date: Date) -> CGFloat { plot.minX + plot.width * CGFloat(date.timeIntervalSince(time.lowerBound) / max(0.001, time.upperBound.timeIntervalSince(time.lowerBound))) }
        func priceY(_ value: Decimal) -> CGFloat { plot.maxY - plot.height * CGFloat((value - domain.lowerBound) / max(Decimal(string: "0.0000001")!, domain.upperBound - domain.lowerBound)) }
        var pricePath = Path()
        for (i, point) in samples.enumerated() {
            let pos = CGPoint(x: x(point.timestamp), y: priceY(point.close))
            if i == 0 { pricePath.move(to: pos) } else { pricePath.addLine(to: pos) }
        }
        if visibleLayers.contains("price") { context.stroke(pricePath, with: .color(p.forest), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)) }
        if visibleLayers.contains("iopv"), let premiumDomain = visiblePremiumDomain {
            var iopvPath = Path(); var started = false
            for point in samples {
                guard let iopv = point.iopv, iopv > 0 else { started = false; continue }
                let premium = (point.close / iopv - 1) * 100
                let y = plot.maxY - plot.height * CGFloat((premium - premiumDomain.lowerBound) / max(Decimal(string: "0.0000001")!, premiumDomain.upperBound - premiumDomain.lowerBound))
                let pos = CGPoint(x: x(point.timestamp), y: y)
                if !started { iopvPath.move(to: pos); started = true } else { iopvPath.addLine(to: pos) }
            }
            context.stroke(iopvPath, with: .color(p.terracotta), style: StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
        }
        for (key, period, color) in [("ma5", 5, p.terracotta), ("ma20", 20, p.jade)] where visibleLayers.contains(key) && samples.count >= period {
            var path = Path()
            for index in samples.indices {
                let start = max(0, index - period + 1)
                let window = samples[start...index]
                let average = window.reduce(Decimal.zero) { $0 + $1.close } / Decimal(window.count)
                let point = CGPoint(x: x(samples[index].timestamp), y: priceY(average))
                if index == start { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        if visibleLayers.contains("cost"), let cost = costPerUnit {
            let y = priceY(cost)
            if y >= plot.minY && y <= plot.maxY {
                var costPath = Path(); costPath.move(to: CGPoint(x: plot.minX, y: y)); costPath.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(costPath, with: .color(p.muted), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            } else {
                let labelY = cost < domain.lowerBound ? plot.maxY : plot.minY
                context.draw(Text("成本线超出本段价格轴 · ¥\(NextMoney.text(cost, digits: 3))").font(.system(size: 8, weight: .medium)).foregroundColor(p.muted), at: CGPoint(x: plot.midX, y: labelY))
            }
        }
        if visibleLayers.contains("volume"), let maxVolume = samples.compactMap(\.volume).max(), maxVolume > 0 {
            let barWidth = max(1, plot.width / CGFloat(samples.count) * 0.55)
            for point in samples {
                guard let volume = point.volume else { continue }
                let h = volumeHeight * CGFloat(volume / maxVolume)
                let rect = CGRect(x: x(point.timestamp) - barWidth / 2, y: size.height - bottom - h, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(p.forest.opacity(0.32)))
            }
        }
        if let selectedTime = displayedCrosshairTime {
            let crossX = x(selectedTime)
            var cross = Path(); cross.move(to: CGPoint(x: crossX, y: plot.minY)); cross.addLine(to: CGPoint(x: crossX, y: plot.maxY))
            context.stroke(cross, with: .color(p.terracotta), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }
        context.draw(Text("\(time.lowerBound.formatted(date: .omitted, time: .shortened))").font(.system(size: 8, design: .monospaced)).foregroundColor(p.muted), at: CGPoint(x: plot.minX + 12, y: size.height - 5))
        context.draw(Text("\(time.upperBound.formatted(date: .omitted, time: .shortened))").font(.system(size: 8, design: .monospaced)).foregroundColor(p.muted), at: CGPoint(x: plot.maxX - 12, y: size.height - 5))
    }

    private func label(_ interval: NextChartInterval) -> String { switch interval { case .intraday: "分时"; case .fiveDay: "5日"; case .day: "日K"; case .week: "周K"; case .month: "月K"; case .threeMonth: "3月"; case .year: "1年"; case .all: "全部" } }
    private func restoreChartState() {
        guard let securityCode else { return }
        let state = model.chartState(for: securityCode)
        if let saved = NextChartInterval(rawValue: state.interval) { interval.wrappedValue = saved }
        if !state.visibleLayers.isEmpty { visibleLayers = state.visibleLayers }
        selectedTime = state.crosshairTime
        magnification = min(8, max(1, state.scale))
    }
    private func saveChartState() {
        guard let securityCode else { return }
        var state = model.chartState(for: securityCode)
        state.interval = interval.wrappedValue.rawValue
        state.visibleLayers = visibleLayers
        state.crosshairTime = selectedTime
        state.scale = magnification
        model.saveChartState(state, for: securityCode)
    }
    private func moveCrosshair(_ offset: Int) {
        guard !samples.isEmpty else { return }
        let current = selectedSample.flatMap { sample in samples.firstIndex(of: sample) } ?? (offset > 0 ? -1 : samples.count)
        selectedTime = samples[min(samples.count - 1, max(0, current + offset))].timestamp
        saveChartState()
    }
    private func layerButton(_ title: String, key: String, available: Bool) -> some View {
        let active = visibleLayers.contains(key)
        return Button { if active { visibleLayers.remove(key) } else { visibleLayers.insert(key) } } label: {
            Text(title).font(.system(size: 9, weight: active ? .semibold : .regular)).foregroundStyle(!available ? p.muted.opacity(0.45) : active ? p.forest : p.muted)
                .padding(.horizontal, 8).padding(.vertical, 5).background(active ? p.tint : .clear, in: Capsule())
        }.buttonStyle(.plain).disabled(!available).accessibilityLabel("\(title)指标\(!available ? "不可用" : active ? "已显示" : "已隐藏")")
    }
    private func legend(_ title: String, color: Color) -> some View { HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(title).font(.system(size: 9)).foregroundStyle(p.muted) } }
}
