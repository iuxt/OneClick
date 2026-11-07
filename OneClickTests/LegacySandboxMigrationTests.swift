import Foundation
import Testing
@testable import OneClick

struct LegacySandboxMigrationTests {
    @Test func importsActiveContainerOnceAndKeepsOriginalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let identifier = "oneclick-migration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: identifier))
        let legacy = root.appendingPathComponent("old-container")
        let support = root.appendingPathComponent("support")
        let source = legacy.appendingPathComponent("Library/Preferences/\(identifier).plist")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        }
        let values: [String: Any] = ["showCommonDirs": false, "inputRules": Data([1, 2]), "count": 0]
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try data.write(to: source)
        defaults.set(true, forKey: "showCommonDirs")
        defaults.set("keep", forKey: "unrelated")
        let template = legacy.appendingPathComponent("Library/Application Support/RClick/Templates/sample.txt")
        try FileManager.default.createDirectory(at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("template".utf8).write(to: template)

        try LegacySandboxMigration.migrate(defaults: defaults, identifier: identifier, legacyData: legacy, support: support)
        #expect(defaults.object(forKey: "showCommonDirs") as? Bool == false)
        #expect(defaults.data(forKey: "inputRules") == Data([1, 2]))
        #expect(defaults.integer(forKey: "count") == 0)
        #expect(defaults.string(forKey: "unrelated") == "keep")
        #expect(try Data(contentsOf: source) == data)
        #expect(try Data(contentsOf: template) == Data("template".utf8))
        #expect(try Data(contentsOf: support.appendingPathComponent("RClick/Templates/sample.txt")) == Data("template".utf8))
        let backup = try Data(contentsOf: support.appendingPathComponent("\(identifier)/PreferencesBeforeUnsandbox.plist"))
        let previous = try #require(PropertyListSerialization.propertyList(from: backup, format: nil) as? [String: Any])
        #expect(previous["showCommonDirs"] as? Bool == true)

        defaults.set(true, forKey: "showCommonDirs")
        try LegacySandboxMigration.migrate(defaults: defaults, identifier: identifier, legacyData: legacy, support: support)
        #expect(defaults.bool(forKey: "showCommonDirs")) // Never reimport stale container values.
    }

    @Test func cleanInstallDoesNotResetExistingPreferences() throws {
        let identifier = "oneclick-migration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        defaults.set(false, forKey: "showMenuBarExtra")
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try LegacySandboxMigration.migrate(defaults: defaults, identifier: identifier, legacyData: absent, support: absent)
        #expect(defaults.object(forKey: "showMenuBarExtra") as? Bool == false)
        #expect(defaults.bool(forKey: LegacySandboxMigration.marker))
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }
}
