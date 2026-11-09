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
        window.contentViewController = NSHostingController(rootView: ArchiveBrowserView(model: model) { [weak window] in
            window?.performClose(nil)
        })
        window.title = url.path
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.applyOneClickChrome()
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 1280, height: 780))
        window.contentMinSize = NSSize(width: 1060, height: 500)
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
    @Published private(set) var previewName: String?
    @Published private(set) var previewText: String?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewError: String?
    @Published private(set) var visibleEntries: [ArchiveEntry] = []
    @Published private(set) var outline = ArchiveBrowserOutline()
    @Published private(set) var fileCount = 0
    @Published private(set) var folderCount = 0
    @Published private(set) var archiveSize: Int64 = 0
    @Published var filter: ArchiveEntryFilter = .all { didSet { updateVisibleEntries() } }
    @Published var folder = "" { didSet { updateVisibleEntries() } }
    @Published var search = "" { didSet { updateVisibleEntries() } }
    @Published var sortOrder = [ArchiveEntrySortComparator()] {
        didSet { if sortOrder != oldValue { updateVisibleEntries() } }
    }
    @Published var selection: String?
    private var index = ArchiveBrowserIndex()
    private var searchTask: Task<Void, Never>?
    private var password: String?
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewDirectory: URL?
    private var closed = false
    @Published private(set) var extracting = false
    @Published private(set) var extractionError: String?
    private var extractionTask: Task<Void, Never>?
    private let extractArchive: @MainActor (URL, String?) async throws -> URL

    init(url: URL, extractArchive: @escaping @MainActor (URL, String?) async throws -> URL = { url, password in
        try await RCRuntime.shared.actionService.extractArchive(url, password: password)
    }) {
        self.url = url
        self.extractArchive = extractArchive
    }

    var selectedEntry: ArchiveEntry? { selection.flatMap { index.byID[$0] } }

    func reload() { load(password: password) }

    private func updateVisibleEntries() {
        searchTask?.cancel()
        guard !closed else { return }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let children = index.children[folder] ?? []
        let sortOrder = self.sortOrder
        let defaultOrder = sortOrder.isEmpty || sortOrder == [ArchiveEntrySortComparator()]
        if query.isEmpty && defaultOrder && filter == .all {
            visibleEntries = children
            outline = ArchiveBrowserOutline(roots: children, children: index.children)
            return
        }
        let snapshot = index
        let folder = self.folder
        let filter = self.filter
        searchTask = Task { [weak self] in
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(120)) }
                let matches = query.isEmpty ? children : try await snapshot.search(query)
                let results = defaultOrder ? matches : try await ArchiveBrowserIndex.sorted(matches, using: sortOrder)
                let outline = try await snapshot.outline(folder: folder, query: query, filter: filter, sortOrder: sortOrder)
                try Task.checkCancellation()
                self?.visibleEntries = results
                self?.outline = outline
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
                let listed = try await ArchiveBrowserService.list(url, password: password)
                try Task.checkCancellation()
                let built = try await ArchiveBrowserIndex.build(listed)
                try Task.checkCancellation()
                index = built
                entries = built.entries
                fileCount = built.entries.lazy.filter { !$0.isDirectory }.count
                folderCount = built.entries.count - fileCount
                archiveSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
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
        previewError = nil
        guard let entry = selectedEntry, !entry.isDirectory else {
            clearPreview(); previewing = false
            return
        }
        guard entry.canPreview else {
            clearPreview(); previewing = false
            previewError = ArchiveBrowserError.entryUnavailable.localizedDescription
            return
        }
        // Keep the current content mounted until its replacement is ready.
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
                previewName = entry.name
                previewText = prepared.text
                previewImage = prepared.image.map { NSImage(cgImage: $0, size: .zero) }
                if let previous { Task { await ArchivePreparedPreview.removeDirectory(previous) } }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                clearPreview()
                previewError = error.localizedDescription
                if let archiveError = error as? ArchiveError,
                   archiveError == .passwordRequired || archiveError == .incorrectPassword { needsPassword = true }
            }
            previewing = false
        }
    }

    private func clearPreview() {
        previewURL = nil; previewName = nil; previewText = nil; previewImage = nil
        if let directory = previewDirectory {
            previewDirectory = nil
            Task { await ArchivePreparedPreview.removeDirectory(directory) }
        }
    }

    func navigate(to path: String) { selection = nil; folder = path; search = ""; showPreview() }

    func extract(closeWindow: @escaping () -> Void) {
        guard !closed, !extracting else { return }
        extracting = true
        extractionError = nil
        extractionTask = Task {
            defer { extracting = false }
            do {
                _ = try await extractArchive(url, password)
                try Task.checkCancellation()
                close()
                closeWindow()
            } catch is CancellationError {
                // Closing the browser cancels extraction and its temporary output.
            } catch {
                guard !closed else { return }
                extractionError = error.localizedDescription
                if let archiveError = error as? ArchiveError,
                   [.passwordRequired, .incorrectPassword, .invalidPassword].contains(archiveError) {
                    needsPassword = true
                }
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel(); previewTask?.cancel(); searchTask?.cancel(); extractionTask?.cancel()
        password = nil
        if let previewDirectory { Task { await ArchivePreparedPreview.removeDirectory(previewDirectory) } }
    }
}

private enum ArchiveBrowserPalette {
    static let toolbar = Color(red: 0.49, green: 0.25, blue: 0.10)
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.16, green: 0.14, blue: 0.12) : Color(red: 0.93, green: 0.87, blue: 0.78)
    }
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(nsColor: .textBackgroundColor) : .white
    }
}

