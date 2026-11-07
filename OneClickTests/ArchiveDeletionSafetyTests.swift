import Foundation
import Testing
@testable import OneClick

struct ArchiveDeletionSafetyTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-deletion-safety-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test(arguments: [ArchiveOperation.zip, .sevenZip], [false, true])
    func excludedSourcesAreKeptEvenWhenArchiveVerificationPasses(operation: ArchiveOperation, directory: Bool) async throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent(directory ? "folder" : "excluded.tmp")
        let excluded: URL
        if directory {
            try fm.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("included".utf8).write(to: source.appendingPathComponent("included.txt"))
            excluded = source.appendingPathComponent("excluded.tmp")
        } else { excluded = source }
        let contents = Data("must survive".utf8)
        try contents.write(to: excluded)
        do {
            _ = try await ArchiveService.perform(.init(operation: operation, urls: [source], deletesSourcesAfterSuccess: true),
                                                 settings: .init(excludeFiles: true, exclusionList: "*.tmp"))
            Issue.record("Exclusions must prevent source deletion")
        } catch let ArchiveError.sourceDeletionFailed(output, _) {
            #expect(fm.fileExists(atPath: output.path))
            let entries = try await ArchiveBrowserService.list(output)
            #expect(!entries.contains { $0.path.hasSuffix("excluded.tmp") })
        }
        #expect(try Data(contentsOf: excluded) == contents)
        if directory { #expect(fm.fileExists(atPath: source.appendingPathComponent("included.txt").path)) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [ArchiveOperation.zip, .sevenZip])
    func newFilesDuringVerificationPreventDeletingTheLiveFolder(operation: ArchiveOperation) async throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("live-folder")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        let original = source.appendingPathComponent("original.bin")
        try Data(repeating: 0x61, count: 32 * 1_048_576).write(to: original)
        let progress = ArchiveProgress()
        let task = Task { try await ArchiveService.perform(.init(operation: operation, urls: [source], deletesSourcesAfterSuccess: true),
                                                          progress: progress) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(15)
        while !progress.isVerifying && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(progress.isVerifying)
        let added = source.appendingPathComponent("new-document.txt")
        let contents = Data("not in the archive".utf8)
        try contents.write(to: added)
        do {
            _ = try await task.value
            Issue.record("A changed source must not be deleted")
        } catch let ArchiveError.sourceDeletionFailed(output, _) {
            #expect(fm.fileExists(atPath: output.path))
            #expect(try await ArchiveBrowserService.list(output).allSatisfy { !$0.path.hasSuffix("new-document.txt") })
        }
        #expect(fm.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: added) == contents)
    }

    @Test func editedOrReplacedFilesPreventAnyDeletion() throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let snapshot = try ArchiveSourceSnapshot([first, second])
        try Data("edited".utf8).write(to: second, options: .atomic)
        #expect(throws: ArchiveSourceSnapshot.Failure.self) { try snapshot.removeUnchanged() }
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "edited")
    }

    @Test(arguments: [ArchiveOperation.zip, .sevenZip, .encryptedZip, .encryptedSevenZip])
    func extractAndDeleteRemovesActualVolumesAndPreservesOrphans(operation: ArchiveOperation) async throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("split.bin")
        let contents = Data(repeating: 0x61, count: 16_384)
        try contents.write(to: source)
        let password = operation.isEncryptedCompression ? "test-password" : nil
        let first = try await ArchiveService.perform(.init(operation: operation, urls: [source], compressionLevel: .store,
                                                           volumeSize: 1_024), password: password)
        let volumes = try await ArchiveBrowserService.sourceVolumes(first, password: password)
        #expect(volumes.count > 1)
        let orphan = first.deletingPathExtension().appendingPathExtension("999")
        try Data("unrelated orphan".utf8).write(to: orphan)
        let output = try await ArchiveService.perform(.init(operation: .extractAndDelete, urls: [first]), password: password)
        #expect(volumes.allSatisfy { !fm.fileExists(atPath: $0.path) })
        #expect(try String(contentsOf: orphan, encoding: .utf8) == "unrelated orphan")
        #expect(try Data(contentsOf: output.appendingPathComponent(source.lastPathComponent)) == contents)
    }

    @Test(arguments: [ArchiveOperation.zip, .sevenZip])
    func unmatchedExclusionsStillAllowVerifiedSourceDeletion(operation: ArchiveOperation) async throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("included.txt")
        let contents = Data("included".utf8)
        try contents.write(to: source)
        let archive = try await ArchiveService.perform(.init(operation: operation, urls: [source], deletesSourcesAfterSuccess: true),
                                                       settings: .init(excludeFiles: true, exclusionList: "*.tmp"))
        #expect(!fm.fileExists(atPath: source.path))
        let output = try await ArchiveService.perform(.init(operation: .extract, urls: [archive]))
        #expect(try Data(contentsOf: output.appendingPathComponent(source.lastPathComponent)) == contents)
    }

    @Test func splitCompressionAlsoDeletesVerifiedUnchangedSources() async throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("split.bin")
        let contents = Data(repeating: 0x61, count: 4_096)
        try contents.write(to: source)
        let archive = try await ArchiveService.perform(.init(operation: .sevenZip, urls: [source], compressionLevel: .store,
                                                             volumeSize: 1_024, deletesSourcesAfterSuccess: true))
        #expect(!fm.fileExists(atPath: source.path))
        let output = try await ArchiveService.perform(.init(operation: .extract, urls: [archive]))
        #expect(try Data(contentsOf: output.appendingPathComponent(source.lastPathComponent)) == contents)
    }

    @Test(arguments: [ArchiveOperation.zip, .sevenZip])
    func compressionDeletionPreservesSymlinkTargets(operation: ArchiveOperation) async throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let source = root.appendingPathComponent("folder")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: outside)
        let output = try await ArchiveService.perform(.init(operation: operation, urls: [source], deletesSourcesAfterSuccess: true))
        #expect(fm.fileExists(atPath: output.path))
        #expect(!fm.fileExists(atPath: source.path))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    }
}
