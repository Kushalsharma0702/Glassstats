import Foundation

public actor TelemetryEngine {
    private let provider: any MonitoringProvider
    private var snapshot = TelemetrySnapshot()
    private var due: [Metric: TimeInterval] = [:]
    private var processDue = -Double.infinity
    private var historyDue = -Double.infinity
    private var previousCPU: [CPUTicks] = []
    private var previousNetwork: NetworkCounters?
    private var received: UInt64 = 0
    private var sent: UInt64 = 0
    private var historyStore: HistoryStore?
    private var previousPolicy: SamplingPolicy?

    public init(provider: any MonitoringProvider = SystemProvider()) {
        self.provider = provider
    }

    public func process(_ id: ProcessID) async -> ProcessReading? {
        await provider.process(id)
    }

    // The app drives this method from one task. On-demand actions join the next pass.
    public func sample(policy: SamplingPolicy, scanPorts: Bool, scanProcesses: Bool,
                       resetBaselines: Bool = false, clearHistory: Bool = false) async -> TelemetrySnapshot {
        let time = ProcessInfo.processInfo.systemUptime
        let date = Date.now
        let cutoff = date.addingTimeInterval(-policy.history)
        if resetBaselines {
            snapshot.revision &+= 1
            due.removeAll()
            previousCPU = []
            previousNetwork = nil
            processDue = -.infinity
            await provider.resetProcessBaseline()
        }
        if previousPolicy != policy {
            snapshot.revision &+= 1
            let becomingInteractive = policy.interactive && previousPolicy?.interactive == false
            for metric in policy.enabled where becomingInteractive || previousPolicy?.enabled.contains(metric) != true {
                due.removeValue(forKey: metric)
            }
            if !policy.persistHistory { historyStore = nil }
            if policy.persistHistory, historyStore == nil {
                historyStore = HistoryStore()
                if previousPolicy == nil, let historyStore { snapshot.history = historyStore.load(cutoff: cutoff) }
            }
            previousPolicy = policy
        }
        if clearHistory {
            snapshot.revision &+= 1
            snapshot.history = MetricHistory()
            if let historyStore { historyStore.clear() }
            else { HistoryStore()?.clear() }
        }
        let active = policy.interactive ? 1.0 : 3.0
        if !policy.enabled.contains(.cpu) {
            previousCPU = []
            snapshot.cpu = nil
            snapshot.load = []
        } else if shouldSample(.cpu, at: time, interval: policy.cpu * active) {
            let cpu = await provider.cpu()
            snapshot.cpu = CPUUsage.calculate(previous: previousCPU, current: cpu)
            snapshot.load = await provider.load()
            previousCPU = cpu
            if policy.recordHistory, let reading = snapshot.cpu { snapshot.history.cpu.add(reading.total, at: date, cutoff: cutoff) }
        }

        if !policy.enabled.contains(.memory) { snapshot.memory = nil }
        else if shouldSample(.memory, at: time, interval: policy.memory * active) {
            snapshot.memory = await provider.memory()
            if policy.recordHistory, let memory = snapshot.memory { snapshot.history.memory.add(memory.fraction, at: date, cutoff: cutoff) }
        }

        if !policy.enabled.contains(.network) {
            previousNetwork = nil
            snapshot.network = nil
        } else if shouldSample(.network, at: time, interval: policy.network * active) {
            await sampleNetwork(time: time, date: date, cutoff: cutoff, record: policy.recordHistory)
        }

        if !policy.enabled.contains(.thermal) { snapshot.thermal = nil }
        else if shouldSample(.thermal, at: time, interval: policy.thermal * active) {
            snapshot.thermal = await provider.thermal()
        }
        if !policy.enabled.contains(.storage) { snapshot.storage = nil }
        else if shouldSample(.storage, at: time, interval: policy.storage * active) {
            snapshot.storage = await provider.storage()
        }
        if policy.enabled.contains(.gpu) || policy.enabled.contains(.neural) {
            if snapshot.hardware == nil { snapshot.hardware = await provider.hardware() }
        } else {
            snapshot.hardware = nil
        }

        if !policy.processInspection || !scanProcesses {
            if snapshot.processes != nil {
                snapshot.revision &+= 1
                await provider.resetProcessBaseline()
                processDue = -.infinity
                snapshot.processes = nil
            }
        } else if scanProcesses, time >= processDue {
            snapshot.revision &+= 1
            processDue = time + policy.processes
            snapshot.processes = await provider.processes(at: time)
        }

        if !policy.enabled.contains(.ports) { snapshot.ports = nil }
        else if shouldSample(.ports, at: time, interval: policy.ports * active, forced: scanPorts) {
            snapshot.ports = await provider.ports()
        }

        snapshot.history.cpu.prune(before: cutoff)
        snapshot.history.memory.prune(before: cutoff)
        snapshot.history.down.prune(before: cutoff)
        snapshot.history.up.prune(before: cutoff)
        if let historyStore, time >= historyDue, !clearHistory {
            historyDue = time + 5
            historyStore.write(date: date, values: [snapshot.cpu?.total, snapshot.memory?.fraction,
                                                     snapshot.network?.rate?.down, snapshot.network?.rate?.up], cutoff: cutoff)
        }
        return snapshot
    }

    public func nextDelay(policy: SamplingPolicy, scanProcesses: Bool) -> Double {
        let clock = ProcessInfo.processInfo.systemUptime
        let scheduled = policy.enabled.compactMap { due[$0] }.min() ?? .infinity
        let processes = scanProcesses && policy.processInspection ? processDue : .infinity
        let history = historyStore != nil ? historyDue : .infinity
        return max(0.05, min(300, min(scheduled, processes, history) - clock))
    }

    private func shouldSample(_ metric: Metric, at time: TimeInterval, interval: Double, forced: Bool = false) -> Bool {
        guard forced || time >= due[metric, default: -.infinity] else { return false }
        due[metric] = time + interval
        snapshot.revision &+= 1
        return true
    }

    private func sampleNetwork(time: TimeInterval, date: Date, cutoff: Date, record: Bool) async {
        guard let (counters, addresses) = await provider.network(at: time) else {
            previousNetwork = nil
            snapshot.network = nil
            return
        }
        let rate = previousNetwork.flatMap { counters.delta(from: $0) }
        previousNetwork = counters
        if let rate {
            received += rate.received
            sent += rate.sent
            if record {
                snapshot.history.down.add(rate.down, at: date, cutoff: cutoff)
                snapshot.history.up.add(rate.up, at: date, cutoff: cutoff)
            }
        }
        snapshot.network = .init(name: counters.name, addresses: addresses, rate: rate, downloaded: received, uploaded: sent)
    }
}
