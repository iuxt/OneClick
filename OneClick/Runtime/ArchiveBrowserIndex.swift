import Foundation

nonisolated enum ArchiveEntryFilter: String, CaseIterable, Sendable {
    case all = "All", files = "Files", folders = "Folders"

    func includes(_ entry: ArchiveEntry) -> Bool {
        switch self {
        case .all: true
        case .files: !entry.isDirectory
        case .folders: entry.isDirectory
        }
    }
}

/// One immutable tree per query/sort change; selection and preview updates reuse it.
nonisolated struct ArchiveBrowserOutline: Sendable {
    let id = UUID()
    var roots: [ArchiveEntry] = []
    var children: [String: [ArchiveEntry]] = [:]
}

/// Built once off the UI thread. Folder navigation and selection are dictionary
/// lookups; preview updates never rescan or sort the archive directory.
nonisolated struct ArchiveBrowserIndex: Sendable {
    let entries: [ArchiveEntry]
    let byID: [String: ArchiveEntry]
    let children: [String: [ArchiveEntry]]
    private let searchPaths: [String]

    init() {
        entries = []; byID = [:]; children = [:]; searchPaths = []
    }

    private init(entries: [ArchiveEntry], byID: [String: ArchiveEntry],
                 children: [String: [ArchiveEntry]], searchPaths: [String]) {
        self.entries = entries; self.byID = byID
        self.children = children; self.searchPaths = searchPaths
    }

    @concurrent
    static func build(_ listed: [ArchiveEntry]) async throws -> Self {
        let entries = try ArchiveBrowserModel.directoryEntries(listed)
        var named = entries.map { entry in
            let path = entry.normalizedPath
            let parts = path.components(separatedBy: "/")
            return (entry: entry, name: parts.last ?? entry.path, path: path,
                    parent: parts.dropLast().joined(separator: "/"))
        }
        try Task.checkCancellation()
        named.sort {
            if $0.entry.isDirectory != $1.entry.isDirectory { return $0.entry.isDirectory }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        var children: [String: [ArchiveEntry]] = [:]
        var byID: [String: ArchiveEntry] = [:]
        for item in named {
            try Task.checkCancellation()
            children[item.parent, default: []].append(item.entry)
            byID[item.entry.id] = item.entry
        }
        return Self(entries: named.map(\.entry), byID: byID, children: children,
                    searchPaths: named.map(\.path))
    }

    @concurrent
    func search(_ query: String, filter: ArchiveEntryFilter = .all) async throws -> [ArchiveEntry] {
        var result: [ArchiveEntry] = []
        for (entry, path) in zip(entries, searchPaths) {
            try Task.checkCancellation()
            if filter.includes(entry), query.isEmpty || path.localizedStandardContains(query) {
                result.append(entry)
            }
        }
        return result
    }

    @concurrent
    func outline(folder: String, query: String, filter: ArchiveEntryFilter,
                 sortOrder: [ArchiveEntrySortComparator]) async throws -> ArchiveBrowserOutline {
        let defaultOrder = ArchiveEntrySortComparator.isDefault(sortOrder)
        if !query.isEmpty || filter != .all {
            let matches = try await search(query, filter: filter)
            let roots = defaultOrder ? matches : try await Self.sorted(matches, using: sortOrder)
            return ArchiveBrowserOutline(roots: roots)
        }
        if defaultOrder {
            return ArchiveBrowserOutline(roots: children[folder] ?? [], children: children)
        }
        var sortedChildren: [String: [ArchiveEntry]] = [:]
        for (path, entries) in children {
            try Task.checkCancellation()
            sortedChildren[path] = entries.sorted(using: sortOrder)
        }
        return ArchiveBrowserOutline(roots: sortedChildren[folder] ?? [], children: sortedChildren)
    }

    @concurrent
    static func sorted(_ entries: [ArchiveEntry], using sortOrder: [ArchiveEntrySortComparator]) async throws -> [ArchiveEntry] {
        try Task.checkCancellation()
        let result = entries.sorted(using: sortOrder.isEmpty ? [ArchiveEntrySortComparator()] : sortOrder)
        try Task.checkCancellation()
        return result
    }
}

/// Keep folders first and unavailable metadata last in either direction.
/// Equal values use natural filename order and then the full path for stability.
nonisolated struct ArchiveEntrySortComparator: SortComparator, Sendable {
    enum Field: Hashable, Sendable { case name, size, modified, created }
    var field: Field = .name
    var order: SortOrder = .forward

    static func isDefault(_ sortOrder: [Self]) -> Bool {
        sortOrder.isEmpty || sortOrder == [Self()]
    }

    func compare(_ lhs: ArchiveEntry, _ rhs: ArchiveEntry) -> ComparisonResult {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory ? .orderedAscending : .orderedDescending }
        let result: ComparisonResult
        switch field {
        case .name: result = ordered(lhs.name.localizedStandardCompare(rhs.name))
        case .size: result = compareValues(lhs.isDirectory ? nil : lhs.size, rhs.isDirectory ? nil : rhs.size)
        case .modified: result = compareValues(lhs.modifiedDate, rhs.modifiedDate)
        case .created: result = compareValues(lhs.createdDate, rhs.createdDate)
        }
        if result != .orderedSame { return result }
        let name = lhs.name.localizedStandardCompare(rhs.name)
        if name != .orderedSame { return name }
        if lhs.normalizedPath == rhs.normalizedPath { return .orderedSame }
        return lhs.normalizedPath < rhs.normalizedPath ? .orderedAscending : .orderedDescending
    }

    private func compareValues<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): ordered(lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending)
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        }
    }

    private func ordered(_ result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
