import CryptoKit
import Foundation

/// The wire format contains one authenticated byte sequence, never a second
/// independently decoded execution payload. Legacy fixed-key messages fail closed.
public nonisolated struct SignedPayload: Codable, Sendable {
    let signature: String
    let jsonData: String
}

nonisolated enum MessageAuthenticationError: Error {
    case invalidKey, invalidSignature, invalidEnvelope, expired, replayed, capacityExceeded
}

/// Each receiver has its own bounded replay cache. The key provider is injectable
/// so regression tests never read or alter the user's Keychain.
nonisolated final class MessageAuthenticator: @unchecked Sendable {
    private struct Envelope: Codable {
        let version: Int
        let id: UUID
        let context: String
        let issuedAt: TimeInterval
        let payload: Data?
    }

    static let lifetime: TimeInterval = 60
    private let keyProvider: @Sendable () throws -> Data
    private let lock = NSLock()
    private var received: [UUID: TimeInterval] = [:]

    init(keyProvider: @escaping @Sendable () throws -> Data) {
        self.keyProvider = keyProvider
    }

    func seal(_ payload: Data?, context: String, id: UUID, now: Date = Date()) throws -> SignedPayload {
        let envelope = Envelope(version: 2, id: id, context: context,
                                issuedAt: now.timeIntervalSince1970, payload: payload)
        let data = try JSONEncoder().encode(envelope)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: try key())
        return SignedPayload(signature: Data(signature).base64EncodedString(), jsonData: data.base64EncodedString())
    }

    func open(_ signed: SignedPayload, context: String, id: UUID, now: Date = Date()) throws -> Data? {
        guard let data = Data(base64Encoded: signed.jsonData),
              let signature = Data(base64Encoded: signed.signature),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: data, using: try key()) else {
            throw MessageAuthenticationError.invalidSignature
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 2, envelope.context == context, envelope.id == id else {
            throw MessageAuthenticationError.invalidEnvelope
        }
        let timestamp = now.timeIntervalSince1970
        guard envelope.issuedAt.isFinite, envelope.issuedAt <= timestamp + 5,
              timestamp - envelope.issuedAt < Self.lifetime else {
            throw MessageAuthenticationError.expired
        }
        try lock.withLock {
            received = received.filter { $0.value > timestamp }
            guard received[id] == nil else { throw MessageAuthenticationError.replayed }
            guard received.count < 4_096 else { throw MessageAuthenticationError.capacityExceeded }
            received[id] = envelope.issuedAt + Self.lifetime
        }
        return envelope.payload
    }

    private func key() throws -> SymmetricKey {
        let data = try keyProvider()
        guard data.count == 32 else { throw MessageAuthenticationError.invalidKey }
        return SymmetricKey(data: data)
    }
}

public nonisolated enum MessageSecurity {
    private static let authenticator = MessageAuthenticator { try IPCKeyStore.shared.key() }

    static func sign<T: Encodable>(_ payload: T?, context: String, id: UUID) throws -> SignedPayload {
        try authenticator.seal(try payload.map { try JSONEncoder().encode($0) }, context: context, id: id)
    }

    static func open(_ signed: SignedPayload, context: String, id: UUID) throws -> Data? {
        try authenticator.open(signed, context: context, id: id)
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(_ string: String) -> String {
        hash(Data(string.utf8))
    }
}
