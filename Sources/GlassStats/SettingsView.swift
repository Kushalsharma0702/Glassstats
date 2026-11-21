import GlassStatsCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    let showDashboard: () -> Void
    let launchAtLogin: () -> Bool
    let setLaunchAtLogin: (Bool) -> Void
    @State private var login = false
    @State private var confirmClear = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            monitoring.tabItem { Label("Monitoring", systemImage: "waveform.path") }
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
            developer.tabItem { Label("Developer", systemImage: "hammer") }
            privacy.tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .padding(12)
        .frame(minWidth: 540, idealWidth: 580, minHeight: 440, idealHeight: 480)
        .onAppear { login = launchAtLogin() }
    }

    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { login }, set: {
                    setLaunchAtLogin($0)
                    login = launchAtLogin()
                }))
                .disabled(Bundle.main.bundleIdentifier == nil)
                if let message = model.loginStatusMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                Toggle("Show dashboard on launch", isOn: $model.preferences.showDashboard)
                Toggle("Start minimized", isOn: $model.preferences.startMinimized)
                    .disabled(!model.preferences.showDashboard)
            }
            Section("Dashboard") {
                Button("Show dashboard", action: showDashboard)
                Toggle("Float above other windows", isOn: $model.preferences.alwaysOnTop)
                Toggle("Show across Spaces and full-screen apps", isOn: $model.preferences.allSpaces)
                Text("Show or hide with ⌃⌥⌘G.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Show in menu bar", isOn: $model.preferences.menuBar)
                Toggle("Low density", isOn: $model.preferences.lowDensity)
                    .disabled(!model.preferences.menuBar)
                Picker("Readout style", selection: $model.preferences.readoutMode) {
                    ForEach(ReadoutMode.allCases, id: \.self) { Text($0.rawValue) }
                }.disabled(!model.preferences.menuBar)
                ForEach(model.preferences.menuMetrics) { metric in
                    HStack {
                        Text(metric.rawValue)
                        Spacer()
                        metricButton("chevron.up", "Move \(metric.rawValue) up") { move(metric, by: -1) }
                            .disabled(model.preferences.menuMetrics.first == metric)
                        metricButton("chevron.down", "Move \(metric.rawValue) down") { move(metric, by: 1) }
                            .disabled(model.preferences.menuMetrics.last == metric)
                        metricButton("minus.circle", "Remove \(metric.rawValue)") {
                            model.preferences.menuMetrics.removeAll { $0 == metric }
                        }
                    }
                }
                let candidates: [Metric] = [.cpu, .memory, .thermal, .network, .storage, .ports]
                Menu("Add menu bar metric") {
                    ForEach(candidates.filter { !model.preferences.menuMetrics.contains($0) }) { metric in
                        Button(metric.rawValue) { model.preferences.menuMetrics.append(metric) }
                    }
                }.disabled(candidates.allSatisfy(model.preferences.menuMetrics.contains))
            }
        }.formStyle(.grouped)
    }

    private var monitoring: some View {
        Form {
            Section("Modules") {
                ForEach(Metric.allCases) { metric in
                    Toggle(metric.rawValue, isOn: Binding(
                        get: { model.preferences.isEnabled(metric) },
                        set: { model.preferences.enable(metric, $0) }
                    ))
                }
            }
            Section("Sampling") {
                Toggle("Low Power", isOn: Binding(get: { model.preferences.economyMode ?? false },
                                                  set: { model.preferences.economyMode = $0 }))
                Text("Low Power slows live sampling and hides dashboard sparklines.")
                    .font(.caption).foregroundStyle(.secondary)
                interval("CPU", $model.preferences.cpuInterval, options: [1, 2, 3, 5, 10])
                interval("Memory", $model.preferences.memoryInterval, options: [1, 2, 3, 5, 10])
                interval("Network", $model.preferences.networkInterval, options: [1, 2, 3, 5, 10])
                interval("Thermal pressure", $model.preferences.thermalInterval, options: [2, 4, 5, 10, 30])
                interval("Storage", $model.preferences.storageInterval, options: [10, 30, 60, 120])
                Picker("History duration", selection: $model.preferences.historyMinutes) {
                    ForEach([1.0, 2.0, 5.0, 10.0, 30.0], id: \.self) { Text("\(Int($0)) minutes") }
                }
            }
            Section("Dashboard alerts") {
                Toggle("Elevated thermal pressure", isOn: $model.preferences.thermalAlerts)
                Toggle("High network throughput", isOn: $model.preferences.networkAlerts)
                Picker("Network threshold", selection: $model.preferences.networkThreshold) {
                    ForEach([1.0, 10.0, 25.0, 50.0, 100.0, 500.0], id: \.self) { Text("\(Int($0)) MB/s") }
                }.disabled(!model.preferences.networkAlerts)
            }
        }.formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Picker("Appearance", selection: $model.preferences.appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue) }
            }
            Toggle("Frosted glass", isOn: Binding(get: { model.preferences.frostGlass ?? false },
                                                 set: { model.preferences.frostGlass = $0 }))
            Toggle("Color-coded accents", isOn: $model.preferences.colorAccents)
            Toggle("Compact dashboard", isOn: $model.preferences.compact)
            Toggle("Animate activity charts", isOn: $model.preferences.animations)
            Section("Dashboard cards") {
                ForEach(Metric.allCases) { metric in
                    Toggle(metric.rawValue, isOn: model.cardBinding(metric))
                        .disabled(!model.preferences.isEnabled(metric))
                }
            }
            Section("Dashboard shortcuts") {
                ForEach(DetailPage.allCases) { page in
                    Toggle(page.rawValue, isOn: Binding(get: { model.preferences.actions.contains(page) }, set: { shown in
                        var actions = model.preferences.actions
                        if shown { actions.insert(page) } else { actions.remove(page) }
                        model.preferences.dashboardActions = actions
                    }))
                }
            }
        }.formStyle(.grouped)
    }

    private var developer: some View {
        Form {
            Toggle("Discover local ports", isOn: Binding(
                get: { model.preferences.modules.contains(.ports) },
                set: { if $0 { model.preferences.modules.insert(.ports) } else { model.preferences.modules.remove(.ports) } }
            ))
            interval("Port refresh", $model.preferences.portInterval, options: [5, 8, 10, 15, 30, 60])
            Toggle("Open inspector with Localhost filter", isOn: $model.preferences.portsLocalOnly)
            Toggle("Inspect processes", isOn: $model.preferences.processInspection)
            interval("Process refresh", $model.preferences.processInterval, options: [2, 3, 5, 10, 15])
            Text("GlassStats reads local socket metadata with your account’s existing permissions. Process sampling runs when you open the process inspector.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("Local data") {
                Text("GlassStats reads system statistics, local process metadata, and socket bind addresses. It collects no analytics and sends no data off this Mac.")
                Toggle("Store recent chart history on disk", isOn: $model.preferences.persistHistory)
                Toggle("Share aggregate snapshots with GlassStats widgets", isOn: $model.preferences.shareWidgets)
                    .disabled(!model.widgetSharingAvailable)
                if let status = model.widgetStatus { Text(status).foregroundStyle(.secondary) }
                if !model.widgetSharingAvailable {
                    Text("Widget snapshot sharing requires an App Group build.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Clear local history…", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear local history?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear History", role: .destructive) { model.clearHistory() }
                    }
            }
            Section("Permissions") {
                Text("GlassStats runs with your existing permissions. It uses no privileged helper. macOS can restrict metadata for other accounts and protected processes.")
            }
        }.formStyle(.grouped)
    }

    private func interval(_ name: String, _ selection: Binding<Double>, options: [Double]) -> some View {
        Picker(name, selection: selection) {
            ForEach(options, id: \.self) { Text("\(Int($0)) seconds") }
        }
    }

    private func metricButton(_ icon: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(name, systemImage: icon, action: action)
            .labelStyle(.iconOnly).help(name).accessibilityLabel(name)
    }

    private func move(_ metric: Metric, by offset: Int) {
        guard let from = model.preferences.menuMetrics.firstIndex(of: metric) else { return }
        let to = from + offset
        guard model.preferences.menuMetrics.indices.contains(to) else { return }
        model.preferences.menuMetrics.swapAt(from, to)
    }
}
