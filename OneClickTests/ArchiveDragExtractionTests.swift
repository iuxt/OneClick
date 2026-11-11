import AppKit
import Foundation
import Testing
@testable import OneClick

struct ArchiveDragExtractionTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-drag-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test(arguments: [ArchiveOperation.zip, .sevenZip, .tarGzip, .encryptedZip, .encryptedSevenZip])
    func exportsOnlyTheDroppedFileOrFolder(operation: ArchiveOperation) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("资料 [1]*")
        let nested = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("notes [1]*.txt")
        let data = Data("Hello, 世界\n".utf8)
        try data.write(to: file)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try Data("other file".utf8).write(to: source.appendingPathComponent("notes 1-other.txt"))
        let password = operation.isEncryptedCompression ? "drag-password" : nil
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: operation, urls: [source]), password: password)
        let original = try Data(contentsOf: archive)
        let entries = try await ArchiveBrowserService.list(archive, password: password)
        let selectedFile = try #require(entries.first { $0.name == file.lastPathComponent })
        let output = root.appendingPathComponent("renamed.txt")
        try await ArchiveDragExtraction.extract(archive, entry: selectedFile, to: output, password: password)
        #expect(try Data(contentsOf: output) == data)
        let folder = try #require(entries.first { $0.normalizedPath == source.lastPathComponent })
        let destination = root.appendingPathComponent("dropped folder")
        try await ArchiveDragExtraction.extract(archive, entry: folder, to: destination, password: password)
        #expect(try Data(contentsOf: destination.appendingPathComponent("nested/" + file.lastPathComponent)) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == ["empty", "nested", "notes 1-other.txt"])
        #expect(try Data(contentsOf: archive) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".oneclick-drag-") })
    }

    @Test(arguments: [ArchiveOperation.zip, .tarGzip])
    func refusesToOverwriteAndCleansUpCancelledExports(operation: ArchiveOperation) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: operation, urls: [source]))
        let entry = try #require(try await ArchiveBrowserService.list(archive).first { !$0.isDirectory })
        let existing = root.appendingPathComponent("existing.txt")
        let original = Data("keep existing contents".utf8)
        try original.write(to: existing)
        await #expect(throws: (any Error).self) { try await ArchiveDragExtraction.extract(archive, entry: entry, to: existing, password: nil) }
        #expect(try Data(contentsOf: existing) == original)
        let cancelledOutput = root.appendingPathComponent("cancelled.txt")
        let task = Task { try await ArchiveDragExtraction.extract(archive, entry: entry, to: cancelledOutput, password: nil) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: cancelledOutput.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".oneclick-drag-") })
    }

    @Test(arguments: [ArchiveOperation.zip, .tarGzip])
    func exportsFilesLargerThanThePreviewLimit(operation: ArchiveOperation) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.dat")
        try Data().write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        let size = ArchiveBrowserService.previewLimit + 1
        try handle.truncate(atOffset: UInt64(size))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("header".utf8))
        try handle.seek(toOffset: 1_048_576)
        try handle.write(contentsOf: Data("middle".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: operation, urls: [source]))
        let entry = try #require(try await ArchiveBrowserService.list(archive).first { !$0.isDirectory })
        let output = root.appendingPathComponent("large output.dat")
        try await ArchiveDragExtraction.extract(archive, entry: entry, to: output, password: nil)
        #expect(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize == size)
        let exported = try FileHandle(forReadingFrom: output)
        defer { try? exported.close() }
        #expect(try exported.read(upToCount: 6) == Data("header".utf8))
        try exported.seek(toOffset: 1_048_576)
        #expect(try exported.read(upToCount: 6) == Data("middle".utf8))
        try exported.seek(toOffset: UInt64(size - 1))
        #expect(try exported.read(upToCount: 1) == Data([0]))
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o100 != 0)
    }

    @Test func rejectsUnsafeSubtreesAndDuplicateNames() throws {
        let folder = ArchiveEntry(path: "folder", size: 0, isDirectory: true)
        let file = ArchiveEntry(path: "folder/file", size: 1, isDirectory: false)
        let invalidLists = [
            [folder, ArchiveEntry(path: "folder/link", size: 0, isDirectory: false, isLink: true)],
            [folder, ArchiveEntry(path: "folder/../escape", size: 1, isDirectory: false)],
            [folder, ArchiveEntry(path: "folder/./alias", size: 1, isDirectory: false)],
            [folder, ArchiveEntry(path: "folder/back\\slash", size: 1, isDirectory: false)],
            [folder, file, file],
            [folder, file, ArchiveEntry(path: "folder/FILE", size: 1, isDirectory: false)],
            [folder, file, ArchiveEntry(path: "folder/file/child", size: 1, isDirectory: false)],
        ]
        for listed in invalidLists {
            #expect(throws: ArchiveBrowserError.extractionUnavailable) { try ArchiveDragExtraction.selectedEntries(folder, in: listed) }
        }
        for path in ["/absolute", "../escape", ".", "", "a//b", "a\0b"] {
            #expect(!ArchiveEntry(path: path, size: 1, isDirectory: false).canExtract)
        }
        let synthetic = ArchiveEntry(path: "folder", size: 0, isDirectory: true)
        #expect(try ArchiveDragExtraction.selectedEntries(synthetic, in: [file]).count == 2)
    }

    @Test @MainActor func nativeOutlinePromisesUseTheDropNameAndPassword() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.txt")
        let contents = Data("encrypted contents".utf8)
        try contents.write(to: source)
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .encryptedZip, urls: [source]), password: "drag-password")
        let model = ArchiveBrowserModel(url: archive)
        defer { model.close() }
        model.load()
        try await waitUntil { !model.loading }
        let entry = try #require(model.entries.first { !$0.isDirectory })
        let view = ArchiveOutlineView(model: model, expansionRequest: 0, expandAll: false, showsCreatedDate: false, quickLook: {})
        let coordinator = view.makeCoordinator()
        let outline = NSOutlineView()
        let promise = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: coordinator.node(entry)) as? NSFilePromiseProvider)
        let delegate = try #require(promise.delegate)
        #expect(promise.userInfo is ArchiveDragPromise)
        #expect(delegate.filePromiseProvider(promise, fileNameForType: promise.fileType) == source.lastPathComponent)
        let destination = root.appendingPathComponent("Finder renamed.txt")
        await #expect(throws: ArchiveError.passwordRequired) { try await fulfill(promise, at: destination) }
        #expect(model.needsPassword)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        model.load(password: "drag-password")
        try await waitUntil { !model.loading }
        try await fulfill(promise, at: destination)
        #expect(try Data(contentsOf: destination) == contents)
        #expect(!model.dragExtracting)
        #expect(model.extractionError == nil)
        #expect(!model.needsPassword)
        // Exercise the receiving API used by Finder, through an actual pasteboard.
        let pasteboard = NSPasteboard(name: .init("oneclick-drag-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([promise]))
        let receivers = try #require(pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver])
        let receiver = try #require(receivers.first)
        #expect(receiver.fileTypes == [promise.fileType])
        model.close()
        #expect(coordinator.outlineView(outline, pasteboardWriterForItem: coordinator.node(entry)) == nil)
        let closedOutput = root.appendingPathComponent("closed.txt")
        await #expect(throws: ArchiveBrowserError.extractionUnavailable) { try await fulfill(promise, at: closedOutput) }
        #expect(!FileManager.default.fileExists(atPath: closedOutput.path))
    }

    @MainActor private func fulfill(_ promise: NSFilePromiseProvider, at destination: URL) async throws {
        let delegate = try #require(promise.delegate)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.filePromiseProvider(promise, writePromiseTo: destination) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
