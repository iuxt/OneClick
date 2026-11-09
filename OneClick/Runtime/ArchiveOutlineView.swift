import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native outline rows keep large archives virtualized and provide keyboard navigation.
struct ArchiveOutlineView: NSViewRepresentable {
    let model: ArchiveBrowserModel
    let expansionRequest: Int
    let expandAll: Bool
    let showsCreatedDate: Bool
    let quickLook: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ArchiveOutlineScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let outline = NSOutlineView()
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.usesAlternatingRowBackgroundColors = false
        outline.rowHeight = 27
        outline.intercellSpacing = NSSize(width: 8, height: 0)
        outline.indentationPerLevel = 16
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.autosaveExpandedItems = false
        outline.setAccessibilityLabel(AppLocalization.localized("Archive"))
        for (key, title, width, minimum) in [
            ("name", "Name", 210.0, 160.0),
            ("size", "Size", 85.0, 65.0),
            ("modified", "Date Modified", 158.0, 145.0),
            ("kind", "Kind", 100.0, 80.0),
            ("created", "Date Created", 158.0, 145.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = AppLocalization.localized(title)
            column.width = width
            column.minWidth = minimum
            column.resizingMask = .userResizingMask
            if key != "kind" { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true) }
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.tableColumns.last?.isHidden = !showsCreatedDate
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openItem(_:))
        scroll.documentView = outline
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let outline = coordinator.outline else { return }
        outline.tableColumns.last?.isHidden = !showsCreatedDate
        (scroll as? ArchiveOutlineScrollView)?.fitColumns()
        if coordinator.snapshot.id != model.outline.id {
            coordinator.suppressSelection = true
            let origin = scroll.contentView.bounds.origin
            coordinator.snapshot = model.outline
            outline.reloadData()
            // Restore parent folders before descendants after a sort or query change.
            for path in coordinator.expandedPaths.sorted(by: { $0.count < $1.count }) {
                if let node = coordinator.nodes[path] { outline.expandItem(node) }
            }
            if !coordinator.hasLoaded && !model.outline.roots.isEmpty {
                coordinator.hasLoaded = true
                if model.outline.roots.count == 1, let entry = model.outline.roots.first, entry.isDirectory {
                    outline.expandItem(coordinator.node(entry))
                }
            }
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            coordinator.suppressSelection = false
        }
        if coordinator.expansionRequest != expansionRequest {
            coordinator.expansionRequest = expansionRequest
            coordinator.suppressSelection = true
            if expandAll { outline.expandItem(nil, expandChildren: true) }
            else { outline.collapseItem(nil, collapseChildren: true) }
            coordinator.suppressSelection = false
        }
        coordinator.suppressSelection = true
        if let id = model.selection, let node = coordinator.nodes[id] {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            else { outline.deselectAll(nil) }
        } else { outline.deselectAll(nil) }
        coordinator.suppressSelection = false
    }

    final class Node: NSObject {
        var entry: ArchiveEntry
        init(_ entry: ArchiveEntry) { self.entry = entry }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: ArchiveOutlineView
        weak var outline: NSOutlineView?
        var snapshot = ArchiveBrowserOutline()
        var nodes: [String: Node] = [:]
        var expandedPaths: Set<String> = []
        var expansionRequest = 0
        var suppressSelection = false
        var hasLoaded = false
        private var icons: [String: NSImage] = [:]
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter
        }()

        init(_ parent: ArchiveOutlineView) { self.parent = parent }

        func node(_ entry: ArchiveEntry) -> Node {
            if let node = nodes[entry.id] { node.entry = entry; return node }
            let node = Node(entry)
            nodes[entry.id] = node
            return node
        }

        private func children(_ item: Any?) -> [ArchiveEntry] {
            guard let node = item as? Node else { return snapshot.roots }
            return snapshot.children[node.entry.normalizedPath] ?? []
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { node(children(item)[index]) }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            return node.entry.isDirectory && !(snapshot.children[node.entry.normalizedPath] ?? []).isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let key = tableColumn?.identifier.rawValue else { return nil }
            let entry = node.entry
            let identifier = NSUserInterfaceItemIdentifier("archive-" + key)
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? makeCell(identifier, name: key == "name")
            let value: String
            switch key {
            case "name":
                value = entry.name
                cell.imageView?.image = icon(entry)
            case "size": value = entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            case "modified": value = entry.modifiedDate.map(dateFormatter.string) ?? "—"
            case "created": value = entry.createdDate.map(dateFormatter.string) ?? "—"
            default: value = kind(entry)
            }
            cell.textField?.stringValue = value
            cell.toolTip = key == "name" ? entry.normalizedPath : value
            return cell
        }

        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, name: Bool) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            var constraints = [label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                               label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)]
            if name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                constraints += [image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18),
                                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8)]
            } else {
                constraints.append(label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
            }
            NSLayoutConstraint.activate(constraints)
            return cell
        }

        private func icon(_ entry: ArchiveEntry) -> NSImage {
            let key = entry.isDirectory ? "folder" : entry.isLink ? "link" : "ext:" + (entry.name as NSString).pathExtension.lowercased()
            if let image = icons[key] { return image }
            let image: NSImage
            if entry.isLink { image = NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage() }
            else if entry.isDirectory { image = NSWorkspace.shared.icon(for: .folder) }
            else { image = NSWorkspace.shared.icon(for: UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data) }
            icons[key] = image
            return image
        }

        private func kind(_ entry: ArchiveEntry) -> String {
            if entry.isDirectory { return AppLocalization.localized("Folder") }
            if entry.isLink { return AppLocalization.localized("Link") }
            let ext = (entry.name as NSString).pathExtension
            return UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? AppLocalization.localized("File") : ext.uppercased())
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelection, let outline else { return }
            parent.model.selection = (outline.item(atRow: outline.selectedRow) as? Node)?.entry.id
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? Node { expandedPaths.insert(node.entry.normalizedPath) }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? Node { expandedPaths.remove(node.entry.normalizedPath) }
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = outlineView.sortDescriptors.first else { return }
            let field: ArchiveEntrySortComparator.Field
            switch descriptor.key {
            case "size": field = .size
            case "modified": field = .modified
            case "created": field = .created
            default: field = .name
            }
            parent.model.sortOrder = [.init(field: field, order: descriptor.ascending ? .forward : .reverse)]
        }

        @objc func openItem(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? Node else { return }
            if node.entry.isDirectory {
                if sender.isItemExpanded(node) { sender.collapseItem(node) }
                else { sender.expandItem(node) }
            } else if parent.model.previewURL != nil && !parent.model.previewing { parent.quickLook() }
        }
    }
}

