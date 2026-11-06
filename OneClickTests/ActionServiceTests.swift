//
//  ActionServiceTests.swift
//  OneClickTests
//
//  ActionService 单测：用 mock 的 PermissionProviding / ActionStateProviding /
//  DeleteConfirmationProviding 验证授权取消、确认取消与授权→确认顺序。
//

import Foundation
import SwiftData
import Testing
@testable import OneClick

@MainActor
final class ActionServiceTests {

    /// Shared ordered log so permission and confirmation mocks can record sequence.
    @MainActor
    private final class CallLog {
        var steps: [String] = []
    }

    @MainActor
    private final class MockPermission: PermissionProviding {
        var hasAccessResult = false
        var accessChecks = 0
        /// 模拟授权面板已把目录写进 BookmarkManager 的那部分目录
        var authorizedDirs: Set<String> = []
        var promptResult: URL?
        var saveCalls: [URL] = []
        var promptCalls: [URL] = []
        var callLog: CallLog?

        func hasAccess(to url: URL) -> Bool {
            accessChecks += 1
            return hasAccessResult || authorizedDirs.contains(url.resolvingSymlinksInPath().path)
        }
        func promptForPermission(for url: URL) async -> URL? {
            promptCalls.append(url)
            callLog?.steps.append("permission")
            if let granted = promptResult {          // 对齐 saveBookmark 的副作用
                authorizedDirs.insert(granted.resolvingSymlinksInPath().path)
            }
            return promptResult
        }
        func saveBookmark(for url: URL) { saveCalls.append(url) }
    }

    @MainActor
    private final class MockConfirmation: DeleteConfirmationProviding {
        var result = true
        var confirmCalls: [[String]] = []
        var callLog: CallLog?

        func confirmPermanentDelete(paths: [String]) -> Bool {
            confirmCalls.append(paths)
            callLog?.steps.append("confirmation")
            return result
        }
    }

    @MainActor
    private final class MockState: ActionStateProviding {
        var apps: [OpenWithApp] = []
        var actions: [RCAction] = []
        var newFiles: [NewFile] = []
        var cdirs: [CommonDir] = []
        var showCommonDirs = false

        func getAppItem(rid: String) -> OpenWithApp? { nil }
        func getActionItem(rid: String) -> RCAction? { actions.first { $0.id == rid } }
        func getFileType(rid: String) -> NewFile? { nil }
    }

    @MainActor
    private final class MockChecksums: ChecksumPresenting {
        var inputs: [ChecksumInput] = []
        func show(inputs: [ChecksumInput]) { self.inputs = inputs }
    }

    @MainActor
    private final class MockArchives: ArchivePresenting {
        var requests: [ArchiveRequest] = []
        func show(requests: [ArchiveRequest]) { self.requests = requests }
    }

