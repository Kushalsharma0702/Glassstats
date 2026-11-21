import Foundation

public struct WidgetSnapshot: Codable, Sendable {
    public let date: Date
    public let cpu, memory, down, up: Double?
    public let thermal: String?
    public let ports: Int?
    public let cpuHistory, memoryHistory, networkHistory: [Double]

    public init(date: Date, cpu: Double?, memory: Double?, down: Double?, up: Double?, thermal: String?,
                ports: Int?, cpuHistory: [Double], memoryHistory: [Double], networkHistory: [Double]) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.down = down
        self.up = up
        self.thermal = thermal
        self.ports = ports
        self.cpuHistory = cpuHistory
        self.memoryHistory = memoryHistory
        self.networkHistory = networkHistory
    }

    private static var group: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GlassStatsAppGroup") as? String,
              !value.isEmpty else { return nil }
        return value
    }

    public static var isConfigured: Bool { group != nil }

    public static var location: URL? {
        guard let group else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Telemetry.json")
    }

    public static func load() -> Self? {
        guard let location, let data = try? Data(contentsOf: location) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func save() throws {
        guard let location = Self.location else { return }
        try JSONEncoder().encode(self).write(to: location, options: .atomic)
    }
}
