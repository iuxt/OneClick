import Foundation

/// Shared with Finder so extraction is offered only for recognized archives.
nonisolated enum ArchiveFormat {
    static let suffixes = [
        "tar.gz", "tar.bz2", "tar.xz", "tar.lzma", "tar.Z", "tar",
        "tgz", "tbz2", "tbz", "txz", "zip.001", "7z.001", "zip", "zipx", "7z", "rar",
        "jar", "war", "apk", "ipa", "xpi", "cab", "iso", "cpio", "cpgz",
    ]

    static func suffix(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        return suffixes.first { name.hasSuffix("." + $0.lowercased()) }
    }

    static func extractionName(for url: URL) -> String {
        guard let suffix = suffix(for: url) else { return url.deletingPathExtension().lastPathComponent }
        let name = String(url.lastPathComponent.dropLast(suffix.count + 1))
        return name.isEmpty || name == "." || name == ".." ? AppLocalization.localized("Archive") : name
    }
}