/// SwiftUI lays out the split after creating this view. Fit the columns to the
/// eventual viewport, rather than letting the name column retain that first size.
private final class ArchiveOutlineScrollView: NSScrollView {
    private var fitting = false

    override func tile() {
        super.tile()
        fitColumns()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitColumns()
    }

    override func layout() {
        super.layout()
        fitColumns()
    }

    func fitColumns() {
        guard !fitting, let outline = documentView as? NSOutlineView else { return }
        let width = min(bounds.width, min(contentSize.width, contentView.bounds.width))
        let columns = outline.tableColumns.filter { !$0.isHidden }
        guard width > 0, let name = columns.first else { return }
        fitting = true
        defer { fitting = false }
        let spacing = outline.intercellSpacing.width * CGFloat(columns.count)
        let fixed = columns.dropFirst().reduce(CGFloat.zero) { $0 + $1.width }
        var available = width - spacing - fixed
        // Keep the four default columns visible at the minimum split width.
        if available < name.minWidth && columns.count == 4 {
            for column in columns.dropFirst().reversed() {
                let reduction = min(name.minWidth - available, column.width - column.minWidth)
                column.width -= reduction
                available += reduction
                if available >= name.minWidth { break }
            }
        }
        let desired = max(name.minWidth, available)
        if abs(name.width - desired) > 0.5 { name.width = desired }
    }
}
