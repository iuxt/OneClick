import Foundation
import OSLog
import SwiftData

nonisolated struct SettingsBackup: Codable, Sendable {
    var version = 1
    let configuration: Data
    var booleans: [String: Bool] = [:]
    var integers: [String: Int] = [:]
    var strings: [String: String] = [:]
    var data: [String: Data] = [:]
    var templates: [String: Template] = [:]

    struct Template: Codable, Sendable {
        let isDirectory: Bool
        let directories: [String]
        let files: [String: Data]
    }
}

nonisolated enum SettingsBackupError: LocalizedError {
    case invalidBackup, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidBackup: AppLocalization.localized("This is not a supported OneClick settings backup.")
        case .tooLarge: AppLocalization.localized("Settings backups are limited to 64 MiB of template data and 10,000 files.")
        }
    }
}

/// An explicit preference list avoids exporting caches, migration markers or IPC state.
@MainActor
final class SettingsManagementService {
    static let booleanKeys = ["foldAppsMenu", "foldActionsMenu", "foldArchivesMenu", "foldNewFileMenu",
                              "foldCommonDirMenu", "showCommonDirs", Key.showMenuBarExtra, "archiveExcludeFiles"]
    static let integerKeys = ["appIconStyle", "archiveCompressionLevel", "archiveCompressionThreads"]
    static let stringKeys = ["archiveCompressionFormat", "archiveExclusionList",
                             Key.globalApplicationArgumentsString, Key.globalApplicationEnvironmentString]
    static let dataKeys = [InputMethodService.storageKey]

    private let config: ConfigService
    private let defaults: UserDefaults
    private let templateDirectory: URL

    init(config: ConfigService, defaults: UserDefaults = .group, templateDirectory: URL? = nil) {
        self.config = config
        self.defaults = defaults
        self.templateDirectory = templateDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RClick/Templates", isDirectory: true)
    }

    func export(_ snapshot: AppConfigData, to url: URL) async throws {
        var backup = SettingsBackup(configuration: try JSONEncoder().encode(snapshot))
        for key in Self.booleanKeys where defaults.object(forKey: key) != nil { backup.booleans[key] = defaults.bool(forKey: key) }
        for key in Self.integerKeys where defaults.object(forKey: key) != nil { backup.integers[key] = defaults.integer(forKey: key) }
        for key in Self.stringKeys { backup.strings[key] = defaults.string(forKey: key) }
        for key in Self.dataKeys { backup.data[key] = defaults.data(forKey: key) }
        let templates = snapshot.newFiles.compactMap { file in file.template.map { (file.id, $0) } }
        try await SettingsBackupIO.write(backup, templates: templates, to: url)
    }

    func restore(from url: URL) async throws -> AppConfigData {
        let backup = try await SettingsBackupIO.read(url)
        var snapshot = try JSONDecoder().decode(AppConfigData.self, from: backup.configuration)
        try validate(snapshot, backup: backup)
        let staging = templateDirectory.appendingPathComponent("import-\(UUID())", isDirectory: true)
        do {
            let restored = try await SettingsBackupIO.restoreTemplates(backup.templates, in: staging)
            for index in snapshot.newFiles.indices { snapshot.newFiles[index].template = restored[snapshot.newFiles[index].id] }
            try config.save(snapshot)
        } catch {
            config.modelContext.rollback()
            await SettingsBackupIO.remove(staging)
            throw error
        }
        // Publish preferences only after the database write has succeeded.
        clearPreferences()
        for (key, value) in backup.booleans { defaults.set(value, forKey: key) }
        for (key, value) in backup.integers { defaults.set(value, forKey: key) }
        for (key, value) in backup.strings { defaults.set(value, forKey: key) }
        for (key, value) in backup.data { defaults.set(value, forKey: key) }
        return snapshot
    }

    func reset() throws -> AppConfigData {
        let directories = CommonDirEntity.createDefaultCommonDirs().map {
            CommonDir(id: $0.id, name: $0.name, url: $0.path, icon: $0.icon)
        }
        let actions = RCAction.all.enumerated().map { index, item in
            var item = item; item.idx = index; return item
        }
        let files = NewFile.all.enumerated().map { index, item in
            var item = item; item.idx = index; return item
        }
        let snapshot = AppConfigData(apps: OpenWithApp.defaultApps, actions: actions,
                                     newFiles: files, commonDirs: directories)
        do { try config.save(snapshot) }
        catch { config.modelContext.rollback(); throw error }
        clearPreferences()
        return snapshot
    }

    private func clearPreferences() {
        for key in Self.booleanKeys + Self.integerKeys + Self.stringKeys + Self.dataKeys { defaults.removeObject(forKey: key) }
    }

