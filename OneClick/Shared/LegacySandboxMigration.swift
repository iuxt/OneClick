import Foundation

/// Import the previous host container once. Database and stored template URLs
/// remain unchanged; legacy bookmark entities stay in the SwiftData schema.
nonisolated enum LegacySandboxMigration {
    static let marker = "OneClick.didLeaveAppSandbox.v1"
    static var legacyDataDirectory: URL {
        guard let identifier = Bundle.main.bundleIdentifier else { return SharedAppGroup.realHomeDirectory }
        return SharedAppGroup.realHomeDirectory
            .appendingPathComponent("Library/Containers/\(identifier)/Data", isDirectory: true)
    }

    static func prepare() throws {
        guard ProcessInfo.processInfo.environment["ONECLICK_TESTING"] != "1",
              let identifier = Bundle.main.bundleIdentifier else { return }
        let home = SharedAppGroup.realHomeDirectory
        try migrate(
            defaults: .standard,
            identifier: identifier,
            legacyData: legacyDataDirectory,
            support: home.appendingPathComponent("Library/Application Support", isDirectory: true)
        )
    }

    static func migrate(defaults: UserDefaults, identifier: String, legacyData: URL, support: URL) throws {
        guard !defaults.bool(forKey: marker) else { return }
        let manager = FileManager.default
        let source = legacyData.appendingPathComponent("Library/Preferences/\(identifier).plist")
        var values: [String: Any] = [:]
        if manager.fileExists(atPath: source.path) {
            let data = try Data(contentsOf: source)
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            values = dictionary
        }

        let old = legacyData.appendingPathComponent("Library/Application Support/RClick/Templates", isDirectory: true)
        let new = support.appendingPathComponent("RClick/Templates", isDirectory: true)
        if manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) {
            try manager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try manager.copyItem(at: old, to: new) }
            catch {
                // copyItem can leave a partial destination on failure.
                try? manager.removeItem(at: new)
                throw error
            }
        }

        // The active sandbox container is authoritative on the first transition.
        // Preserve the previous non-sandboxed preferences before replacing keys.
        if !values.isEmpty {
            let backup = support.appendingPathComponent("\(identifier)/PreferencesBeforeUnsandbox.plist")
            if !manager.fileExists(atPath: backup.path) {
                var previous: [String: Any] = [:]
                for key in values.keys { previous[key] = defaults.object(forKey: key) }
                let data = try PropertyListSerialization.data(fromPropertyList: previous, format: .binary, options: 0)
                try manager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: backup, options: .atomic)
            }
            for (key, value) in values where key != marker { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
        defaults.synchronize()
    }
}
