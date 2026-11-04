import Darwin
import Foundation
import OSLog
import Security

/// A private stream, authenticated using the kernel's peer audit token and the
/// installed counterpart's designated code requirement. No shared secret is used.
nonisolated final class LocalIPCTransport: @unchecked Sendable {
    static let maximumFrameSize = 4 * 1_024 * 1_024
    private let socketURL: URL
    private let isServer: Bool
    private let verifyPeer: @Sendable (Int32) -> Bool
    private let receive: @Sendable (Data) -> Void
    private let connected: @Sendable () -> Void
    private let disconnected: @Sendable () -> Void
    private let lock = NSLock()
    private var active = true
    private var listener: Int32 = -1
    private var connections: [UUID: Connection] = [:]
    private let logger = Logger(subsystem: "cn.wflixu.RClick", category: "LocalIPC")

    convenience init(isExtension: Bool, receive: @escaping @Sendable (Data) -> Void,
                     connected: @escaping @Sendable () -> Void,
                     disconnected: @escaping @Sendable () -> Void) throws {
        guard let directory = SharedAppGroup.containerURL else { throw POSIXError(.EACCES) }
        let host = isExtension
            ? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            : Bundle.main.bundleURL
        let counterpart = isExtension ? host : host.appendingPathComponent("Contents/PlugIns/FinderSyncExt.appex")
        let verifier = try PeerCodeVerifier(bundleURL: counterpart)
        self.init(socketURL: directory.appendingPathComponent("ipc.sock"), isServer: !isExtension,
                  verifyPeer: { verifier.accepts(socket: $0) }, receive: receive, connected: connected, disconnected: disconnected)
    }

    /// Explicit socket/verification injection supports transport tests without
    /// inspecting user credentials or communicating with the running app.
    init(socketURL: URL, isServer: Bool, verifyPeer: @escaping @Sendable (Int32) -> Bool,
         receive: @escaping @Sendable (Data) -> Void, connected: @escaping @Sendable () -> Void = {},
         disconnected: @escaping @Sendable () -> Void = {}) {
        self.socketURL = socketURL.standardizedFileURL.resolvingSymlinksInPath()
        self.isServer = isServer
        self.verifyPeer = verifyPeer
        self.receive = receive
        self.connected = connected
        self.disconnected = disconnected
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            if isServer { serve() } else { reconnect() }
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty, data.count <= Self.maximumFrameSize else { return }
        let peers = lock.withLock { Array(connections.values) }
        for peer in peers { peer.send(data) }
    }

    func stop() {
        let peers = lock.withLock {
            active = false
            if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR) }
            return Array(connections.values)
        }
        for peer in peers { peer.stop() }
    }

    private var isActive: Bool { lock.withLock { active } }

    private func serve() {
        var fd: Int32 = -1
        var identity: stat?
        var operation = "create directory"
        defer {
            lock.withLock {
                listener = -1
                if fd >= 0 { Darwin.close(fd) }
            }
            if let identity {
                var current = stat()
                if lstat(socketURL.path, &current) == 0,
                   current.st_dev == identity.st_dev, current.st_ino == identity.st_ino {
                    unlink(socketURL.path)
                }
            }
        }
        do {
            try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            operation = "inspect endpoint"
            var existing = stat()
            if lstat(socketURL.path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid() else { throw POSIXError(.EACCES) }
                let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard probe >= 0 else { throw Self.posixError() }
                let result = try Self.address(socketURL) { Darwin.connect(probe, $0, $1) }
                let reason = errno
                Darwin.close(probe)
                guard result != 0, reason == ECONNREFUSED || reason == ENOENT else { throw POSIXError(.EADDRINUSE) }
                guard unlink(socketURL.path) == 0 || errno == ENOENT else { throw Self.posixError() }
            }
            operation = "create socket"
            fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Self.posixError() }
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Self.posixError() }
            operation = "bind socket"
            guard try Self.address(socketURL, { Darwin.bind(fd, $0, $1) }) == 0 else { throw Self.posixError() }
            var bound = stat()
            guard lstat(socketURL.path, &bound) == 0 else { throw Self.posixError() }
            identity = bound
            operation = "set socket permissions"
            guard chmod(socketURL.path, 0o600) == 0 else { throw Self.posixError() }
            operation = "listen"
            guard Darwin.listen(fd, 16) == 0 else { throw Self.posixError() }
            operation = "accept"
            lock.withLock { listener = fd }
            while isActive {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    if !isActive { break }
                    throw Self.posixError()
                }
                guard verifyPeer(client) else {
                    Darwin.close(client)
                    logger.warning("Rejected IPC peer with an unexpected code signature")
                    continue
                }
                guard let connection = attach(client) else { continue }
                connected()
                DispatchQueue.global(qos: .utility).async { [self] in
                    connection.readMessages(receive)
                    detach(connection)
                }
            }
        } catch {
            logger.error("IPC listener stopped during \(operation, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reconnect() {
        while isActive {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            if fd >= 0 {
                let result = try? Self.address(socketURL) { Darwin.connect(fd, $0, $1) }
                if result == 0, verifyPeer(fd) {
                    if let connection = attach(fd) {
                        connected()
                        connection.readMessages(receive)
                        detach(connection)
                        disconnected()
                    }
                } else {
                    Darwin.close(fd)
                }
            }
            if isActive { Thread.sleep(forTimeInterval: 1) }
        }
    }

    private func attach(_ fd: Int32) -> Connection? {
        lock.withLock {
            guard active, connections.count < 32 else { Darwin.close(fd); return nil }
            let connection = Connection(fd: fd)
            connections[connection.id] = connection
            return connection
        }
    }

    private func detach(_ connection: Connection) {
        lock.withLock { _ = connections.removeValue(forKey: connection.id) }
    }

    private static func address<T>(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private final class Connection: @unchecked Sendable {
        let id = UUID()
        private let fd: Int32
        private let lock = NSLock()
        private var stopped = false
        private let writer = DispatchQueue(label: "RClick.IPC.write")

        init(fd: Int32) {
            self.fd = fd
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var enabled: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        }

        func stop() {
            lock.withLock {
                if !stopped { stopped = true; Darwin.shutdown(fd, SHUT_RDWR) }
            }
        }

        func send(_ data: Data) {
            writer.async { [self] in
                lock.withLock {
                    guard !stopped else { return }
                    var count = UInt32(data.count).bigEndian
                    var frame = withUnsafeBytes(of: &count) { Data($0) }
                    frame.append(data)
                    let sent = frame.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { return false }
                            offset += count
                        }
                        return true
                    }
                    if !sent { stopped = true; Darwin.shutdown(fd, SHUT_RDWR) }
                }
            }
        }

        func readMessages(_ receive: @Sendable (Data) -> Void) {
            defer {
                // Only the reader closes this descriptor. Other threads merely
                // shut it down, so a concurrent send cannot use a recycled FD.
                lock.withLock { stopped = true; Darwin.close(fd) }
            }
            while let header = readExactly(4) {
                let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= LocalIPCTransport.maximumFrameSize,
                      let data = readExactly(Int(length)) else { return }
                receive(data)
            }
        }

        private func readExactly(_ count: Int) -> Data? {
            var data = Data(count: count)
            let complete = data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < count {
                    let amount = Darwin.recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { return false }
                    offset += amount
                }
                return true
            }
            return complete ? data : nil
        }
    }
}

nonisolated final class PeerCodeVerifier: @unchecked Sendable {
    private let requirement: SecRequirement

    init(bundleURL: URL) throws {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code)
        guard created == errSecSuccess, let code else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(created)) }
        var requirement: SecRequirement?
        let copied = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard copied == errSecSuccess, let requirement else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(copied)) }
        self.requirement = requirement
    }

    func accepts(socket: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout.size(ofValue: token))
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout.size(ofValue: token) else { return false }
        let bytes = withUnsafeBytes(of: &token) { Data($0) }
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: bytes] as CFDictionary, [], &peer) == errSecSuccess,
              let peer else { return false }
        return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
    }
}
