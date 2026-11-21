import Darwin
import Foundation
@testable import GlassStatsCore
import Testing

@Test func dockerReadsContainersFromALocalSocket() async throws {
    let path = "/tmp/glassstats-docker-\(UUID().uuidString.prefix(12)).sock"
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(listener >= 0)
    defer { close(listener); unlink(path) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: Array(path.utf8CString).map { UInt8(bitPattern: $0) })
    }
    let length = socklen_t(address.sun_len)
    try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try #require(bind(listener, $0, length) == 0)
        }
    }
    try #require(listen(listener, 1) == 0)
    let body = """
    [{"Id":"123","Names":["/example"],"Image":"example:dev","State":"running","Status":"Up",
    "Ports":[{"IP":"::","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}]}]
    """
    let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    let server = Task.detached {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 2500) == 1 else { return "" }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return "" }
        defer { close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = [UInt8](repeating: 0, count: 1024)
        let count = recv(client, &request, request.count, 0)
        guard count > 0 else { return "" }
        _ = response.withCString { send(client, $0, response.utf8.count, 0) }
        return String(decoding: request.prefix(count), as: UTF8.self)
    }
    let inventory = await DockerMonitor(socketPaths: [path]).read()
    let request = await server.value
    #expect(request.hasPrefix("GET /containers/json?all=1 HTTP/"))
    let container = try #require(inventory.containers?.first)
    #expect(container.name == "example")
    #expect(container.publishedPorts == ["[::]:8080 → 80/tcp"])
}

@Test func dockerReportsMissingEngine() async {
    let inventory = await DockerMonitor(socketPaths: []).read()
    #expect(inventory.containers == nil)
}

@Test func portActionStopsOnlyAConfirmedFixture() async throws {
    guard let path = ProcessInfo.processInfo.environment["GLASSSTATS_LISTENER_FIXTURE"] else { return }
    let listener = Process()
    let output = Pipe()
    listener.executableURL = URL(fileURLWithPath: path)
    listener.standardOutput = output
    try listener.run()
    defer {
        if listener.isRunning { listener.terminate() }
        listener.waitUntilExit()
    }
    let data = output.fileHandleForReading.availableData
    let port = try #require(Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    let inventory = await SystemProvider().ports()
    let socket = try #require(inventory.sockets.first { $0.owner.pid == listener.processIdentifier && $0.port == port })
    let actions = PortActions()
    let plan = await actions.prepare([socket])
    #expect(plan.owners.count == 1)
    #expect(listener.isRunning)
    let result = await actions.confirm(plan)
    #expect(result.requested == 1)
    for _ in 0..<30 where listener.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!listener.isRunning)
    let retry = await actions.confirm(plan)
    #expect(retry.requested == 0)
}

@Test func samplerSleepsWhenNoProviderIsNeeded() async {
    let engine = TelemetryEngine()
    var policy = SamplingPolicy()
    policy.enabled = []
    let quiet = await engine.sample(policy: policy, scanPorts: false, scanProcesses: false)
    #expect(quiet.cpu == nil)
    #expect(quiet.ports == nil)
    #expect(await engine.nextDelay(policy: policy, scanProcesses: false) >= 299)
    policy.enabled = [.cpu]
    _ = await engine.sample(policy: policy, scanPorts: false, scanProcesses: false)
    #expect(await engine.nextDelay(policy: policy, scanProcesses: false) <= 1)
}
