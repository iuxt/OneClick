import Darwin
import Foundation
import Testing
@testable import RClick

struct IPCTransportTests {
    private nonisolated final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Data] = []
        private var count = 0
        func receive(_ data: Data) { lock.withLock { frames.append(data) } }
        func increment() { lock.withLock { count += 1 } }
        var messages: [Data] { lock.withLock { frames } }
        var total: Int { lock.withLock { count } }
    }

    @Test func multipleExtensionsExchangeFramesAndReconnectAfterHostRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ipc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("s")
        let hostEvents = Events()
        let connections = Events()
        let firstEvents = Events()
        let secondEvents = Events()
        let host = LocalIPCTransport(socketURL: url, isServer: true, verifyPeer: { _ in true },
                                     receive: { hostEvents.receive($0) }, connected: { connections.increment() })
        let first = LocalIPCTransport(socketURL: url, isServer: false, verifyPeer: { _ in true }, receive: { firstEvents.receive($0) })
        let second = LocalIPCTransport(socketURL: url, isServer: false, verifyPeer: { _ in true }, receive: { secondEvents.receive($0) })
        defer { first.stop(); second.stop(); host.stop() }
        host.start()
        first.start()
        second.start()
        try await wait { connections.total == 2 }
        let event = Data("literal%20.txt".utf8)
        first.send(event)
        second.send(event)
        try await wait { hostEvents.messages.count == 2 }
        #expect(hostEvents.messages == [event, event])
        // Back-to-back frames larger than a typical socket read preserve boundaries.
        let large = Data(repeating: 0x43, count: 131_072)
        host.send(large)
        host.send(event)
        try await wait { firstEvents.messages.count == 2 && secondEvents.messages.count == 2 }
        #expect(firstEvents.messages == [large, event])
        #expect(secondEvents.messages == [large, event])
        host.stop()
        try await wait {
            var info = stat()
            return lstat(url.path, &info) != 0
        }
        let restarted = LocalIPCTransport(socketURL: url, isServer: true, verifyPeer: { _ in true },
                                          receive: { hostEvents.receive($0) }, connected: { connections.increment() })
        defer { restarted.stop() }
        restarted.start()
        try await wait { connections.total == 4 }
        first.send(Data("after restart".utf8))
        try await wait { hostEvents.messages.count == 3 }
        #expect(hostEvents.messages.last == Data("after restart".utf8))
    }

    @Test func failedPeerValidationNeverDispatchesPayloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ipc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rejected = Events()
        let received = Events()
        let host = LocalIPCTransport(socketURL: root.appendingPathComponent("s"), isServer: true,
                                     verifyPeer: { _ in rejected.increment(); return false }, receive: { received.receive($0) })
        let client = LocalIPCTransport(socketURL: root.appendingPathComponent("s"), isServer: false,
                                       verifyPeer: { _ in true }, receive: { _ in })
        defer { host.stop(); client.stop() }
        host.start()
        client.start()
        try await wait { rejected.total > 0 }
        client.send(Data("delete-direct".utf8))
        #expect(received.messages.isEmpty)
    }

    @Test func listenerDoesNotReplaceAnExistingRegularFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ipc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("s")
        let contents = Data("retain this file".utf8)
        try contents.write(to: url)
        let host = LocalIPCTransport(socketURL: url, isServer: true, verifyPeer: { _ in true }, receive: { _ in })
        host.start()
        defer { host.stop() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try Data(contentsOf: url) == contents)
    }

    private func wait(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
