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
    private var sizing: AnyCancellable?
    private var automaticCloseScheduled = false

    init(requests: [ArchiveRequest], onClose: @escaping () -> Void) {
        model = ArchiveViewModel(requests: requests)
        self.onClose = onClose
        let window = NSWindow()
        let sizesToContent = model.rows.contains { $0.needsConfiguration }
        let minimumWidth: CGFloat = sizesToContent ? 400 : 500
        window.title = AppLocalization.localized("Archives")
        window.styleMask = sizesToContent
            ? [.titled, .closable, .miniaturizable]
            : [.titled, .closable, .miniaturizable, .resizable]
        window.applyOneClickChrome()
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let titlebarHeight = window.frameRect(forContentRect: .zero).height
        window.contentViewController = NSHostingController(rootView: ArchiveView(
            model: model,
            maximumContentHeight: max(280, screenHeight - titlebarHeight),
            contentHeightChanged: { [weak window, weak model = model] height in
                guard let window, let model, !model.isRunning,
                      model.pendingRow?.needsConfiguration == true else { return }
                Self.setContentHeight(height, for: window)
            },
            close: { [weak window] in window?.performClose(nil) },
            minimumContentWidth: minimumWidth
        ))
        window.setContentSize(NSSize(width: sizesToContent ? minimumWidth : 520, height: model.preferredWindowHeight))
        window.contentMinSize = NSSize(width: minimumWidth, height: 280)
        window.center()
        super.init(window: window)
        window.delegate = self
        sizing = model.$rows.combineLatest(model.$isRunning)
            .sink { [weak self, weak window] values in
                guard let self, let window else { return }
                let (rows, running) = values
                // Close successful operations directly from the same state
                // transition. Restoring the result height first briefly shows
                // a huge 100% progress view, while relying on a later SwiftUI
                // update can leave the compact window stuck onscreen.
                if ArchiveViewModel.shouldCloseAutomatically(rows: rows, isRunning: running) {
                    guard !self.automaticCloseScheduled else { return }
                    self.automaticCloseScheduled = true
                    DispatchQueue.main.async { [weak window] in window?.performClose(nil) }
                    return
                }
                let height = ArchiveViewModel.windowHeight(rows: rows, isRunning: running)
                let operation = rows.first(where: { $0.isRunning })?.request.operation ?? rows.first?.request.operation
                window.title = running
                    ? AppLocalization.localized(operation?.isExtraction == true ? "Extracting…" : "Processing archive…")
                    : AppLocalization.localized("Archives")
                window.contentMinSize = NSSize(width: minimumWidth, height: running ? height : 280)
                window.contentMaxSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: running ? height : CGFloat.greatestFiniteMagnitude
                )
                // The configuration view measures its actual content, including
                // options and validation messages that do not change the rows.
                guard running || !rows.contains(where: { $0.needsConfiguration }) else { return }
                // The form disappears in the same update that progress appears.
                // Animating that large height change exposes an empty intermediate
                // frame, which reads as a flash when the user clicks Compress.
                Self.setContentHeight(height, for: window, animate: window.isVisible && !running)
            }
    }

    required init?(coder: NSCoder) { nil }

    private static func setContentHeight(_ height: CGFloat, for window: NSWindow, animate: Bool = false) {
        let size = NSSize(width: window.contentLayoutRect.width, height: ceil(height))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard abs(frame.height - window.frame.height) > 0.5 else { return }
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen = window.screen, frame.minY < screen.visibleFrame.minY {
            frame.origin.y = screen.visibleFrame.minY
        }
        window.setFrame(frame, display: true, animate: animate)
    }

    func windowWillClose(_ notification: Notification) {
        // Cancellation publishes row changes synchronously. Stop sizing and
        // hide the window before those changes replace the form/progress UI.
        sizing?.cancel()
        sizing = nil
        window?.orderOut(nil)
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
    private var pendingRowIndex: Int?
    var pendingRow: Row? { pendingRowIndex.map { rows[$0] } }

    /// Progress invalidates only the activity view, not the entire batch list.
    final class Activity: ObservableObject {
        struct State: Equatable {
            var progress = ArchiveProgress.Snapshot()
            var overallFraction: Double?
        }
        @Published private(set) var state = State()
        var isVerifying: Bool { state.progress.isVerifying }

        func update(_ snapshot: ArchiveProgress.Snapshot, completedCount: Int = 0, totalCount: Int = 1,
                    includesVerification: Bool = false) {
            let fraction = includesVerification && snapshot.isVerifying
                ? 0.9 + (snapshot.fraction ?? 0) * 0.1
                : snapshot.fraction.map { includesVerification ? $0 * 0.9 : $0 }
            let overall = fraction.map { (Double(completedCount) + $0) / Double(max(1, totalCount)) }
                ?? (completedCount > 0 ? Double(completedCount) / Double(max(1, totalCount)) : nil)
            let updated = State(progress: snapshot, overallFraction: overall)
            if state != updated { state = updated }
        }

        func update(_ snapshots: [ArchiveProgress.Snapshot], completedCount: Int, totalCount: Int) {
            let known = snapshots.contains { $0.fraction != nil }
            let sum = snapshots.reduce(0) { $0 + ($1.fraction ?? 0) }
            let overall = known || completedCount > 0
                ? (Double(completedCount) + sum) / Double(max(1, totalCount)) : nil
            let updated = State(progress: .init(fraction: known ? sum / Double(max(1, snapshots.count)) : nil),
                                overallFraction: overall)
            if state != updated { state = updated }
        }
    }
    let activity = Activity()
    var isVerifying: Bool { activity.isVerifying }
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var activeProgress: [Int: ArchiveProgress] = [:]
    private var hasStarted = false
    private let compressionSettings: ArchiveCompressionSettings
    private let performArchive: @Sendable (ArchiveRequest, String?, ArchiveCompressionSettings, ArchiveProgress) async throws -> URL

    var preferredWindowHeight: CGFloat { Self.windowHeight(rows: rows, isRunning: isRunning) }

    static func windowHeight(rows: [Row], isRunning: Bool) -> CGFloat {
        if isRunning || shouldCloseAutomatically(rows: rows, isRunning: isRunning) { return 80 }
        if rows.contains(where: { $0.needsConfiguration }) { return 500 }
        if !isRunning, rows.contains(where: { $0.needsPassword }) { return 360 }
        return 340 + CGFloat(min(3, max(0, rows.count - 1))) * 72
    }

    var shouldCloseAutomatically: Bool {
        Self.shouldCloseAutomatically(rows: rows, isRunning: isRunning)
    }

    static func shouldCloseAutomatically(rows: [Row], isRunning: Bool) -> Bool {
        !isRunning && !rows.isEmpty && rows.allSatisfy {
            $0.output != nil && $0.error == nil && !$0.isRunning && !$0.needsPassword && !$0.needsConfiguration
        }
    }

    init(requests: [ArchiveRequest], compressionSettings: ArchiveCompressionSettings = .load(from: .group),
         performArchive: @escaping @Sendable (ArchiveRequest, String?, ArchiveCompressionSettings, ArchiveProgress) async throws -> URL = {
             try await ArchiveService.perform($0, password: $1, settings: $2, progress: $3)
         }) {
        self.compressionSettings = compressionSettings
        self.performArchive = performArchive
        rows = requests.enumerated().map {
            Row(id: $0.offset, request: $0.element, error: $0.element.error,
                needsPassword: $0.element.operation.isEncryptedCompression && $0.element.error == nil,
                needsConfiguration: $0.element.operation == .compress && $0.element.error == nil)
        }
        pendingRowIndex = rows.firstIndex { $0.needsConfiguration || $0.needsPassword }
    }

    private func refreshPendingRow() {
        pendingRowIndex = rows.firstIndex { $0.needsConfiguration || $0.needsPassword }
    }

    func start() {
        guard !hasStarted, !rows.isEmpty else { return }
        hasStarted = true
        run(indices: rows.indices.filter { !rows[$0].needsPassword && !rows[$0].needsConfiguration && rows[$0].error == nil })
    }

    func submitCompression(for index: Int, format: ArchiveCompressionFormat,
                           level: ArchiveCompressionLevel, password: String?,
                           volumeSize: UInt64? = nil, solid: Bool? = nil, verifyAfterCompression: Bool = false,
                           excludeMacResourceFiles: Bool? = nil, deletesSourcesAfterSuccess: Bool = false,
                           separately: Bool = false, zipUsesAES256: Bool = true, encryptFileNames: Bool = true,
                           windowsSelfExtracting: Bool = false, diskImageFormat: ArchiveDiskImageFormat = .lzfse,
                           volumeName: String = "") {
        guard !isRunning, rows.indices.contains(index), rows[index].needsConfiguration else { return }
        // Never silently discard a requested password for an unsupported format.
        guard format.supportsPassword || password == nil else {
            rows[index].error = ArchiveError.encryptionNotSupported.localizedDescription
            return
        }
        if let volumeSize, volumeSize == 0 || volumeSize > Int64.max {
            rows[index].error = ArchiveError.invalidVolumeSize.localizedDescription
            return
        }
        guard format.supportsVolumes || volumeSize == nil else {
            rows[index].error = ArchiveError.splittingNotSupported.localizedDescription
            return
        }
        guard format == .sevenZip || solid == nil else {
            rows[index].error = ArchiveError.solidNotSupported.localizedDescription
            return
        }
        guard !windowsSelfExtracting || (format == .sevenZip && volumeSize == nil) else {
            rows[index].error = AppLocalization.localized("Windows self-extracting archives require 7Z without split volumes.")
            return
        }
        let original = rows[index].request
        let groups = separately ? original.urls.map { [$0] } : [original.urls]
        let requests = groups.map { urls in
            ArchiveRequest(operation: format.operation(encrypted: password != nil), urls: urls,
                           compressionLevel: level, volumeSize: volumeSize, solid: solid,
                           verifyAfterCompression: verifyAfterCompression,
                           deletesSourcesAfterSuccess: deletesSourcesAfterSuccess || original.deletesSourcesAfterSuccess,
                           excludeMacResourceFiles: format == .dmg ? nil : excludeMacResourceFiles,
                           zipUsesAES256: zipUsesAES256, encryptFileNames: encryptFileNames,
                           windowsSelfExtracting: windowsSelfExtracting, diskImageFormat: diskImageFormat,
                           volumeName: volumeName)
        }
        guard let request = requests.first else { return }
        let newIndices = Array(rows.count..<(rows.count + requests.count - 1))
        run(indices: [index] + newIndices, password: password) {
            // Enter the running state before removing the form. Window sizing
            // then observes one direct configuration-to-progress transition
            // instead of briefly expanding the intermediate result layout.
            self.rows[index].request = request
            self.rows[index].error = nil
            self.rows[index].needsConfiguration = false
            for (id, request) in zip(newIndices, requests.dropFirst()) {
                self.rows.append(Row(id: id, request: request))
            }
            self.refreshPendingRow()
        }
    }

    func submitPassword(for index: Int, password: String) {
        guard !isRunning, rows.indices.contains(index), rows[index].needsPassword else { return }
        run(indices: [index], password: password) {
            self.rows[index].error = nil
            self.rows[index].needsPassword = false
            self.refreshPendingRow()
        }
    }

    private func run(indices: [Int], password: String? = nil, prepare: () -> Void = {}) {
        guard !indices.isEmpty, !isRunning else { return }
        isRunning = true
        prepare()
        task = Task { [weak self] in
            guard let self else { return }
            self.polling = Task { [weak self] in
                while !Task.isCancelled {
                    self?.updateActivity()
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
                }
            }
            // Parallelize only ordinary extraction. Compression already uses
            // multiple CPUs, and deletion jobs must retain their ordered safety
            // checks (including when the same source is selected twice).
            let limit = indices.allSatisfy {
                self.rows[$0].request.operation == .extract && !self.rows[$0].request.deletesSourcesAfterSuccess
            } ? 2 : 1
            await withTaskGroup(of: Void.self) { group in
                var pending = indices.makeIterator()
                for _ in 0..<min(limit, indices.count) {
                    guard !Task.isCancelled, let index = pending.next() else { break }
                    group.addTask { await self.runRow(index, password: password) }
                }
                while await group.next() != nil {
                    guard !Task.isCancelled, let index = pending.next() else { continue }
                    group.addTask { await self.runRow(index, password: password) }
                }
            }
            self.polling?.cancel()
            self.polling = nil
            self.updateActivity()
            self.isRunning = false
            self.task = nil
        }
    }

    private func runRow(_ index: Int, password: String?) async {
        guard !Task.isCancelled else { return }
        if let error = rows[index].request.error {
            rows[index].error = error
            return
        }
        let progress = ArchiveProgress()
        activeProgress[index] = progress
        rows[index].isRunning = true
        updateActivity()
        defer {
            rows[index].isRunning = false
            activeProgress[index] = nil
            refreshPendingRow()
            updateActivity()
        }
        do {
            rows[index].output = try await performArchive(rows[index].request, password, compressionSettings, progress)
        } catch is CancellationError {
            rows[index].error = AppLocalization.localized("Cancelled")
        } catch let error as ArchiveError {
            switch error {
            case .sourceDeletionFailed(let output, _):
                rows[index].output = output
            case .passwordRequired, .incorrectPassword, .invalidPassword, .invalidZIPPassword:
                rows[index].needsPassword = true
            default: break
            }
            rows[index].error = error.localizedDescription
        } catch {
            rows[index].error = error.localizedDescription
        }
    }

    private func updateActivity() {
        let completed = rows.filter { !$0.isRunning && ($0.output != nil || ($0.error != nil && !$0.needsPassword)) }.count
        if activeProgress.count == 1, let (index, progress) = activeProgress.first {
            let request = rows[index].request
            activity.update(progress.snapshot, completedCount: completed, totalCount: rows.count,
                            includesVerification: !request.operation.isExtraction
                                && (request.verifyAfterCompression || request.deletesSourcesAfterSuccess))
        } else {
            activity.update(activeProgress.values.map(\.snapshot), completedCount: completed, totalCount: rows.count)
        }
    }

    func cancel() {
        hasStarted = true
        task?.cancel()
        for progress in activeProgress.values { progress.cancel() }
        for index in rows.indices where rows[index].output == nil && (rows[index].error == nil || rows[index].needsPassword || rows[index].needsConfiguration) {
            rows[index].error = AppLocalization.localized("Cancelled")
            rows[index].needsPassword = false
            rows[index].needsConfiguration = false
        }
        refreshPendingRow()
        // Keep isRunning until the worker exits and cleans its staging folder.
    }
}

