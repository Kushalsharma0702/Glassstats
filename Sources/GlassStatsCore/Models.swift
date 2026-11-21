import Foundation

public struct CPUTicks: Equatable, Sendable {
    public let user, system, idle, nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32 = 0) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public struct CPUUsage: Sendable {
    public let user, system: Double
    public let cores: [Double?]
    public var total: Double { user + system }

    public static func calculate(previous: [CPUTicks], current: [CPUTicks]) -> Self? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        var user: UInt64 = 0
        var system: UInt64 = 0
        var total: UInt64 = 0
        let cores: [Double?] = zip(previous, current).map { old, new in
            let u = UInt64(new.user &- old.user) + UInt64(new.nice &- old.nice)
            let s = UInt64(new.system &- old.system)
            let ticks = u + s + UInt64(new.idle &- old.idle)
            user += u
            system += s
            total += ticks
            return ticks == 0 ? nil : Double(u + s) / Double(ticks)
        }
        guard total > 0 else { return nil }
        return Self(user: Double(user) / Double(total), system: Double(system) / Double(total), cores: cores)
    }
}

public enum MemoryPressure: String, Sendable {
    case unknown = "Awaiting pressure event"
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"
}

public struct MemoryUsage: Sendable {
    public let total, used, available, compressed, cached: UInt64
    public let swap: UInt64?
    public let pressure: MemoryPressure
    public var fraction: Double { Double(used) / Double(total) }

    public init?(total: UInt64, internalBytes: UInt64, wired: UInt64, compressed: UInt64,
                 purgeable: UInt64, cached: UInt64, swap: UInt64?, pressure: MemoryPressure) {
        guard total > 0 else { return nil }
        self.total = total
        let app = internalBytes - min(internalBytes, purgeable)
        let wiredBytes = min(total, wired)
        let compressedBytes = min(total - wiredBytes, compressed)
        self.used = wiredBytes + compressedBytes + min(total - wiredBytes - compressedBytes, app)
        self.available = total - used
        self.compressed = compressed
        self.cached = cached
        self.swap = swap
        self.pressure = pressure
    }
}

public struct NetworkCounters: Sendable {
    public let name: String
    public let received, sent: UInt64
    public let time: TimeInterval

    public init(name: String, received: UInt64, sent: UInt64, time: TimeInterval) {
        self.name = name
        self.received = received
        self.sent = sent
        self.time = time
    }

    public func delta(from previous: Self) -> NetworkDelta? {
        let seconds = time - previous.time
        guard seconds.isFinite, seconds > 0, name == previous.name,
              received >= previous.received, sent >= previous.sent else { return nil }
        return .init(received: received - previous.received, sent: sent - previous.sent, seconds: seconds)
    }
}

public struct NetworkDelta: Sendable {
    public let received, sent: UInt64
    public let seconds: TimeInterval
    public var down: Double { Double(received) / seconds }
    public var up: Double { Double(sent) / seconds }
}

public struct NetworkUsage: Sendable {
    public let name: String
    public let addresses: [String]
    public let rate: NetworkDelta?
    public let downloaded, uploaded: UInt64
}

public struct ProcessID: Hashable, Sendable {
    public let pid: Int32
    public let started: UInt64
}

public struct ProcessReading: Identifiable, Sendable {
    public let id: ProcessID
    public let name: String
    public let memory: UInt64
    public let cpu: Double?
}

public enum SocketTransport: String, CaseIterable, Sendable {
    case tcp = "TCP", udp = "UDP"
}

public enum SocketScope: String, Sendable {
    case loopback = "Localhost", wildcard = "All interfaces", interface = "Interface"
}

public struct SocketReading: Identifiable, Hashable, Sendable {
    public let owner: ProcessID
    public let process, address, service: String
    public let port: Int
    public let transport: SocketTransport
    public let ipv6, connected: Bool
    public let scope: SocketScope
    public var id: Self { self }
    public var status: String { transport == .tcp ? "Listening" : connected ? "Connected" : "Bound" }
    public var endpoint: String { ipv6 ? "[\(address)]:\(port)" : "\(address):\(port)" }
}

public struct SocketInventory: Sendable {
    public let sockets: [SocketReading]
    public let inspected, inaccessible: Int
    public let date: Date
    public var listeners: Int { sockets.filter { $0.transport == .tcp }.count }
}

public enum ThermalState: String, Codable, Sendable {
    case nominal = "Nominal", fair = "Fair", serious = "Serious", critical = "Critical", unknown = "Unavailable"
}

public struct GPUDevice: Sendable {
    public let name: String
    public let unifiedMemory: Bool
    public let workingSet: UInt64
}

public struct HardwareInfo: Sendable {
    public let gpus: [GPUDevice]
    public let neuralEngine: Bool
    public let model: String
}

public struct StorageUsage: Sendable {
    public let capacity, available: UInt64
}

public struct HistoryPoint: Identifiable, Sendable {
    public let date: Date
    public let value: Double
    public var id: Date { date }
}

public struct HistoryBuffer: Sendable {
    private var points: [HistoryPoint] = []
    private var skip = 0
    public var values: [HistoryPoint] { Array(points[skip...]) }

    public init() {}

    mutating func add(_ value: Double, at date: Date, cutoff: Date) {
        points.append(.init(date: date, value: value))
        prune(before: cutoff)
    }

    mutating func prune(before date: Date) {
        while skip < points.count, points[skip].date < date { skip += 1 }
        if skip >= 128 || points.count > 4096 {
            points = Array(points.suffix(min(points.count - skip, 2048)))
            skip = 0
        }
    }
}

public struct MetricHistory: Sendable {
    public var cpu = HistoryBuffer()
    public var memory = HistoryBuffer()
    public var down = HistoryBuffer()
    public var up = HistoryBuffer()
}

public struct TelemetrySnapshot: Sendable {
    public internal(set) var revision: UInt64 = 0
    public var cpu: CPUUsage?
    public var load: [Double] = []
    public var memory: MemoryUsage?
    public var network: NetworkUsage?
    public var thermal: ThermalState?
    public var hardware: HardwareInfo?
    public var storage: StorageUsage?
    public var processes: [ProcessReading]?
    public var ports: SocketInventory?
    public var history = MetricHistory()

    public init() {}
}

public enum Metric: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpu = "CPU", memory = "Memory", gpu = "GPU", neural = "Neural Engine"
    case thermal = "Temperature", fans = "Fans", network = "Network", storage = "Storage", ports = "Ports", docker = "Docker"
    public var id: Self { self }
}

public struct SamplingPolicy: Equatable, Sendable {
    public var enabled = Set(Metric.allCases)
    public var cpu: Double = 1
    public var memory: Double = 2
    public var network: Double = 1
    public var thermal: Double = 4
    public var storage: Double = 30
    public var ports: Double = 8
    public var processes: Double = 3
    public var history: Double = 120
    public var interactive = true
    public var processInspection = true
    public var persistHistory = false
    public var recordHistory = true
    public init() {}
}
