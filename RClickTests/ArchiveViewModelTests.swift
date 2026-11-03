import Foundation
import Testing
@testable import RClick

@MainActor
struct ArchiveViewModelTests {
    @Test(arguments: ArchiveCompressionFormat.allCases, [false, true])
    func configurableCompressionWaitsForSubmission(format: ArchiveCompressionFormat, encrypted: Bool) async throws {
        if format == .tarGzip && encrypted { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rclick-options-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("configurable contents".utf8).write(to: file)
        let model = ArchiveViewModel(requests: [ArchiveRequest(operation: .compress, urls: [file])])
        model.start()
        #expect(model.rows[0].needsConfiguration)
        #expect(!model.isRunning)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file.txt"])

        let password = encrypted ? "test-password" : nil
        model.submitCompression(for: 0, format: format, level: .fast, password: password)
        try await waitUntilIdle(model)
        let archive = try #require(model.rows[0].output)
        #expect(!model.rows[0].needsConfiguration)
        #expect(model.rows[0].request.compressionLevel == .fast)
        if encrypted {
            await #expect(throws: ArchiveError.passwordRequired) {
                try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]))
            }
        }
        let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]), password: password)
        #expect(try Data(contentsOf: output.appendingPathComponent("file.txt")) == Data(contentsOf: file))
    }

    @Test func cancellingConfigurationPreventsLaterSubmission() {
        let model = ArchiveViewModel(requests: [ArchiveRequest(operation: .compress, urls: [URL(fileURLWithPath: "/tmp/file")])])
        model.start()
        model.cancel()
        model.submitCompression(for: 0, format: .zip, level: .normal, password: nil)
        #expect(!model.rows[0].needsConfiguration)
        #expect(!model.isRunning)
        #expect(model.rows[0].output == nil)
        #expect(model.rows[0].error == AppLocalization.localized("Cancelled"))
    }

    private func waitUntilIdle(_ model: ArchiveViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isRunning)
    }

    @Test(arguments: [ArchiveOperation.encryptedZip, .encryptedSevenZip])
    func encryptedCreationWaitsForPasswordBeforeWriting(operation: ArchiveOperation) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rclick-password-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("contents".utf8).write(to: file)
        let model = ArchiveViewModel(requests: [ArchiveRequest(operation: operation, urls: [file])])
        model.start()
        #expect(model.rows[0].needsPassword)
        #expect(!model.isRunning)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file.txt"])

        model.submitPassword(for: 0, password: operation == .encryptedSevenZip ? "中文密码" : "test-password")
        try await waitUntilIdle(model)
        #expect(model.rows[0].output != nil)
        #expect(!model.rows[0].needsPassword)
        #expect(model.rows[0].error == nil)
    }

    @Test func passwordRetryPreservesOtherBatchResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rclick-password-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locked = root.appendingPathComponent("locked.txt")
        let plain = root.appendingPathComponent("plain.txt")
        try Data("secret".utf8).write(to: locked)
        try Data("plain".utf8).write(to: plain)
        let encrypted = try await ArchiveService.perform(ArchiveRequest(operation: .encryptedZip, urls: [locked]), password: "password")
        let regular = try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [plain]))
        let model = ArchiveViewModel(requests: [encrypted, regular].map { ArchiveRequest(operation: .extract, urls: [$0]) })
        model.start()
        try await waitUntilIdle(model)
        #expect(model.rows[0].needsPassword)
        let plainOutput = try #require(model.rows[1].output)

        model.submitPassword(for: 0, password: "wrong")
        try await waitUntilIdle(model)
        #expect(model.rows[0].needsPassword)
        #expect(model.rows[0].output == nil)
        #expect(model.rows[0].error == ArchiveError.incorrectPassword.localizedDescription)

        model.submitPassword(for: 0, password: "password")
        try await waitUntilIdle(model)
        #expect(model.rows[0].output != nil)
        #expect(model.rows[0].error == nil)
        #expect(model.rows[1].output == plainOutput)
        #expect(try String(contentsOf: plainOutput.appendingPathComponent("plain.txt"), encoding: .utf8) == "plain")
    }
}