/// Credentials remain in view state and are cleared whenever an attempt is submitted.
struct ArchiveFormState {
    var format = ArchiveCompressionFormat(rawValue: UserDefaults.group.string(forKey: "archiveCompressionFormat") ?? "") ?? .zip
    var level = ArchiveCompressionLevel.loadDefault(from: .group)
    var encrypted = false
    var password = ""
    var confirmation = ""
    var splitVolumes = false
    var volumePreset = ArchiveVolumePreset.cd
    var customVolumeSize = "100"
    var volumeUnit = ArchiveVolumeUnit.mebibytes
    var solid = true
    var verifyAfterCompression = false
    var excludeMacResourceFiles = true
    var deletesSourcesAfterSuccess = false
    var separately = false
    var zipUsesAES256 = true
    var encryptFileNames = true
    var windowsSelfExtracting = false
    var diskImageFormat = ArchiveDiskImageFormat.lzfse
    var volumeName = ""
    var volumeSizeText = ""

    var volumeSize: UInt64? {
        guard format.supportsVolumes, !windowsSelfExtracting else { return nil }
        if !volumeSizeText.trimmingCharacters(in: .whitespaces).isEmpty {
            return Self.parseVolumeSize(volumeSizeText)
        }
        guard splitVolumes else { return nil }
        return volumePreset.bytes ?? volumeUnit.bytes(for: customVolumeSize)
    }

