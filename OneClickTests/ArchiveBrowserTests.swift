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
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        try Data("different".utf8).write(to: folder.appendingPathComponent("notes 1-other.txt"))
        let password = operation.isEncryptedCompression ? "test-password" : nil
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: operation, urls: [folder]), password: password)
        let listed = try await ArchiveBrowserService.list(archive, password: password)
        let entry = try #require(listed.first { $0.name == file.lastPathComponent })
        #expect(entry.size == contents.count)
        let listedModified = try #require(entry.modifiedDate)
        #expect(abs(listedModified.timeIntervalSince(modified)) < 2)
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

    @Test func sevenZipListingReadsOptionalDatesAndFractionalSeconds() throws {
        let entries = try ArchiveBrowserService.parseSevenZipListing("""
        Path = folder/report.txt
        Size = 1234
        Modified = 2025-03-04 05:06:07.1234567
        Created = 2024-01-02 03:04:05

        Path = missing.txt
        Size = 0
        Modified =
        Created = invalid

        Path = folder/
        Size = 0
        Folder = +
        Modified = 2025-03-04 05:06:07

        """.replacingOccurrences(of: "Modified =\n", with: "Modified = \n"))
        #expect(entries.count == 3)
        let calendar = Calendar(identifier: .gregorian)
        let modified = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 4, hour: 5, minute: 6, second: 7)))
        let created = try #require(calendar.date(from: DateComponents(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5)))
        #expect(abs(try #require(entries[0].modifiedDate).timeIntervalSince(modified) - 0.1234567) < 0.000001)
        #expect(entries[0].createdDate == created)
        #expect(entries[1].modifiedDate == nil)
        #expect(entries[1].createdDate == nil)
        #expect(entries[2].isDirectory)
        #expect(entries[2].modifiedDate == modified)
        #expect(entries[2].createdDate == nil)
        let indexed = try ArchiveBrowserModel.directoryEntries(entries)
        #expect(indexed.first { $0.normalizedPath == "folder" }?.modifiedDate == modified)
    }

    @Test func nativeReaderPreservesCreationTimeWhenStoredInPaxArchive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("dates.txt")
        try Data("metadata".utf8).write(to: file)
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: file.path)
        let archive = root.appendingPathComponent("dates.tar")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["--format=pax", "-cf", archive.path, "-C", root.path, file.lastPathComponent]
        process.environment = ["PATH": "/usr/bin:/bin", "COPYFILE_DISABLE": "1"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let entries = try SystemArchiveReader.list(archive)
        let entry = try #require(entries.first { $0.path == file.lastPathComponent })
        #expect(entry.modifiedDate == modified)
        #expect(entry.createdDate == created)
    }

    @Test(arguments: [SortOrder.forward, .reverse])
    func sortingUsesNumericSizesDatesAndKeepsUnknownValuesLast(order: SortOrder) async throws {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let entries = [
            ArchiveEntry(path: "folder", size: 0, isDirectory: true),
            ArchiveEntry(path: "file10", size: 100, isDirectory: false, modifiedDate: early, createdDate: late),
            ArchiveEntry(path: "file2", size: 20, isDirectory: false, modifiedDate: late, createdDate: early),
            ArchiveEntry(path: "unknown", size: 0, isDirectory: false),
        ]
        let forward = order == .forward
        let names = try await ArchiveBrowserIndex.sorted(entries, using: [.init(field: .name, order: order)])
        #expect(names.map(\.path) == (forward ? ["folder", "file2", "file10", "unknown"] : ["folder", "unknown", "file10", "file2"]))
        let sizes = try await ArchiveBrowserIndex.sorted(entries, using: [.init(field: .size, order: order)])
        #expect(sizes.map(\.path) == (forward ? ["folder", "unknown", "file2", "file10"] : ["folder", "file10", "file2", "unknown"]))
        let modified = try await ArchiveBrowserIndex.sorted(entries, using: [.init(field: .modified, order: order)])
        #expect(modified.map(\.path) == (forward ? ["folder", "file10", "file2", "unknown"] : ["folder", "file2", "file10", "unknown"]))
        let created = try await ArchiveBrowserIndex.sorted(entries, using: [.init(field: .created, order: order)])
        #expect(created.map(\.path) == (forward ? ["folder", "file2", "file10", "unknown"] : ["folder", "file10", "file2", "unknown"]))
        let ties = try await ArchiveBrowserIndex.sorted([
            ArchiveEntry(path: "b/file2", size: 10, isDirectory: false),
            ArchiveEntry(path: "file10", size: 10, isDirectory: false),
            ArchiveEntry(path: "a/file2", size: 10, isDirectory: false),
        ], using: [.init(field: .size, order: order)])
        #expect(ties.map(\.path) == ["a/file2", "b/file2", "file10"])
    }

    @Test @MainActor func sortingSurvivesSearchAndNavigationWithoutChangingSelection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data(repeating: 65, count: 200).write(to: folder.appendingPathComponent("file2.txt"))
        try Data(repeating: 66, count: 10).write(to: folder.appendingPathComponent("file10.txt"))
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [folder]))
        let model = ArchiveBrowserModel(url: archive)
        defer { model.close() }
        model.load()
        try await waitUntil { !model.loading }
        #expect(model.error == nil)
        model.navigate(to: "source")
        model.selection = "source/file2.txt"
        model.sortOrder = [.init(field: .size, order: .reverse)]
        model.sortOrder = [.init(field: .size)]
        try await waitUntil { model.visibleEntries.map(\.name) == ["file10.txt", "file2.txt"] }
        #expect(model.selectedEntry?.path == "source/file2.txt")
        model.search = "file2"
        try await waitUntil { model.visibleEntries.map(\.name) == ["file2.txt"] }
        model.search = "file"
        try await waitUntil { model.visibleEntries.map(\.name) == ["file10.txt", "file2.txt"] }
        model.navigate(to: "")
        try await waitUntil { model.visibleEntries.map(\.name) == ["source"] }
        model.navigate(to: "source")
        try await waitUntil { model.visibleEntries.map(\.name) == ["file10.txt", "file2.txt"] }
        model.sortOrder = [.init()]
        #expect(model.visibleEntries.map(\.name) == ["file2.txt", "file10.txt"])
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

    @Test @MainActor func previewSwitchRetainsContentUntilReadyAndClearsOnFailure() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.json")
        try Data("first preview".utf8).write(to: first)
        try Data("{\"second\":true}".utf8).write(to: second)
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [first, second]))
        let model = ArchiveBrowserModel(url: archive)
        defer { model.close() }
        model.load()
        try await waitUntil { !model.loading }
        #expect(model.error == nil)
        model.selection = "first.txt"
        model.showPreview()
        try await waitUntil { !model.previewing }
        let firstURL = try #require(model.previewURL)

        model.selection = "second.json"
        model.showPreview()
        #expect(model.previewing)
        #expect(model.previewURL == firstURL)
        #expect(model.previewName == "first.txt")
        #expect(model.previewText == "first preview")
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        try await waitUntil { !model.previewing }
        #expect(model.previewError == nil)
        #expect(model.previewName == "second.json")
        #expect(model.previewText == "{\"second\":true}")
        let secondURL = try #require(model.previewURL)
        #expect(secondURL != firstURL)
        try await waitUntil { !FileManager.default.fileExists(atPath: firstURL.deletingLastPathComponent().path) }

        try FileManager.default.removeItem(at: archive)
        model.selection = "first.txt"
        model.showPreview()
        #expect(model.previewURL == secondURL)
        try await waitUntil { !model.previewing }
        #expect(model.previewError != nil)
        #expect(model.previewURL == nil)
        #expect(model.previewName == nil)
        #expect(model.previewText == nil)
        #expect(model.previewImage == nil)
        try await waitUntil { !FileManager.default.fileExists(atPath: secondURL.deletingLastPathComponent().path) }
        model.navigate(to: "")
        #expect(model.previewError == nil)
        #expect(!model.previewing)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test @MainActor func extractAllClosesBrowserAndKeepsPasswordForBackgroundWork() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        let contents = Data("encrypted contents".utf8)
        try contents.write(to: file)
        let password = "test-password"
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .encryptedSevenZip, urls: [file]), password: password)
        var closed = false
        var extractionCount = 0
        var output: URL?
        var extractionError: Error?
        let model = ArchiveBrowserModel(url: archive) { url, capturedPassword in
            #expect(closed)
            #expect(url == archive)
            #expect(capturedPassword == password)
            extractionCount += 1
            do {
                output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [url]), password: capturedPassword)
            } catch { extractionError = error }
        }
        defer { model.close() }
        model.load(password: password)
        try await waitUntil { !model.loading }
        #expect(model.error == nil)
        model.extract { closed = true }
        #expect(closed)
        model.close()
        model.extract { Issue.record("A closed browser must not extract twice") }
        try await waitUntil { output != nil || extractionError != nil }
        #expect(extractionError == nil)
        #expect(extractionCount == 1)
        let extracted = try #require(output)
        #expect(try Data(contentsOf: extracted.appendingPathComponent(file.lastPathComponent)) == contents)
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
