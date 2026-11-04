import Foundation

nonisolated struct InstalledApplication: Identifiable, Sendable {
    let url: URL
    let name: String
    var id: URL { url }

    /// Enumerate metadata away from the main actor, without descending into app
    /// bundles (which can contain many thousands of files and nested helper apps).
    @concurrent
    static func discover(in directories: [URL]? = nil) async -> [Self] {
        let manager = FileManager.default
        let roots = directories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ] + manager.urls(for: .applicationDirectory, in: .userDomainMask)
        var found: [URL: Self] = [:]
        for root in roots {
            guard !Task.isCancelled else { return [] }
            guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = entries.nextObject() as? URL {
                guard !Task.isCancelled else { return [] }
                guard url.pathExtension.lowercased() == "app",
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                entries.skipDescendants()
                let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
                let displayName = manager.displayName(atPath: url.path)
                let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
                found[canonicalURL] = Self(url: canonicalURL, name: name)
            }
        }
        return found.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }
}
