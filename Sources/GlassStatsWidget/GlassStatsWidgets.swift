import SwiftUI
import WidgetKit

private enum WidgetMetric: String, CaseIterable {
    case cpu = "CPU", memory = "Memory", thermal = "Temperature", network = "Network", ports = "Developer Ports", overview = "System Overview"
    var kind: String { "GlassStats." + String(describing: self) }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .thermal: "thermometer.medium"
        case .network: "arrow.up.arrow.down"
        case .ports: "network"
        case .overview: "waveform.path"
        }
    }

    var accent: Color {
        switch self {
        case .cpu: .cyan
        case .memory: .purple
        case .thermal: .orange
        case .network: .teal
        case .ports, .overview: .indigo
        }
    }

    var link: URL? {
        switch self {
        case .ports: URL(string: "glassstats://ports")
        case .thermal: URL(string: "glassstats://sensors")
        default: URL(string: "glassstats://dashboard")
        }
    }
}

private struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        let value = WidgetSnapshot.load()
        let current = Entry(date: now, snapshot: value)
        if let value, value.date > now.addingTimeInterval(-20 * 60) {
            let expired = Entry(date: value.date.addingTimeInterval(20 * 60), snapshot: nil)
            completion(Timeline(entries: [current, expired], policy: .after(now.addingTimeInterval(15 * 60))))
        } else {
            completion(Timeline(entries: [Entry(date: now, snapshot: nil)], policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }
}

private protocol WidgetModule { static var metric: WidgetMetric { get } }
private enum CPUWidget: WidgetModule { static let metric = WidgetMetric.cpu }
private enum MemoryWidget: WidgetModule { static let metric = WidgetMetric.memory }
private enum ThermalWidget: WidgetModule { static let metric = WidgetMetric.thermal }
private enum NetworkWidget: WidgetModule { static let metric = WidgetMetric.network }
private enum PortsWidget: WidgetModule { static let metric = WidgetMetric.ports }
private enum OverviewWidget: WidgetModule { static let metric = WidgetMetric.overview }

private struct ModuleWidget<Module: WidgetModule>: Widget {
    private var metric: WidgetMetric { Module.metric }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: metric.kind, provider: Provider()) { entry in
            WidgetReadout(metric: metric, entry: entry)
                .widgetURL(metric.link)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [metric.accent.opacity(0.22), Color.purple.opacity(0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName(metric.rawValue)
        .description("Recent \(metric.rawValue.lowercased()) readings from GlassStats.")
        .supportedFamilies(metric == .overview ? [.systemSmall, .systemMedium, .systemLarge] : [.systemSmall, .systemMedium])
    }
}

private struct WidgetReadout: View {
    let metric: WidgetMetric
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(metric.rawValue, systemImage: metric.symbol)
                .font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 3)
            if let data = entry.snapshot, data.date > entry.date.addingTimeInterval(-20 * 60) {
                reading(data)
                Spacer(minLength: 2)
                HStack(spacing: 2) {
                    Text("Updated")
                    Text(data.date, style: .time)
                }
                .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(WidgetSnapshot.isConfigured ? "Open GlassStats to collect a snapshot." : "An App Group build is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private func reading(_ data: WidgetSnapshot) -> some View {
        switch metric {
        case .cpu: value(percent(data.cpu)); graph(data.cpuHistory, max: 1)
        case .memory: value(percent(data.memory)); graph(data.memoryHistory, max: 1)
        case .thermal:
            value(data.thermal ?? "Unavailable")
            Text("Thermal pressure").font(.caption).foregroundStyle(.secondary)
        case .network:
            value("↓ " + rate(data.down))
            Text("↑ " + rate(data.up)).font(.caption.monospacedDigit())
            if family != .systemSmall { graph(data.networkHistory, max: max(1024, data.networkHistory.max() ?? 0)) }
        case .ports:
            value(data.ports.map(String.init) ?? "—")
            Text("TCP listeners").font(.caption).foregroundStyle(.secondary)
        case .overview:
            if family == .systemSmall {
                overviewRow("CPU", percent(data.cpu))
                overviewRow("RAM", percent(data.memory))
            } else {
                overviewRow("CPU", percent(data.cpu))
                overviewRow("Memory", percent(data.memory))
                overviewRow("Thermal pressure", data.thermal ?? "—")
                if family == .systemLarge {
                    overviewRow("Download", rate(data.down))
                    overviewRow("Upload", rate(data.up))
                    overviewRow("TCP listeners", data.ports.map(String.init) ?? "—")
                    graph(data.cpuHistory, max: 1)
                }
            }
        }
    }

    private func value(_ string: String) -> some View {
        Text(string).font(.system(size: family == .systemSmall ? 23 : 29, weight: .light))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
    }

    private func overviewRow(_ title: String, _ string: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(string).monospacedDigit().fontWeight(.medium)
        }.font(.caption)
    }

    private func graph(_ values: [Double], max: Double) -> some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: size.width * Double(index) / Double(values.count - 1),
                                    y: size.height * (1 - min(1, value / max)))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        .frame(height: family == .systemLarge ? 45 : 18)
        .accessibilityHidden(true)
    }

    private func percent(_ value: Double?) -> String {
        value?.formatted(.percent.precision(.fractionLength(0))) ?? "—"
    }

    private func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        if value < 1_000 { return "\(Int(value).formatted()) B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
    }
}

@main
struct GlassStatsWidgets: WidgetBundle {
    var body: some Widget {
        ModuleWidget<CPUWidget>()
        ModuleWidget<MemoryWidget>()
        ModuleWidget<ThermalWidget>()
        ModuleWidget<NetworkWidget>()
        ModuleWidget<PortsWidget>()
        ModuleWidget<OverviewWidget>()
    }
}
