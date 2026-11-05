import Foundation
import SwiftData
import Testing
@testable import OneClick

// The pre-fix on-disk schema, without pathEncodingVersion. Matching the model
// name lets SwiftData exercise the same lightweight migration as an app upgrade.
private enum LegacyDirectorySchema {
    @Model final class CommonDirEntity {
        @Attribute(.unique) var id: String
        var name: String
        var pathString: String
        var icon: String
        var sortOrder: Int
        var isEnabled: Bool
        var createdAt: Date
        var updatedAt: Date

        init(path: URL) {
            id = "legacy"
            name = "Legacy"
            pathString = path.path()
            icon = "folder"
            sortOrder = 0
            isEnabled = true
            createdAt = Date()
            updatedAt = Date()
        }
    }
}

@MainActor
struct ReviewRegressionTests {
    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self,
                                           CommonDirEntity.self, BookmarkEntity.self, DataVersion.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    @Test func firstLaunchPublishesDefaultsBeforeReturning() throws {
        let container = try SharedDataManager.makeSharedModelContainer()
        let context = ModelContext(container)
        let state = AppState(configService: ConfigService(modelContext: context))
        #expect(state.actions.count == RCAction.all.count)
        #expect(state.newFiles.count == NewFile.all.count)
        #expect(state.cdirs.count == 5)
    }

    @Test func clearedConfigurationStaysEmptyOnNextLaunch() throws {
        let context = try context()
        try SharedDataManager.initializeDefaultData(context: context)
        try ConfigService(modelContext: context).save(AppConfigData())
        let restarted = ModelContext(context.container)
        try SharedDataManager.initializeDefaultData(context: restarted)
        let data = ConfigService(modelContext: restarted).load()
        #expect(data.apps.isEmpty && data.actions.isEmpty && data.newFiles.isEmpty && data.commonDirs.isEmpty)
        #expect(try restarted.fetchCount(FetchDescriptor<DataVersion>()) == 1)
    }

    @Test func existingEmptyLegacyStoreIsNotSeeded() throws {
        let context = try context()
        try SharedDataManager.initializeDefaultData(context: context, isExistingStore: true)
        #expect(try context.fetchCount(FetchDescriptor<ActionEntity>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CommonDirEntity>()) == 0)
    }

