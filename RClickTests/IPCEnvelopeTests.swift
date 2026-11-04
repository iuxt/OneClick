import Foundation
import Testing
@testable import RClick

struct IPCEnvelopeTests {
    @Test func payloadAndIdentitySurviveAnAuthenticatedStreamAndReplayIsRejected() throws {
        let payload = Data("/tmp/literal%20%2F.txt".utf8)
        let frame = IPCEnvelope(direction: .extensionToMain, action: "click", payload: payload)
        let data = try JSONEncoder().encode(frame)
        let inbox = IPCInbox(direction: .extensionToMain)
        let received = try inbox.decode(data)
        #expect(received.id == frame.id)
        #expect(received.payload == payload)
        #expect(received.action == "click")
        #expect(throws: (any Error).self) { try inbox.decode(data) }
    }

    @Test func wrongDirectionStaleFutureAndLegacyFramesAreRejected() throws {
        let now = Date()
        for (direction, date) in [(IPCDirection.mainToExtension, now), (.extensionToMain, now.addingTimeInterval(-61)), (.extensionToMain, now.addingTimeInterval(6))] {
            let frame = IPCEnvelope(direction: direction, action: "click", payload: nil, now: date)
            let data = try JSONEncoder().encode(frame)
            #expect(throws: (any Error).self) { try IPCInbox(direction: .extensionToMain).decode(data, now: now) }
        }
        let old = Data(#"{"signature":"public-key-signature","jsonData":"e30=","payload":{"itemId":"delete-direct"}}"#.utf8)
        #expect(throws: (any Error).self) { try IPCInbox(direction: .extensionToMain).decode(old) }
        let valid = IPCEnvelope(direction: .mainToExtension, action: "quit", payload: nil, now: now)
        #expect(try IPCInbox(direction: .mainToExtension).decode(JSONEncoder().encode(valid), now: now).payload == nil)
    }
}
