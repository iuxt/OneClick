import Foundation
import SwiftData
import Testing

@testable import OneClick

/// Use an isolated SQLite store to check identity, incremental changes and reloads.
@MainActor
struct ConfigServiceSaveTests {
    /// Backed by a real file, not `isStoredInMemoryOnly`: the failure this is
    /// chasing only shows up against actual SQLite, and a temp file is as close to
    /// the App Group store as a test may get.
    private func makeService() throws -> (ConfigService, ModelContext) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneclick-config-\(UUID()).sqlite")
        let configuration = ModelConfiguration(url: url, allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: AppEntity.self,
            ActionEntity.self,
            NewFileTypeEntity.self,
            CommonDirEntity.self,
            BookmarkEntity.self,
            DataVersion.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        return (ConfigService(modelContext: context), context)
    }

    private var payload: AppConfigData {
        AppConfigData(
            apps: [OpenWithApp(id: "zed-id", appURL: URL(fileURLWithPath: "/Applications/Zed.app"))],
            actions: [RCAction(id: "copy-path", name: "Copy Path", enabled: true, idx: 0, icon: "doc")],
            newFiles: [NewFile(ext: ".txt", name: "TXT", enabled: true, idx: 0, icon: "doc", id: "txt-id")],
            commonDirs: [CommonDir(id: "desktop", name: "Desktop",
                                   url: URL(fileURLWithPath: "/Users/x/Desktop"), icon: "folder")]
        )
    }

    @Test func aSingleChangePreservesUnchangedRecordsAndNoOpSave() throws {
        let (service, context) = try makeService()
        var snapshot = payload
        try service.save(snapshot)
        let app = try #require(context.fetch(FetchDescriptor<AppEntity>()).first)
        let action = try #require(context.fetch(FetchDescriptor<ActionEntity>()).first)
        let file = try #require(context.fetch(FetchDescriptor<NewFileTypeEntity>()).first)
        let directory = try #require(context.fetch(FetchDescriptor<CommonDirEntity>()).first)
        let originalIDs = [app.persistentModelID, action.persistentModelID, file.persistentModelID, directory.persistentModelID]
        let originalDates = [app.createdAt, action.updatedAt, file.updatedAt, directory.updatedAt]
        snapshot.apps[0].showInToolbar = false
        try service.save(snapshot)
        #expect(!app.showInToolbar)
        #expect([app.persistentModelID, action.persistentModelID, file.persistentModelID, directory.persistentModelID] == originalIDs)
        #expect([app.createdAt, action.updatedAt, file.updatedAt, directory.updatedAt] == originalDates)
        let updatedAt = app.updatedAt
        try service.save(snapshot)
        #expect(app.updatedAt == updatedAt)
        #expect(!context.hasChanges)
        let fresh = ModelContext(context.container)
        #expect(try fresh.fetch(FetchDescriptor<AppEntity>()).first?.showInToolbar == false)
    }

    @Test func pendingContextEditsInvalidateTheSavedBaseline() throws {
        let (service, context) = try makeService()
        let snapshot = payload
        try service.save(snapshot)
        let app = try #require(context.fetch(FetchDescriptor<AppEntity>()).first)
        app.showInToolbar = false
        try service.save(snapshot)
        #expect(app.showInToolbar)
        #expect(!context.hasChanges)
        _ = service.load()
        var changed = snapshot
        changed.apps[0].showInContextMenu = false
        try service.save(changed)
        #expect(!app.showInContextMenu)
    }

    @Test func incrementalSaveReordersAddsRemovesAndUpdatesAllCategories() throws {
        let (service, context) = try makeService()
        var snapshot = payload
        snapshot.apps.append(OpenWithApp(id: "second", appURL: URL(fileURLWithPath: "/Applications/Second.app")))
        try service.save(snapshot)
        snapshot.apps.reverse()
        snapshot.apps[0].arguments = ["--one", "two words"]
        snapshot.apps[0].environment = ["KEY": "value"]
        snapshot.apps[0].opensContainingDir = true
        snapshot.actions[0].enabled = false
        snapshot.newFiles[0].template = URL(fileURLWithPath: "/tmp/new-template.txt")
        snapshot.commonDirs[0].name = "Changed"
        try service.save(snapshot)
        let fresh = ModelContext(context.container)
        let apps = try fresh.fetch(FetchDescriptor<AppEntity>(sortBy: [SortDescriptor(\.sortOrder)]))
        #expect(apps.map(\.id) == snapshot.apps.map(\.id))
        #expect(apps[0].arguments == snapshot.apps[0].arguments)
        #expect(apps[0].environment == snapshot.apps[0].environment)
        #expect(apps[0].opensContainingDir == true)
        #expect(try fresh.fetch(FetchDescriptor<ActionEntity>()).first?.isEnabled == false)
        #expect(try fresh.fetch(FetchDescriptor<NewFileTypeEntity>()).first?.templatePath == "/tmp/new-template.txt")
        #expect(try fresh.fetch(FetchDescriptor<CommonDirEntity>()).first?.name == "Changed")
        try service.save(AppConfigData())
        #expect(try context.fetchCount(FetchDescriptor<AppEntity>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ActionEntity>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<NewFileTypeEntity>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CommonDirEntity>()) == 0)
    }

