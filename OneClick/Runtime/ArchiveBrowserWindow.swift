import AppKit
import Combine
import QuickLook
import SwiftUI

@MainActor
final class ArchiveBrowserPresenter {
    static let shared = ArchiveBrowserPresenter()
    private var windows: [URL: ArchiveBrowserWindowController] = [:]

    func open(_ url: URL) {
        let key = url.standardizedFileURL
        let controller: ArchiveBrowserWindowController
        if let existing = windows[key] { controller = existing }
        else {
            controller = ArchiveBrowserWindowController(url: url) { [weak self] in self?.windows[key] = nil }
            windows[key] = controller
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class ArchiveBrowserWindowController: NSWindowController, NSWindowDelegate {
    private let model: ArchiveBrowserModel
    private let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        model = ArchiveBrowserModel(url: url)
        self.onClose = onClose
        let window = NSWindow()
        window.contentViewController = NSHostingController(rootView: ArchiveBrowserView(model: model))
        window.title = url.lastPathComponent
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 640))
        window.contentMinSize = NSSize(width: 760, height: 460)
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { model.close(); onClose() }
}

@MainActor
final class ArchiveBrowserModel: ObservableObject {
    let url: URL
    @Published private(set) var entries: [ArchiveEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var needsPassword = false
    @Published private(set) var previewing = false
    @Published private(set) var previewURL: URL?
    @Published private(set) var previewText: String?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewError: String?
    @Published private(set) var visibleEntries: [ArchiveEntry] = []
    @Published var folder = "" { didSet { updateVisibleEntries() } }
    @Published var search = "" { didSet { updateVisibleEntries() } }
    @Published var selection: String?
    private var index = ArchiveBrowserIndex()
    private var searchTask: Task<Void, Never>?
    private var password: String?
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewDirectory: URL?
    private var scoped = false
    private var closed = false

    init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    var selectedEntry: ArchiveEntry? { selection.flatMap { index.byID[$0] } }

    private func updateVisibleEntries() {
        searchTask?.cancel()
        guard !closed else { return }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            visibleEntries = index.children[folder] ?? []
            return
        }
        let snapshot = index
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let results = try await snapshot.search(query)
                try Task.checkCancellation()
                self?.visibleEntries = results
            } catch { /* A new query or closing the window cancels stale results. */ }
        }
    }

    func load(password: String? = nil) {
        guard !closed else { return }
        task?.cancel()
        self.password = password
        error = nil; needsPassword = false; loading = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if ArchiveFormat.suffix(for: url)?.hasSuffix(".001") == true {
                    // A file-open grant covers the selected volume only. All
                    // volumes require the same explicit folder grant as extraction.
                    let permission = RCRuntime.shared.permissionService
                    let parent = url.deletingLastPathComponent()
                    if !permission.hasAccess(to: parent) {
                        guard await permission.promptForPermission(for: parent) != nil,
                              permission.hasAccess(to: parent) else { throw CocoaError(.fileReadNoPermission) }
                    }
                }
                let listed = try await ArchiveBrowserService.list(url, password: password)
                try Task.checkCancellation()
                let built = try await ArchiveBrowserIndex.build(listed)
                try Task.checkCancellation()
                index = built
                entries = built.entries
                updateVisibleEntries()
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                if let archiveError = error as? ArchiveError,
                   [.passwordRequired, .incorrectPassword, .invalidPassword].contains(archiveError) { needsPassword = true }
            }
            loading = false
        }
    }

    nonisolated static func directoryEntries(_ listed: [ArchiveEntry]) throws -> [ArchiveEntry] {
        var nodes: [String: ArchiveEntry] = [:]
        for entry in listed {
            try Task.checkCancellation()
            let path = entry.normalizedPath
            guard !path.isEmpty else { continue }
            if var duplicate = nodes[path] {
                // A synthetic folder can be replaced with its real metadata.
                if !duplicate.isDirectory || !entry.isDirectory { duplicate.isLink = true }
                nodes[path] = duplicate
            } else { nodes[path] = entry }
        }
        for entry in Array(nodes.values) {
            try Task.checkCancellation()
            let parts = entry.normalizedPath.components(separatedBy: "/")
            guard parts.count <= 256 else { throw ArchiveBrowserError.listingTooLarge }
            guard !parts.contains(".."), !parts.contains("") else { continue }
            var path = ""
            for part in parts.dropLast() {
                path = path.isEmpty ? part : path + "/" + part
                if nodes[path] == nil {
                    guard nodes.count < 100_000 else { throw ArchiveBrowserError.listingTooLarge }
                    nodes[path] = ArchiveEntry(path: path, size: 0, isDirectory: true)
                }
            }
        }
        return Array(nodes.values)
    }

    func showPreview() {
        guard !closed else { return }
        previewTask?.cancel()
        previewURL = nil; previewText = nil; previewImage = nil; previewError = nil; previewing = false
        guard let entry = selectedEntry, !entry.isDirectory else { return }
        guard entry.canPreview else { previewError = ArchiveBrowserError.entryUnavailable.localizedDescription; return }
        previewing = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await ArchivePreparedPreview.prepare(url, entry: entry, password: password)
                guard !Task.isCancelled else {
                    await ArchivePreparedPreview.removeDirectory(prepared.directory)
                    return
                }
                let previous = previewDirectory
                previewDirectory = prepared.directory
                previewURL = prepared.file
                previewText = prepared.text
                previewImage = prepared.image.map { NSImage(cgImage: $0, size: .zero) }
                if let previous { Task { await ArchivePreparedPreview.removeDirectory(previous) } }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                previewError = error.localizedDescription
                if let archiveError = error as? ArchiveError,
                   archiveError == .passwordRequired || archiveError == .incorrectPassword { needsPassword = true }
            }
            previewing = false
        }
    }

    func navigate(to path: String) { selection = nil; folder = path; search = ""; showPreview() }

    func extract() {
        Task { await RCRuntime.shared.actionService.showArchives([url.path], operation: .extract) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel(); previewTask?.cancel(); searchTask?.cancel()
        password = nil
        if let previewDirectory { Task { await ArchivePreparedPreview.removeDirectory(previewDirectory) } }
        if scoped { url.stopAccessingSecurityScopedResource(); scoped = false }
    }
}

