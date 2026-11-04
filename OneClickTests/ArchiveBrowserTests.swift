import Foundation
import Testing
@testable import OneClick

struct ArchiveBrowserTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-browser-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: [ArchiveOperation.zip, .sevenZip, .tarGzip, .encryptedZip, .encryptedSevenZip])
    func browseAndPreviewRealArchives(operation: ArchiveOperation) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("中文 Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let contents = Data("Hello, 世界\n".utf8)
        let file = folder.appendingPathComponent("notes [1]*.txt")
        try contents.write(to: file)
        try Data("different".utf8).write(to: folder.appendingPathComponent("notes 1-other.txt"))
        let password = operation.isEncryptedCompression ? "test-password" : nil
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: operation, urls: [folder]), password: password)
        let listed = try await ArchiveBrowserService.list(archive, password: password)
        let entry = try #require(listed.first { $0.name == file.lastPathComponent })
        #expect(entry.size == contents.count)
        let preview = try await ArchiveBrowserService.preview(archive, entry: entry, password: password)
        #expect(preview == contents)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set([folder.lastPathComponent, archive.lastPathComponent]))
        #expect(try Data(contentsOf: file) == contents)
        if operation == .encryptedSevenZip {
            await #expect(throws: ArchiveError.passwordRequired) { try await ArchiveBrowserService.list(archive) }
            await #expect(throws: ArchiveError.incorrectPassword) { try await ArchiveBrowserService.list(archive, password: "incorrect") }
        }
        if operation == .encryptedZip {
            let visible = try await ArchiveBrowserService.list(archive)
            let encryptedEntry = try #require(visible.first { $0.name == file.lastPathComponent })
            await #expect(throws: ArchiveError.passwordRequired) { try await ArchiveBrowserService.preview(archive, entry: encryptedEntry) }
        }
    }

    @Test func unsafeAndOversizedEntriesCannotBePreviewed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.txt")
        try Data("hello".utf8).write(to: file)
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [file]))
        for path in ["../outside.txt", "/etc/passwd", "folder/../../outside", "folder\\outside", "bad\0name"] {
            let entry = ArchiveEntry(path: path, size: 1, isDirectory: false)
            #expect(!entry.canPreview)
            await #expect(throws: ArchiveBrowserError.entryUnavailable) { try await ArchiveBrowserService.preview(archive, entry: entry) }
        }
        let oversized = ArchiveEntry(path: "test.txt", size: Int64(ArchiveBrowserService.previewLimit + 1), isDirectory: false)
        await #expect(throws: ArchiveBrowserError.previewTooLarge) { try await ArchiveBrowserService.preview(archive, entry: oversized) }
    }

    @Test(arguments: [ArchiveOperation.zip, .tarGzip])
    func previewLimitsActualOutputEvenWithIncorrectMetadata(operation: ArchiveOperation) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ArchiveBrowserService.previewLimit + 1))
        try handle.close()
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: operation, urls: [file]))
        let listed = try await ArchiveBrowserService.list(archive)
        let actual = try #require(listed.first { !$0.isDirectory })
        let entry = ArchiveEntry(path: actual.path, size: 0, isDirectory: false)
        await #expect(throws: ArchiveBrowserError.previewTooLarge) { try await ArchiveBrowserService.preview(archive, entry: entry) }
    }

    @Test @MainActor func impliedFoldersAndDuplicateNames() throws {
        let entries = try ArchiveBrowserModel.directoryEntries([
            ArchiveEntry(path: "nested/deep/a.txt", size: 5, isDirectory: false),
            ArchiveEntry(path: "duplicate.txt", size: 5, isDirectory: false),
            ArchiveEntry(path: "./duplicate.txt", size: 6, isDirectory: false),
        ])
        #expect(entries.contains { $0.path == "nested" && $0.isDirectory })
        #expect(entries.contains { $0.path == "nested/deep" && $0.isDirectory })
        #expect(entries.filter { $0.normalizedPath == "duplicate.txt" }.count == 1)
        #expect(entries.first { $0.name == "duplicate.txt" }?.canPreview == false)
    }

    @Test(arguments: [ArchiveOperation.zip, .tarGzip])
    func nativeDirectoryReaderPreservesNewlinesAndRejectsLinks(operation: ArchiveOperation) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("line\nbreak.txt")
        try Data("safe".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: file.lastPathComponent)
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: operation, urls: [folder]))
        let entries = try await ArchiveBrowserService.list(archive)
        let selected = try #require(entries.first { $0.name == file.lastPathComponent })
        #expect(try await ArchiveBrowserService.preview(archive, entry: selected) == Data("safe".utf8))
        #expect(entries.first { $0.name == "link" }?.canPreview == false)
    }
}
