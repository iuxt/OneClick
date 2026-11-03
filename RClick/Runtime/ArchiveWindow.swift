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
        let window = NSWindow()
        window.contentViewController = NSHostingController(rootView: ArchiveView(model: model) { [weak window] in
            window?.performClose(nil)
        })
        window.title = AppLocalization.localized("Archives")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let contentHeight: CGFloat = if requests.contains(where: { $0.operation == .compress }) {
            640
        } else if requests.contains(where: { $0.operation.isEncryptedCompression }) {
            320
        } else {
            280
        }
        window.setContentSize(NSSize(width: 560, height: contentHeight))
        window.contentMinSize = NSSize(width: 500, height: 280)
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
    private let compressionSettings: ArchiveCompressionSettings

    init(requests: [ArchiveRequest], compressionSettings: ArchiveCompressionSettings = .load(from: .group)) {
        self.compressionSettings = compressionSettings
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
                           level: ArchiveCompressionLevel, password: String?,
                           volumeSize: UInt64? = nil, solid: Bool? = nil) {
        guard !isRunning, rows.indices.contains(index), rows[index].needsConfiguration else { return }
        // Never silently discard a requested password for an unsupported format.
        guard format != .tarGzip || password == nil else {
            rows[index].error = ArchiveError.encryptionNotSupported.localizedDescription
            return
        }
        if let volumeSize, volumeSize == 0 || volumeSize > Int64.max {
            rows[index].error = ArchiveError.invalidVolumeSize.localizedDescription
            return
        }
        guard format != .tarGzip || volumeSize == nil else {
            rows[index].error = ArchiveError.splittingNotSupported.localizedDescription
            return
        }
        guard format == .sevenZip || solid == nil else {
            rows[index].error = ArchiveError.solidNotSupported.localizedDescription
            return
        }
        rows[index].request = ArchiveRequest(operation: format.operation(encrypted: password != nil),
                                             urls: rows[index].request.urls, compressionLevel: level,
                                             volumeSize: volumeSize, solid: solid)
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
                    self.rows[index].output = try await ArchiveService.perform(self.rows[index].request, password: password,
                                                                             settings: self.compressionSettings, progress: progress)
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

/// Credentials remain in view state and are cleared whenever an attempt is submitted.
struct ArchiveFormState {
    var format = ArchiveCompressionFormat(rawValue: UserDefaults.group.string(forKey: "archiveCompressionFormat") ?? "") ?? .zip
    var level = ArchiveCompressionLevel(rawValue: UserDefaults.group.integer(forKey: "archiveCompressionLevel")) ?? .normal
    var encrypted = false
    var password = ""
    var confirmation = ""
    var splitVolumes = false
    var volumePreset = ArchiveVolumePreset.cd
    var customVolumeSize = "100"
    var volumeUnit = ArchiveVolumeUnit.mebibytes
    var solid = true

    var volumeSize: UInt64? {
        guard splitVolumes, format != .tarGzip else { return nil }
        return volumePreset.bytes ?? volumeUnit.bytes(for: customVolumeSize)
    }

    var volumeSizeError: String? {
        splitVolumes && format != .tarGzip && volumeSize == nil ? ArchiveError.invalidVolumeSize.localizedDescription : nil
    }

    var passwordError: String? {
        guard encrypted, !password.isEmpty else { return nil }
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

    var canCompress: Bool {
        volumeSizeError == nil && (!encrypted || (!password.isEmpty && password == confirmation && passwordError == nil && format != .tarGzip))
    }

    func canSubmitPassword(for operation: ArchiveOperation) -> Bool {
        !password.isEmpty && (!operation.isEncryptedCompression || password == confirmation)
            && (operation != .encryptedZip || ArchiveService.isValidZIPPassword(password))
    }

    mutating func clearPassword() {
        password = ""
        confirmation = ""
    }
}

private struct ArchiveView: View {
    @ObservedObject var model: ArchiveViewModel
    let close: () -> Void
    @State private var form = ArchiveFormState()

    // A batch can request different passwords. Resolve one pending prompt at a time,
    // while keeping completed results and the remaining queue visible.
    private var pendingRow: ArchiveViewModel.Row? {
        model.rows.first { $0.needsConfiguration || $0.needsPassword }
    }

    private var canSubmit: Bool {
        guard !model.isRunning, let row = pendingRow else { return false }
        return row.needsConfiguration ? form.canCompress : form.canSubmitPassword(for: row.request.operation)
    }

    private var submitTitle: String {
        guard let row = pendingRow else { return "Create Archive" }
        if row.needsConfiguration { return "Create Archive" }
        switch row.request.operation {
        case .encryptedSevenZip: return "Create Encrypted 7Z"
        case .encryptedZip: return "Create Encrypted ZIP"
        default: return "Unlock and Extract"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(AppLocalization.localized("Archives"), systemImage: "archivebox")
                    .font(.title2.bold())
                Spacer()
                if pendingRow?.needsConfiguration == true {
                    Picker(AppLocalization.localized("Archive Format"), selection: $form.format) {
                        ForEach(ArchiveCompressionFormat.allCases, id: \.self) { format in
                            Text(verbatim: format.rawValue).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .controlSize(.large)
                    .disabled(model.isRunning)
                }
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.isRunning {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(appLocalized: "Processing archive…")
                                if let detail = model.detail.components(separatedBy: .newlines).last(where: { !$0.isEmpty }) {
                                    Text(detail)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.rows) { row in
                        archiveRow(row)
                        if row.id != model.rows.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            HStack(spacing: 12) {
                Spacer()
                if model.isRunning || pendingRow != nil {
                    Button(AppLocalization.localized("Cancel"), action: close)
                        .keyboardShortcut(.cancelAction)
                    if pendingRow != nil {
                        Button(AppLocalization.localized(submitTitle), action: submit)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canSubmit)
                    }
                } else {
                    Button(AppLocalization.localized("Done"), action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(minWidth: 500, minHeight: 280)
        .onAppear { model.start() }
        .onChange(of: pendingRow?.id) { form.clearPassword() }
        .onChange(of: form.format) {
            if form.format == .tarGzip {
                form.encrypted = false
                form.splitVolumes = false
            }
        }
        .onChange(of: form.encrypted) {
            if !form.encrypted { form.clearPassword() }
        }
    }

    private func archiveRow(_ row: ArchiveViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.request.operation == .extract ? "archivebox" : "doc.on.doc")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.request.urls.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.headline).lineLimit(2).textSelection(.enabled)
                    Text(row.request.operation.title)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let output = row.output {
                Text(output.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(AppLocalization.localized("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } else {
                if let error = row.error {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if row.id == pendingRow?.id {
                    Group {
                        if row.needsConfiguration {
                            ArchiveCompressionForm(form: $form)
                        } else if row.needsPassword {
                            ArchivePasswordForm(operation: row.request.operation, form: $form, submit: submit)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 14))
                    .disabled(model.isRunning)
                } else if !row.isRunning && row.error == nil {
                    Text(appLocalized: "Waiting…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func submit() {
        guard canSubmit, let row = pendingRow else { return }
        let password = form.password
        form.clearPassword()
        if row.needsConfiguration {
            model.submitCompression(for: row.id, format: form.format, level: form.level,
                                    password: form.encrypted ? password : nil,
                                    volumeSize: form.volumeSize, solid: form.format == .sevenZip ? form.solid : nil)
        } else {
            model.submitPassword(for: row.id, password: password)
        }
    }
}

private struct ArchiveCompressionForm: View {
    @Binding var form: ArchiveFormState
    private let levels = ArchiveCompressionLevel.allCases

    private var levelIndex: Binding<Double> {
        Binding {
            Double(levels.firstIndex(of: form.level) ?? 2)
        } set: { value in
            form.level = levels[Int(value.rounded())]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(appLocalized: "Compression Level")
                    Text(form.level.title).foregroundStyle(.secondary)
                }
                .font(.headline)
                Slider(value: levelIndex, in: 0...Double(levels.count - 1), step: 1) {
                    Text(appLocalized: "Compression Level")
                }
                .labelsHidden()
                HStack(spacing: 0) {
                    ForEach(Array(levels.enumerated()), id: \.element) { index, level in
                        if index > 0 { Spacer(minLength: 0) }
                        Text(level.title)
                            .foregroundStyle(form.level == level ? .primary : .secondary)
                    }
                }
                .font(.caption)
                Text(appLocalized: "Higher compression levels can create smaller archives but take more time.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(AppLocalization.localized("Split into Volumes"), isOn: $form.splitVolumes)
                    .disabled(form.format == .tarGzip)
                if form.format == .tarGzip {
                    Text(appLocalized: "Split volumes are available for ZIP and 7Z only.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if form.splitVolumes {
                    Picker(AppLocalization.localized("Volume Size"), selection: $form.volumePreset) {
                        ForEach(ArchiveVolumePreset.allCases, id: \.self) { preset in
                            Text(verbatim: preset.title).tag(preset)
                        }
                    }
                    if form.volumePreset == .custom {
                        HStack {
                            TextField(AppLocalization.localized("Volume Size"), text: $form.customVolumeSize)
                            Picker(AppLocalization.localized("Size Unit"), selection: $form.volumeUnit) {
                                ForEach(ArchiveVolumeUnit.allCases, id: \.self) { unit in
                                    Text(verbatim: unit.rawValue).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }
                    }
                    Text(appLocalized: "Keep all volumes together. Open the .001 file to extract.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = form.volumeSizeError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                if form.format == .sevenZip {
                    Toggle(AppLocalization.localized("Solid Compression"), isOn: $form.solid)
                    Text(appLocalized: "Compresses files together for smaller archives. Extracting individual files may take longer.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(AppLocalization.localized("Password Protection"), isOn: $form.encrypted)
                    .disabled(form.format == .tarGzip)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text(appLocalized: "Password")
                        SecureField(AppLocalization.localized("Password"), text: $form.password)
                            .labelsHidden()
                    }
                    GridRow {
                        Text(appLocalized: "Confirm Password")
                        SecureField(AppLocalization.localized("Confirm Password"), text: $form.confirmation)
                            .labelsHidden()
                    }
                }
                .disabled(!form.encrypted)
                if form.format == .tarGzip {
                    Text(appLocalized: "TAR.GZ does not support passwords.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if form.encrypted {
                    Text(appLocalized: form.format == .sevenZip
                         ? "AES-256 protects file contents and file names."
                         : "AES-256 protects file contents. File names remain visible.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = form.passwordError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

private struct ArchivePasswordForm: View {
    let operation: ArchiveOperation
    @Binding var form: ArchiveFormState
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if operation.isEncryptedCompression {
                Text(appLocalized: operation == .encryptedSevenZip
                     ? "AES-256 protects file contents and file names."
                     : "AES-256 protects file contents. File names remain visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SecureField(AppLocalization.localized("Password"), text: $form.password)
                .onSubmit(submit)
            if operation.isEncryptedCompression {
                SecureField(AppLocalization.localized("Confirm Password"), text: $form.confirmation)
                    .onSubmit(submit)
                if !form.confirmation.isEmpty && form.confirmation != form.password {
                    Text(appLocalized: "Passwords do not match.").font(.caption).foregroundStyle(.red)
                }
                if operation == .encryptedZip && !form.password.isEmpty && !ArchiveService.isValidZIPPassword(form.password) {
                    Text(appLocalized: "ZIP passwords must use 1–99 printable ASCII characters. Use Encrypted 7Z for other characters.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}
