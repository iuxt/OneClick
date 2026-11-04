import Foundation
import SwiftData
import Testing
@testable import OneClick

@MainActor
struct SettingsManagementTests {
    private func withFixture(_ work: (URL, ConfigService, UserDefaults, SettingsManagementService) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-settings-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "oneclick-settings-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let container = try ModelContainer(for: AppEntity.self, ActionEntity.self, NewFileTypeEntity.self, CommonDirEntity.self,
                                           BookmarkEntity.self, configurations: ModelConfiguration(url: root.appendingPathComponent("store.sqlite")))
        let config = ConfigService(modelContext: ModelContext(container))
        let service = SettingsManagementService(config: config, defaults: defaults, templateDirectory: root.appendingPathComponent("templates"))
        try await work(root, config, defaults, service)
    }

    @Test func backupRoundTripIncludesTemplatesAppOptionsAndInputMethodRules() async throws {
        try await withFixture { root, config, defaults, service in
            let template = root.appendingPathComponent("template.txt")
            try Data("original template".utf8).write(to: template)
            let package = root.appendingPathComponent("template.pages")
            try FileManager.default.createDirectory(at: package.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try Data("package contents".utf8).write(to: package.appendingPathComponent("index"))
            var app = OpenWithApp(id: "editor", appURL: URL(fileURLWithPath: "/Applications/Editor.app"))
            app.arguments = ["--new-window", "space value"]
            app.environment = ["KEY": "value=with=equals"]
            app.opensNewInstance = true
            app.showInToolbar = false
            var file = NewFile(ext: ".txt", name: "Custom", idx: 0, id: "custom")
            file.template = template
            var packageFile = NewFile(ext: ".pages", name: "Package", idx: 1, id: "package")
            packageFile.template = package
            var action = RCAction.copyPath; action.enabled = false
            let snapshot = AppConfigData(apps: [app], actions: [action], newFiles: [file, packageFile], commonDirs: [
                CommonDir(id: "z", name: "Z", url: root, icon: "folder"),
                CommonDir(id: "a", name: "A", url: root.appendingPathComponent("other"), icon: "folder")
            ])
            defaults.set(true, forKey: "foldArchivesMenu")
            defaults.set(9, forKey: "archiveCompressionLevel")
            var input = InputMethodConfiguration()
            input.enabled = true
            input.rules = [InputMethodRule(bundleID: "editor", name: "Editor", sourceID: "test-source")]
            defaults.set(try JSONEncoder().encode(input), forKey: InputMethodService.storageKey)
            defaults.set("keep me", forKey: "unrelated-cache")
            let backup = root.appendingPathComponent("backup.plist")
            try await service.export(snapshot, to: backup)
            try Data("changed later".utf8).write(to: template)
            defaults.set(false, forKey: "foldArchivesMenu")
            defaults.set(true, forKey: "archiveExcludeFiles")
            let restored = try await service.restore(from: backup)
            #expect(restored.apps.first?.arguments == app.arguments)
            #expect(restored.apps.first?.environment == app.environment)
            #expect(restored.apps.first?.opensNewInstance == true)
            #expect(restored.apps.first?.showInToolbar == false)
            let restoredTemplate = try #require(restored.newFiles.first?.template)
            #expect(restoredTemplate != template)
            #expect(try String(contentsOf: restoredTemplate, encoding: .utf8) == "original template")
            let restoredPackage = try #require(restored.newFiles.last?.template)
            #expect(try String(contentsOf: restoredPackage.appendingPathComponent("index"), encoding: .utf8) == "package contents")
            #expect(FileManager.default.fileExists(atPath: restoredPackage.appendingPathComponent("empty").path))
            let persisted = config.load()
            #expect(persisted.newFiles.first?.template == restoredTemplate)
            #expect(persisted.commonDirs.map(\.id) == ["z", "a"])
            #expect(persisted.actions.first?.enabled == false)
            #expect(defaults.bool(forKey: "foldArchivesMenu"))
            #expect(defaults.integer(forKey: "archiveCompressionLevel") == 9)
            #expect(defaults.object(forKey: "archiveExcludeFiles") == nil)
            #expect(try JSONDecoder().decode(InputMethodConfiguration.self, from: #require(defaults.data(forKey: InputMethodService.storageKey))) == input)
            #expect(defaults.string(forKey: "unrelated-cache") == "keep me")
        }
    }

    @Test func invalidBackupsLeaveTheCurrentSettingsUntouched() async throws {
        try await withFixture { root, config, defaults, service in
            let current = AppConfigData(apps: [OpenWithApp(id: "keep", appURL: URL(fileURLWithPath: "/Applications/Keep.app"))])
            try config.save(current)
            defaults.set(true, forKey: "foldAppsMenu")
            let url = root.appendingPathComponent("bad.plist")
            var backup = SettingsBackup(configuration: try JSONEncoder().encode(AppConfigData()))
            backup.version = 99
            try PropertyListEncoder().encode(backup).write(to: url)
            await #expect(throws: SettingsBackupError.self) { try await service.restore(from: url) }
            backup.version = 1
            backup.booleans["unrecognized-setting"] = true
            try PropertyListEncoder().encode(backup).write(to: url)
            await #expect(throws: SettingsBackupError.self) { try await service.restore(from: url) }
            backup.booleans = [:]
            backup.templates["evil"] = SettingsBackup.Template(isDirectory: true, directories: [], files: ["../escape": Data()])
            try PropertyListEncoder().encode(backup).write(to: url)
            await #expect(throws: SettingsBackupError.self) { try await service.restore(from: url) }
            #expect(config.load().apps.map(\.id) == ["keep"])
            #expect(defaults.bool(forKey: "foldAppsMenu"))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
        }
    }

    @Test func resetRestoresDefaultsAndRetainsFolderGrantsAndUnrelatedPreferences() async throws {
        try await withFixture { _, config, defaults, service in
            try config.save(AppConfigData(apps: [OpenWithApp(id: "custom", appURL: URL(fileURLWithPath: "/tmp/Custom.app"))]))
            config.modelContext.insert(BookmarkEntity(bookmarkData: Data("grant".utf8), pathString: "/tmp/granted"))
            try config.modelContext.save()
            defaults.set(true, forKey: "foldAppsMenu")
            defaults.set("keep", forKey: "unrelated-cache")
            let reset = try service.reset()
            #expect(reset.actions.map(\.id) == RCAction.all.map(\.id))
            #expect(reset.newFiles.map(\.id) == NewFile.all.map(\.id))
            #expect(!config.load().apps.contains { $0.id == "custom" })
            #expect(defaults.object(forKey: "foldAppsMenu") == nil)
            #expect(defaults.string(forKey: "unrelated-cache") == "keep")
            #expect(try config.modelContext.fetch(FetchDescriptor<BookmarkEntity>()).count == 1)
        }
    }
}
