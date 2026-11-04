import Foundation
import SwiftData
import Testing

@testable import OneClick

/// `ConfigService.save` replaces the whole store: it deletes every row of each
/// entity and inserts the in-memory arrays back.
///
/// Every entity carries `@Attribute(.unique)` on its `id`, and the ids survive the
/// round trip (`OpenWithApp(id: entity.id, ...)`), so the second save re-inserts
/// ids the context is still holding as pending deletions. These tests use an
/// in-memory container - the real store in the App Group must not be touched.
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