    @Test func batchAuthorizationChecksSharedDirectoryOnceAndDoesNotCacheAcrossActions() async {
        let permission = MockPermission()
        permission.hasAccessResult = true
        let checksums = MockChecksums()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(), checksums: checksums)
        let paths = (0..<1000).map { "/tmp/oneclick-batch/file-\($0)" }
        await service.showChecksums(paths)
        #expect(permission.accessChecks == 1)
        #expect(checksums.inputs.count == paths.count)
        #expect(checksums.inputs.allSatisfy { $0.error == nil })
        permission.hasAccessResult = false
        await service.showChecksums(paths)
        #expect(permission.accessChecks == 2)
        #expect(permission.promptCalls.count == 1)
        #expect(checksums.inputs.allSatisfy { $0.error != nil })
    }

    @Test(arguments: ["report%20.txt", "literal%2F.txt", "100%25.txt", "中文%20.txt"])
    func deletionPreservesLiteralPercentNames(name: String) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("oneclick-literal-delete-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let selected = root.appendingPathComponent(name)
        let other = root.appendingPathComponent(try #require(name.removingPercentEncoding))
        try fm.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("selected".utf8).write(to: selected)
        let otherContents = Data("unselected".utf8)
        try otherContents.write(to: other)
        let permission = MockPermission()
        permission.hasAccessResult = true
        let confirmation = MockConfirmation()
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)
        await service.deleteFoldorFile([selected.path], "ctx-items")
        #expect(!fm.fileExists(atPath: selected.path))
        #expect(try Data(contentsOf: other) == otherContents)
        #expect(confirmation.confirmCalls == [[selected.path]])
    }

    @Test func hidingAndNewFileTargetsPreserveLiteralNames() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("oneclick-literal-target-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let literal = root.appendingPathComponent("literal%20.txt")
        let other = root.appendingPathComponent("literal .txt")
        try Data().write(to: literal)
        try Data().write(to: other)
        let permission = MockPermission()
        permission.hasAccessResult = true
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation())
        await service.hideFilesAndDirs([literal.path], "ctx-items")
        #expect(try URL(fileURLWithPath: literal.path).resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
        #expect(try URL(fileURLWithPath: other.path).resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        await service.unhideFilesAndDirs([literal.path], "ctx-items")
        #expect(try URL(fileURLWithPath: literal.path).resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        let literalDirectory = root.appendingPathComponent("folder%2Fname")
        try fm.createDirectory(at: literalDirectory, withIntermediateDirectories: false)
        #expect(await service.targetDirectoryForNewFile([literalDirectory.path]) == literalDirectory.path)
        #expect(await service.targetDirectoryForNewFile([literal.path]) == root.path)
    }

    @Test func archiveDispatchKeepsLiteralNamesAndRejectsEmptySpaceMenus() async {
        let permission = MockPermission()
        permission.hasAccessResult = true
        let archives = MockArchives()
        let state = MockState()
        state.actions = [.compress, .compressZip, .compressTarGzip, .extract]
        let service = ActionService(state: state, permission: permission, confirmation: MockConfirmation(), archives: archives)
        await service.actionHandler(rid: "compress-zip", target: ["/tmp/literal%20.txt"], trigger: "ctx-container")
        #expect(archives.requests.isEmpty)
        await service.actionHandler(rid: "compress-zip", target: ["/tmp/literal%20.txt"], trigger: "ctx-items")
        #expect(archives.requests.first?.urls.first?.lastPathComponent == "literal%20.txt")
        #expect(archives.requests.first?.operation == .zip)
        #expect(archives.requests.first?.error == nil)
        await service.actionHandler(rid: "compress", target: ["/tmp/literal%20.txt"], trigger: "ctx-items")
        #expect(archives.requests.first?.operation == .compress)
    }

    @Test func browserExtractionWritesContentsWithoutPresentingAnotherWindow() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("oneclick-silent-extract-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("literal%20.txt")
        let contents = Data("background extraction".utf8)
        try contents.write(to: source)
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .tarGzip, urls: [source]))
        let permission = MockPermission()
        permission.hasAccessResult = true
        let archives = MockArchives()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(), archives: archives)

        let output = try await service.extractArchive(archive)
        #expect(try Data(contentsOf: output.appendingPathComponent(source.lastPathComponent)) == contents)
        #expect(fm.fileExists(atPath: archive.path))
        #expect(permission.promptCalls.isEmpty)
        #expect(archives.requests.isEmpty)

        await #expect(throws: (any Error).self) {
            try await service.extractArchive(root.appendingPathComponent("missing.zip"))
        }
        #expect(permission.promptCalls.isEmpty)
        #expect(archives.requests.isEmpty)
    }

    @Test func browserExtractionPromptsAndReportsMissingPermission() async {
        let permission = MockPermission()
        let archives = MockArchives()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(), archives: archives)
        await #expect(throws: CocoaError.self) {
            try await service.extractArchive(URL(fileURLWithPath: "/tmp/denied/archive.zip"))
        }
        #expect(permission.promptCalls.count == 1)
        #expect(archives.requests.isEmpty)
    }

    @Test func separateZIPActionCreatesIndependentArchivesAndContinuesAfterFailure() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("oneclick-separate-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("literal%20.txt")
        let folder = root.appendingPathComponent("folder")
        try Data("file contents".utf8).write(to: file)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("nested contents".utf8).write(to: folder.appendingPathComponent("nested.txt"))
        let existing = root.appendingPathComponent("literal%20.txt.zip")
        let existingContents = Data("existing archive".utf8)
        try existingContents.write(to: existing)

        let permission = MockPermission()
        permission.hasAccessResult = true
        let archives = MockArchives()
        let state = MockState()
        state.actions = [.compressZipSeparately]
        let service = ActionService(state: state, permission: permission, confirmation: MockConfirmation(), archives: archives)
        let target = [root.appendingPathComponent("missing.txt").path, file.path, folder.path]
        for trigger in ["ctx-container", "toolbar", "ctx-sidebar"] {
            await service.actionHandler(rid: "compress-zip-separately", target: target, trigger: trigger)
            #expect(archives.requests.isEmpty)
        }
        await service.actionHandler(rid: "compress-zip-separately", target: [], trigger: "ctx-items")
        #expect(archives.requests.isEmpty)
        await service.actionHandler(rid: "compress-zip-separately", target: target, trigger: "ctx-items")

        let model = ArchiveViewModel(requests: archives.requests, compressionSettings: ArchiveCompressionSettings())
        model.start()
        let deadline = ContinuousClock.now + .seconds(15)
        while model.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        defer { model.cancel() }
        #expect(!model.isRunning)
        try #require(model.rows.count == 3)
        #expect(model.rows[0].error != nil)
        let fileZIP = try #require(model.rows[1].output)
        let folderZIP = try #require(model.rows[2].output)
        #expect(fileZIP == root.appendingPathComponent("literal%20.txt (2).zip"))
        #expect(folderZIP == root.appendingPathComponent("folder.zip"))
        #expect(try Data(contentsOf: existing) == existingContents)
        for (archive, expectedPath, contents) in [(fileZIP, "literal%20.txt", "file contents"), (folderZIP, "folder/nested.txt", "nested contents")] {
            let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]))
            #expect(try String(contentsOf: output.appendingPathComponent(expectedPath), encoding: .utf8) == contents)
            #expect(try fm.contentsOfDirectory(atPath: output.path).count == 1)
        }
    }

    @Test func separateZIPAuthorizationFailureAffectsOnlyItsDirectory() async throws {
        let permission = MockPermission()
        let allowed = URL(fileURLWithPath: "/tmp/allowed")
        permission.authorizedDirs = [allowed.resolvingSymlinksInPath().path]
        let archives = MockArchives()
        let state = MockState()
        state.actions = [.compressZipSeparately]
        let service = ActionService(state: state, permission: permission, confirmation: MockConfirmation(), archives: archives)
        await service.actionHandler(rid: "compress-zip-separately",
                                    target: ["/tmp/denied/a.txt", "/tmp/denied/b.txt", allowed.appendingPathComponent("c.txt").path],
                                    trigger: "ctx-items")
        #expect(permission.promptCalls.count == 1)
        try #require(archives.requests.count == 3)
        #expect(archives.requests[0].error != nil)
        #expect(archives.requests[1].error != nil)
        #expect(archives.requests[2].error == nil)
    }

    @Test func fastZipCompatibleCompressionShortcutsDispatchFormatSeparationAndDeletion() async throws {
        let permission = MockPermission()
        permission.hasAccessResult = true
        let archives = MockArchives()
        let state = MockState()
        state.actions = [
            .compressSevenZip, .compressSevenZipSeparately,
            .compressZipAndDelete, .compressSevenZipAndDelete,
            .compressZipSeparatelyAndDelete, .compressSevenZipSeparatelyAndDelete,
        ]
        let service = ActionService(state: state, permission: permission,
                                    confirmation: MockConfirmation(), archives: archives)
        let targets = ["/tmp/first.txt", "/tmp/second.txt"]

        await service.actionHandler(rid: "compress-7z", target: targets, trigger: "ctx-items")
        #expect(archives.requests.count == 1)
        #expect(archives.requests[0].operation == .sevenZip)
        #expect(archives.requests[0].urls.count == 2)
        #expect(!archives.requests[0].deletesSourcesAfterSuccess)

        await service.actionHandler(rid: "compress-7z-separately", target: targets, trigger: "ctx-items")
        #expect(archives.requests.count == 2)
        #expect(archives.requests.allSatisfy { $0.operation == .sevenZip && $0.urls.count == 1 })

        let deleteActions: [(String, ArchiveOperation, Bool)] = [
            ("compress-zip-and-delete", .zip, false),
            ("compress-7z-and-delete", .sevenZip, false),
            ("compress-zip-separately-and-delete", .zip, true),
            ("compress-7z-separately-and-delete", .sevenZip, true),
        ]
        for (id, operation, separately) in deleteActions {
            await service.actionHandler(rid: id, target: targets, trigger: "ctx-items")
            #expect(archives.requests.count == (separately ? 2 : 1))
            #expect(archives.requests.allSatisfy {
                $0.operation == operation && $0.deletesSourcesAfterSuccess
                    && $0.urls.count == (separately ? 1 : 2)
            })
        }
    }

    @Test func cancelledArchiveAuthorizationPromptsOnceAndFailsWholeCompression() async {
        let permission = MockPermission()
        let archives = MockArchives()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(), archives: archives)
        await service.showArchives(["/tmp/a.txt", "/tmp/b.txt"], operation: .tarGzip)
        #expect(permission.promptCalls.count == 1)
        #expect(archives.requests.count == 1)
        #expect(archives.requests.first?.urls.count == 2)
        #expect(archives.requests.first?.error != nil)
    }

    @Test(arguments: [ArchiveOperation.encryptedZip, .encryptedSevenZip])
    func encryptedArchiveActionsDispatchToPasswordWindow(operation: ArchiveOperation) async {
        let permission = MockPermission()
        permission.hasAccessResult = true
        let archives = MockArchives()
        let state = MockState()
        state.actions = [.compressEncryptedZip, .compressEncryptedSevenZip]
        let service = ActionService(state: state, permission: permission, confirmation: MockConfirmation(), archives: archives)
        await service.actionHandler(rid: operation.rawValue, target: ["/tmp/file.txt"], trigger: "ctx-items")
        #expect(archives.requests.count == 1)
        #expect(archives.requests.first?.operation == operation)
        #expect(archives.requests.first?.error == nil)
    }

    @Test(arguments: [ArchiveOperation.extract, .extractAndDelete])
    func unrelatedArchivePermissionDoesNotAllowExtraction(operation: ArchiveOperation) async {
        let permission = MockPermission()
        permission.promptResult = URL(fileURLWithPath: "/unrelated")
        let archives = MockArchives()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(), archives: archives)
        await service.showArchives(["/tmp/a.zip", "/tmp/b.tar.gz"], operation: operation)
        #expect(permission.promptCalls.count == 1)
        #expect(archives.requests.count == 2)
        #expect(archives.requests.allSatisfy { $0.error != nil })
    }

    @Test func extractAndDeleteDispatchesEachArchiveOnlyFromSelectionMenus() async {
        let permission = MockPermission()
        permission.hasAccessResult = true
        let archives = MockArchives()
        let state = MockState()
        state.actions = [.extractAndDelete]
        let service = ActionService(state: state, permission: permission, confirmation: MockConfirmation(), archives: archives)
        let target = ["/tmp/literal%20.zip", "/tmp/other.7z"]
        for trigger in ["ctx-container", "toolbar", "ctx-sidebar"] {
            await service.actionHandler(rid: "extract-and-delete", target: target, trigger: trigger)
            #expect(archives.requests.isEmpty)
        }
        await service.actionHandler(rid: "extract-and-delete", target: target, trigger: "ctx-items")
        #expect(archives.requests.map(\.urls) == target.map { [URL(fileURLWithPath: $0)] })
        #expect(archives.requests.allSatisfy { $0.operation == .extractAndDelete && $0.error == nil })
    }

    @Test func checksumActionKeepsLiteralPercentPathsAndRequestsPermission() async {
        let permission = MockPermission()
        permission.promptResult = URL(fileURLWithPath: "/tmp")
        let checksums = MockChecksums()
        let state = MockState()
        state.actions = [.checksum]
        let service = ActionService(state: state, permission: permission, confirmation: MockConfirmation(), checksums: checksums)

        await service.actionHandler(rid: "checksum", target: ["/tmp/literal%20.txt"], trigger: "ctx-items")

        #expect(permission.promptCalls.count == 1)
        #expect(checksums.inputs.first?.url.lastPathComponent == "literal%20.txt")
        #expect(checksums.inputs.first?.error == nil)
    }

    @Test func cancelledChecksumAuthorizationIsReportedWithoutRepeatedPrompts() async {
        let permission = MockPermission()
        let checksums = MockChecksums()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(), checksums: checksums)

        await service.showChecksums(["/tmp/a.txt", "/tmp/b.txt"])

        #expect(permission.promptCalls.count == 1)
        #expect(checksums.inputs.count == 2)
        #expect(checksums.inputs.allSatisfy { $0.error != nil })
    }

    @Test func unrelatedChecksumAuthorizationDoesNotAllowReading() async {
        let permission = MockPermission()
        permission.promptResult = URL(fileURLWithPath: "/unrelated")
        let checksums = MockChecksums()
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation(), checksums: checksums)

        await service.showChecksums(["/tmp/a.txt"])

        #expect(checksums.inputs.first?.error != nil)
    }

    private func makeTempFile() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneclick-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("dummy.txt")
        try Data("x".utf8).write(to: file)
        return (dir, file)
    }

    @Test func deleteIsSkippedWhenAuthorizationIsCancelled() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let permission = MockPermission()
        permission.hasAccessResult = false
        permission.promptResult = nil
        let confirmation = MockConfirmation()
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.isEmpty)
    }

    @Test func deleteProceedsWhenAuthorizationGranted() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let permission = MockPermission()
        permission.hasAccessResult = false
        permission.promptResult = file.deletingLastPathComponent()
        let confirmation = MockConfirmation()
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls == [[file.path]])
    }

    @Test func deleteIsSkippedWhenUserCancelsConfirmation() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let permission = MockPermission()
        permission.hasAccessResult = true
        let confirmation = MockConfirmation()
        confirmation.result = false
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.count == 1)
        #expect(confirmation.confirmCalls[0] == [file.path])
    }

    @Test func deleteProceedsWhenUserConfirms() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let permission = MockPermission()
        permission.hasAccessResult = true
        let confirmation = MockConfirmation()
        confirmation.result = true
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.count == 1)
    }

    @Test func optionClickSkipsConfirmation() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let permission = MockPermission()
        permission.hasAccessResult = true
        let confirmation = MockConfirmation()
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items", optionKeyPressed: true)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.isEmpty)
    }

    @Test func authorizationIsRequestedBeforeConfirmation() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = CallLog()
        let permission = MockPermission()
        permission.hasAccessResult = false
        permission.promptResult = file.deletingLastPathComponent()
        permission.callLog = log
        let confirmation = MockConfirmation()
        confirmation.result = true
        confirmation.callLog = log
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(log.steps == ["permission", "confirmation"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.count == 1)
        #expect(confirmation.confirmCalls[0] == [file.path])
    }


    @Test func deleteIsSkippedWhenPromptGrantsUnrelatedDirectory() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneclick-unrelated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unrelated) }

        let permission = MockPermission()
        permission.hasAccessResult = false
        permission.promptResult = unrelated   // 面板返回了无关目录 → 目标目录仍未授权
        let confirmation = MockConfirmation()
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([file.path], "ctx-items")

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(confirmation.confirmCalls.isEmpty)
    }

    @Test func confirmationOnlySeesAuthorizedPaths() async throws {
        let (dirA, fileA) = try makeTempFile()
        let (dirB, fileB) = try makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let permission = MockPermission()
        permission.authorizedDirs = [dirA.resolvingSymlinksInPath().path]
        permission.promptResult = nil          // B 的授权被取消 → B 在确认之前出局
        let confirmation = MockConfirmation()  // result 默认 true
        let service = ActionService(state: MockState(), permission: permission, confirmation: confirmation)

        await service.deleteFoldorFile([fileA.path, fileB.path], "ctx-items")

        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fileB.path))
        #expect(permission.promptCalls.count == 1)          // 非死字段：只为 B 弹了一次
        #expect(confirmation.confirmCalls == [[fileA.path]]) // 确认框只拿到已授权子集
    }

    @Test(arguments: ["/Applications/Safari.app", "/Applications/literal%20%2F.app"])
    func appEntityPersistsOpensNewInstanceAndLiteralPaths(path: String) throws {
        let container = try ModelContainer(
            for: AppEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        var app = OpenWithApp(appURL: URL(fileURLWithPath: path))
        app.opensNewInstance = true
        context.insert(AppEntity(from: app, sortOrder: 0))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AppEntity>())
        #expect(fetched.first?.opensNewInstance == true)
        #expect(fetched.first?.url.path == path)
    }

    @Test func fileTemplateSurvivesSaveAndReload() throws {
        let container = try ModelContainer(
            for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self, CommonDirEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = ConfigService(modelContext: container.mainContext)
        var file = NewFile(ext: ".txt", name: "Template", idx: 0, id: "stable-template-id")
        file.template = URL(fileURLWithPath: "/tmp/template with spaces.txt")
        file.openApp = URL(fileURLWithPath: "/Applications/TextEdit.app")
        try service.save(AppConfigData(newFiles: [file]))

        for _ in 0..<2 {
            let loaded = try #require(service.load().newFiles.first)
            #expect(loaded.id == file.id)
            #expect(loaded.template == file.template)
            #expect(loaded.openApp == file.openApp)
            try service.save(AppConfigData(newFiles: [loaded]))
        }
    }

    @Test func unhideProcessesAllSelectedItemsWithoutChangingTheirChildren() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("oneclick-unhide-selection-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let folder = root.appendingPathComponent("folder")
        let child = folder.appendingPathComponent("child.txt")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: first)
        try Data().write(to: child)
        for var url in [first, folder, child] {
            var values = URLResourceValues(); values.isHidden = true
            try url.setResourceValues(values)
        }
        let permission = MockPermission()
        permission.authorizedDirs.insert(root.resolvingSymlinksInPath().path)
        let service = ActionService(state: MockState(), permission: permission, confirmation: MockConfirmation())
        await service.unhideFilesAndDirs([first.path, folder.path], "ctx-items")
        #expect(try URL(fileURLWithPath: first.path).resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        #expect(try URL(fileURLWithPath: folder.path).resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        #expect(try URL(fileURLWithPath: child.path).resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
        #expect(permission.promptCalls.isEmpty)

        permission.authorizedDirs.insert(folder.resolvingSymlinksInPath().path)
        await service.unhideFilesAndDirs([folder.path], "ctx-container")
        #expect(try URL(fileURLWithPath: child.path).resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
    }

}
