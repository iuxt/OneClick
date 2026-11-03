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
    struct Row: Identifiable {
        let id: Int
        let url: URL
        let algorithm: ChecksumAlgorithm
        var fraction: Double = 0
        var digest: String?
        var error: String?
    }

    @Published private(set) var rows: [Row]
    @Published private(set) var isRunning = false
    private let inputs: [ChecksumInput]
    private var task: Task<Void, Never>?
    private var hasStarted = false

    init(inputs: [ChecksumInput]) {
        self.inputs = inputs
        rows = inputs.enumerated().flatMap { index, input in
            ChecksumAlgorithm.allCases.enumerated().map { offset, algorithm in
                Row(id: index * ChecksumAlgorithm.allCases.count + offset, url: input.url, algorithm: algorithm)
            }
        }
    }

    var progress: Double {
        rows.isEmpty ? 0 : rows.reduce(0) { $0 + $1.fraction } / Double(rows.count)
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
        task = Task(priority: .userInitiated) { [weak self] in
            await ChecksumService.calculate(inputs: inputs) { [weak self] update in
                guard let self, self.isRunning else { return }
                self.rows[update.index].fraction = update.fraction
                self.rows[update.index].digest = update.digest
                self.rows[update.index].error = update.error
            }
            self?.isRunning = false
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        for index in rows.indices where rows[index].digest == nil && rows[index].error == nil {
            rows[index].error = AppLocalization.localized("Cancelled")
        }
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
                    .disabled(model.copyText.isEmpty)
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
                        ForEach(model.rows) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(row.url.lastPathComponent).font(.headline)
                                    Text(row.algorithm.rawValue).foregroundStyle(.secondary)
                                    Spacer()
                                    if let digest = row.digest {
                                        Button(AppLocalization.localized("Copy")) { model.copy(digest) }
                                    }
                                }
                                Text(row.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let digest = row.digest {
                                    Text(digest).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                } else if let error = row.error {
                                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                                } else {
                                    ProgressView(value: row.fraction)
                                }
                            }
                            Divider()
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
