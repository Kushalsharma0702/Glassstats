import Charts
import GlassStatsCore
import SwiftUI

extension Metric {
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "square.stack.3d.up"
        case .neural: "point.3.connected.trianglepath.dotted"
        case .thermal: "thermometer.medium"
        case .fans: "fan"
        case .network: "arrow.up.arrow.down"
        case .storage: "internaldrive"
        case .ports: "point.3.filled.connected.trianglepath.dotted"
        case .docker: "shippingbox"
        }
    }

    func color(in scheme: ColorScheme, custom: Bool) -> Color {
        guard custom else { return .accentColor }
        let dark = scheme == .dark
        return switch self {
        case .cpu: dark ? Color(red: 0.40, green: 0.90, blue: 1) : Color(red: 0.03, green: 0.38, blue: 0.58)
        case .memory: dark ? Color(red: 0.78, green: 0.63, blue: 1) : .purple
        case .gpu: dark ? .mint : Color(red: 0.04, green: 0.43, blue: 0.33)
        case .neural: dark ? Color(red: 0.67, green: 0.70, blue: 1) : .indigo
        case .thermal: dark ? .orange : Color(red: 0.66, green: 0.30, blue: 0.06)
        case .fans, .storage: dark ? .white.opacity(0.76) : .secondary
        case .network: dark ? Color(red: 0.43, green: 0.94, blue: 0.80) : Color(red: 0.02, green: 0.43, blue: 0.41)
        case .ports: dark ? Color(red: 0.80, green: 0.71, blue: 1) : .indigo
        case .docker: dark ? .cyan : Color(red: 0.04, green: 0.39, blue: 0.67)
        }
    }
}

struct DashboardSurface: ViewModifier {
    let frosted: Bool
    var documentationPreview = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var noTransparency
    private let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    func body(content: Content) -> some View {
        content.background {
            if noTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else if frosted && !documentationPreview {
                if #available(macOS 26, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
        }
        .overlay {
            shape.strokeBorder(.white.opacity(scheme == .dark ? 0.45 : 0.65), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct GlassTile: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        content.background((scheme == .dark ? Color.black.opacity(0.23) : Color.white.opacity(0.32)), in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(scheme == .dark ? 0.21 : 0.50))
                    .allowsHitTesting(false)
            }
    }
}

struct Sparkline: View {
    let primary: [HistoryPoint]
    var secondary: [HistoryPoint] = []
    let accent: Color
    var comparison: Color = .purple
    var scale: ClosedRange<Double>
    var label: String

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
            guard plot.width > 0, plot.height > 0,
                  let start = [primary.first?.date, secondary.first?.date].compactMap({ $0 }).min(),
                  let end = [primary.last?.date, secondary.last?.date].compactMap({ $0 }).max(),
                  end > start else {
                let baseline = Path { path in
                    path.move(to: .init(x: 0, y: size.height - 1))
                    path.addLine(to: .init(x: size.width, y: size.height - 1))
                }
                context.stroke(baseline, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
                return
            }
            let duration = end.timeIntervalSince(start)
            func project(_ point: HistoryPoint) -> CGPoint {
                let clamped = min(scale.upperBound, max(scale.lowerBound, point.value))
                let y = (clamped - scale.lowerBound) / (scale.upperBound - scale.lowerBound)
                return CGPoint(x: plot.minX + plot.width * point.date.timeIntervalSince(start) / duration,
                               y: plot.maxY - plot.height * y)
            }

            if primary.count >= 2 {
                let points = primary.map(project)
                let line = smoothed(points)
                var area = line
                if let first = points.first, let last = points.last {
                    area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                    area.addLine(to: CGPoint(x: first.x, y: plot.maxY))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [accent.opacity(0.30), accent.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)
                    ))
                }
                context.stroke(line, with: .color(accent), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            if secondary.count >= 2 {
                context.stroke(smoothed(secondary.map(project)), with: .color(comparison),
                               style: StrokeStyle(lineWidth: 1.35, lineCap: .round, dash: [3, 3]))
            }
        }
        .accessibilityLabel(label)
    }

    private func smoothed(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for (previous, next) in zip(points, points.dropFirst()) {
                let middleX = (previous.x + next.x) / 2
                path.addCurve(to: next, control1: CGPoint(x: middleX, y: previous.y),
                              control2: CGPoint(x: middleX, y: next.y))
            }
        }
    }
}

struct TrendChart: View {
    let primary: [HistoryPoint]
    var secondary: [HistoryPoint] = []
    let accent: Color
    var comparison: Color = .purple
    var scale: ClosedRange<Double>
    var animate = true
    var label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if primary.count < 2 && secondary.count < 2 {
            Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .accessibilityHidden(true)
        } else {
            Group {
                if #available(macOS 15, *) {
                    modernChart
                } else {
                    Chart { legacyMarks }
                        .chartXScale(range: .plotDimension(padding: 2))
                        .chartYScale(domain: scale)
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                }
            }
            .animation(reduceMotion || !animate ? nil : .easeOut(duration: 0.22), value: primary.last?.date)
            .accessibilityLabel(label)
        }
    }

    @available(macOS 15, *)
    private var modernChart: some View {
        Chart {
            AreaPlot(primary, x: .value("Time", \.date), y: .value("Value", \.value))
                .foregroundStyle(.linearGradient(colors: [accent.opacity(0.25), accent.opacity(0.01)],
                                                 startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LinePlot(primary, x: .value("Time", \.date), y: .value("Value", \.value))
                .foregroundStyle(accent)
                .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            if !secondary.isEmpty {
                LinePlot(secondary, x: .value("Time", \.date), y: .value("Upload", \.value))
                    .foregroundStyle(comparison)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(range: .plotDimension(padding: 2))
        .chartYScale(domain: scale)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    @ChartContentBuilder private var legacyMarks: some ChartContent {
        ForEach(primary) { point in
            AreaMark(x: .value("Time", point.date), y: .value("Value", point.value))
                .foregroundStyle(.linearGradient(colors: [accent.opacity(0.25), accent.opacity(0.01)],
                                                 startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Metric", "Primary"))
                .foregroundStyle(accent)
                .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        ForEach(secondary) { point in
            LineMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Metric", "Upload"))
                .foregroundStyle(comparison)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                .interpolationMethod(.monotone)
        }
    }
}

struct MetricTile<Content: View>: View {
    let metric: Metric
    let accent: Color
    let compact: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            Label(metric.rawValue, systemImage: metric.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .labelStyle(.titleAndIcon)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 10 : 13)
        .modifier(GlassTile())
    }
}

struct MetricValue: View {
    let value: String
    var compact = false

    var body: some View {
        Text(value)
            .font(.system(size: compact ? 21 : 28, weight: .light))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }
}
