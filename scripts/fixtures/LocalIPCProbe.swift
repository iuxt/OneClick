import Darwin
import Foundation

/// Compiled with the production transport by test-local-ipc.py. Each endpoint
/// runs in its own signed app sandbox and authenticates the counterpart's code.
@main
struct LocalIPCProbe {
    static func main() throws {
        let arguments = CommandLine.arguments
        let isServer = arguments[1] == "host"
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let peer = URL(fileURLWithPath: arguments[3])
        let timeout = Double(arguments[4])!
        precondition(FileManager.default.homeDirectoryForCurrentUser.path != SharedAppGroup.realHomeDirectory.path,
                     "Probe must run inside the app sandbox")
        let verifier = try PeerCodeVerifier(bundleURL: peer)
        let connected = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let disconnected = DispatchSemaphore(value: 0)
        let expected = Data((isServer ? "ping" : "pong").utf8)
        let transport = LocalIPCTransport(socketURL: directory.appendingPathComponent("ipc.sock"), isServer: isServer,
                                          verifyPeer: { verifier.accepts(socket: $0) }, receive: { data in
            if data == expected { received.signal() }
            if data == Data("done".utf8) { done.signal() }
        }, connected: { connected.signal() }, disconnected: { disconnected.signal() })
        defer { transport.stop() }
        transport.start()
        guard connected.wait(timeout: .now() + timeout) == .success else { exit(2) }
        if !isServer { transport.send(Data("ping".utf8)) }
        guard received.wait(timeout: .now() + timeout) == .success else { exit(3) }
        transport.send(Data((isServer ? "pong" : "done").utf8))
        if isServer, done.wait(timeout: .now() + timeout) != .success { exit(4) }
        if !isServer, disconnected.wait(timeout: .now() + timeout) != .success { exit(5) }
        print("\(isServer ? "Host" : "Extension"): authenticated sandbox IPC passed")
    }
}
