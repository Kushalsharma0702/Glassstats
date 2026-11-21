import Foundation
import GlassStatsCore
import Observation
import SwiftUI
import os
import WidgetKit
import WidgetSnapshot

enum ReadoutMode: String, CaseIterable, Codable {
    case text = "Text", icon = "Icon and value", graph = "Mini graph"
}

enum Appearance: String, CaseIterable, Codable {
    case system = "System", light = "Light", dark = "Dark"
}

struct Preferences: Codable, Equatable {
    var menuBar = true
    var showDashboard = true
    var startMinimized = false
    var appearance = Appearance.system
    var frostGlass: Bool?
    var dashboardModules: Set<Metric>?
    var dashboardActions: Set<DetailPage>?
    var economyMode: Bool?
    var dashboardCharts: Bool?
    var dockerEnabled: Bool?
    var colorAccents = true
    var compact = false
    var alwaysOnTop = false
    var allSpaces = false
    var animations = true
    var lowDensity = false
    var readoutMode = ReadoutMode.icon
    var menuMetrics: [Metric] = [.cpu, .memory]
    var modules = Set(Metric.allCases)
    var cpuInterval = 1.0
    var memoryInterval = 2.0
    var networkInterval = 1.0
    var thermalInterval = 4.0
    var storageInterval = 30.0
    var portInterval = 8.0
    var processInterval = 3.0
    var historyMinutes = 2.0
    var thermalAlerts = false
    var networkAlerts = false
    var networkThreshold = 50.0
    var portsLocalOnly = false
    var processInspection = true
    var persistHistory = false
    var shareWidgets = true

    var cards: Set<Metric> { dashboardModules ?? Set(Metric.allCases) }
    var actions: Set<DetailPage> { dashboardActions ?? [.activity, .processes, .sensors] }

    func isEnabled(_ metric: Metric) -> Bool {
        metric == .docker ? (dockerEnabled ?? true) : modules.contains(metric)
    }

    mutating func enable(_ metric: Metric, _ enabled: Bool) {
        if metric == .docker { dockerEnabled = enabled }
        else if enabled { modules.insert(metric) }
        else { modules.remove(metric) }
    }
}

enum DetailPage: String, CaseIterable, Codable, Identifiable {
    case activity = "Activity", processes = "Processes", sensors = "Sensors", ports = "Ports", docker = "Docker"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .activity: "waveform.path"
        case .processes: "list.bullet.rectangle"
        case .sensors: "thermometer.medium"
        case .ports: "network"
        case .docker: "shippingbox"
        }
    }
}

@MainActor @Observable
final class AppModel {
    var preferences: Preferences {
        didSet {
            guard oldValue != preferences else { return }
            if let data = try? JSONEncoder().encode(preferences) { defaults?.set(data, forKey: "preferences-v1") }
            preferencesChanged?()
            wake()
        }
    }
    private(set) var snapshot = TelemetrySnapshot()
    var detailPage = DetailPage.activity { didSet { if detailPage != oldValue { wake() } } }
    var focusedProcess: ProcessID?
    var dashboardVisible = false { didSet { if dashboardVisible != oldValue { wake() } } }
    var detailsVisible = false { didSet { if detailsVisible != oldValue { wake() } } }
    private(set) var dockerInventory: DockerInventory?
    private let dockerMonitor = DockerMonitor()
    private let portActions = PortActions()
    var alert: String?
    var loginStatusMessage: String?
    var preferencesChanged: (() -> Void)?
    var didSample: (() -> Void)?
    var widgetStatus: String?
    private let defaults: UserDefaults?
    private let widgetLocation: URL?
    private let engine = TelemetryEngine()
    private let log = Logger(subsystem: "org.glassstats.app", category: "sampling")
    private var task: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var wakeCount = 0
    private var dockerTask: Task<Void, Never>?
    private var dockerDue = 0.0
    private var refreshPorts = false
    private var reset = false
    private var clear = false
    private var lastWidgetWrite = Date.distantPast
    private let started = Date.now

    init(defaults: UserDefaults? = .standard, widgets: Bool = true) {
        self.defaults = defaults
        widgetLocation = widgets ? WidgetSnapshot.location : nil
        preferences = defaults?.data(forKey: "preferences-v1").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
            ?? Preferences()
    }

