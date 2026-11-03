import AppKit
import Combine
import SwiftUI

@MainActor
protocol ArchivePresenting: AnyObject {
    func show(requests: [ArchiveRequest])
}

@MainActor
final class ArchiveWindowPresenter: ArchivePresenting {
    static let shared = ArchiveWindowPresenter()
    private var windows: [UUID: ArchiveWindowController] = [:]

    func show(requests: [ArchiveRequest]) {
        guard !requests.isEmpty else { return }
        let id = UUID()
        let controller = ArchiveWindowController(requests: requests) { [weak self] in self?.windows[id] = nil }
        windows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class ArchiveWindowController: NSWindowController, NSWindowDelegate {
    private let model: ArchiveViewModel
    private let onClose: () -> Void

    init(requests: [ArchiveRequest], onClose: @escaping () -> Void) {
        model = ArchiveViewModel(requests: requests)
        self.onClose = onClose
        let window = NSWindow(contentViewController: NSHostingController(rootView: ArchiveView(model: model)))
        window.title = AppLocalization.localized("Archives")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: requests.contains(where: { $0.operation == .compress }) ? 520 : 400))
        window.minSize = NSSize(width: 520, height: 300)
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
final class ArchiveViewModel: ObservableObject {
    struct Row: Identifiable {
        let id: Int
        var request: ArchiveRequest
        var output: URL?
        var error: String?
        var isRunning = false
        var needsPassword = false
        var needsConfiguration = false
    }

    @Published private(set) var rows: [Row]
    @Published private(set) var isRunning = false
    @Published private(set) var detail = ""
    private var task: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var progress: ArchiveProgress?
    private var hasStarted = false

    init(requests: [ArchiveRequest]) {
        rows = requests.enumerated().map {
            Row(id: $0.offset, request: $0.element, error: $0.element.error,
                needsPassword: $0.element.operation.isEncryptedCompression && $0.element.error == nil,
                needsConfiguration: $0.element.operation == .compress && $0.element.error == nil)
        }
    }

    func start() {
        guard !hasStarted, !rows.isEmpty else { return }
        hasStarted = true
        run(indices: rows.indices.filter { !rows[$0].needsPassword && !rows[$0].needsConfiguration && rows[$0].error == nil })
    }

    func submitCompression(for index: Int, format: ArchiveCompressionFormat,
                           level: ArchiveCompressionLevel, password: String?) {
        guard !isRunning, rows.indices.contains(index), rows[index].needsConfiguration else { return }
        // Never silently discard a requested password for an unsupported format.
        guard format != .tarGzip || password == nil else {
            rows[index].error = ArchiveError.encryptionNotSupported.localizedDescription
            return
        }
        rows[index].request = ArchiveRequest(operation: format.operation(encrypted: password != nil),
                                             urls: rows[index].request.urls, compressionLevel: level)
        rows[index].error = nil
        rows[index].needsConfiguration = false
        run(indices: [index], password: password)
    }

    func submitPassword(for index: Int, password: String) {
        guard !isRunning, rows.indices.contains(index), rows[index].needsPassword else { return }
        rows[index].error = nil
        rows[index].needsPassword = false
        run(indices: [index], password: password)
    }

    private func run(indices: [Int], password: String? = nil) {
        guard !indices.isEmpty, !isRunning else { return }
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            for index in indices {
                guard !Task.isCancelled else { break }
                if let error = self.rows[index].request.error {
                    self.rows[index].error = error
                    continue
                }
                let progress = ArchiveProgress()
                self.progress = progress
                self.rows[index].isRunning = true
                self.detail = ""
                self.polling = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.detail = progress.detail
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
                    }
                }
                do {
                    self.rows[index].output = try await ArchiveService.perform(self.rows[index].request, password: password, progress: progress)
                } catch is CancellationError {
                    self.rows[index].error = AppLocalization.localized("Cancelled")
                } catch let error as ArchiveError {
                    switch error {
                    case .passwordRequired, .incorrectPassword, .invalidPassword, .invalidZIPPassword:
                        self.rows[index].needsPassword = true
                    default: break
                    }
                    self.rows[index].error = error.localizedDescription
                } catch {
                    self.rows[index].error = error.localizedDescription
                }
                self.rows[index].isRunning = false
                self.polling?.cancel()
                self.polling = nil
                self.progress = nil
            }
            self.isRunning = false
            self.task = nil
        }
    }

    func cancel() {
        hasStarted = true
        task?.cancel()
        progress?.cancel()
        for index in rows.indices where rows[index].output == nil && (rows[index].error == nil || rows[index].needsPassword || rows[index].needsConfiguration) {
            rows[index].error = AppLocalization.localized("Cancelled")
            rows[index].needsPassword = false
            rows[index].needsConfiguration = false
        }
        // Keep isRunning until the worker exits and cleans its staging folder.
    }
}

