import Darwin
import Foundation
@testable import GlassStatsCore
import Testing

@Test func CPUUsesWeightedCoreDeltasAndCounterWrap() throws {
    let old = [CPUTicks(user: .max, system: 0, idle: 0), CPUTicks(user: 0, system: 0, idle: 0)]
    let new = [CPUTicks(user: 4, system: 5, idle: 10, nice: 5), CPUTicks(user: 0, system: 0, idle: 25)]
    let usage = try #require(CPUUsage.calculate(previous: old, current: new))
    #expect(abs(usage.total - 0.30) < 1e-12)
    #expect(usage.cores == [0.60, 0])
    #expect(CPUUsage.calculate(previous: old, current: old) == nil)
    #expect(CPUUsage.calculate(previous: old, current: []) == nil)
}

@Test func memoryCountsCompressedAndWiredButExcludesPurgeable() throws {
    let usage = try #require(MemoryUsage(total: 1000, internalBytes: 300, wired: 125, compressed: 75,
                                         purgeable: 50, cached: 90, swap: nil, pressure: .warning))
    #expect(usage.used == 450)
    #expect(usage.available == 550)
    #expect(usage.fraction == 0.45)
    #expect(usage.pressure == .warning)
    #expect(usage.swap == nil)
}

@Test func networkUsesElapsedTimeAndDiscardsDiscontinuities() throws {
    let start = NetworkCounters(name: "en0", received: 500, sent: 100, time: 10)
    let next = NetworkCounters(name: "en0", received: 1500, sent: 600, time: 12)
    let delta = try #require(next.delta(from: start))
    #expect(delta.down == 500)
    #expect(delta.up == 250)
    #expect(start.delta(from: next) == nil)
    #expect(NetworkCounters(name: "en0", received: 0, sent: 0, time: 14).delta(from: next) == nil)
    #expect(NetworkCounters(name: "en1", received: 1600, sent: 700, time: 14).delta(from: next) == nil)
}

@Test func systemProviderMeasuresTheHost() async throws {
    let provider = SystemProvider()
    let ticks = await provider.cpu()
    #expect(!ticks.isEmpty)
    let memory = try #require(await provider.memory())
    #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
    #expect(memory.used + memory.available == memory.total)
    let processes = await provider.processes(at: ProcessInfo.processInfo.systemUptime)
    let own = try #require(processes.first { $0.id.pid == getpid() })
    #expect(own.memory > 0)
    #expect(await provider.process(own.id) != nil)
}

@Test func historyRetainsOnlyRecentReadings() {
    var history = HistoryBuffer()
    let start = Date(timeIntervalSince1970: 1_000)
    for tick in 0...500 {
        let date = start.addingTimeInterval(Double(tick))
        history.add(Double(tick), at: date, cutoff: date.addingTimeInterval(-60))
    }
    #expect(history.values.count == 61)
    #expect(history.values.first?.value == 440)
    #expect(history.values.last?.value == 500)
}

@Test(arguments: [SOCK_STREAM, SOCK_DGRAM], [AF_INET, AF_INET6])
func findsRealLoopbackSockets(_ type: Int32, _ family: Int32) async throws {
    let fd = socket(family, type, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    let host = family == AF_INET6 ? "::1" : "127.0.0.1"
    var hints = addrinfo()
    hints.ai_family = family
    hints.ai_socktype = type
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    var bindAddress: UnsafeMutablePointer<addrinfo>?
    try #require(getaddrinfo(host, "0", &hints, &bindAddress) == 0)
    let address = try #require(bindAddress)
    defer { freeaddrinfo(address) }
    try #require(bind(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0)

    var local = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
    try withUnsafeMutablePointer(to: &local) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try #require(getsockname(fd, $0, &length) == 0)
            let capacity = socklen_t(service.count)
            try #require(getnameinfo($0, length, nil, 0, &service, capacity, NI_NUMERICSERV) == 0)
        }
    }
    let portText = String(decoding: service.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let port = try #require(Int(portText))
    if type == SOCK_STREAM { try #require(listen(fd, 1) == 0) }
    let inventory = await SystemProvider().ports()
    let socket = try #require(inventory.sockets.first {
        $0.owner.pid == getpid() && $0.port == port && $0.transport == (type == SOCK_STREAM ? .tcp : .udp)
    })
    #expect(socket.address == host)
    #expect(socket.ipv6 == (family == AF_INET6))
    #expect(socket.scope == .loopback)
}
