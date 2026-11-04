import AppKit
import Combine
import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

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
    @Published var folder = ""
    @Published var search = ""
    @Published var selection: String?
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

    var visibleEntries: [ArchiveEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter {
            query.isEmpty ? $0.parent == folder : $0.normalizedPath.localizedStandardContains(query)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var selectedEntry: ArchiveEntry? { entries.first { $0.id == selection } }

    func load(password: String? = nil) {
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
                entries = try Self.directoryEntries(listed)
            } catch is CancellationError { return }
            catch {
                self.error = error.localizedDescription
                if let archiveError = error as? ArchiveError,
                   [.passwordRequired, .incorrectPassword, .invalidPassword].contains(archiveError) { needsPassword = true }
            }
            loading = false
        }
    }

    static func directoryEntries(_ listed: [ArchiveEntry]) throws -> [ArchiveEntry] {
        var nodes: [String: ArchiveEntry] = [:]
        for entry in listed {
            let path = entry.normalizedPath
            guard !path.isEmpty else { continue }
            if var duplicate = nodes[path] {
                // A synthetic folder can be replaced with its real metadata.
                if !duplicate.isDirectory || !entry.isDirectory { duplicate.isLink = true }
                nodes[path] = duplicate
            } else { nodes[path] = entry }
        }
        for entry in Array(nodes.values) {
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
        previewTask?.cancel()
        previewURL = nil; previewText = nil; previewImage = nil; previewError = nil; previewing = false
        guard let entry = selectedEntry, !entry.isDirectory else { return }
        guard entry.canPreview else { previewError = ArchiveBrowserError.entryUnavailable.localizedDescription; return }
        previewing = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await ArchiveBrowserService.preview(url, entry: entry, password: password)
                try Task.checkCancellation()
                // Every preview has an isolated directory; names are never taken from an archive path.
                if let previous = previewDirectory { try? FileManager.default.removeItem(at: previous) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rclick-preview-\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                previewDirectory = directory
                let ext = (entry.name as NSString).pathExtension
                let safeExtension = ext.count <= 20 && ext.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) ? ext : ""
                let file = directory.appendingPathComponent("Preview" + (safeExtension.isEmpty ? "" : "." + safeExtension))
                try data.write(to: file, options: .atomic)
                previewURL = file
                let type = UTType(filenameExtension: safeExtension)
                if type?.conforms(to: .image) == true,
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_600,
                   ] as CFDictionary) {
                    previewImage = NSImage(cgImage: thumbnail, size: .zero)
                }
                if data.count <= 2 * 1_024 * 1_024,
                   type?.conforms(to: .text) == true || ["md", "json", "yaml", "yml", "swift", "js", "ts", "py", "sh", "log", "csv", "xml", "toml"].contains(safeExtension.lowercased()) {
                    previewText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                }
            } catch is CancellationError { return }
            catch {
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
        task?.cancel(); previewTask?.cancel()
        password = nil
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
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
                .onTapGesture(count: 2) {
                    if entry.isDirectory { model.navigate(to: entry.normalizedPath) }
                    else { model.selection = entry.id }
                }
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
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                    }
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
