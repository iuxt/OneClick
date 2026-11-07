import Foundation

nonisolated enum IPCDirection: String, Codable, Sendable {
    case mainToExtension, extensionToMain
}

/// Frames are accepted only on a stream whose peer code signature was verified.
/// No distributed notification can dispatch an execution payload.
nonisolated struct IPCEnvelope: Codable, Sendable {
    let version: Int
    let id: UUID
    let direction: IPCDirection
    let action: String
    let createdAt: TimeInterval
    let payload: Data?

    init(id: UUID = UUID(), direction: IPCDirection, action: String, payload: Data?, now: Date = Date()) {
        self.version = 3
        self.id = id
        self.direction = direction
        self.action = action
        self.createdAt = now.timeIntervalSince1970
        self.payload = payload
    }
}

nonisolated enum IPCEnvelopeError: Error { case invalid, expired, replayed, full }

nonisolated final class IPCInbox: @unchecked Sendable {
    private let direction: IPCDirection
    private let lock = NSLock()
    private var received: [UUID: TimeInterval] = [:]

    init(direction: IPCDirection) { self.direction = direction }

    func decode(_ data: Data, now: Date = Date()) throws -> IPCEnvelope {
        guard data.count <= LocalIPCTransport.maximumFrameSize else { throw IPCEnvelopeError.invalid }
        let envelope = try JSONDecoder().decode(IPCEnvelope.self, from: data)
        guard envelope.version == 3, envelope.direction == direction else { throw IPCEnvelopeError.invalid }
        let timestamp = now.timeIntervalSince1970
        guard envelope.createdAt.isFinite, envelope.createdAt <= timestamp + 5,
              timestamp - envelope.createdAt < 60 else { throw IPCEnvelopeError.expired }
        try lock.withLock {
            received = received.filter { $0.value > timestamp }
            guard received[envelope.id] == nil else { throw IPCEnvelopeError.replayed }
            guard received.count < 4_096 else { throw IPCEnvelopeError.full }
            received[envelope.id] = envelope.createdAt + 60
        }
        return envelope
    }
}
