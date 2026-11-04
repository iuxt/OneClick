import CryptoKit
import Foundation
import Testing
@testable import RClick

@MainActor
struct MessageSecurityTests {
    private let key = Data(repeating: 0x37, count: 32)
    private let context = "extension-to-main:click"

    private func authenticator() -> MessageAuthenticator {
        let key = key
        return MessageAuthenticator { key }
    }

    @Test func transportUsesAuthenticatedBytesAndIgnoresInjectedLegacyPayload() throws {
        let sender = authenticator()
        let transport = Messager(authenticator: authenticator())
        let event = ClickEventPayload(itemId: "checksum", itemType: .action, target: ["/tmp/literal%20.txt"], trigger: .contextualItems)
        let id = UUID()
        let signed = try sender.seal(JSONEncoder().encode(event), context: context, id: id)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(signed)) as? [String: Any])
        object["payload"] = ["itemId": "delete-direct", "optionKeyPressed": true]
        let wire = try notification(id: id, action: "click", signedData: JSONSerialization.data(withJSONObject: object))
        var received: [ClickEventPayload] = []
        transport.onExtensionMessage(.click) { data in
            if let event: ClickEventPayload = transport.decode(data) { received.append(event) }
        }
        transport.handleExtensionToMainMessage(wire)
        transport.handleExtensionToMainMessage(wire) // A replay must not execute twice.
        #expect(received.count == 1)
        #expect(received.first?.itemId == "checksum")
        #expect(received.first?.target == event.target)
    }

    @Test func changedAuthenticatedPayloadAndForeignKeyAreRejected() throws {
        let sender = authenticator()
        let id = UUID()
        let signed = try sender.seal(Data("original".utf8), context: context, id: id)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(base64Encoded: signed.jsonData)!) as? [String: Any])
        envelope["payload"] = Data("delete-direct".utf8).base64EncodedString()
        let modified = SignedPayload(signature: signed.signature,
                                     jsonData: try JSONSerialization.data(withJSONObject: envelope).base64EncodedString())
        #expect(throws: (any Error).self) { try authenticator().open(modified, context: context, id: id) }
        let foreign = MessageAuthenticator { Data(repeating: 0x99, count: 32) }
        #expect(throws: (any Error).self) { try foreign.open(signed, context: context, id: id) }
    }

    @Test func actionDirectionIDAndTimeAreBoundToSignature() throws {
        let now = Date()
        let sender = authenticator()
        let id = UUID()
        let signed = try sender.seal(nil, context: context, id: id, now: now)
        for other in ["extension-to-main:heartbeat", "main-to-extension:click"] {
            #expect(throws: (any Error).self) { try authenticator().open(signed, context: other, id: id, now: now) }
        }
        #expect(throws: (any Error).self) { try authenticator().open(signed, context: context, id: UUID(), now: now) }
        #expect(throws: (any Error).self) { try authenticator().open(signed, context: context, id: id, now: now.addingTimeInterval(61)) }
        #expect(throws: (any Error).self) { try authenticator().open(signed, context: context, id: id, now: now.addingTimeInterval(-6)) }
        #expect(try authenticator().open(signed, context: context, id: id, now: now) == nil)
    }

    @Test func unsignedAndLegacyFixedKeyControlMessagesNeverReachHandlers() throws {
        let receiver = authenticator()
        let transport = Messager(authenticator: receiver)
        var calls = 0
        transport.onExtensionMessage(.requestConfig) { _ in calls += 1 }
        transport.onMainMessage(.quit) { _ in calls += 1 }
        let id = UUID()
        transport.handleExtensionToMainMessage(try notification(id: id, action: "request-config", signedData: nil))
        transport.handleMainToExtensionMessage(try notification(id: id, action: "quit", signedData: nil))
        let oldBytes = Data("{}".utf8)
        let oldKey = SymmetricKey(data: Data("RClick_IPC_SharedKey_2026_v1".utf8))
        let legacy = SignedPayload(signature: Data(HMAC<SHA256>.authenticationCode(for: oldBytes, using: oldKey)).base64EncodedString(), jsonData: oldBytes.base64EncodedString())
        transport.handleExtensionToMainMessage(try notification(id: id, action: "request-config", signedData: JSONEncoder().encode(legacy)))
        #expect(calls == 0)
        // A valid control message requires the same ID outside and inside the signature.
        let validID = UUID()
        let valid = try authenticator().seal(nil, context: "main-to-extension:quit", id: validID)
        transport.handleMainToExtensionMessage(try notification(id: validID, action: "quit", signedData: JSONEncoder().encode(valid)))
        #expect(calls == 1)
        let requestID = UUID()
        let request = try authenticator().seal(nil, context: "extension-to-main:request-config", id: requestID)
        transport.handleExtensionToMainMessage(try notification(id: requestID, action: "request-config", signedData: JSONEncoder().encode(request)))
        #expect(calls == 2)
    }

    @Test func missingCredentialDoesNotFallBackToAnInsecureKey() {
        let missing = MessageAuthenticator { throw MessageAuthenticationError.invalidKey }
        #expect(throws: (any Error).self) { try missing.seal(nil, context: context, id: UUID()) }
        let invalid = MessageAuthenticator { Data() }
        #expect(throws: (any Error).self) { try invalid.seal(nil, context: context, id: UUID()) }
    }

    private func notification(id: UUID, action: String, signedData: Data?) throws -> NSNotification {
        var object: [String: Any] = ["id": id.uuidString, "action": action]
        if let signedData { object["signedData"] = signedData.base64EncodedString() }
        let data = try JSONSerialization.data(withJSONObject: object)
        return NSNotification(name: .init("RClick.TestOnly"), object: String(decoding: data, as: UTF8.self))
    }
}
