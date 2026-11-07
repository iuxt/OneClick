import Foundation

/// Built once off the UI thread. Folder navigation and selection are dictionary
/// lookups; preview updates never rescan or sort the archive directory.
nonisolated struct ArchiveBrowserIndex: Sendable {
    let entries: [ArchiveEntry]
    let byID: [String: ArchiveEntry]
    let children: [String: [ArchiveEntry]]
    private let searchable: [(entry: ArchiveEntry, path: String)]

    init() {
        entries = []; byID = [:]; children = [:]; searchable = []
    }

    private init(entries: [ArchiveEntry], byID: [String: ArchiveEntry],
                 children: [String: [ArchiveEntry]], searchable: [(entry: ArchiveEntry, path: String)]) {
        self.entries = entries; self.byID = byID
        self.children = children; self.searchable = searchable
    }

    @concurrent
    static func build(_ listed: [ArchiveEntry]) async throws -> Self {
        let entries = try ArchiveBrowserModel.directoryEntries(listed)
        // Cache path components before sorting instead of splitting strings in
        // every comparison (and again on every SwiftUI body evaluation).
        var named = entries.map { (entry: $0, name: $0.name, path: $0.normalizedPath, parent: $0.parent) }
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
                    searchable: named.map { ($0.entry, $0.path) })
    }

    @concurrent
    func search(_ query: String) async throws -> [ArchiveEntry] {
        var result: [ArchiveEntry] = []
        for item in searchable {
            try Task.checkCancellation()
            if item.path.localizedStandardContains(query) { result.append(item.entry) }
        }
        return result
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
