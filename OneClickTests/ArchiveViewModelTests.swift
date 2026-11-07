import Foundation
import Combine
import Testing
@testable import OneClick

@MainActor
struct ArchiveViewModelTests {
    @Test func storeOnlyIsCustomCompressionLevel() {
        #expect(ArchiveCompressionLevel.allCases.first == .store)
        #expect(!ArchiveCompressionLevel.defaultCases.contains(.store))
        let suite = "ArchiveViewModelTests.storeOnly.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ArchiveCompressionLevel.loadDefault(from: defaults) == .normal)
        defaults.set(ArchiveCompressionLevel.fast.rawValue, forKey: "archiveCompressionLevel")
        #expect(ArchiveCompressionLevel.loadDefault(from: defaults) == .fast)
        defaults.set(ArchiveCompressionLevel.store.rawValue, forKey: "archiveCompressionLevel")
        #expect(ArchiveCompressionLevel.loadDefault(from: defaults) == .normal)
        var form = ArchiveFormState()
        form.level = .store
        #expect(form.level == .store)
    }

    @Test func progressDoesNotInvalidateBatchAndPendingPromptTracksCancellation() {
        let model = ArchiveViewModel(requests: (0..<1000).map { _ in
            ArchiveRequest(operation: .compress, urls: [URL(fileURLWithPath: "/tmp/file")])
        })
        #expect(model.pendingRow?.id == 0)
        var batchChanges = 0
        var progressChanges = 0
        let batch = model.objectWillChange.sink { batchChanges += 1 }
        let progress = model.activity.objectWillChange.sink { progressChanges += 1 }
        for _ in 0..<20 { model.activity.update(.init(fraction: 0.25)) }
        #expect(batchChanges == 0)
        #expect(progressChanges == 1)
        model.cancel()
        #expect(model.pendingRow == nil)
        #expect(model.rows.allSatisfy { !$0.needsConfiguration && $0.error != nil })
        withExtendedLifetime((batch, progress)) {}
    }

    @Test func archiveWindowUsesCompactConfigurationAndProgressHeights() {
        let model = ArchiveViewModel(requests: [
            ArchiveRequest(operation: .compress, urls: [URL(fileURLWithPath: "/tmp/file")])
        ])
        #expect(model.preferredWindowHeight == 500)
        #expect(ArchiveViewModel.windowHeight(rows: model.rows, isRunning: true) == 80)
    }

    @Test(arguments: [false, true])
    func successfulAutoCloseKeepsTheCompactProgressHeight(verify: Bool) {
        let request = ArchiveRequest(operation: .zip, urls: [URL(fileURLWithPath: "/tmp/file")],
                                     verifyAfterCompression: verify)
        let rows = [ArchiveViewModel.Row(
            id: 0,
            request: request,
            output: URL(fileURLWithPath: "/tmp/file.zip")
        )]

        #expect(ArchiveViewModel.shouldCloseAutomatically(rows: rows, isRunning: false))
        #expect(ArchiveViewModel.windowHeight(rows: rows, isRunning: false) == 80)
    }

    @Test func submittingCompressionSkipsTheIntermediateIdleLayout() {
        let model = ArchiveViewModel(requests: [
            ArchiveRequest(operation: .compress, urls: [URL(fileURLWithPath: "/tmp/file")])
        ])
        var observedHeights: [CGFloat] = []
        let changes = model.$rows.combineLatest(model.$isRunning).dropFirst().sink { rows, isRunning in
            observedHeights.append(ArchiveViewModel.windowHeight(rows: rows, isRunning: isRunning))
        }

        model.submitCompression(for: 0, format: .zip, level: .normal, password: nil)

        #expect(model.isRunning)
        #expect(!observedHeights.isEmpty)
        #expect(observedHeights.allSatisfy { $0 == 80 })
        model.cancel()
        withExtendedLifetime(changes) {}
    }

