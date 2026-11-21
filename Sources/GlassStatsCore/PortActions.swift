import DarwinMetrics
import Foundation

public struct PortStopPlan: Sendable {
    public let selectedCount: Int
    public let endpoints: [SocketReading]
    public var owners: [SocketReading] {
        var seen = Set<ProcessID>()
        return endpoints.filter { seen.insert($0.owner).inserted }
    }
}

public struct PortStopResult: Sendable {
    public let requested: Int
    public let skipped: Int
}

public actor PortActions {
    public init() {}

    public func prepare(_ selected: [SocketReading]) -> PortStopPlan {
        var eligibility: [ProcessID: Bool] = [:]
        let endpoints = selected.filter { row in
            if let canStop = eligibility[row.owner] { return canStop }
            let allowed = gs_can_stop_listener(row.owner.pid, row.owner.started)
            eligibility[row.owner] = allowed
            return allowed
        }
        return .init(selectedCount: selected.count, endpoints: endpoints)
    }

    public func confirm(_ plan: PortStopPlan) async -> PortStopResult {
        let current = Set(await SystemProvider().ports().sockets)
        var requested = 0
        for (owner, endpoints) in Dictionary(grouping: plan.endpoints, by: \.owner) {
            guard endpoints.contains(where: current.contains) else { continue }
            if gs_stop_listener(owner.pid, owner.started) { requested += 1 }
        }
        return .init(requested: requested, skipped: plan.owners.count - requested)
    }
}
