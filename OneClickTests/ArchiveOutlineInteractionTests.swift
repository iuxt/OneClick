import AppKit
import SwiftUI
import Testing
@testable import OneClick

@MainActor
struct ArchiveOutlineInteractionTests {
    @Test func nativeTreeExpandsSelectsPreviewsAndSortsWithoutChangingSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-outline-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("temp/data/certs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = "{\n  \"server\": \"https://example.com\",\n  \"tls\": {\n    \"server_name\": \"example.com\"\n  }\n}\n"
        try Data(contents.utf8).write(to: root.appendingPathComponent("temp/data/config.json"))
        try Data("#!/bin/sh\necho hello\n".utf8).write(to: root.appendingPathComponent("temp/run.sh"))
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [root.appendingPathComponent("temp")]))
        let model = ArchiveBrowserModel(url: archive)
        defer { model.close() }
        let host = NSHostingView(rootView: ArchiveBrowserView(model: model, close: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        model.load()
        try await waitUntil(host) { !model.loading && !model.entries.isEmpty && Self.outline(in: host) != nil }
        let outline = try #require(Self.outline(in: host))
        let rootItem = try #require(outline.item(atRow: 0))
        #expect(outline.isItemExpanded(rootItem))
        let folder = try #require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? ArchiveOutlineView.Node }
            .first { $0.entry.normalizedPath == "temp/data" })
        outline.expandItem(folder)
        let config = try #require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? ArchiveOutlineView.Node }
            .first { $0.entry.name == "config.json" })
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: config)), byExtendingSelection: false)
        try await waitUntil(host) { model.previewText == contents }
        #expect(model.selection == config.entry.id)
        #expect(model.fileCount == 2)
        #expect(model.folderCount == 3)
        let previousTree = model.outline.id
        outline.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        try await waitUntil(host) { model.outline.id != previousTree && outline.selectedRow >= 0 }
        #expect(model.selection == config.entry.id)
        #expect((outline.item(atRow: outline.selectedRow) as? ArchiveOutlineView.Node)?.entry.id == config.entry.id)
        #expect(outline.isItemExpanded(folder))
        let scroll = try #require(outline.enclosingScrollView)
        #expect(outline.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue) == ["name", "size", "modified", "kind"])
        #expect(outline.rect(ofColumn: 3).maxX <= scroll.contentSize.width + 1)
        window.setContentSize(NSSize(width: 1060, height: 500))
        try await waitUntil(host) {
            scroll.frame.width < 600
                && outline.rect(ofColumn: 3).maxX <= scroll.contentSize.width + 1
        }

        model.filter = .files
        try await waitUntil(host) { model.outline.children.isEmpty && model.outline.roots.count == 2 }
        #expect(model.outline.roots.allSatisfy { !$0.isDirectory })
        model.filter = .all
        model.search = "config"
        try await waitUntil(host) { model.outline.roots.map(\.name) == ["config.json"] }
        #expect(model.previewText == contents)
    }

    private static func outline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews {
            if let outline = outline(in: child) { return outline }
        }
        return nil
    }

    private func waitUntil(_ host: NSView, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        host.layoutSubtreeIfNeeded()
    }
}