    @Test func failedVerificationKeepsTheResultWindowOpen() {
        let rows = [ArchiveViewModel.Row(
            id: 0,
            request: ArchiveRequest(operation: .zip, urls: [URL(fileURLWithPath: "/tmp/file")],
                                    verifyAfterCompression: true),
            error: ArchiveError.verificationFailed("Damaged archive").localizedDescription
        )]
        #expect(!ArchiveViewModel.shouldCloseAutomatically(rows: rows, isRunning: false))
        #expect(ArchiveViewModel.windowHeight(rows: rows, isRunning: false) == 340)
    }

    @Test func activityCombinesBatchAndVerificationProgress() {
        let activity = ArchiveViewModel.Activity()
        activity.update(.init(fraction: 0.5), completedCount: 1, totalCount: 2)
        #expect(activity.state.overallFraction == 0.75)
        activity.update(.init(fraction: 1), completedCount: 0, totalCount: 1, includesVerification: true)
        #expect(activity.state.overallFraction == 0.9)
        activity.update(.init(fraction: 0.5, isVerifying: true), includesVerification: true)
        #expect(abs((activity.state.overallFraction ?? 0) - 0.95) < 0.0001)
        #expect(activity.isVerifying)
    }

    @Test func activityAggregatesConcurrentJobsWithoutCountingUnknownWorkAsFinished() {
        let activity = ArchiveViewModel.Activity()
        activity.update([.init(fraction: 0.5), .init(fraction: 0.25)], completedCount: 1, totalCount: 4)
        #expect(activity.state.overallFraction == 0.4375)
        activity.update([.init(), .init(fraction: 0.5)], completedCount: 1, totalCount: 4)
        #expect(activity.state.overallFraction == 0.375)
        activity.update([], completedCount: 4, totalCount: 4)
        #expect(activity.state.overallFraction == 1)
    }

    @Test func extractionRunsTwoJobsAndRefillsOnlyTheFreedSlot() async throws {
        let gate = ArchiveBatchGate()
        let requests = (0..<4).map { ArchiveRequest(operation: .extract, urls: [URL(fileURLWithPath: "/tmp/batch-\($0).zip")]) }
        let model = ArchiveViewModel(requests: requests, performArchive: { request, _, _, _ in
            try await gate.perform(request)
        })
        defer { model.cancel() }
        model.start()
        try await waitForStartedCount(2, gate: gate)
        #expect(await gate.started.count == 2)
        #expect(model.rows.filter(\.isRunning).count == 2)
        await gate.complete(requests[0].urls[0])
        try await waitForStartedCount(3, gate: gate)
        #expect(await gate.started.count == 3)
        #expect(model.rows.filter(\.isRunning).count == 2)
        await gate.complete(requests[1].urls[0])
        try await waitForStartedCount(4, gate: gate)
        await gate.complete(requests[2].urls[0])
        await gate.complete(requests[3].urls[0])
        try await waitUntilIdle(model)
        #expect(model.shouldCloseAutomatically)
        #expect(model.activity.state.overallFraction == 1)
    }

    @Test func cancellingBatchStopsBothActiveJobsAndLeavesQueuedJobsUnstarted() async throws {
        let gate = ArchiveBatchGate()
        let model = ArchiveViewModel(requests: (0..<4).map {
            ArchiveRequest(operation: .extract, urls: [URL(fileURLWithPath: "/tmp/cancel-\($0).zip")])
        }, performArchive: { request, _, _, _ in try await gate.perform(request) })
        model.start()
        try await waitForStartedCount(2, gate: gate)
        model.cancel()
        try await waitUntilIdle(model)
        #expect(await gate.started.count == 2)
        #expect(await gate.pendingCount == 0)
        #expect(model.rows.allSatisfy { !$0.isRunning && $0.output == nil && $0.error == AppLocalization.localized("Cancelled") })
    }

