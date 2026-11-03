import Foundation
import SwiftData
import Testing

@testable import RClick

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
            .appendingPathComponent("rclick-config-\(UUID()).sqlite")
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
        #expect(first.actions.map(\.id) == ["copy-path", "checksum", "compress-zip", "compress-targz", "extract", "compress-zip-encrypted", "compress-7z-encrypted", "compress", "compress-zip-separately"])
        #expect(first.actions.dropFirst().allSatisfy { $0.enabled })
        #expect(first.actions.map(\.idx) == [0, 1, 2, 3, 4, 5, 6, 7, 8])
        _ = service.load()
        #expect(try context.fetch(FetchDescriptor<ActionEntity>()).count == 9)

        var disabled = first
        disabled.actions[1].enabled = false
        disabled.actions[2].enabled = false
        disabled.actions[3].enabled = false
        disabled.actions[4].enabled = false
        disabled.actions[5].enabled = false
        disabled.actions[6].enabled = false
        disabled.actions[7].enabled = false
        disabled.actions[8].enabled = false
        try service.save(disabled)
        #expect(service.load().actions.dropFirst().allSatisfy { !$0.enabled })
    }
}
