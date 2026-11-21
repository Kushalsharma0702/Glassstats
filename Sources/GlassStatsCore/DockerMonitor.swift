import DarwinMetrics
import Foundation

public struct DockerPort: Decodable, Sendable {
    public let ip: String?
    public let privatePort: Int
    public let publicPort: Int?
    public let transport: String

    private enum CodingKeys: String, CodingKey {
        case ip = "IP", privatePort = "PrivatePort", publicPort = "PublicPort", transport = "Type"
    }

    public var label: String? {
        guard let publicPort else { return nil }
        let host = ip ?? ""
        let endpoint = host.contains(":") ? "[\(host)]" : host
        let prefix = endpoint.isEmpty ? "" : "\(endpoint):"
        return "\(prefix)\(publicPort) → \(privatePort)/\(transport)"
    }
}

public struct DockerContainer: Decodable, Identifiable, Sendable {
    public let id: String
    public let names: [String]
    public let image, state, status: String
    public let ports: [DockerPort]?

    private enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", state = "State", status = "Status", ports = "Ports"
    }

    public var name: String { names.first.map { String($0.drop(while: { $0 == "/" })) } ?? String(id.prefix(12)) }
    public var publishedPorts: [String] { (ports ?? []).compactMap(\.label) }
}

public enum DockerInventory: Sendable {
    case unavailable
    case available([DockerContainer])

    public var containers: [DockerContainer]? {
        if case .available(let containers) = self { return containers }
        return nil
    }
}

public actor DockerMonitor {
    private let socketPaths: [String]

    public init(socketPaths: [String]? = nil) {
        self.socketPaths = socketPaths ?? [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".docker/run/docker.sock").path,
            "/var/run/docker.sock"
        ]
    }

    public func read() -> DockerInventory {
        for path in socketPaths {
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { continue }
            var bytes: UnsafeMutablePointer<CChar>?
            var length = 0
            guard gs_docker_list(path, &bytes, &length), let bytes else { continue }
            let data = Data(bytesNoCopy: bytes, count: length, deallocator: .free)
            if let containers = try? JSONDecoder().decode([DockerContainer].self, from: data) {
                return .available(containers.sorted {
                    ($0.state == "running" ? 0 : 1, $0.name) < ($1.state == "running" ? 0 : 1, $1.name)
                })
            }
        }
        return .unavailable
    }
}
