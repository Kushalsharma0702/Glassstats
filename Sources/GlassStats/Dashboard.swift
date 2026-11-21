import GlassStatsCore
import SwiftUI

struct Dashboard: View {
    let model: AppModel
    let close: () -> Void
    let settings: () -> Void
    let show: (DetailPage) -> Void
    var documentationPreview = false
    @Environment(\.colorScheme) private var scheme

    private var compact: Bool { model.preferences.compact }
    private var enabled: Set<Metric> { Set(model.preferences.cards.filter(model.preferences.isEnabled)) }
    private var charts: Bool { (model.preferences.dashboardCharts ?? true) && !(model.preferences.economyMode ?? false) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if documentationPreview {
                tiles.frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView { tiles }
                    .defaultScrollAnchor(.top)
                    .scrollIndicators(.automatic)
            }
            footer
        }
        .modifier(DashboardSurface(frosted: model.preferences.frostGlass ?? false, documentationPreview: documentationPreview))
        .frame(minWidth: 330, minHeight: 360)
        .tint(color(.memory))
    }

    private var tiles: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 11) {
            if let alert = model.alert { alertBanner(alert) }
            let cards = [Metric.cpu, .memory, .gpu, .neural, .thermal, .fans].filter { enabled.contains($0) }
            if !cards.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                    ForEach(cards) { metric in tile(metric) }
                }
            }
            if enabled.contains(.network) { networkTile }
            if enabled.contains(.ports) { portsTile }
            if enabled.contains(.docker) { dockerTile }
            if enabled.contains(.storage) { storageTile }
            if enabled.isEmpty {
                ContentUnavailableView("No visible cards", systemImage: "rectangle.grid.2x2",
                                       description: Text("Choose cards from the dashboard menu."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .padding(.top, 2)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform.path")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color(.memory))
                .frame(width: 39, height: 39)
                .background(color(.memory).opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(color(.memory).opacity(0.24)) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("GlassStats").font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(model.snapshot.hardware?.model ?? "System Monitor")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            headerButton(compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                         compact ? "Expand dashboard" : "Compact dashboard") { model.preferences.compact.toggle() }
            if documentationPreview {
                headerButton("slider.horizontal.3", "Dashboard cards") {}
            } else {
                Menu {
                    ForEach(Metric.allCases) { metric in
                        Toggle(metric.rawValue, isOn: model.cardBinding(metric))
                            .disabled(!model.preferences.isEnabled(metric))
                    }
                    Divider()
                    Toggle("Charts", isOn: Binding(get: { model.preferences.dashboardCharts ?? true },
                                                   set: { model.preferences.dashboardCharts = $0 }))
                    Button("Settings…", action: settings)
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                        .frame(width: 29, height: 29)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Dashboard cards")
                .accessibilityLabel("Dashboard cards")
            }
            headerButton("xmark", "Hide dashboard", action: close)
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 13)
        .accessibilityElement(children: .contain)
    }

    private func headerButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .frame(width: 29, height: 29)
                .background(.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func tile(_ metric: Metric) -> some View {
        let data = model.snapshot
        let accent = color(metric)
        return MetricTile(metric: metric, accent: accent, compact: compact) {
            switch metric {
            case .cpu:
                MetricValue(value: Display.percent(data.cpu?.total), compact: compact)
                    .accessibilityLabel("CPU utilization")
                    .accessibilityValue(Display.percent(data.cpu?.total))
                note(data.cpu.map { "\($0.cores.count) logical cores" } ?? "Sampling CPU")
                if !compact && charts {
                    Sparkline(primary: data.history.cpu.values, accent: accent, scale: 0...1,
                               label: "CPU history")
                        .frame(height: 24)
                }
            case .memory:
                MetricValue(value: data.memory.map { Display.bytes($0.used) } ?? "—", compact: compact)
                    .accessibilityLabel("Memory used")
                    .accessibilityValue(data.memory.map { Display.bytes($0.used) } ?? "Unavailable")
                note(data.memory.map { "of \(Display.bytes($0.total)) · \(Display.percent($0.fraction))" } ?? "Reading memory")
                if !compact && charts {
                    Sparkline(primary: data.history.memory.values, accent: accent, scale: 0...1,
                               label: "Memory history")
                        .frame(height: 24)
                }
            case .gpu:
                MetricValue(value: data.hardware?.gpus.isEmpty == false ? "Detected" : "Unavailable", compact: compact)
                note(data.hardware?.gpus.first?.name ?? "Metal device")
                if !compact { note("Utilization unavailable") }
            case .neural:
                MetricValue(value: data.hardware.map { $0.neuralEngine ? "Available" : "Unavailable" } ?? "—", compact: compact)
                note("Live utilization unavailable")
                if !compact { note("Core ML profiling") }
            case .thermal:
                MetricValue(value: data.thermal?.rawValue ?? "—", compact: compact)
                    .foregroundStyle(thermalColor)
                note("System thermal pressure")
                if !compact { note("Temperature sensor unavailable") }
            case .fans:
                MetricValue(value: "Unavailable", compact: compact)
                note("Fan speed reading")
                if !compact { note("Hardware-dependent") }
            default:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var thermalColor: Color {
        switch model.snapshot.thermal {
        case .critical: .red
        case .serious, .fair: color(.thermal)
        default: .primary
        }
    }

    private var networkTile: some View {
        let network = model.snapshot.network
        let accent = color(.network)
        return MetricTile(metric: .network, accent: accent, compact: compact) {
            HStack(alignment: .firstTextBaseline, spacing: 17) {
                VStack(alignment: .leading, spacing: 3) {
                    note("Download")
                    MetricValue(value: Display.rate(network?.rate?.down), compact: compact)
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    note("Upload")
                    MetricValue(value: Display.rate(network?.rate?.up), compact: compact)
                        .foregroundStyle(color(.memory))
                }
                Spacer(minLength: 0)
                if let name = network?.name {
                    Text(name).font(.caption.monospaced())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.primary.opacity(0.08), in: Capsule())
                        .help(network?.addresses.joined(separator: "\n") ?? "")
                }
            }
            if charts {
                let down = model.snapshot.history.down.values
                let up = model.snapshot.history.up.values
                let peak = max(1024, down.lazy.map(\.value).max() ?? 0, up.lazy.map(\.value).max() ?? 0)
                Sparkline(primary: down, secondary: up, accent: accent, comparison: color(.memory),
                          scale: 0...(peak * 1.12), label: "Download and upload history")
                    .frame(height: compact ? 24 : 43)
            }
            if network == nil { note("No primary network interface") }
        }
        .accessibilityElement(children: .contain)
    }

    private var portsTile: some View {
        let ports = model.snapshot.ports
        let count = ports.map { $0.inspected == 0 ? "Unavailable" : "\($0.listeners) listening" } ?? "Discovering sockets"
        return Button { show(.ports) } label: {
            HStack(spacing: 11) {
                Image(systemName: Metric.ports.symbol).foregroundStyle(color(.ports))
                    .font(.system(size: 16)).frame(width: 25)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open ports").font(.system(size: 12, weight: .semibold))
                    note(count)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 13).padding(.vertical, compact ? 8 : 10)
            .contentShape(Rectangle())
            .modifier(GlassTile())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the port inspector")
    }

    private var dockerTile: some View {
        let containers = model.dockerInventory?.containers
        let status = containers.map { rows in
            "\(rows.lazy.filter { $0.state == "running" }.count) running · \(rows.count) total"
        } ?? (model.dockerInventory == nil ? "Checking Docker…" : "Docker unavailable")
        return Button { show(.docker) } label: {
            HStack {
                Label("Docker", systemImage: Metric.docker.symbol).foregroundStyle(color(.docker))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                note(status)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .contentShape(Rectangle())
            .modifier(GlassTile())
        }
        .buttonStyle(.plain)
    }

    private var storageTile: some View {
        let storage = model.snapshot.storage
        return HStack {
            Label("Storage", systemImage: Metric.storage.symbol).font(.system(size: 11, weight: .semibold))
            Spacer()
            note(storage.map { "\(Display.bytes($0.available)) available" } ?? "Unavailable")
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
        .modifier(GlassTile())
    }

    @ViewBuilder private var footer: some View {
        let actions = DetailPage.allCases.filter { model.preferences.actions.contains($0) }
        if !actions.isEmpty {
        HStack(spacing: 3) {
            ForEach(actions) { page in
                Button { show(page) } label: {
                    Label(page.rawValue, systemImage: page.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(.primary.opacity(0.065), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 15)
        } else {
            Spacer().frame(height: 12)
        }
    }

    private func alertBanner(_ alert: String) -> some View {
        HStack {
            Label(alert, systemImage: "exclamationmark.triangle.fill")
            Spacer()
            Button("Dismiss", systemImage: "xmark") { model.alert = nil }.labelStyle(.iconOnly)
        }
        .font(.caption.weight(.medium))
        .padding(9)
        .background(.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.80)
    }

    private func color(_ metric: Metric) -> Color {
        metric.color(in: scheme, custom: model.preferences.colorAccents)
    }
}
