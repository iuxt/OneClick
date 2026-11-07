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
        window.applyOneClickChrome()
        window.setContentSize(NSSize(width: 720, height: 440))
        window.minSize = NSSize(width: 620, height: 320)
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
        VStack(alignment: .leading, spacing: 0) {
            if model.rows.isEmpty {
                ContentUnavailableView(AppLocalization.localized("Select files in Finder to calculate checksums."), systemImage: "doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if model.isRunning {
                    HStack(spacing: 14) {
                        Image(systemName: "number.square.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 42, height: 42)
                            .background(.tint.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(appLocalized: "Calculating checksums…")
                                    .font(.headline)
                                Spacer()
                                Text("\(Int((model.progress * 100).rounded(.down)))%")
                                    .font(.headline.monospacedDigit())
                                    .contentTransition(.numericText())
                            }
                            OneClickProgressBar(
                                fraction: model.progress,
                                accessibilityLabel: AppLocalization.localized("Calculating checksums…")
                            )
                        }
                        Button { model.cancel() } label: {
                            Image(systemName: "xmark")
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                        .help(AppLocalization.localized("Cancel"))
                        .accessibilityLabel(AppLocalization.localized("Cancel"))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                } else {
                    HStack {
                        Spacer()
                        Button(AppLocalization.localized("Copy All")) { model.copy(model.copyText) }
                            .buttonStyle(.glassProminent)
                            .disabled(!model.hasResults)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.fileGroups) { file in
                            ChecksumFileView(file: file, copy: model.copy)
                            if file.id != model.fileGroups.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
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