    @Test func persistedLegacySchemaUpgradesWithoutLosingPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = ModelConfiguration(url: root.appendingPathComponent("legacy.sqlite"), cloudKitDatabase: .none)
        let directory = URL(fileURLWithPath: "/tmp/中文 空格 literal%20")
        do {
            let legacy = try ModelContainer(for: LegacyDirectorySchema.CommonDirEntity.self, configurations: configuration)
            let context = ModelContext(legacy)
            context.insert(LegacyDirectorySchema.CommonDirEntity(path: directory))
            try context.save()
        }
        let upgraded = try ModelContainer(for: CommonDirEntity.self, configurations: configuration)
        let context = ModelContext(upgraded)
        let row = try #require(context.fetch(FetchDescriptor<CommonDirEntity>()).first)
        #expect(row.pathEncodingVersion == 0)
        #expect(row.migratePath())
        try context.save()
        #expect(row.path.path == directory.path)
        #expect(row.pathEncodingVersion == 1)
    }

    @Test(arguments: ["空 格 #?.txt", "literal%20", "literal%2520", "100% complete"])
    func directoryPathsRoundTripAndMigrateOnlyOnce(name: String) throws {
        let context = try context()
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name, isDirectory: true)
        let entity = CommonDirEntity(id: "custom", name: name, path: url)
        // Emulate a row written by the previous URL.path() implementation.
        entity.pathString = url.path()
        entity.pathEncodingVersion = 0
        context.insert(entity)
        try context.save()
        let service = ConfigService(modelContext: context)
        #expect(service.load().commonDirs.first?.url.path == url.path)
        #expect(entity.pathEncodingVersion == 1)
        #expect(!entity.migratePath())
        var data = service.load()
        let changedURL = url.appendingPathComponent("new %20 folder")
        data.commonDirs[0].url = changedURL
        try service.save(data)
        #expect(ConfigService(modelContext: ModelContext(context.container)).load().commonDirs.first?.url.path == changedURL.path)
    }

    @Test func defaultDirectoriesUseRealHomeAndRepairOnlyOldDefaults() {
        let real = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let sandbox = real.appendingPathComponent("Library/Containers/OneClick/Data", isDirectory: true)
        let defaults = CommonDirEntity.createDefaultCommonDirs(homeDir: real)
        #expect(defaults.first { $0.id == "home" }?.path.pathComponents == real.pathComponents)
        #expect(defaults.first { $0.id == "documents" }?.path == real.appendingPathComponent("Documents"))
        let old = CommonDirEntity(id: "documents", name: "Documents", path: sandbox.appendingPathComponent("Documents"))
        old.pathEncodingVersion = 0
        #expect(old.migratePath(sandboxHome: sandbox, realHome: real))
        #expect(old.path == real.appendingPathComponent("Documents"))
        let oldHome = CommonDirEntity(id: "home", name: "Home", path: sandbox)
        oldHome.pathEncodingVersion = 0
        #expect(oldHome.migratePath(sandboxHome: sandbox, realHome: real))
        #expect(oldHome.path.pathComponents == real.pathComponents)
        let custom = CommonDirEntity(id: "documents", name: "Custom", path: real.appendingPathComponent("Work"))
        #expect(!custom.migratePath(sandboxHome: sandbox, realHome: real))
    }

    @Test func renamedDuplicateBookmarksAreRevokedByIDAndScopesAreBalanced() throws {
        let context = try context()
        let original = URL(fileURLWithPath: "/tmp/old-folder")
        let moved = URL(fileURLWithPath: "/tmp/new-folder")
        for _ in 0..<2 { context.insert(BookmarkEntity(bookmarkData: Data([1]), pathString: original.path)) }
        // An unresolved grant on an offline volume must remain intact.
        context.insert(BookmarkEntity(bookmarkData: Data([2]), pathString: "/Volumes/Offline"))
        try context.save()
        var started: [URL] = []
        var stopped: [URL] = []
        let manager = BookmarkManager(context: context, startAccess: { started.append($0); return true },
                                      stopAccess: { stopped.append($0) }, resolve: { data in
            if data == Data([2]) { throw CocoaError(.fileNoSuchFile) }
            return (moved, false)
        })
        manager.restoreBookmarks(context: context)
        manager.restoreBookmarks(context: context)
        #expect(manager.authorizedDirectories.count == 1)
        #expect(started.count == 2)
        #expect(manager.hasAccess(to: moved.appendingPathComponent("child")))
        manager.removeDirectory(moved)
        #expect(manager.authorizedDirectories.isEmpty)
        #expect(stopped == started)
        let remaining = try ModelContext(context.container).fetch(FetchDescriptor<BookmarkEntity>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.pathString == "/Volumes/Offline")
    }

    @Test(arguments: ["txt", ".txt", "  txt\n", "..txt"])
    func extensionInputCreatesExpectedFilename(ext: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await FileActionWorker.create(in: root, extension: ext, template: nil, baseName: "Untitled")
        #expect(file.lastPathComponent == "Untitled.txt")
        let second = try await FileActionWorker.create(in: root, extension: ext, template: nil, baseName: "Untitled")
        #expect(second.lastPathComponent == "Untitled1.txt")
    }

    @Test(arguments: ["docx", "pptx", "xlsx", "pages", "key", "numbers"])
    func structuredDocumentsRequireTemplates(ext: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: FileCreationPolicy.Failure.self) {
            try await FileActionWorker.create(in: root, extension: ext, template: nil, baseName: "Untitled")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        if ext != "xlsx" {
            #expect(NewFile.all.first { $0.id == ext }?.enabled == false)
            #expect(NewFileTypeEntity.createDefaultFileTypes().first { $0.id == ext }?.isEnabled == false)
        }
        let template = root.appendingPathComponent("template")
        let bytes = Data("template content".utf8)
        try bytes.write(to: template)
        let file = try await FileActionWorker.create(in: root, extension: ext, template: template, baseName: "Untitled")
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func extractionFailureKeepsBrowserAvailableForRetry() async throws {
        var calls = 0
        var closed = false
        let url = URL(fileURLWithPath: "/tmp/archive.zip")
        let model = ArchiveBrowserModel(url: url) { _, _ in
            calls += 1
            if calls == 1 { throw ArchiveError.incorrectPassword }
            return url.deletingLastPathComponent()
        }
        defer { model.close() }
        model.extract { closed = true }
        while model.extracting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!closed)
        #expect(model.extractionError != nil)
        #expect(model.needsPassword)
        model.extract { closed = true }
        while model.extracting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(closed)
        #expect(calls == 2)
    }
}
