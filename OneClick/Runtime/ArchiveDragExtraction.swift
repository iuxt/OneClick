import Darwin
import Foundation

/// Extract into a private staging directory and publish only the promised item.
/// Finder supplies the final name, including any collision resolution.
nonisolated enum ArchiveDragExtraction {
    static func selectedEntries(_ selected: ArchiveEntry, in listed: [ArchiveEntry]) throws -> [ArchiveEntry] {
        let entries = try ArchiveBrowserModel.directoryEntries(listed)
        let path = selected.normalizedPath
        guard let current = entries.first(where: { $0.normalizedPath == path }),
              current.isDirectory == selected.isDirectory, current.canExtract else {
            throw ArchiveBrowserError.extractionUnavailable
        }
        let result = entries.filter { $0.normalizedPath == path || (current.isDirectory && $0.normalizedPath.hasPrefix(path + "/")) }
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.normalizedPath, $0) })
        var names = Set<String>()
        for entry in result {
            try Task.checkCancellation()
            guard entry.canExtract,
                  names.insert(entry.normalizedPath.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ArchiveBrowserError.extractionUnavailable
            }
            var parent = entry.parent
            while !parent.isEmpty {
                guard let ancestor = byPath[parent], ancestor.isDirectory, ancestor.canExtract else {
                    throw ArchiveBrowserError.extractionUnavailable
                }
                parent = ancestor.parent
            }
        }
        return result
    }

    @concurrent
    static func extract(_ archive: URL, entry: ArchiveEntry, to destination: URL, password: String?,
                        progress: ArchiveProgress = ArchiveProgress()) async throws {
        try await withTaskCancellationHandler {
            guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
            let listed = try await ArchiveBrowserService.list(archive, password: password, progress: progress)
            let selected = try selectedEntries(entry, in: listed)
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".oneclick-drag-\(UUID())", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            if ArchiveService.usesSevenZip(for: archive) {
                try ArchiveService.extractEntry(at: archive, path: entry.path, to: staging, password: password, progress: progress)
            } else {
                try SystemArchiveReader.extract(archive, entries: selected, to: staging)
            }
            try Task.checkCancellation()
            try validateOutput(staging, entry: entry, selected: selected)
            let output = staging.appendingPathComponent(entry.normalizedPath)
            try Task.checkCancellation()
            guard renamex_np(output.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
            }
        } onCancel: { progress.cancel() }
    }

    private static func validateOutput(_ staging: URL, entry: ArchiveEntry, selected: [ArchiveEntry]) throws {
        let fm = FileManager.default
        // Recheck actual output before moving it outside the private directory.
        let allowed = Set(selected.map(\.normalizedPath))
        // Relative names also avoid /var versus /private/var URL aliases.
        guard let enumerator = fm.enumerator(atPath: staging.path) else {
            throw ArchiveBrowserError.extractionUnavailable
        }
        for case let path as String in enumerator {
            try Task.checkCancellation()
            let file = staging.appendingPathComponent(path)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            let isParent = entry.normalizedPath.hasPrefix(path + "/")
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true,
                  allowed.contains(path) || (isParent && values.isDirectory == true) else {
                throw ArchiveBrowserError.extractionUnavailable
            }
        }
        for item in selected {
            try Task.checkCancellation()
            let file = staging.appendingPathComponent(item.normalizedPath)
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard item.isDirectory ? values.isDirectory == true : values.isRegularFile == true && Int64(values.fileSize ?? -1) == item.size else {
                throw ArchiveBrowserError.extractionUnavailable
            }
        }
    }
}