private struct ArchiveView: View {
    @ObservedObject var model: ArchiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(AppLocalization.localized("Archives"), systemImage: "archivebox")
                    .font(.title2.bold())
                Spacer()
                if model.isRunning || model.rows.contains(where: { $0.needsPassword || $0.needsConfiguration }) {
                    Button(AppLocalization.localized("Cancel")) { model.cancel() }
                }
            }
            if model.isRunning {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(appLocalized: "Processing archive…")
                }
                Text(model.detail.components(separatedBy: .newlines).filter { !$0.isEmpty }.last ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(row.request.operation.title).font(.headline)
                            Text(row.request.urls.map(\.lastPathComponent).joined(separator: ", "))
                                .foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                            if let output = row.output {
                                Text(output.path).font(.caption).textSelection(.enabled)
                                Button(AppLocalization.localized("Show in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([output])
                                }
                            } else {
                                if let error = row.error {
                                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                                } else if !row.isRunning && !row.needsPassword && !row.needsConfiguration {
                                    Text(appLocalized: "Waiting…").foregroundStyle(.secondary)
                                }
                                if row.needsConfiguration {
                                    ArchiveCompressionForm(disabled: model.isRunning) { format, level, password in
                                        model.submitCompression(for: row.id, format: format, level: level, password: password)
                                    }
                                }
                                if row.needsPassword {
                                    ArchivePasswordForm(operation: row.request.operation,
                                                        disabled: model.isRunning) { password in
                                        model.submitPassword(for: row.id, password: password)
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 260)
        .onAppear { model.start() }
    }
}

private struct ArchiveCompressionForm: View {
    let disabled: Bool
    let submit: (ArchiveCompressionFormat, ArchiveCompressionLevel, String?) -> Void
    @State private var format = ArchiveCompressionFormat(rawValue: UserDefaults.group.string(forKey: "archiveCompressionFormat") ?? "") ?? .zip
    @State private var level = ArchiveCompressionLevel(rawValue: UserDefaults.group.integer(forKey: "archiveCompressionLevel")) ?? .normal
    @State private var encrypted = false
    @State private var password = ""
    @State private var confirmation = ""

    private var passwordError: String? {
        guard encrypted else { return nil }
        if password.isEmpty { return nil }
        if password.utf8.count > 1_024 || password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            return ArchiveError.invalidPassword.localizedDescription
        }
        if format == .zip && !ArchiveService.isValidZIPPassword(password) {
            return ArchiveError.invalidZIPPassword.localizedDescription
        }
        if !confirmation.isEmpty && password != confirmation {
            return AppLocalization.localized("Passwords do not match.")
        }
        return nil
    }

    private var canSubmit: Bool {
        !disabled && (!encrypted || (!password.isEmpty && password == confirmation && passwordError == nil && format != .tarGzip))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(AppLocalization.localized("Archive Format")) {
                Picker(AppLocalization.localized("Archive Format"), selection: $format) {
                    ForEach(ArchiveCompressionFormat.allCases, id: \.self) { format in
                        Text(verbatim: format.rawValue).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            LabeledContent(AppLocalization.localized("Compression Level")) {
                Picker(AppLocalization.localized("Compression Level"), selection: $level) {
                    ForEach(ArchiveCompressionLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Text(appLocalized: "Higher compression levels can create smaller archives but take more time.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle(AppLocalization.localized("Password Protection"), isOn: $encrypted)
                .disabled(format == .tarGzip)
            if format == .tarGzip {
                Text(appLocalized: "TAR.GZ does not support passwords.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if encrypted {
                SecureField(AppLocalization.localized("Password"), text: $password)
                SecureField(AppLocalization.localized("Confirm Password"), text: $confirmation)
                Text(appLocalized: format == .sevenZip
                     ? "AES-256 protects file contents and file names."
                     : "AES-256 protects file contents. File names remain visible.")
                    .font(.caption).foregroundStyle(.secondary)
                if let passwordError {
                    Text(passwordError).font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                Button(AppLocalization.localized("Create Archive")) {
                    guard canSubmit else { return }
                    let value = encrypted ? password : nil
                    password = ""
                    confirmation = ""
                    submit(format, level, value)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(disabled)
        .onChange(of: format) {
            if format == .tarGzip { encrypted = false }
        }
        .onChange(of: encrypted) {
            if !encrypted {
                password = ""
                confirmation = ""
            }
        }
    }
}

/// Credentials stay in view state until submission, then in the worker's memory
/// until that attempt finishes. They never enter persisted requests or settings.
private struct ArchivePasswordForm: View {
    let operation: ArchiveOperation
    let disabled: Bool
    let submit: (String) -> Void
    @State private var password = ""
    @State private var confirmation = ""
    private var confirmationRequired: Bool { operation.isEncryptedCompression }

    private var canSubmit: Bool {
        !disabled && !password.isEmpty && (!confirmationRequired || password == confirmation)
            && (operation != .encryptedZip || ArchiveService.isValidZIPPassword(password))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if confirmationRequired {
                Text(appLocalized: operation == .encryptedSevenZip
                     ? "AES-256 protects file contents and file names."
                     : "AES-256 protects file contents. File names remain visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SecureField(AppLocalization.localized("Password"), text: $password)
                .onSubmit { submitIfValid() }
            if confirmationRequired {
                SecureField(AppLocalization.localized("Confirm Password"), text: $confirmation)
                    .onSubmit { submitIfValid() }
                if !confirmation.isEmpty && confirmation != password {
                    Text(appLocalized: "Passwords do not match.").font(.caption).foregroundStyle(.red)
                }
                if operation == .encryptedZip && !password.isEmpty && !ArchiveService.isValidZIPPassword(password) {
                    Text(appLocalized: "ZIP passwords must use 1–99 printable ASCII characters. Use Encrypted 7Z for other characters.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Button(AppLocalization.localized(operation == .encryptedSevenZip ? "Create Encrypted 7Z" : confirmationRequired ? "Create Encrypted ZIP" : "Unlock and Extract")) {
                submitIfValid()
            }
            .disabled(!canSubmit)
        }
        .textFieldStyle(.roundedBorder)
        .disabled(disabled)
    }

    private func submitIfValid() {
        guard canSubmit else { return }
        let value = password
        password = ""
        confirmation = ""
        submit(value)
    }
}