    @Test(arguments: [ArchiveOperation.zip, .extractAndDelete, .extract])
    func compressionAndDeletionBatchesKeepTheirSequentialOrder(operation: ArchiveOperation) async throws {
        let gate = ArchiveBatchGate()
        let requests = (0..<3).map {
            ArchiveRequest(operation: operation, urls: [URL(fileURLWithPath: "/tmp/ordered-\($0).zip")],
                           deletesSourcesAfterSuccess: operation == .extract)
        }
        let model = ArchiveViewModel(requests: requests, performArchive: { request, _, _, _ in try await gate.perform(request) })
        defer { model.cancel() }
        model.start()
        for count in 1...3 {
            try await waitForStartedCount(count, gate: gate)
            #expect(await gate.started == requests.prefix(count).map { $0.urls[0] })
            #expect(model.rows.filter(\.isRunning).count == 1)
            await gate.complete(requests[count - 1].urls[0])
        }
        try await waitUntilIdle(model)
        #expect(model.shouldCloseAutomatically)
    }

    private func waitForStartedCount(_ count: Int, gate: ArchiveBatchGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await gate.started.count < count && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await gate.started.count >= count)
    }

    @Test func volumePresetsAndCustomSizeValidation() {
        #expect(ArchiveVolumePreset.cd.bytes == 734_003_200)
        #expect(ArchiveVolumePreset.dvd.bytes == 4_700_000_000)
        #expect(ArchiveVolumePreset.fat32.bytes == 4_294_967_295)
        var form = ArchiveFormState()
        form.format = .sevenZip
        #expect(!form.splitVolumes)
        #expect(form.solid)
        #expect(!form.verifyAfterCompression)
        form.splitVolumes = true
        #expect(form.volumeSize == ArchiveVolumePreset.cd.bytes)
        form.volumePreset = .custom
        form.volumeUnit = .mebibytes
        form.customVolumeSize = " 25 "
        #expect(form.volumeSize == 26_214_400)
        #expect(form.canCompress)
        for invalid in ["", "0", "-1", "1.5", "NaN", "1m", "18446744073709551615", "999999999999999999999"] {
            form.customVolumeSize = invalid
            #expect(form.volumeSize == nil)
            #expect(form.volumeSizeError != nil)
            #expect(!form.canCompress)
        }
        form.splitVolumes = false
        #expect(form.canCompress)
    }

    @Test func customVolumeAndSolidOptionsReachWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-volume-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file.txt")
        let contents = Data((0..<8_192).map { _ in UInt8.random(in: .min ... .max) })
        try contents.write(to: source)
        let model = ArchiveViewModel(requests: [ArchiveRequest(operation: .compress, urls: [source])])
        model.start()
        model.submitCompression(for: 0, format: .tarGzip, level: .fast, password: nil, volumeSize: 1_024)
        #expect(model.rows[0].needsConfiguration)
        #expect(!model.isRunning)
        #expect(model.rows[0].error == ArchiveError.splittingNotSupported.localizedDescription)
        model.submitCompression(for: 0, format: .sevenZip, level: .fast, password: nil, volumeSize: 1_024, solid: false)
        try await waitUntilIdle(model)
        #expect(model.rows[0].request.volumeSize == 1_024)
        #expect(model.rows[0].request.solid == false)
        let archive = try #require(model.rows[0].output)
        #expect(archive.lastPathComponent.hasSuffix(".7z.001"))
        let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]))
        #expect(try Data(contentsOf: output.appendingPathComponent("file.txt")) == contents)
    }

    @Test(arguments: [ArchiveOperation.compress, .zip, .sevenZip, .tarGzip, .encryptedZip, .encryptedSevenZip])
    func compressionSettingsReachEveryEntryPoint(operation: ArchiveOperation) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-settings-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: source.appendingPathComponent("keep.txt"))
        try Data("skip".utf8).write(to: source.appendingPathComponent(".DS_Store"))
        let model = ArchiveViewModel(requests: [ArchiveRequest(operation: operation, urls: [source])],
                                     compressionSettings: ArchiveCompressionSettings(excludeFiles: true, threadCount: 1))
        model.start()
        let password = operation.isEncryptedCompression ? "test-password" : nil
        if operation == .compress {
            model.submitCompression(for: 0, format: .zip, level: .fast, password: nil)
        } else if let password {
            model.submitPassword(for: 0, password: password)
        }
        try await waitUntilIdle(model)
        let archive = try #require(model.rows[0].output)
        #expect(model.shouldCloseAutomatically)
        let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]), password: password)
        #expect(try String(contentsOf: output.appendingPathComponent("project/keep.txt"), encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("project/.DS_Store").path))
    }

    @Test(arguments: ArchiveCompressionFormat.allCases, [false, true])
    func configurableCompressionWaitsForSubmission(format: ArchiveCompressionFormat, encrypted: Bool) async throws {
        if format == .tarGzip && encrypted { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-options-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("configurable contents".utf8).write(to: file)
        let model = ArchiveViewModel(requests: [ArchiveRequest(operation: .compress, urls: [file])])
        model.start()
        #expect(model.rows[0].needsConfiguration)
        #expect(!model.isRunning)
        #expect(!model.shouldCloseAutomatically)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file.txt"])

        var observedHeights: [CGFloat] = []
        let changes = model.$rows.combineLatest(model.$isRunning).dropFirst().sink { rows, isRunning in
            observedHeights.append(ArchiveViewModel.windowHeight(rows: rows, isRunning: isRunning))
        }
        let password = encrypted ? "test-password" : nil
        model.submitCompression(for: 0, format: format, level: .fast, password: password, verifyAfterCompression: true)
        try await waitUntilIdle(model)
        let archive = try #require(model.rows[0].output)
        #expect(!model.rows[0].needsConfiguration)
        #expect(model.rows[0].request.compressionLevel == .fast)
        #expect(model.rows[0].request.verifyAfterCompression)
        #expect(model.rows[0].error == nil)
        #expect(!model.isVerifying)
        #expect(model.shouldCloseAutomatically)
        #expect(model.preferredWindowHeight == 80)
        #expect(!observedHeights.isEmpty)
        #expect(observedHeights.allSatisfy { $0 == 80 })
        withExtendedLifetime(changes) {}
        if encrypted {
            await #expect(throws: ArchiveError.passwordRequired) {
                try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]))
            }
        }
        let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]), password: password)
        #expect(try Data(contentsOf: output.appendingPathComponent("file.txt")) == Data(contentsOf: file))
    }

    @Test func cancellingConfigurationPreventsLaterSubmission() {
        let model = ArchiveViewModel(requests: [ArchiveRequest(operation: .compress, urls: [URL(fileURLWithPath: "/tmp/file")])])
        model.start()
        model.cancel()
        model.submitCompression(for: 0, format: .zip, level: .normal, password: nil)
        #expect(!model.rows[0].needsConfiguration)
        #expect(!model.isRunning)
        #expect(model.rows[0].output == nil)
        #expect(model.rows[0].error == AppLocalization.localized("Cancelled"))
        #expect(!model.shouldCloseAutomatically)
    }

    private func waitUntilIdle(_ model: ArchiveViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isRunning)
    }

    @Test(arguments: [ArchiveOperation.encryptedZip, .encryptedSevenZip])
    func encryptedCreationWaitsForPasswordBeforeWriting(operation: ArchiveOperation) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-password-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("contents".utf8).write(to: file)
        let model = ArchiveViewModel(requests: [ArchiveRequest(operation: operation, urls: [file])])
        model.start()
        #expect(model.rows[0].needsPassword)
        #expect(!model.isRunning)
        #expect(!model.shouldCloseAutomatically)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file.txt"])

        model.submitPassword(for: 0, password: operation == .encryptedSevenZip ? "中文密码" : "test-password")
        try await waitUntilIdle(model)
        #expect(model.rows[0].output != nil)
        #expect(!model.rows[0].needsPassword)
        #expect(model.rows[0].error == nil)
        #expect(model.shouldCloseAutomatically)
    }

    @Test(arguments: [ArchiveOperation.extract, .extractAndDelete])
    func passwordRetryPreservesOtherBatchResults(operation: ArchiveOperation) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-password-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locked = root.appendingPathComponent("locked.txt")
        let plain = root.appendingPathComponent("plain.txt")
        try Data("secret".utf8).write(to: locked)
        try Data("plain".utf8).write(to: plain)
        let encrypted = try await ArchiveService.perform(ArchiveRequest(operation: .encryptedZip, urls: [locked]), password: "password")
        let regular = try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [plain]))
        let model = ArchiveViewModel(requests: [encrypted, regular].map { ArchiveRequest(operation: operation, urls: [$0]) })
        model.start()
        try await waitUntilIdle(model)
        #expect(model.rows[0].needsPassword)
        #expect(FileManager.default.fileExists(atPath: encrypted.path))
        let plainOutput = try #require(model.rows[1].output)
        #expect(!model.shouldCloseAutomatically)
        #expect(FileManager.default.fileExists(atPath: regular.path) == (operation == .extract))

        model.submitPassword(for: 0, password: "wrong")
        try await waitUntilIdle(model)
        #expect(model.rows[0].needsPassword)
        #expect(model.rows[0].output == nil)
        #expect(model.rows[0].error == ArchiveError.incorrectPassword.localizedDescription)
        #expect(!model.shouldCloseAutomatically)
        #expect(FileManager.default.fileExists(atPath: encrypted.path))

        model.submitPassword(for: 0, password: "password")
        try await waitUntilIdle(model)
        #expect(model.rows[0].output != nil)
        #expect(model.rows[0].error == nil)
        #expect(FileManager.default.fileExists(atPath: encrypted.path) == (operation == .extract))
        #expect(model.rows[1].output == plainOutput)
        #expect(model.shouldCloseAutomatically)
        #expect(try String(contentsOf: plainOutput.appendingPathComponent("plain.txt"), encoding: .utf8) == "plain")
    }

    @Test func deletionFailureKeepsExtractedOutputAvailable() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("oneclick-delete-failure-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("contents".utf8).write(to: source)
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [source]))
        try fm.setAttributes([.immutable: true], ofItemAtPath: archive.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: archive.path) }
        let model = ArchiveViewModel(requests: [ArchiveRequest(operation: .extractAndDelete, urls: [archive])])
        model.start()
        try await waitUntilIdle(model)
        let output = try #require(model.rows[0].output)
        #expect(try Data(contentsOf: output.appendingPathComponent("source.txt")) == Data("contents".utf8))
        #expect(fm.fileExists(atPath: archive.path))
        #expect(model.rows[0].error != nil)
        #expect(!model.rows[0].needsPassword)
        #expect(!model.shouldCloseAutomatically)
    }

    @Test func batchWithFailureRemainsOpenAfterOtherRowsSucceed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-auto-close-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file.txt")
        try Data("contents".utf8).write(to: source)
        let model = ArchiveViewModel(requests: [
            ArchiveRequest(operation: .zip, urls: [source]),
            ArchiveRequest(operation: .extract, urls: [source], error: "Invalid archive")
        ])
        #expect(!model.shouldCloseAutomatically)
        model.start()
        #expect(!model.shouldCloseAutomatically)
        try await waitUntilIdle(model)
        #expect(model.rows[0].output != nil)
        #expect(model.rows[1].error == "Invalid archive")
        #expect(!model.shouldCloseAutomatically)
    }
}

/// Suspends workers until explicitly released, so scheduler assertions do not
/// depend on helper speed or the contents of the disk cache.
private actor ArchiveBatchGate {
    private(set) var started: [URL] = []
    private var pending: [URL: CheckedContinuation<URL, any Error>] = [:]
    var pendingCount: Int { pending.count }

    func perform(_ request: ArchiveRequest) async throws -> URL {
        let url = request.urls[0]
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            started.append(url)
            return try await withCheckedThrowingContinuation { pending[url] = $0 }
        } onCancel: {
            Task { await self.cancel(url) }
        }
    }

    func complete(_ url: URL) {
        pending.removeValue(forKey: url)?.resume(returning: url.appendingPathExtension("output"))
    }

    private func cancel(_ url: URL) {
        pending.removeValue(forKey: url)?.resume(throwing: CancellationError())
    }
}