struct ArchiveBrowserView: View {
    @ObservedObject var model: ArchiveBrowserModel
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var password = ""
    @State private var quickLookURL: URL?
    @State private var previewProgressVisible = false
    @State private var showsPreview = true
    @State private var expandAll = false
    @State private var expansionRequest = 0
    @State private var showsCreatedDate = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.extracting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(appLocalized: "Extracting…").font(.callout.weight(.medium))
                    Spacer()
                }.padding(12)
            }
            if let error = model.extractionError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(12)
            }
            if model.needsPassword {
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    SecureField(AppLocalization.localized("Password"), text: $password).onSubmit(unlock)
                        .textFieldStyle(.roundedBorder)
                    Button(AppLocalization.localized("Unlock"), action: unlock).disabled(password.isEmpty)
                }.padding(16)
                Divider()
            }
            if model.loading {
                ProgressView(AppLocalization.localized("Reading archive…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(AppLocalization.localized("Unable to Open Archive"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    if !model.needsPassword { Button(AppLocalization.localized("Retry")) { model.load() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    fileList.frame(minWidth: 490, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                    if showsPreview {
                        preview
                            .background(ArchiveBrowserPalette.paper(colorScheme))
                            .padding(10)
                            .frame(minWidth: 320, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Divider()
            statusBar
        }
        .background(ArchiveBrowserPalette.canvas(colorScheme))
        .ignoresSafeArea(.container, edges: .top)
        .task { model.load() }
        .onChange(of: model.selection) { model.showPreview() }
        .quickLookPreview($quickLookURL)
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            Text(model.url.path)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 120)
                .frame(maxWidth: .infinity).frame(height: 26)
                .help(model.url.path)
            HStack(alignment: .bottom, spacing: 18) {
                toolbarAction("Quick Look", symbol: "eye", colors: [.pink, .purple]) {
                    quickLookURL = model.previewURL
                }.disabled(model.previewURL == nil || model.previewing)
                toolbarAction("Extract All…", symbol: "archivebox", colors: [.yellow, .orange]) {
                    model.extract(closeWindow: close)
                }.disabled(model.loading || model.extracting || model.error != nil)
                toolbarAction("Refresh", symbol: "arrow.clockwise", colors: [.mint, .green]) {
                    model.reload()
                }.disabled(model.loading || model.extracting)
                toolbarAction(expandAll ? "Collapse All" : "Expand All", symbol: expandAll ? "chevron.down" : "chevron.right",
                              colors: [.purple, .blue]) {
                    expandAll.toggle()
                    expansionRequest += 1
                }.disabled(model.loading || model.outline.children.isEmpty)
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Text(appLocalized: "Filter:").font(.system(size: 13, weight: .medium))
                    Picker(AppLocalization.localized("Filter:"), selection: $model.filter) {
                        ForEach(ArchiveEntryFilter.allCases, id: \.self) { filter in
                            Text(AppLocalization.localized(filter.rawValue)).tag(filter)
                        }
                    }.labelsHidden().frame(width: 104)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        TextField(AppLocalization.localized("Search Archive"), text: $model.search)
                            .textFieldStyle(.plain)
                        if !model.search.isEmpty {
                            Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel(AppLocalization.localized("Clear Search"))
                        }
                    }
                    .padding(.horizontal, 9).frame(width: 175, height: 28)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    Button { showsPreview.toggle() } label: { Image(systemName: "sidebar.right") }
                        .help(AppLocalization.localized(showsPreview ? "Hide Preview" : "Show Preview"))
                        .accessibilityLabel(AppLocalization.localized(showsPreview ? "Hide Preview" : "Show Preview"))
                    Menu {
                        Toggle(AppLocalization.localized("Date Created"), isOn: $showsCreatedDate)
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .menuIndicator(.hidden).fixedSize()
                    .help(AppLocalization.localized("Columns"))
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .padding(.bottom, 3)
            }
            .padding(.horizontal, 24).padding(.top, 2).padding(.bottom, 10)
        }
        .foregroundStyle(.white)
        .background(ArchiveBrowserPalette.toolbar.gradient)
        .environment(\.colorScheme, .dark)
    }

    private func toolbarAction(_ title: String, symbol: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom), in: Circle())
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                Text(AppLocalization.localized(title)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }.frame(minWidth: 66)
        }
        .buttonStyle(.plain)
        .help(AppLocalization.localized(title))
    }

    private var fileList: some View {
        ArchiveOutlineView(model: model, expansionRequest: expansionRequest, expandAll: expandAll,
                           showsCreatedDate: showsCreatedDate, quickLook: { quickLookURL = model.previewURL })
            .overlay {
                if model.outline.roots.isEmpty {
                    ContentUnavailableView(AppLocalization.localized("No Files"), systemImage: "folder")
                }
            }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Text(String(format: AppLocalization.localized("Archive Size: %@"),
                        ByteCountFormatter.string(fromByteCount: model.archiveSize, countStyle: .file)))
            Text(String(format: AppLocalization.localized("%lld files, %lld folders"), model.fileCount, model.folderCount))
            if model.selectedEntry != nil {
                Text("|").foregroundStyle(.secondary)
                Text(String(format: AppLocalization.localized("%lld selected"), 1))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).lineLimit(1)
        .padding(.horizontal, 16).frame(height: 30)
    }

    private var preview: some View {
        // Content and loading indicators must not change the split pane's sizing.
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                previewContent
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if let file = model.previewURL {
                    Button { quickLookURL = file } label: {
                        Image(systemName: "eye.fill").font(.system(size: 16))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(AppLocalization.localized("Quick Look"))
                    .accessibilityLabel(AppLocalization.localized("Quick Look"))
                    .disabled(model.previewing).padding(8)
                }
                if model.previewing && previewProgressVisible {
                    ProgressView(AppLocalization.localized("Preparing preview…"))
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: model.previewing) {
            previewProgressVisible = false
            guard model.previewing else { return }
            // Fast file switches should not flash a loading indicator.
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            previewProgressVisible = true
        }
    }

    @ViewBuilder private var previewContent: some View {
        if let error = model.previewError {
            ContentUnavailableView { Label(AppLocalization.localized("Preview Unavailable"), systemImage: "eye.slash") }
                description: { Text(error) }
        } else if model.previewURL != nil {
            VStack(spacing: 0) {
                if let text = model.previewText {
                    ArchiveTextPreview(text: text)
                } else if let image = model.previewImage {
                    Image(nsImage: image).resizable().scaledToFit().padding(20)
                } else {
                    Spacer()
                    Image(systemName: "doc.richtext").font(.system(size: 54)).foregroundStyle(.secondary)
                    Text(model.previewName ?? "").font(.headline)
                    Text(appLocalized: "Open Quick Look to preview this file.").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        } else if !model.previewing {
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
        view.textContainerInset = NSSize(width: 10, height: 8)
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