    var volumeSizeError: String? {
        (splitVolumes || !volumeSizeText.trimmingCharacters(in: .whitespaces).isEmpty)
            && format.supportsVolumes && !windowsSelfExtracting && volumeSize == nil
            ? ArchiveError.invalidVolumeSize.localizedDescription : nil
    }

    static func parseVolumeSize(_ text: String) -> UInt64? {
        let value = text.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [(String, Double)] = [("GIB", 1_073_741_824), ("MIB", 1_048_576), ("KIB", 1_024),
                                         ("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1_000), ("B", 1)]
        for (suffix, multiplier) in units where value.hasSuffix(suffix) {
            let number = value.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let amount = Double(number), amount.isFinite else { return nil }
            let bytes = amount * multiplier
            guard bytes >= 1, bytes < Double(Int64.max), bytes.rounded(.down) == bytes else { return nil }
            return UInt64(bytes)
        }
        return ArchiveVolumeUnit.bytes.bytes(for: value)
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
        volumeSizeError == nil && (format != .dmg || ArchiveService.isValidVolumeName(volumeName))
            && (!encrypted || (!password.isEmpty && password == confirmation && passwordError == nil && format.supportsPassword))
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

struct ArchiveView: View {
    @ObservedObject var model: ArchiveViewModel
    let maximumContentHeight: CGFloat
    let contentHeightChanged: (CGFloat) -> Void
    let close: () -> Void
    var minimumContentWidth: CGFloat = 500
    @State var form = ArchiveFormState()
    @State private var rowsHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    // A batch can request different passwords. Resolve one pending prompt at a time,
    // while keeping completed results and the remaining queue visible.
    private var pendingRow: ArchiveViewModel.Row? {
        model.pendingRow
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
            if model.isRunning || model.shouldCloseAutomatically {
                ArchiveActivityView(activity: model.activity, cancel: close)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    if pendingRow?.needsConfiguration == true {
                        // Measure every configuration row; a lazy stack only
                        // knows the height of content already in its viewport.
                        VStack(alignment: .leading, spacing: 8) {
                            archiveRows
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            archiveRows
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: pendingRow?.needsConfiguration == true
                       ? min(rowsHeight, max(0, maximumContentHeight - footerHeight - 1))
                       : nil)

                Divider()
                HStack(spacing: 12) {
                    Spacer()
                    if pendingRow != nil {
                        Button(AppLocalization.localized("Cancel"), action: close)
                            .buttonStyle(.glass)
                            .keyboardShortcut(.cancelAction)
                        Button(AppLocalization.localized(submitTitle), action: submit)
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canSubmit)
                    } else {
                        Button(AppLocalization.localized("Done"), action: close)
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .controlSize(pendingRow?.needsConfiguration == true ? .regular : .large)
                .padding(.horizontal, pendingRow?.needsConfiguration == true ? 14 : 20)
                .padding(.vertical, pendingRow?.needsConfiguration == true ? 10 : 14)
                .background(.bar)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
        }
        .frame(minWidth: minimumContentWidth, minHeight: model.isRunning || model.shouldCloseAutomatically ? 80 : 280)
        .fixedSize(horizontal: false, vertical: pendingRow?.needsConfiguration == true && !model.isRunning)
        .background(ArchiveFormatTitlebarAccessory(
            format: $form.format,
            isVisible: pendingRow?.needsConfiguration == true && !model.isRunning
        ).frame(width: 0, height: 0))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeightChanged($0) }
        .onAppear { model.start() }
        .onChange(of: pendingRow?.id) { form.clearPassword() }
        .onChange(of: form.format) {
            if !form.format.supportsPassword {
                form.encrypted = false
                form.clearPassword()
            }
            if !form.format.supportsVolumes {
                form.splitVolumes = false
                form.volumeSizeText = ""
            }
            if form.format != .sevenZip { form.windowsSelfExtracting = false }
        }
        .onChange(of: form.encrypted) {
            if !form.encrypted { form.clearPassword() }
        }
    }

    private var archiveRows: some View {
        ForEach(model.rows) { row in
            archiveRow(row)
            if row.id != model.rows.last?.id {
                Divider()
            }
        }
    }

    private func archiveRow(_ row: ArchiveViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: row.needsConfiguration ? 8 : 14) {
            Text(row.request.urls.map(\.lastPathComponent).joined(separator: ", "))
                .font(.headline).lineLimit(2).textSelection(.enabled)
            if let error = row.error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let output = row.output {
                if row.request.verifyAfterCompression && !row.request.operation.isExtraction {
                    Label(AppLocalization.localized("Archive verification passed."), systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(output.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(AppLocalization.localized("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } else {
                if row.id == pendingRow?.id {
                    Group {
                        if row.needsConfiguration {
                            ArchiveCompressionForm(form: $form)
                        } else if row.needsPassword {
                            ArchivePasswordForm(operation: row.request.operation, form: $form, submit: submit)
                        }
                    }
                    .padding(.vertical, row.needsConfiguration ? 4 : 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isRunning)
                } else if !row.isRunning && row.error == nil {
                    Text(appLocalized: "Waiting…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func submit() {
        guard canSubmit, let row = pendingRow else { return }
        let options = form
        let password = options.encrypted ? options.password : nil
        form.clearPassword()
        if row.needsConfiguration {
            model.submitCompression(for: row.id, format: options.format, level: options.level,
                                    password: password, volumeSize: options.volumeSize,
                                    solid: options.format == .sevenZip ? options.solid : nil,
                                    verifyAfterCompression: options.verifyAfterCompression,
                                    excludeMacResourceFiles: options.excludeMacResourceFiles,
                                    deletesSourcesAfterSuccess: options.deletesSourcesAfterSuccess,
                                    separately: options.separately, zipUsesAES256: options.zipUsesAES256,
                                    encryptFileNames: options.encryptFileNames,
                                    windowsSelfExtracting: options.windowsSelfExtracting,
                                    diskImageFormat: options.diskImageFormat, volumeName: options.volumeName)
        } else {
            model.submitPassword(for: row.id, password: options.password)
        }
    }
}

private struct ArchiveFormatTitlebarAccessory: NSViewRepresentable {
    @Binding var format: ArchiveCompressionFormat
    let isVisible: Bool

    func makeNSView(context: Context) -> ArchiveFormatTitlebarHostView {
        ArchiveFormatTitlebarHostView()
    }

    func updateNSView(_ view: ArchiveFormatTitlebarHostView, context: Context) {
        view.update(format: $format, isVisible: isVisible)
    }

    static func dismantleNSView(_ view: ArchiveFormatTitlebarHostView, coordinator: ()) {
        view.removeAccessory()
    }
}

private final class ArchiveFormatTitlebarHostView: NSView {
    private var format: Binding<ArchiveCompressionFormat> = .constant(.zip)
    private var isPickerVisible = false
    private weak var installedWindow: NSWindow?
    private var accessory: NSTitlebarAccessoryViewController?
    private var previousTitleVisibility: NSWindow.TitleVisibility = .visible

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAccessory()
    }

    func update(format: Binding<ArchiveCompressionFormat>, isVisible: Bool) {
        self.format = format
        isPickerVisible = isVisible
        updateAccessory()
    }

    func removeAccessory() {
        if let installedWindow, let accessory,
           let index = installedWindow.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            installedWindow.removeTitlebarAccessoryViewController(at: index)
            installedWindow.titleVisibility = previousTitleVisibility
        }
        accessory = nil
        installedWindow = nil
    }

    private func updateAccessory() {
        if installedWindow !== window || !isPickerVisible { removeAccessory() }
        guard let window, isPickerVisible else { return }
        let picker = ArchiveFormatPicker(format: format)
        if let host = accessory?.view as? NSHostingView<ArchiveFormatPicker> {
            host.rootView = picker
            return
        }
        let host = NSHostingView(rootView: picker)
        host.frame = NSRect(x: 0, y: 0, width: 156, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        // A trailing accessory shares the native titlebar with the traffic lights.
        accessory.layoutAttribute = .trailing
        accessory.view = host
        previousTitleVisibility = window.titleVisibility
        window.titleVisibility = .hidden
        installedWindow = window
        self.accessory = accessory
        window.addTitlebarAccessoryViewController(accessory)
    }
}

private struct ArchiveFormatPicker: View {
    @Binding var format: ArchiveCompressionFormat

    var body: some View {
        Menu {
            Picker(AppLocalization.localized("Archive Format"), selection: $format) {
                ForEach(ArchiveCompressionFormat.allCases, id: \.self) { format in
                    Label(format.rawValue, systemImage: format == .dmg ? "externaldrive" : "doc.zipper")
                        .tag(format)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(format.rawValue, systemImage: format == .dmg ? "externaldrive" : "doc.zipper")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .buttonStyle(.plain)
        .frame(width: 140, height: 26)
        .controlSize(.regular)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel(AppLocalization.localized("Archive Format"))
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
    }
}

private struct ArchiveActivityView: View {
    @ObservedObject var activity: ArchiveViewModel.Activity
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: activity.isVerifying ? "checkmark.shield.fill" : "archivebox.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(appLocalized: activity.isVerifying ? "Verifying archive…" : "Processing archive…")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text(percentageText)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized: "Overall Progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    OneClickProgressBar(
                        fraction: activity.state.overallFraction,
                        accessibilityLabel: AppLocalization.localized("Overall Progress")
                    )
                }
            }

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            .help(AppLocalization.localized("Cancel"))
            .accessibilityLabel(AppLocalization.localized("Cancel"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.25), value: activity.state.overallFraction)
    }

    private var percentageText: String {
        activity.state.overallFraction.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "—"
    }
}

private struct ArchiveCompressionForm: View {
    @Binding var form: ArchiveFormState
    @State private var showsPassword = false
    private let levels = ArchiveCompressionLevel.allCases

    private var levelIndex: Binding<Double> {
        Binding {
            Double(levels.firstIndex(of: form.level) ?? 3)
        } set: { value in
            form.level = levels[Int(value.rounded())]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                compressionLevel

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    if form.format == .dmg {
                        GridRow {
                            Text(appLocalized: "Volume Name")
                            inputField {
                                TextField(AppLocalization.localized("Custom Name"), text: $form.volumeName)
                            }
                        }
                    } else if form.format.supportsVolumes {
                        GridRow {
                            Text(appLocalized: "Split Volume Size")
                            inputField {
                                TextField(AppLocalization.localized("e.g. 5 MB"), text: $form.volumeSizeText)
                                Menu {
                                    Button(AppLocalization.localized("Do Not Split")) { form.volumeSizeText = "" }
                                    ForEach(["5 MB", "100 MB", "700 MiB", "4.7 GB", "4095 MiB"], id: \.self) { size in
                                        Button(size) { form.volumeSizeText = size }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .frame(width: 20, height: 20)
                                .accessibilityLabel(AppLocalization.localized("Volume Size"))
                            }
                            .disabled(form.windowsSelfExtracting)
                        }
                    }
                    if form.format.supportsPassword {
                        GridRow {
                            Text(appLocalized: "Password")
                            inputField {
                                Group {
                                    if showsPassword {
                                        TextField(AppLocalization.localized("Password"), text: $form.password)
                                    } else {
                                        SecureField(AppLocalization.localized("Password"), text: $form.password)
                                    }
                                }
                                .labelsHidden()
                                Button {
                                    showsPassword.toggle()
                                } label: {
                                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(AppLocalization.localized(showsPassword ? "Hide Password" : "Show Password"))
                            }
                        }
                        GridRow {
                            Text(appLocalized: "Confirm Password")
                            inputField {
                                Group {
                                    if showsPassword {
                                        TextField(AppLocalization.localized("Confirm Password"), text: $form.confirmation)
                                    } else {
                                        SecureField(AppLocalization.localized("Confirm Password"), text: $form.confirmation)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                    if form.format == .dmg {
                        GridRow {
                            Text(appLocalized: "Disk Image Format")
                            Picker(AppLocalization.localized("Disk Image Format"), selection: $form.diskImageFormat) {
                                ForEach(ArchiveDiskImageFormat.allCases, id: \.self) { format in
                                    Text(format.title).tag(format)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)

                VStack(alignment: .leading, spacing: 8) {
                    if form.format == .zip {
                        Toggle(AppLocalization.localized("Use AES-256 Encryption"), isOn: $form.zipUsesAES256)
                            .disabled(form.password.isEmpty)
                    } else if form.format == .sevenZip {
                        Toggle(AppLocalization.localized("Encrypt File Names"), isOn: $form.encryptFileNames)
                            .disabled(form.password.isEmpty)
                        Toggle(AppLocalization.localized("Solid Compression"), isOn: $form.solid)
                        Toggle(AppLocalization.localized("Windows Self-Extracting Archive"), isOn: $form.windowsSelfExtracting)
                    }
                    if let error = form.volumeSizeError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if let error = form.passwordError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if form.format == .dmg && !ArchiveService.isValidVolumeName(form.volumeName) {
                        Text(appLocalized: "Enter a volume name without slashes, colons or line breaks (up to 255 UTF-8 bytes).")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 8) {
                if form.format != .dmg {
                    Toggle(AppLocalization.localized("Exclude Mac Resource Files"), isOn: $form.excludeMacResourceFiles)
                }
                Toggle(AppLocalization.localized("Verify After Compression"), isOn: $form.verifyAfterCompression)
                Toggle(AppLocalization.localized("Delete Source Files After Compression"), isOn: $form.deletesSourcesAfterSuccess)
                Toggle(AppLocalization.localized("Compress Each Item Separately"), isOn: $form.separately)
            }
            .padding(.horizontal, 2)
        }
        .toggleStyle(.checkbox)
        .onChange(of: form.password) { form.encrypted = !form.password.isEmpty }
        .onChange(of: form.diskImageFormat) {
            if form.diskImageFormat == .readOnly { form.level = .store }
            else if form.level == .store { form.level = .normal }
        }
        .onChange(of: form.windowsSelfExtracting) {
            if form.windowsSelfExtracting {
                form.volumeSizeText = ""
                form.splitVolumes = false
            }
        }
    }

    private func inputField<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
            }
    }

    private var compressionLevel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(appLocalized: "Compression Level")
                Text(form.level.title)
            }
            .font(.headline)
            Slider(value: levelIndex, in: 0...Double(levels.count - 1), step: 1) {
                Text(appLocalized: "Compression Level")
            }
            .labelsHidden()
            .disabled(form.format == .dmg && form.diskImageFormat != .zlib)
            HStack(spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.element) { index, level in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(level.title)
                        .foregroundStyle(form.level == level ? .primary : .secondary)
                }
            }
            .font(.caption)
            if form.format == .dmg && form.diskImageFormat != .zlib {
                Text(appLocalized: "Compression level is available for Zlib disk images only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