    func cardBinding(_ metric: Metric) -> Binding<Bool> {
        Binding(get: { self.preferences.cards.contains(metric) }, set: { shown in
            var cards = self.preferences.cards
            if shown { cards.insert(metric) } else { cards.remove(metric) }
            self.preferences.dashboardModules = cards
        })
    }

    var widgetSharingAvailable: Bool { widgetLocation != nil }

    func start() {
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let generation = wakeCount
                let delay = await update()
                guard !Task.isCancelled else { return }
                if generation != wakeCount { continue }
                let timer = Task<Void, Never> {
                    try? await ContinuousClock().sleep(for: .seconds(delay), tolerance: .milliseconds(60))
                }
                sleeper = timer
                await timer.value
                sleeper = nil
            }
        }
    }

    func stop() {
        task?.cancel()
        sleeper?.cancel()
        dockerTask?.cancel()
        task = nil
    }

    private func wake() {
        wakeCount &+= 1
        sleeper?.cancel()
    }

    func requestPorts() { refreshPorts = true; wake() }

    func requestDocker() { dockerDue = 0; wake() }

    func resetBaselines() { reset = true; wake() }

    func clearHistory() {
        clear = true
        removeWidgetSnapshot()
        wake()
    }

    func preparePortClose(_ rows: [SocketReading]) async -> PortStopPlan {
        await portActions.prepare(rows)
    }

    func closePorts(_ plan: PortStopPlan) async -> PortStopResult {
        let result = await portActions.confirm(plan)
        requestPorts()
        return result
    }

    func clearWidgetIfDisabled() {
        if !preferences.shareWidgets { removeWidgetSnapshot() }
    }

    func process(_ id: ProcessID) async -> ProcessReading? {
        guard preferences.processInspection else { return nil }
        return await engine.process(id)
    }

    private func update() async -> Double {
        let prefs = preferences
        let widgetDemand = widgetLocation != nil && prefs.shareWidgets
        let activity = detailsVisible && detailPage == .activity
        let sensors = detailsVisible && detailPage == .sensors
        let portsOpen = detailsVisible && detailPage == .ports
        let dockerOpen = detailsVisible && detailPage == .docker
        let processOpen = detailsVisible && detailPage == .processes
        let economy = prefs.economyMode ?? false
        let cards = dashboardVisible ? prefs.cards : []
        let status = prefs.menuBar ? Set(prefs.menuMetrics.filter(prefs.isEnabled).prefix(prefs.lowDensity ? 2 : 4)) : []
        var demand = cards.union(status)
        if activity { demand.formUnion([.cpu, .memory, .network, .storage]) }
        if sensors { demand.formUnion([.thermal, .gpu, .neural]) }
        if portsOpen { demand.insert(.ports) }
        if dashboardVisible && prefs.thermalAlerts { demand.insert(.thermal) }
        if dashboardVisible && prefs.networkAlerts { demand.insert(.network) }
        if widgetDemand { demand.formUnion([.cpu, .memory, .network, .thermal, .ports]) }
        if prefs.persistHistory { demand.formUnion([.cpu, .memory, .network]) }

        var policy = SamplingPolicy()
        policy.enabled = Set(demand.filter(prefs.isEnabled)).subtracting([.fans, .docker])
        policy.cpu = prefs.cpuInterval
        policy.memory = prefs.memoryInterval
        policy.network = prefs.networkInterval
        policy.thermal = prefs.thermalInterval
        policy.storage = prefs.storageInterval
        policy.ports = prefs.portInterval
        policy.processes = prefs.processInterval
        policy.processInspection = prefs.processInspection
        policy.interactive = (dashboardVisible || activity || sensors || portsOpen || processOpen) && !economy
        policy.recordHistory = activity || widgetDemand || prefs.persistHistory ||
            (dashboardVisible && (prefs.dashboardCharts ?? true) && !economy) ||
            (prefs.menuBar && prefs.readoutMode == .graph && !economy)
        policy.history = prefs.historyMinutes * 60
        policy.persistHistory = prefs.persistHistory
        let ports = refreshPorts
        let rebase = reset
        let erase = clear
        refreshPorts = false
        reset = false
        clear = false
        let dockerDelay = updateDocker(enabled: prefs.isEnabled(.docker) && (cards.contains(.docker) || dockerOpen),
                                       economy: economy)
        let next = await engine.sample(policy: policy, scanPorts: ports,
                                       scanProcesses: processOpen,
                                       resetBaselines: rebase, clearHistory: erase)
        if next.revision != snapshot.revision {
            let previous = snapshot
            snapshot = next
            updateAlerts(previous: previous)
            didSample?()
        }
        if !erase && !clear { saveWidgetSnapshot() }
        let delay = await engine.nextDelay(policy: policy, scanProcesses: processOpen)
        let widgetDelay = max(0.05, lastWidgetWrite == .distantPast
            ? 2 - Date.now.timeIntervalSince(started) : 300 - Date.now.timeIntervalSince(lastWidgetWrite))
        return min(delay, dockerDelay, widgetDemand ? widgetDelay : .infinity)
    }

    private func updateDocker(enabled: Bool, economy: Bool) -> Double {
        guard enabled else {
            if dockerInventory != nil { dockerInventory = nil }
            dockerDue = 0
            return .infinity
        }
        let time = ProcessInfo.processInfo.systemUptime
        if dockerTask == nil && time >= dockerDue {
            dockerTask = Task(priority: .utility) { [weak self, dockerMonitor] in
                let reading = await dockerMonitor.read()
                guard let self, !Task.isCancelled else { return }
                dockerInventory = reading
                let interval = reading.containers == nil ? 20.0 : 5.0
                dockerDue = ProcessInfo.processInfo.systemUptime + interval * (economy ? 2 : 1)
                dockerTask = nil
                wake()
            }
        }
        return dockerTask == nil ? max(0.05, dockerDue - time) : .infinity
    }

    private func updateAlerts(previous: TelemetrySnapshot) {
        if preferences.thermalAlerts, let thermal = snapshot.thermal, previous.thermal != thermal,
           thermal == .serious || thermal == .critical {
            alert = "Thermal pressure is \(thermal.rawValue.lowercased())."
        }
        let threshold = preferences.networkThreshold * 1_000_000
        func peak(_ reading: NetworkUsage?) -> Double { max(reading?.rate?.down ?? 0, reading?.rate?.up ?? 0) }
        if preferences.networkAlerts, peak(snapshot.network) >= threshold, peak(previous.network) < threshold {
            alert = "Network activity reached \(Display.rate(peak(snapshot.network)))."
        }
    }

    private func saveWidgetSnapshot() {
        let now = Date.now
        guard widgetLocation != nil, preferences.shareWidgets,
              now.timeIntervalSince(started) >= 2,
              now.timeIntervalSince(lastWidgetWrite) >= 5 * 60 else { return }
        lastWidgetWrite = now
        let reading = WidgetSnapshot(
            date: .now, cpu: snapshot.cpu?.total, memory: snapshot.memory?.fraction,
            down: snapshot.network?.rate?.down, up: snapshot.network?.rate?.up,
            thermal: snapshot.thermal?.rawValue, ports: snapshot.ports?.inspected == 0 ? nil : snapshot.ports?.listeners,
            cpuHistory: snapshot.history.cpu.values.suffix(40).map(\.value),
            memoryHistory: snapshot.history.memory.values.suffix(40).map(\.value),
            networkHistory: snapshot.history.down.values.suffix(40).map(\.value))
        do {
            try reading.save()
            widgetStatus = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            widgetStatus = "The shared widget snapshot could not be written."
            log.error("Could not publish widget snapshot")
        }
    }

    private func removeWidgetSnapshot() {
        guard let widgetLocation else { return }
        do {
            try FileManager.default.removeItem(at: widgetLocation)
            WidgetCenter.shared.reloadAllTimelines()
            lastWidgetWrite = .now
            widgetStatus = nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            widgetStatus = nil
        } catch {
            widgetStatus = "The shared widget snapshot could not be removed."
        }
    }
}

enum Display {
    static func percent(_ value: Double?) -> String {
        value?.formatted(.percent.precision(.fractionLength(0))) ?? "—"
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(UInt64.max) else { return "—" }
        if value < 1_000 { return "\(Int(value).formatted()) B/s" }
        return "\(bytes(UInt64(value)))/s"
    }
}
