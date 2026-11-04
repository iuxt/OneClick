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
        let prepared = try await ArchivePreparedPreview.prepare(archive, entry: entry, password: password)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        #expect(prepared.text == "Hello, 世界\n")
        #expect(try Data(contentsOf: prepared.file) == contents)
        let permissions = try FileManager.default.attributesOfItem(atPath: prepared.directory.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
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

    @Test func indexedDirectoryKeepsNaturalOrderAndSearchesNestedPaths() async throws {
        var entries = (0..<20_000).map {
            ArchiveEntry(path: "large/file\($0).txt", size: 1, isDirectory: false)
        }
        entries += [
            ArchiveEntry(path: "large/nested/a.txt", size: 1, isDirectory: false),
            ArchiveEntry(path: "large/file2.txt", size: 2, isDirectory: false),
        ]
        let index = try await ArchiveBrowserIndex.build(entries)
        let children = try #require(index.children["large"])
        #expect(children.count == 20_001)
        #expect(children.prefix(4).map(\.name) == ["nested", "file0.txt", "file1.txt", "file2.txt"])
        #expect(index.byID["large/file2.txt"]?.canPreview == false)
        #expect(index.children[""]?.map(\.name) == ["large"])
        let results = try await index.search("nested/a")
        #expect(results.map(\.path) == ["large/nested/a.txt"])
        let cancelled = Task { try await index.search("file") }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test @MainActor func rapidNavigationAndSelectionKeepLatestPreview() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let first = folder.appendingPathComponent("first.txt")
        let second = folder.appendingPathComponent("second.txt")
        try Data(repeating: 65, count: 2 * 1_024 * 1_024).write(to: first)
        try Data("latest selection".utf8).write(to: second)
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [folder]))
        let model = ArchiveBrowserModel(url: archive)
        defer { model.close() }
        model.load()
        try await waitUntil { !model.loading }
        #expect(model.error == nil)
        model.navigate(to: "source")
        #expect(model.visibleEntries.map(\.name) == ["first.txt", "second.txt"])
        model.search = "first"
        model.search = "second"
        try await waitUntil { model.visibleEntries.map(\.name) == ["second.txt"] }
        model.search = ""
        model.selection = "source/first.txt"
        model.showPreview()
        model.selection = "source/second.txt"
        model.showPreview()
        try await waitUntil { !model.previewing }
        #expect(model.previewError == nil)
        #expect(model.previewText == "latest selection")
        let previewURL = try #require(model.previewURL)
        #expect(try String(contentsOf: previewURL, encoding: .utf8) == "latest selection")
        model.close()
        try await waitUntil { !FileManager.default.fileExists(atPath: previewURL.deletingLastPathComponent().path) }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
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