private struct ArchiveBrowserView: View {
    @ObservedObject var model: ArchiveBrowserModel
    @State private var password = ""
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill").font(.title).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.url.lastPathComponent).font(.headline).lineLimit(1)
                    Text(appLocalized: "Browse files without extracting the entire archive")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppLocalization.localized("Extract All…"), systemImage: "arrow.down.doc") { model.extract() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.loading)
            }.padding(20)
            Divider()
            if model.needsPassword {
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    SecureField(AppLocalization.localized("Password"), text: $password).onSubmit(unlock)
                        .textFieldStyle(.roundedBorder)
                    Button(AppLocalization.localized("Unlock"), action: unlock).disabled(password.isEmpty)
                }.padding(16)
                Divider()
            }
            HStack {
                Button { model.navigate(to: model.folder.components(separatedBy: "/").dropLast().joined(separator: "/")) }
                    label: { Image(systemName: "chevron.up") }
                    .disabled(model.folder.isEmpty).help(AppLocalization.localized("Parent Folder"))
                Button(AppLocalization.localized("Archive")) { model.navigate(to: "") }.buttonStyle(.plain)
                if !model.folder.isEmpty {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    Text(model.folder).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                TextField(AppLocalization.localized("Search Archive"), text: $model.search)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if model.loading {
                ProgressView(AppLocalization.localized("Reading archive…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(AppLocalization.localized("Unable to Open Archive"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    if !model.needsPassword { Button(AppLocalization.localized("Retry")) { model.load() } }
                }
            } else {
                HSplitView {
                    fileList.frame(minWidth: 380)
                    preview.frame(minWidth: 280, idealWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text(String(format: AppLocalization.localized("%lld entries"), model.entries.count))
                Spacer()
                if let entry = model.selectedEntry { Text(entry.normalizedPath).lineLimit(1).truncationMode(.middle) }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        }
        .background(.background)
        .task { model.load() }
        .onChange(of: model.selection) { model.showPreview() }
        .quickLookPreview($quickLookURL)
    }

    private var fileList: some View {
        List(selection: $model.selection) {
            ForEach(model.visibleEntries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : entry.isLink ? "link" : "doc")
                        .foregroundStyle(entry.isDirectory ? .blue : .secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(1)
                        if !model.search.isEmpty { Text(entry.parent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if entry.encrypted { Image(systemName: "lock").font(.caption).foregroundStyle(.secondary) }
                    if entry.isDirectory {
                        Button { model.navigate(to: entry.normalizedPath) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.borderless).help(AppLocalization.localized("Open Folder"))
                    } else {
                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.vertical, 5).contentShape(Rectangle()).tag(entry.id)
            }
        }
        // Let the list handle double-clicks without delaying single-click selection
        // while a row-level double-tap recognizer waits for a second click.
        .contextMenu(forSelectionType: String.self) { _ in
            EmptyView()
        } primaryAction: { selection in
            guard let id = selection.first else { return }
            model.selection = id
            if let entry = model.selectedEntry, entry.isDirectory {
                model.navigate(to: entry.normalizedPath)
            }
        }
        .overlay {
            if model.visibleEntries.isEmpty {
                ContentUnavailableView(AppLocalization.localized("No Files"), systemImage: "folder")
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if model.previewing {
            ProgressView(AppLocalization.localized("Preparing preview…"))
        } else if let error = model.previewError {
            ContentUnavailableView { Label(AppLocalization.localized("Preview Unavailable"), systemImage: "eye.slash") }
                description: { Text(error) }
        } else if let file = model.previewURL {
            VStack(spacing: 16) {
                if let text = model.previewText {
                    ArchiveTextPreview(text: text)
                } else if let image = model.previewImage {
                    Image(nsImage: image).resizable().scaledToFit().padding(20)
                } else {
                    Spacer()
                    Image(systemName: "doc.richtext").font(.system(size: 54)).foregroundStyle(.secondary)
                    Text(model.selectedEntry?.name ?? "").font(.headline)
                    Text(appLocalized: "Open Quick Look to preview this file.").foregroundStyle(.secondary)
                    Spacer()
                }
                Button(AppLocalization.localized("Quick Look"), systemImage: "eye") { quickLookURL = file }
                    .padding(.bottom, 16)
            }
        } else {
            ContentUnavailableView(AppLocalization.localized("Select a File to Preview"), systemImage: "doc.text.magnifyingglass")
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let value = password
        password = ""
        model.load(password: value)
        model.showPreview()
    }
}

/// NSTextView lays out the visible portion of large text previews on demand.
/// A single SwiftUI Text measures the entire file before drawing its first frame.
private struct ArchiveTextPreview: NSViewRepresentable {
    let text: String

    final class Coordinator { var text: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = view.maxSize
        view.textContainer?.widthTracksTextView = false
        view.layoutManager?.allowsNonContiguousLayout = true
        view.usesFindBar = true
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.text != text, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = text
        view.string = text
        view.scrollToBeginningOfDocument(nil)
    }
}
