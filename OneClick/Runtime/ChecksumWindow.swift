import AppKit
import Combine
import SwiftUI

@MainActor
protocol ChecksumPresenting: AnyObject {
    func show(inputs: [ChecksumInput])
}

/// AppKit only manages window lifetime; all window content is SwiftUI.
@MainActor
final class ChecksumWindowPresenter: ChecksumPresenting {
    static let shared = ChecksumWindowPresenter()
    private var windows: [UUID: ChecksumWindowController] = [:]

    func show(inputs: [ChecksumInput]) {
        let id = UUID()
        let controller = ChecksumWindowController(inputs: inputs) { [weak self] in
            self?.windows[id] = nil
        }
        windows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class ChecksumWindowController: NSWindowController, NSWindowDelegate {
    private let model: ChecksumViewModel
    private let onClose: () -> Void

    init(inputs: [ChecksumInput], onClose: @escaping () -> Void) {
        model = ChecksumViewModel(inputs: inputs)
        self.onClose = onClose
        let window = NSWindow(contentViewController: NSHostingController(rootView: ChecksumView(model: model)))
        window.title = AppLocalization.localized("File Checksums")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 480))
        window.minSize = NSSize(width: 650, height: 360)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        onClose()
    }
}

@MainActor
final class ChecksumViewModel: ObservableObject {
    final class Row: ObservableObject, Identifiable {
        let id: Int
        let url: URL
        let algorithm: ChecksumAlgorithm
        @Published private(set) var result: ChecksumUpdate
        var fraction: Double { result.fraction }
        var digest: String? { result.digest }
        var error: String? { result.error }

        init(id: Int, url: URL, algorithm: ChecksumAlgorithm) {
            self.id = id; self.url = url; self.algorithm = algorithm
            result = ChecksumUpdate(index: id)
        }

        func update(_ value: ChecksumUpdate) { result = value }
    }

    struct FileGroup: Identifiable {
        let id: Int
        let url: URL
        let rows: [Row]
    }

    let rows: [Row]
    let fileGroups: [FileGroup]
    @Published private(set) var progress: Double = 0
    @Published private(set) var hasResults = false
    @Published private(set) var isRunning = false
    private let inputs: [ChecksumInput]
    private var task: Task<Void, Never>?
    private var hasStarted = false
    private var pendingUpdates: [Int: ChecksumUpdate] = [:]
    private var polling: Task<Void, Never>?
    private var totalFraction: Double = 0

    init(inputs: [ChecksumInput]) {
        self.inputs = inputs
        let groups = inputs.enumerated().map { index, input in
            FileGroup(id: index, url: input.url, rows: ChecksumAlgorithm.allCases.enumerated().map { offset, algorithm in
                Row(id: index * ChecksumAlgorithm.allCases.count + offset, url: input.url, algorithm: algorithm)
            })
        }
        fileGroups = groups
        rows = groups.flatMap(\.rows)
    }

    var copyText: String {
        rows.compactMap { row in
            row.digest.map { "\(row.algorithm.rawValue) (\(row.url.path)) = \($0)" }
        }.joined(separator: "\n")
    }

    func start() {
        guard !hasStarted, !inputs.isEmpty else { return }
        hasStarted = true
        isRunning = true
        let inputs = self.inputs
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                self?.flushUpdates()
            }
        }
        task = Task(priority: .userInitiated) { [weak self] in
            await ChecksumService.calculate(inputs: inputs) { [weak self] update in
                guard let self, self.isRunning else { return }
                self.pendingUpdates[update.index] = update
            }
            self?.flushUpdates()
            self?.polling?.cancel()
            self?.polling = nil
            self?.isRunning = false
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        polling?.cancel()
        polling = nil
        flushUpdates()
        isRunning = false
        for row in rows where row.digest == nil && row.error == nil {
            row.update(ChecksumUpdate(index: row.id, fraction: row.fraction, error: AppLocalization.localized("Cancelled")))
        }
    }

    private func flushUpdates() {
        guard !pendingUpdates.isEmpty else { return }
        for (index, update) in pendingUpdates {
            totalFraction += update.fraction - rows[index].fraction
            rows[index].update(update)
            if update.digest != nil && !hasResults { hasResults = true }
        }
        pendingUpdates.removeAll(keepingCapacity: true)
        progress = rows.isEmpty ? 0 : min(1, max(0, totalFraction / Double(rows.count)))
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ChecksumView: View {
    @ObservedObject var model: ChecksumViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(AppLocalization.localized("File Checksums"), systemImage: "number.square")
                    .font(.title2.bold())
                Spacer()
                if model.isRunning {
                    Button(AppLocalization.localized("Cancel")) { model.cancel() }
                }
                Button(AppLocalization.localized("Copy All")) { model.copy(model.copyText) }
                    .disabled(!model.hasResults)
            }
            if model.rows.isEmpty {
                ContentUnavailableView(AppLocalization.localized("Select files in Finder to calculate checksums."), systemImage: "doc")
            } else {
                if model.isRunning {
                    ProgressView(value: model.progress)
                    Text(appLocalized: "Calculating checksums…")
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.fileGroups) { file in
                            ChecksumFileView(file: file, copy: model.copy)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 610, minHeight: 320)
        .onAppear { model.start() }
    }
}

private struct ChecksumFileView: View {
    let file: ChecksumViewModel.FileGroup
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.url.lastPathComponent)
                        .font(.headline)
                    Text(file.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(14)
            .help(file.url.path)

            Divider()

            VStack(spacing: 12) {
                ForEach(file.rows) { row in
                    ChecksumResultRow(row: row, copy: copy)
                    if row.id != file.rows.last?.id {
                        Divider()
                    }
                }
            }
            .padding(14)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}

private struct ChecksumResultRow: View {
    @ObservedObject var row: ChecksumViewModel.Row
    let copy: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.algorithm.rawValue)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Group {
                if let digest = row.digest {
                    Text(digest)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } else if let error = row.error {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    ProgressView(value: row.fraction)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            Button(AppLocalization.localized("Copy")) {
                if let digest = row.digest { copy(digest) }
            }
            .disabled(row.digest == nil)
        }
    }
}
