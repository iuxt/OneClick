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
        window.title = url.lastPathComponent
        window.representedURL = url
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.applyOneClickChrome()
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
    @Published private(set) var dragExtracting = false
    @Published private(set) var extractionError: String?
    @Published private(set) var verifying = false
    @Published private(set) var verificationPassed = false
    @Published private(set) var verificationError: String?
    private var verificationTask: Task<Void, Never>?
    private var verificationNeedsPassword = false
    private var extractionTask: Task<Void, Never>?
    private var dragExtractionTask: Task<Void, Error>?
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
        let sortOrder = self.sortOrder
        if query.isEmpty && filter == .all && ArchiveEntrySortComparator.isDefault(sortOrder) {
            outline = ArchiveBrowserOutline(roots: index.children[folder] ?? [], children: index.children)
            return
        }
        let snapshot = index
        let folder = self.folder
        let filter = self.filter
        searchTask = Task { [weak self] in
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(120)) }
                let outline = try await snapshot.outline(folder: folder, query: query, filter: filter, sortOrder: sortOrder)
                try Task.checkCancellation()
                self?.outline = outline
            } catch { /* A new query or closing the window cancels stale results. */ }
        }
    }

    func load(password: String? = nil) {
        guard !closed, !verifying, !extracting, !dragExtracting else { return }
        task?.cancel()
        self.password = password
        verificationPassed = false; verificationError = nil
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
            if error == nil, verificationNeedsPassword, password != nil { verify() }
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
        guard !closed, !loading, !extracting, !verifying, !dragExtracting else { return }
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

    func verify() {
        guard !closed, !loading, !extracting, !verifying, !dragExtracting else { return }
        verifying = true
        verificationPassed = false
        verificationError = nil
        verificationNeedsPassword = false
        let password = self.password
        verificationTask = Task { [weak self] in
            guard let self else { return }
            defer { verifying = false }
            do {
                try await ArchiveBrowserService.verify(url, password: password)
                try Task.checkCancellation()
                verificationPassed = true
            } catch is CancellationError {
                // Closing the browser cancels the archive test process.
            } catch {
                guard !closed, !Task.isCancelled else { return }
                verificationError = error.localizedDescription
                if let archiveError = error as? ArchiveError,
                   [.passwordRequired, .incorrectPassword, .invalidPassword].contains(archiveError) {
                    needsPassword = true
                    verificationNeedsPassword = true
                }
            }
        }
    }

    func canDrag(_ entry: ArchiveEntry) -> Bool {
        !closed && !loading && !extracting && !verifying && !dragExtracting && entry.canExtract
    }

    func extractDraggedEntry(_ entry: ArchiveEntry, to destination: URL) async throws {
        guard canDrag(entry) else { throw ArchiveBrowserError.extractionUnavailable }
        dragExtracting = true
        extractionError = nil
        let archive = url
        let password = self.password
        let extraction = Task { try await ArchiveDragExtraction.extract(archive, entry: entry, to: destination, password: password) }
        dragExtractionTask = extraction
        defer { dragExtracting = false; dragExtractionTask = nil }
        do {
            try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
        } catch {
            if !closed, !(error is CancellationError) {
                extractionError = error.localizedDescription
                if let archiveError = error as? ArchiveError,
                   [.passwordRequired, .incorrectPassword, .invalidPassword].contains(archiveError) { needsPassword = true }
            }
            throw error
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel(); previewTask?.cancel(); searchTask?.cancel(); extractionTask?.cancel(); verificationTask?.cancel()
        dragExtractionTask?.cancel()
        password = nil
        if let previewDirectory { Task { await ArchivePreparedPreview.removeDirectory(previewDirectory) } }
    }
}

struct ArchiveBrowserView: View {
    @ObservedObject var model: ArchiveBrowserModel
    let close: () -> Void
    @State private var password = ""
    @FocusState private var passwordFocused: Bool
    @State private var quickLookURL: URL?
    @State private var previewProgressVisible = false
    @State private var showsPreview = true
    @State private var expandAll = false
    @State private var expansionRequest = 0
    @State private var showsCreatedDate = false

    private var busy: Bool { model.loading || model.extracting || model.dragExtracting || model.verifying }
    private var canQuickLook: Bool {
        model.previewURL != nil && !model.previewing && !model.loading && model.error == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 12) {
                operationStatus
                if model.needsPassword { passwordPrompt }
                workspace
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.primary.opacity(0.025))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(.bordered)
        .task { model.load() }
        .onChange(of: model.selection) { model.showPreview() }
        .quickLookPreview($quickLookURL)
    }

    private var header: some View {
        HStack(spacing: 14) {
            OneClickHeaderIcon(symbol: "archivebox", color: .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.url.lastPathComponent)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Text(model.url.deletingLastPathComponent().path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(model.url.path)
            Spacer(minLength: 16)
            Button(AppLocalization.localized("Verify Archive"), systemImage: "checkmark.shield") { model.verify() }
                .disabled(busy)
            Button(AppLocalization.localized("Extract All…"), systemImage: "archivebox") { model.extract(closeWindow: close) }
                .buttonStyle(.borderedProminent)
                .disabled(busy || model.error != nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var operationStatus: some View {
        if model.extracting || model.dragExtracting {
            statusBanner { ProgressView(AppLocalization.localized("Extracting…")).controlSize(.small) }
        } else if model.verifying {
            statusBanner { ProgressView(AppLocalization.localized("Verifying archive…")).controlSize(.small) }
        } else if model.extractionError != nil || model.verificationError != nil || model.verificationPassed {
            statusBanner {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = model.extractionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let error = model.verificationError {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(AppLocalization.localized("Archive verification failed."), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } else if model.verificationPassed {
                        Label(AppLocalization.localized("Archive verification passed. No errors found."), systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private func statusBanner<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        OneClickPanel {
            content()
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var passwordPrompt: some View {
        OneClickPanel {
            HStack(spacing: 12) {
                Label(AppLocalization.localized("Archive Password"), systemImage: "lock")
                    .font(.headline)
                Spacer()
                SecureField(AppLocalization.localized("Password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .focused($passwordFocused)
                    .onSubmit(unlock)
                Button(AppLocalization.localized("Unlock"), action: unlock)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear { passwordFocused = true }
    }

    @ViewBuilder private var workspace: some View {
        if model.loading {
            OneClickPanel {
                ProgressView(AppLocalization.localized("Reading archive…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let error = model.error {
            OneClickPanel {
                ContentUnavailableView {
                    Label(AppLocalization.localized("Unable to Open Archive"), systemImage: model.needsPassword ? "lock" : "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    if !model.needsPassword { Button(AppLocalization.localized("Retry")) { model.reload() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ArchiveBrowserSplitView(showsPreview: showsPreview) {
                contentsPanel
            } preview: {
                previewPanel
            }
        }
    }

    private var contentsPanel: some View {
        OneClickPanel {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text(appLocalized: "Archive Contents")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 4)
                        if !showsPreview { quickLookButton }
                        Button(AppLocalization.localized("Refresh"), systemImage: "arrow.clockwise") { model.reload() }
                            .labelStyle(.iconOnly)
                            .help(AppLocalization.localized("Refresh"))
                            .disabled(busy)
                        viewOptions
                        Button(AppLocalization.localized(showsPreview ? "Hide Preview" : "Show Preview"), systemImage: "sidebar.right") {
                            showsPreview.toggle()
                        }
                        .labelStyle(.iconOnly)
                        .help(AppLocalization.localized(showsPreview ? "Hide Preview" : "Show Preview"))
                    }

                    HStack(spacing: 8) {
                        searchField
                        Picker(AppLocalization.localized("Filter:"), selection: $model.filter) {
                            ForEach(ArchiveEntryFilter.allCases, id: \.self) { filter in
                                Text(appLocalized: filter.rawValue).tag(filter)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                Divider()

                ArchiveOutlineView(model: model, expansionRequest: expansionRequest, expandAll: expandAll,
                                   showsCreatedDate: showsCreatedDate, quickLook: openQuickLook)
                    .overlay {
                        if model.outline.roots.isEmpty {
                            if model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                ContentUnavailableView(AppLocalization.localized("No Files"), systemImage: "folder")
                            } else {
                                ContentUnavailableView.search(text: model.search)
                            }
                        }
                    }

                Divider()
                contentsFooter
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(AppLocalization.localized("Search Archive"), text: $model.search)
                .textFieldStyle(.plain)
            if !model.search.isEmpty {
                Button(AppLocalization.localized("Clear Search"), systemImage: "xmark.circle.fill") { model.search = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 27)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }

    private var viewOptions: some View {
        Menu {
            Button(AppLocalization.localized("Expand All"), systemImage: "chevron.down") {
                requestExpansion(true)
            }
            .disabled(model.outline.children.isEmpty)
            Button(AppLocalization.localized("Collapse All"), systemImage: "chevron.right") {
                requestExpansion(false)
            }
            .disabled(model.outline.children.isEmpty)
            Divider()
            Toggle(AppLocalization.localized("Date Created"), isOn: $showsCreatedDate)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 18, height: 18)
                .accessibilityLabel(AppLocalization.localized("View Options"))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(AppLocalization.localized("View Options"))
    }

    private func requestExpansion(_ expanded: Bool) {
        expandAll = expanded
        expansionRequest += 1
    }

    private var contentsFooter: some View {
        HStack(spacing: 10) {
            Text(String(format: AppLocalization.localized("%lld files, %lld folders"), Int64(model.fileCount), Int64(model.folderCount)))
            if model.selectedEntry != nil {
                Text(String(format: AppLocalization.localized("%lld selected"), Int64(1)))
            }
            Spacer(minLength: 10)
            Text(String(format: AppLocalization.localized("Archive Size: %@"), fileSize(model.archiveSize)))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var previewPanel: some View {
        OneClickPanel {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(appLocalized: "File Preview")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    quickLookButton
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                Divider()
                if let entry = model.selectedEntry, !entry.isDirectory {
                    previewFileInfo(entry)
                    Divider()
                }
                preview
            }
        }
    }

    private var quickLookButton: some View {
        Button(AppLocalization.localized("Quick Look"), systemImage: "eye", action: openQuickLook)
            .disabled(!canQuickLook)
    }

    private func previewFileInfo(_ entry: ArchiveEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !entry.parent.isEmpty {
                    Text(entry.parent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(entry.normalizedPath)
            Spacer(minLength: 8)
            Text(fileSize(entry.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.primary.opacity(0.025))
    }

    private var preview: some View {
        // Keep text and images contained when the split is resized or the selection changes.
        GeometryReader { geometry in
            previewContent
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay {
                    if model.previewing && previewProgressVisible {
                        ProgressView(AppLocalization.localized("Preparing preview…"))
                            .padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .clipped()
        }
        .task(id: model.previewing) {
            previewProgressVisible = false
            guard model.previewing else { return }
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            previewProgressVisible = true
        }
    }

    @ViewBuilder private var previewContent: some View {
        if let error = model.previewError {
            ContentUnavailableView {
                Label(AppLocalization.localized("Preview Unavailable"), systemImage: "eye.slash")
            } description: {
                Text(error)
            }
        } else if let text = model.previewText {
            ArchiveTextPreview(text: text)
        } else if let image = model.previewImage {
            Image(nsImage: image).resizable().scaledToFit().padding(16)
                .accessibilityLabel(model.previewName ?? "")
        } else if model.previewURL != nil {
            ContentUnavailableView {
                Label(AppLocalization.localized("Quick Look"), systemImage: "eye")
            } description: {
                Text(appLocalized: "Open Quick Look to preview this file.")
            }
        } else if !model.previewing {
            ContentUnavailableView(AppLocalization.localized("Select a File to Preview"), systemImage: "doc.text.magnifyingglass")
        }
    }

    private func openQuickLook() {
        guard canQuickLook else { return }
        quickLookURL = model.previewURL
    }

    private func fileSize(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let value = password
        password = ""
        model.load(password: value)
        model.showPreview()
    }
}

private struct ArchiveBrowserSplitView<Contents: View, Preview: View>: View {
    let showsPreview: Bool
    @ViewBuilder var contents: () -> Contents
    @ViewBuilder var preview: () -> Preview
    @State private var contentsFraction: CGFloat = 0.5
    @State private var hoveringDivider = false
    @GestureState private var dragOffset: CGFloat = 0
    private let dividerWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let available = max(1, geometry.size.width - dividerWidth)
            let baseWidth = clampedContentsWidth(available * contentsFraction, available: available)
            let contentsWidth = clampedContentsWidth(baseWidth + dragOffset, available: available)

            HStack(spacing: 0) {
                contents()
                    .frame(width: showsPreview ? contentsWidth : geometry.size.width)

                if showsPreview {
                    divider(width: baseWidth, available: available)
                    preview()
                        .frame(width: available - contentsWidth)
                }
            }
            .frame(height: geometry.size.height)
        }
        .onChange(of: showsPreview) { if !showsPreview { hoveringDivider = false } }
    }

    private func divider(width: CGFloat, available: CGFloat) -> some View {
        Rectangle()
            .fill(hoveringDivider || dragOffset != 0 ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18))
            .frame(width: 1)
            .frame(width: dividerWidth)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .onHover { hoveringDivider = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragOffset) { value, offset, _ in offset = value.translation.width }
                    .onEnded { value in resize(to: width + value.translation.width, available: available) }
            )
            .accessibilityLabel(AppLocalization.localized("Resize Preview"))
            .accessibilityValue(Text(1 - width / available, format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resize(to: width - 32, available: available)
                case .decrement: resize(to: width + 32, available: available)
                @unknown default: break
                }
            }
    }

    private func resize(to width: CGFloat, available: CGFloat) {
        contentsFraction = clampedContentsWidth(width, available: available) / available
    }

    private func clampedContentsWidth(_ width: CGFloat, available: CGFloat) -> CGFloat {
        min(max(490, width), max(0, available - 320))
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
