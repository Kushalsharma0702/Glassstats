import CoreML
import Darwin
import DarwinMetrics
import Foundation
import Metal
import os
import SystemConfiguration

public protocol MonitoringProvider: Actor {
    func cpu() -> [CPUTicks]
    func load() -> [Double]
    func memory() -> MemoryUsage?
    func network(at time: TimeInterval) -> (NetworkCounters, [String])?
    func thermal() -> ThermalState
    func hardware() -> HardwareInfo
    func storage() -> StorageUsage?
    func processes(at time: TimeInterval) -> [ProcessReading]
    func ports() -> SocketInventory
    func process(_ id: ProcessID) -> ProcessReading?
    func resetProcessBaseline()
}

private final class PressureObserver: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: MemoryPressure.unknown)
    private let source = DispatchSource.makeMemoryPressureSource(
        eventMask: [.normal, .warning, .critical], queue: DispatchQueue(label: "GlassStats.MemoryPressure")
    )

    init() {
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = source.data
            let next: MemoryPressure
            if data.contains(.critical) { next = .critical }
            else if data.contains(.warning) { next = .warning }
            else if data.contains(.normal) { next = .normal }
            else { return }
            state.withLock { $0 = next }
        }
        source.activate()
    }

    var value: MemoryPressure { state.withLock { $0 } }
    deinit { source.cancel() }
}

public actor SystemProvider: MonitoringProvider {
    private let pressure = PressureObserver()
    private var previousProcesses: [ProcessID: UInt64] = [:]
    private var previousProcessTime: TimeInterval?
    private var hardwareCache: HardwareInfo?

    public init() {}

    public func cpu() -> [CPUTicks] {
        var result: UnsafeMutablePointer<GSCPUTicks>?
        let count = gs_cpu(&result)
        defer { free(result) }
        return UnsafeBufferPointer(start: result, count: count).map {
            CPUTicks(user: $0.user, system: $0.system, idle: $0.idle, nice: $0.nice)
        }
    }

    public func load() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        return count > 0 ? Array(loads.prefix(Int(count))) : []
    }

    public func memory() -> MemoryUsage? {
        var info = GSMemory()
        guard gs_memory(&info) else { return nil }
        return MemoryUsage(total: info.total, internalBytes: info.internal, wired: info.wired,
                           compressed: info.compressed, purgeable: info.purgeable, cached: info.external,
                           swap: info.has_swap ? info.swap : nil, pressure: pressure.value)
    }

    public func network(at time: TimeInterval) -> (NetworkCounters, [String])? {
        let globalKeys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"]
        let interfaces = globalKeys.compactMap {
            (SCDynamicStoreCopyValue(nil, $0 as CFString) as? [String: Any])?["PrimaryInterface"] as? String
        }
        for name in interfaces {
            var counters = GSNetwork()
            guard gs_network(name, &counters) else { continue }
            return (.init(name: name, received: counters.received, sent: counters.sent, time: time),
                    addresses(for: name))
        }
        return nil
    }

    private func addresses(for interface: String) -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var addresses = Set<String>()
        var cursor = head
        while let entry = cursor {
            let item = entry.pointee
            cursor = item.ifa_next
            guard let addr = item.ifa_addr, String(cString: item.ifa_name) == interface,
                  addr.pointee.sa_family == AF_INET || addr.pointee.sa_family == AF_INET6 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                addresses.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return addresses.sorted()
    }

    public func thermal() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }

    public func hardware() -> HardwareInfo {
        if let hardwareCache { return hardwareCache }
        let gpus = MTLCopyAllDevices().map {
            GPUDevice(name: $0.name, unifiedMemory: $0.hasUnifiedMemory, workingSet: $0.recommendedMaxWorkingSetSize)
        }
        let neural = MLComputeDevice.allComputeDevices.contains {
            if case .neuralEngine = $0 { return true }
            return false
        }
        var model = [CChar](repeating: 0, count: 128)
        var count = model.count
        let result = sysctlbyname("hw.model", &model, &count, nil, 0)
        let modelName = result == 0 ? String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "Mac"
        let info = HardwareInfo(gpus: gpus, neuralEngine: neural, model: modelName)
        hardwareCache = info
        return info
    }

    public func storage() -> StorageUsage? {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity,
              total > 0, free >= 0 else { return nil }
        return .init(capacity: UInt64(total), available: UInt64(free))
    }

    public func resetProcessBaseline() {
        previousProcesses.removeAll()
        previousProcessTime = nil
    }

    public func processes(at time: TimeInterval) -> [ProcessReading] {
        var result: UnsafeMutablePointer<GSProcess>?
        let count = gs_processes(&result)
        defer { free(result) }
        let elapsed = time - (previousProcessTime ?? time)
        var next: [ProcessID: UInt64] = [:]
        let rows = UnsafeBufferPointer(start: result, count: count).map { row -> ProcessReading in
            let id = ProcessID(pid: row.pid, started: row.started)
            next[id] = row.cpu_ns
            let cpu = previousProcesses[id].flatMap { old in
                elapsed > 0 && row.cpu_ns >= old ? Double(row.cpu_ns - old) / (elapsed * 1e9) : nil
            }
            return .init(id: id, name: cString(row.name), memory: row.footprint, cpu: cpu)
        }
        previousProcesses = next
        previousProcessTime = time
        return rows
    }

    public func ports() -> SocketInventory {
        var result: UnsafeMutablePointer<GSSocket>?
        var inspected = 0
        var inaccessible = 0
        let count = gs_sockets(&result, &inspected, &inaccessible)
        defer { free(result) }
        let rows = UnsafeBufferPointer(start: result, count: count).map { row in
            SocketReading(owner: .init(pid: row.owner.pid, started: row.owner.started),
                          process: cString(row.owner.name), address: cString(row.address), service: cString(row.service),
                          port: Int(row.port), transport: row.tcp ? .tcp : .udp, ipv6: row.ipv6, connected: row.connected,
                          scope: row.loopback ? .loopback : row.wildcard ? .wildcard : .interface)
        }
        let unique = Set(rows).sorted { ($0.port, $0.owner.pid, $0.address) < ($1.port, $1.owner.pid, $1.address) }
        return .init(sockets: unique, inspected: inspected, inaccessible: inaccessible, date: .now)
    }

    public func process(_ id: ProcessID) -> ProcessReading? {
        var row = GSProcess()
        guard gs_process(id.pid, &row), row.started == id.started else { return nil }
        return .init(id: id, name: cString(row.name), memory: row.footprint, cpu: nil)
    }

    private func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