    private func validate(_ snapshot: AppConfigData, backup: SettingsBackup) throws {
        let groups = [snapshot.apps.map(\.id), snapshot.actions.map(\.id), snapshot.newFiles.map(\.id), snapshot.commonDirs.map(\.id)]
        guard groups.allSatisfy({ $0.count <= 10_000 && Set($0).count == $0.count && !$0.contains("") }),
              snapshot.apps.allSatisfy({ $0.url.isFileURL }), snapshot.commonDirs.allSatisfy({ $0.url.isFileURL }),
              snapshot.newFiles.allSatisfy({ !$0.ext.contains("/") && !$0.ext.contains("\\") && !$0.ext.contains("\0") }),
              Set(backup.templates.keys) == Set(snapshot.newFiles.filter { $0.template != nil }.map(\.id)),
              Set(backup.booleans.keys).isSubset(of: Set(Self.booleanKeys)),
              Set(backup.integers.keys).isSubset(of: Set(Self.integerKeys)),
              Set(backup.strings.keys).isSubset(of: Set(Self.stringKeys)),
              Set(backup.data.keys).isSubset(of: Set(Self.dataKeys)) else { throw SettingsBackupError.invalidBackup }
        if let data = backup.data[InputMethodService.storageKey] {
            _ = try JSONDecoder().decode(InputMethodConfiguration.self, from: data)
        }
        if let value = backup.integers["appIconStyle"], RCAppIconStyle(rawValue: value) == nil { throw SettingsBackupError.invalidBackup }
        if let value = backup.integers["archiveCompressionLevel"],
           !ArchiveCompressionLevel.defaultCases.contains(where: { $0.rawValue == value }) {
            throw SettingsBackupError.invalidBackup
        }
        if let value = backup.integers["archiveCompressionThreads"], value < 0 { throw SettingsBackupError.invalidBackup }
        if let value = backup.strings["archiveCompressionFormat"], ArchiveCompressionFormat(rawValue: value) == nil { throw SettingsBackupError.invalidBackup }
    }
}

nonisolated enum SettingsBackupIO {
    static let dataLimit = 64 * 1_024 * 1_024

    @concurrent
    static func write(_ snapshot: SettingsBackup, templates: [(String, URL)], to url: URL) async throws {
        var backup = snapshot
        var bytes = 0
        var count = 0
        for (id, source) in templates {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw SettingsBackupError.invalidBackup }
            var files: [String: Data] = [:]
            var directories: [String] = []
            func readFile(_ file: URL, path: String) throws {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw SettingsBackupError.invalidBackup }
                guard bytes + (values.fileSize ?? 0) <= dataLimit, count < 10_000 else { throw SettingsBackupError.tooLarge }
                let data = try Data(contentsOf: file)
                bytes += data.count; count += 1
                guard bytes <= dataLimit else { throw SettingsBackupError.tooLarge }
                files[path] = data
            }
            if values.isDirectory == true {
                let canonicalSource = source.resolvingSymlinksInPath()
                var enumerationError: Error?
                guard let enumerator = FileManager.default.enumerator(
                    at: canonicalSource, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    errorHandler: { _, error in enumerationError = error; return false }
                ) else {
                    throw SettingsBackupError.invalidBackup
                }
                while let child = enumerator.nextObject() as? URL {
                    let info = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard info.isSymbolicLink != true else { throw SettingsBackupError.invalidBackup }
                    let childPath = child.resolvingSymlinksInPath().path
                    let prefix = canonicalSource.path + "/"
                    guard childPath.hasPrefix(prefix) else { throw SettingsBackupError.invalidBackup }
                    let path = String(childPath.dropFirst(prefix.count))
                    if info.isDirectory == true {
                        directories.append(path)
                        guard directories.count + count <= 10_000 else { throw SettingsBackupError.tooLarge }
                    } else { try readFile(child, path: path) }
                }
                if let enumerationError { throw enumerationError }
            } else { try readFile(source, path: "") }
            backup.templates[id] = SettingsBackup.Template(isDirectory: values.isDirectory == true, directories: directories, files: files)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(backup)
        guard data.count <= dataLimit * 2 else { throw SettingsBackupError.tooLarge }
        try data.write(to: url, options: .atomic)
    }

    @concurrent
    static func read(_ url: URL) async throws -> SettingsBackup {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= dataLimit * 2 else { throw SettingsBackupError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= dataLimit * 2 else { throw SettingsBackupError.tooLarge }
        let backup = try PropertyListDecoder().decode(SettingsBackup.self, from: data)
        guard backup.version == 1 else { throw SettingsBackupError.invalidBackup }
        var bytes = 0
        var count = 0
        for template in backup.templates.values {
            bytes += template.files.values.reduce(0) { $0 + $1.count }
            count += template.files.count + template.directories.count
            guard bytes <= dataLimit, count <= 10_000 else { throw SettingsBackupError.tooLarge }
            if template.isDirectory {
                guard (Array(template.files.keys) + template.directories).allSatisfy(safePath) else { throw SettingsBackupError.invalidBackup }
            } else {
                guard template.directories.isEmpty, Set(template.files.keys) == [""] else { throw SettingsBackupError.invalidBackup }
            }
        }
        return backup
    }

    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    @concurrent
    static func restoreTemplates(_ templates: [String: SettingsBackup.Template], in root: URL) async throws -> [String: URL] {
        guard !templates.isEmpty else { return [:] }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var restored: [String: URL] = [:]
        for (id, template) in templates {
            let destination = root.appendingPathComponent(UUID().uuidString)
            if template.isDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                for path in template.directories {
                    try FileManager.default.createDirectory(at: destination.appendingPathComponent(path), withIntermediateDirectories: true)
                }
                for (path, data) in template.files {
                    let file = destination.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file, options: .withoutOverwriting)
                }
            } else {
                guard let data = template.files[""] else { throw SettingsBackupError.invalidBackup }
                try data.write(to: destination, options: .withoutOverwriting)
            }
            restored[id] = destination
        }
        return restored
    }

    @concurrent
    static func remove(_ url: URL) async { try? FileManager.default.removeItem(at: url) }

    @concurrent
    static func exportLogs(to url: URL) async throws {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: Date().addingTimeInterval(-86_400)))
        var lines = ["OneClick \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")",
                     ProcessInfo.processInfo.operatingSystemVersionString]
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(entry.date) [\(entry.subsystem)/\(entry.category)] \(entry.composedMessage)")
            if lines.count >= 10_000 { break }
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