    @Test func theFirstSaveStoresEverything() throws {
        let (service, context) = try makeService()

        try service.save(payload)

        #expect(try context.fetch(FetchDescriptor<AppEntity>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ActionEntity>()).count == 1)
    }

    @Test func savingAgainWithTheSameIDsDoesNotThrow() throws {
        let (service, _) = try makeService()
        try service.save(payload)

        // This is what every mutation in AppState does to an already-populated store.
        try service.save(payload)
    }

    @Test func savingAfterAddingAnAppKeepsBoth() throws {
        let (service, context) = try makeService()
        try service.save(payload)

        var grown = payload
        grown.apps.append(OpenWithApp(id: "ghostty-id",
                                      appURL: URL(fileURLWithPath: "/Applications/Ghostty.app")))
        try service.save(grown)

        #expect(try context.fetch(FetchDescriptor<AppEntity>()).count == 2)
    }

    @Test func existingConfigGetsNewActionsOnceAndKeepsDisabledChoices() throws {
        let (service, context) = try makeService()
        try service.save(payload)
        let first = service.load()
        #expect(first.actions.map(\.id) == ["copy-path", "checksum", "compress-zip", "compress-targz", "extract", "compress", "compress-zip-separately", "extract-and-delete"])
        #expect(first.actions.dropFirst().allSatisfy { $0.enabled })
        #expect(first.actions.map(\.idx) == [0, 1, 2, 3, 4, 5, 6, 7])
        _ = service.load()
        #expect(try context.fetch(FetchDescriptor<ActionEntity>()).count == 8)

        var disabled = first
        for index in disabled.actions.indices.dropFirst() {
            disabled.actions[index].enabled = false
        }
        try service.save(disabled)
        #expect(service.load().actions.dropFirst().allSatisfy { !$0.enabled })
    }

    @Test func loadingRemovesEncryptedShortcutsAndPreservesOtherActions() throws {
        let (service, context) = try makeService()
        var saved = payload
        saved.actions = RCAction.all.reversed().enumerated().map { index, action in
            var action = action
            action.idx = index
            action.enabled = index.isMultiple(of: 2)
            return action
        }
        let expected = saved.actions
        saved.actions += [
            RCAction(id: "compress-zip-encrypted", name: "Compress to Encrypted ZIP…", idx: -2, icon: "lock.doc"),
            RCAction(id: "compress-7z-encrypted", name: "Compress to Encrypted 7Z…", enabled: false, idx: -1, icon: "lock.doc"),
        ]
        try service.save(saved)

        for _ in 0..<2 {
            let loaded = service.load()
            #expect(loaded.actions.map(\.id) == expected.map(\.id))
            #expect(loaded.actions.map(\.idx) == expected.map(\.idx))
            #expect(loaded.actions.map(\.enabled) == expected.map(\.enabled))
            let stored = try context.fetch(FetchDescriptor<ActionEntity>())
            #expect(Set(stored.map(\.id)) == Set(expected.map(\.id)))
        }
    }

    @Test func loadingRepairsLegacyExtractAndDeleteIconAndPersistsIt() throws {
        let (service, context) = try makeService()
        var saved = payload
        var action = RCAction.extractAndDelete
        action.icon = "archivebox.badge.arrow.trianglehead.2.clockwise"
        action.enabled = false
        action.idx = 42
        saved.actions.append(action)
        try service.save(saved)

        let loaded = try #require(service.load().actions.first { $0.id == action.id })
        #expect(loaded.icon == RCAction.extractAndDelete.icon)
        #expect(!loaded.enabled)
        #expect(loaded.idx == 42)

        let freshContext = ModelContext(context.container)
        let persisted = try #require(freshContext.fetch(FetchDescriptor<ActionEntity>()).first { $0.id == action.id })
        #expect(persisted.icon == RCAction.extractAndDelete.icon)
        #expect(!persisted.isEnabled)
        #expect(persisted.sortOrder == 42)
    }
}
