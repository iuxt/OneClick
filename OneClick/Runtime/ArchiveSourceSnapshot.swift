import Darwin
import Foundation

/// Destructive archive actions must account for every source, including entries
/// omitted by exclusion rules. Never recursively remove a live source directory.
nonisolated struct ArchiveSourceSnapshot {
    enum Failure: LocalizedError {
        case changed, notArchived

        var errorDescription: String? {
            let key = switch self {
            case .changed: "The source files changed during the operation. Deletion was stopped to protect the remaining originals."
            case .notArchived: "Some source files were excluded or could not be confirmed in the archive. Originals were kept."
            }
            return AppLocalization.localized(key)
        }
    }

    private struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ url: URL) throws {
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }

        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isLink: Bool { mode & S_IFMT == S_IFLNK }
        func hasSameIdentity(as other: Self) -> Bool {
            device == other.device && inode == other.inode && mode == other.mode
        }
    }

    private let sources: [URL]
    private let nodes: [URL: Fingerprint]

    init(_ sources: [URL]) throws {
        self.sources = sources
        var nodes: [URL: Fingerprint] = [:]
        var pending = sources
        var pathBytes = 0
        while let url = pending.popLast() {
            try Task.checkCancellation()
            guard nodes[url] == nil else { continue }
            let info = try Fingerprint(url)
            pathBytes += url.path.utf8.count
            guard nodes.count < 100_000, pathBytes <= 32 * 1_024 * 1_024,
                  info.isDirectory || info.isLink || info.mode & S_IFMT == S_IFREG else {
                throw Failure.notArchived
            }
            nodes[url] = info
            if info.isDirectory {
                // The URL-based enumerator can silently change /var to
                // /private/var. Keep names relative to the selected spelling.
                pending.append(contentsOf: try FileManager.default.contentsOfDirectory(atPath: url.path)
                    .map { url.appendingPathComponent($0) })
            }
        }
        self.nodes = nodes
    }

    func requireCoverage(in entries: [ArchiveEntry], relativeTo parent: URL) throws {
        var archived: [String: ArchiveEntry] = [:]
        for entry in entries {
            guard archived.updateValue(entry, forKey: entry.normalizedPath) == nil else { throw Failure.notArchived }
        }
        let prefix = parent.path == "/" ? "/" : parent.path + "/"
        for (url, info) in nodes {
            try Task.checkCancellation()
            guard url.path.hasPrefix(prefix),
                  let entry = archived[String(url.path.dropFirst(prefix.count))],
                  info.isDirectory == entry.isDirectory, info.isLink == entry.isLink,
                  info.isDirectory || info.isLink || info.size == entry.size else { throw Failure.notArchived }
        }
    }

    func removeUnchanged() throws {
        // Check the complete selection before deleting any of it. ctime also
        // catches edits whose modification time has subsequently been restored.
        guard try Self(sources).nodes == nodes else { throw Failure.changed }
        let deepestFirst = nodes.keys.sorted { $0.pathComponents.count > $1.pathComponents.count }
        for url in deepestFirst {
            try Task.checkCancellation()
            guard let expected = nodes[url] else { continue }
            let current = try Fingerprint(url)
            // Removing our own children changes directory times and sizes.
            guard expected.isDirectory ? expected.hasSameIdentity(as: current) : expected == current else {
                throw Failure.changed
            }
            // rmdir refuses newly added, unrecorded children, including changes
            // after the complete pre-deletion check. unlink never follows links.
            let status = expected.isDirectory ? rmdir(url.path) : unlink(url.path)
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
}
