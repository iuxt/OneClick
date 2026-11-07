import Foundation
import Darwin

nonisolated enum ArchiveOperation: String, Sendable, CaseIterable {
    case compress = "compress"
    case zip = "compress-zip"
    case sevenZip = "compress-7z"
    case tarGzip = "compress-targz"
    case encryptedZip = "compress-zip-encrypted"
    case encryptedSevenZip = "compress-7z-encrypted"
    case extract = "extract"
    case extractAndDelete = "extract-and-delete"

    var title: String {
        let key = switch self {
        case .compress: "Compress…"
        case .zip: "Compress to ZIP"
        case .sevenZip: "Compress to 7Z"
        case .tarGzip: "Compress to TAR.GZ"
        case .encryptedZip: "Compress to Encrypted ZIP…"
        case .encryptedSevenZip: "Compress to Encrypted 7Z…"
        case .extract: "Extract Here"
        case .extractAndDelete: "Extract and Delete Archive"
        }
        return AppLocalization.localized(key)
    }

    var fileExtension: String {
        switch self {
        case .tarGzip: "tar.gz"
        case .sevenZip, .encryptedSevenZip: "7z"
        default: "zip"
        }
    }

    var isEncryptedCompression: Bool { self == .encryptedZip || self == .encryptedSevenZip }
    var isExtraction: Bool { self == .extract || self == .extractAndDelete }
}

nonisolated enum ArchiveCompressionFormat: String, CaseIterable, Sendable {
    case zip = "ZIP"
    case sevenZip = "7Z"
    case tarGzip = "TAR.GZ"

    func operation(encrypted: Bool) -> ArchiveOperation {
        switch self {
        case .zip: encrypted ? .encryptedZip : .zip
        case .sevenZip: encrypted ? .encryptedSevenZip : .sevenZip
        case .tarGzip: .tarGzip
        }
    }
}

nonisolated enum ArchiveCompressionLevel: Int, CaseIterable, Sendable {
    case store = 0, fastest = 1, fast = 3, normal = 5, maximum = 9

    /// Store mode is deliberately available only from the configurable
    /// compression window. Direct Finder actions keep using a real compression
    /// level so their existing size/speed behaviour does not change.
    static let defaultCases: [Self] = [.fastest, .fast, .normal, .maximum]

    static func loadDefault(from defaults: UserDefaults) -> Self {
        guard defaults.object(forKey: "archiveCompressionLevel") != nil,
              let level = Self(rawValue: defaults.integer(forKey: "archiveCompressionLevel")),
              defaultCases.contains(level) else { return .normal }
        return level
    }

    var title: String {
        let key = switch self {
        case .store: "Store Only"
        case .fastest: "Fastest"
        case .fast: "Fast"
        case .normal: "Normal"
        case .maximum: "Maximum"
        }
        return AppLocalization.localized(key)
    }
}

nonisolated enum ArchiveVolumeUnit: String, CaseIterable, Sendable {
    case bytes = "B", kibibytes = "KiB", mebibytes = "MiB", gibibytes = "GiB"

    var multiplier: UInt64 {
        switch self {
        case .bytes: 1
        case .kibibytes: 1_024
        case .mebibytes: 1_048_576
        case .gibibytes: 1_073_741_824
        }
    }

    func bytes(for text: String) -> UInt64? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(text) else { return nil }
        let (bytes, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return !overflow && bytes > 0 && bytes <= Int64.max ? bytes : nil
    }
}

nonisolated enum ArchiveVolumePreset: CaseIterable, Sendable {
    case cd, dvd, fat32, custom

    var title: String {
        switch self {
        case .cd: "CD (700 MiB)"
        case .dvd: "DVD (4.7 GB)"
        case .fat32: "FAT32 (4 GiB − 1 B)"
        case .custom: AppLocalization.localized("Custom Size")
        }
    }

    var bytes: UInt64? {
        switch self {
        case .cd: 700 * 1_048_576
        case .dvd: 4_700_000_000
        case .fat32: 4_294_967_295
        case .custom: nil
        }
    }
}

nonisolated struct ArchiveCompressionSettings: Sendable {
    static let defaultExclusionList = ".DS_Store\n__MACOSX"
    static var maximumThreadCount: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }

    var excludeFiles = false
    var exclusionList = defaultExclusionList
    /// Zero selects the available logical CPU count.
    var threadCount = 0

    var effectiveThreadCount: Int {
        threadCount <= 0 ? Self.maximumThreadCount : min(threadCount, Self.maximumThreadCount)
    }

    var exclusionPatterns: [String] {
        guard excludeFiles else { return [] }
        var seen = Set<String>()
        return exclusionList.components(separatedBy: .newlines).compactMap { line in
            let pattern = line.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !pattern.contains("\0"), seen.insert(pattern).inserted else { return nil }
            return pattern
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        Self(excludeFiles: defaults.bool(forKey: "archiveExcludeFiles"),
             exclusionList: defaults.string(forKey: "archiveExclusionList") ?? defaultExclusionList,
             threadCount: defaults.integer(forKey: "archiveCompressionThreads"))
    }
}

nonisolated struct ArchiveRequest: Sendable {
    let operation: ArchiveOperation
    let urls: [URL]
    var error: String? = nil
    var compressionLevel: ArchiveCompressionLevel? = nil
    var volumeSize: UInt64? = nil
    /// nil retains the tool's default for direct compression shortcuts.
    var solid: Bool? = nil
    var verifyAfterCompression = false
    /// Destructive compression shortcuts remove inputs only after the staged
    /// archive has passed verification and the finished output is published.
    var deletesSourcesAfterSuccess = false
}

nonisolated enum ArchiveError: LocalizedError, Equatable {
    case sourceDeletionFailed(output: URL, detail: String)
    case verificationFailed(String)
    case invalidSelection, notArchive, configurationRequired, passwordRequired, incorrectPassword, invalidPassword, invalidZIPPassword, encryptionNotSupported, invalidVolumeSize, splittingNotSupported, solidNotSupported, toolUnavailable, failed(String)

    var errorDescription: String? {
        switch self {
        case .verificationFailed(let detail):
            AppLocalization.localized("Archive verification failed. No archive was saved.") + "\n" + detail
        case .sourceDeletionFailed(_, let detail):
            AppLocalization.localized("The output was created, but the source files could not be deleted.") + "\n" + detail
        case .configurationRequired:
            AppLocalization.localized("Choose compression options before creating the archive.")
        case .invalidSelection:
            AppLocalization.localized("Select files or folders from the same directory to compress.")
        case .notArchive:
            AppLocalization.localized("Select a supported archive to extract.")
        case .passwordRequired:
            AppLocalization.localized("This archive requires a password.")
        case .incorrectPassword:
            AppLocalization.localized("The password is incorrect. Please try again.")
        case .invalidPassword:
            AppLocalization.localized("Use a non-empty password of up to 1,024 UTF-8 bytes without line breaks or null characters.")
        case .invalidZIPPassword:
            AppLocalization.localized("ZIP passwords must use 1–99 printable ASCII characters. Use Encrypted 7Z for other characters.")
        case .encryptionNotSupported:
            AppLocalization.localized("Choose Encrypted ZIP or Encrypted 7Z for password protection.")
        case .invalidVolumeSize:
            AppLocalization.localized("Enter a positive whole-number volume size within the supported range.")
        case .splittingNotSupported:
            AppLocalization.localized("Split volumes are available for ZIP and 7Z only.")
        case .solidNotSupported:
            AppLocalization.localized("Solid compression is available for 7Z only.")
        case .toolUnavailable:
            AppLocalization.localized("The bundled archive tool is missing. Please reinstall OneClick.")
        case .failed(let detail):
            AppLocalization.localized("The archive operation failed. The archive may be damaged or unsupported.") + "\n" + detail
        }
    }
}

/// The worker and UI share only this small, locked state. Output is bounded,
/// including when a damaged archive or a huge directory produces many lines.
nonisolated final class ArchiveProgress: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var fraction: Double?
        var isVerifying = false
    }

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var output = Data()
    private var askedForPassword = false
    private var reportedWrongPassword = false
    private var verifying = false
    private var state = Snapshot()
    private var record = Data()
    private var passwordScanTail = Data()
    private var fileSizes: [String: Double] = [:]
    private var currentFileName = ""
    private var totalSize = 0.0
    private var completedSize = 0.0
    private var visitedFiles = Set<String>()
    private var nativeFraction: Double?

    var snapshot: Snapshot { lock.withLock { state } }

    func configure(entries: [ArchiveEntry]) {
        lock.withLock {
            fileSizes = [:]
            for entry in entries where !entry.isDirectory && !entry.isLink {
                let path = entry.normalizedPath
                let size = Double(entry.size)
                fileSizes[path] = size
            }
            totalSize = fileSizes.values.reduce(0, +)
        }
    }

    func complete() {
        lock.withLock {
            state.fraction = 1
        }
    }

    func reportFraction(_ fraction: Double) {
        lock.withLock {
            state.fraction = max(state.fraction ?? 0, min(1, max(0, fraction)))
        }
    }

    var isVerifying: Bool { lock.withLock { verifying } }

    func setVerifying(_ value: Bool) {
        lock.withLock {
            verifying = value
            if value {
                state = Snapshot(isVerifying: true)
            } else {
                state.isVerifying = false
            }
        }
    }

    var detail: String {
        lock.withLock { String(decoding: output.suffix(2_048), as: UTF8.self) }
    }

    var isRunning: Bool {
        lock.withLock { process?.isRunning == true }
    }

    var passwordFailure: Bool {
        lock.withLock { askedForPassword || reportedWrongPassword }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    func launch(_ process: Process) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            output = Data()
            record = Data()
            passwordScanTail = Data()
            state = Snapshot(isVerifying: verifying)
            completedSize = 0
            currentFileName = ""
            visitedFiles = []
            nativeFraction = nil
            askedForPassword = false
            reportedWrongPassword = false
            try process.run()
            self.process = process
        }
    }

    func finish() throws {
        try lock.withLock {
            consumeRecord()
            record = Data()
            process = nil
            if cancelled { throw CancellationError() }
        }
    }

    func append(_ data: Data) {
        lock.withLock {
            output.append(data)
            if output.count > 16_384 { output = Data(output.suffix(16_384)) }
            // Search only the new bytes plus a short overlap. Decoding the
            // complete diagnostic buffer for every pipe read becomes quadratic
            // when a tool emits output one byte at a time.
            passwordScanTail.append(data)
            let passwordText = String(decoding: passwordScanTail, as: UTF8.self)
            askedForPassword = askedForPassword || passwordText.contains("Enter password")
            reportedWrongPassword = reportedWrongPassword || passwordText.contains("Wrong password")
            if passwordScanTail.count > 32 { passwordScanTail = Data(passwordScanTail.suffix(32)) }
            // 7-Zip redraws percentages using backspaces on macOS. Keep the
            // incomplete UTF-8 record between reads; pipe reads can split anywhere.
            for byte in data {
                if byte == 8 || byte == 10 || byte == 13 {
                    consumeRecord()
                    record.removeAll(keepingCapacity: true)
                } else if record.count < 16_384 {
                    record.append(byte)
                }
            }
            // Percentages need not end in a newline. TAR boundary records are
            // consumed only after their complete record arrives.
            consumePercentage(String(decoding: record, as: UTF8.self))
        }
    }

    private func consumeRecord() {
        let text = String(decoding: record, as: UTF8.self)
        guard !text.isEmpty else { return }
        consumePercentage(text)
        // bsdtar has no byte percentage, so use its file-boundary records only
        // to advance the aggregate total. Other output remains diagnostic.
        for prefix in ["a ", "x "] where text.hasPrefix(prefix) {
            var name = String(text.dropFirst(prefix.count))
            while name.hasPrefix("./") { name.removeFirst(2) }
            guard !name.hasSuffix("/"), name != currentFileName else { return }
            if let size = fileSizes[currentFileName], visitedFiles.insert(currentFileName).inserted {
                completedSize += size
            }
            currentFileName = name
            updateFractions()
            return
        }
    }

    private func consumePercentage(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, text.dropFirst(digits.count).first == "%",
              let percent = Double(digits), percent <= 100 else { return }
        let fraction = percent / 100
        if let nativeFraction, fraction <= nativeFraction { return }
        nativeFraction = fraction
        updateFractions()
    }

    private func updateFractions() {
        if let nativeFraction {
            state.fraction = nativeFraction
        } else if totalSize > 0 {
            // bsdtar reports file boundaries but no byte percentages. Never
            // invent a timed percentage for a file that is still being read.
            state.fraction = min(1, completedSize / totalSize)
        }
    }
}

/// System bsdtar handles TAR compression and extraction; the bundled
/// 7-Zip helper handles ZIP/7Z creation and ZIP/7Z/RAR extraction. Neither is
/// invoked through a shell. Passwords travel only through a private stdin pipe.
/// Work is staged in a private sibling directory; only successful output is
/// published. Originals and existing destinations are never overwritten.
nonisolated enum ArchiveService {
    @concurrent
    static func perform(_ request: ArchiveRequest, password: String? = nil,
                        settings: ArchiveCompressionSettings = ArchiveCompressionSettings(),
                        progress: ArchiveProgress = ArchiveProgress()) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let error = request.error { throw ArchiveError.failed(error) }
            guard request.operation != .compress else { throw ArchiveError.configurationRequired }
            if let volumeSize = request.volumeSize {
                guard volumeSize > 0, volumeSize <= Int64.max else { throw ArchiveError.invalidVolumeSize }
                guard [.zip, .sevenZip, .encryptedZip, .encryptedSevenZip].contains(request.operation) else {
                    throw ArchiveError.splittingNotSupported
                }
            }
            if request.solid != nil && ![.sevenZip, .encryptedSevenZip].contains(request.operation) {
                throw ArchiveError.solidNotSupported
            }
            if let password {
                guard !password.isEmpty, password.utf8.count <= 1_024,
                      !password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
                    throw ArchiveError.invalidPassword
                }
                if request.operation == .encryptedZip && !isValidZIPPassword(password) { throw ArchiveError.invalidZIPPassword }
                guard request.operation.isExtraction || request.operation.isEncryptedCompression else {
                    throw ArchiveError.encryptionNotSupported
                }
            } else if request.operation.isEncryptedCompression {
                throw ArchiveError.passwordRequired
            }
            let fm = FileManager.default
            guard let first = request.urls.first, first.isFileURL,
                  request.urls.allSatisfy({ $0.standardizedFileURL.path != "/" && ![".", ".."].contains($0.lastPathComponent) }) else {
                throw ArchiveError.invalidSelection
            }
            let parent = first.deletingLastPathComponent().standardizedFileURL
            if request.operation.isExtraction {
                guard request.urls.count == 1, ArchiveFormat.suffix(for: first) != nil,
                      try first.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                      try first.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw ArchiveError.notArchive
                }
            } else {
                guard request.urls.allSatisfy({ $0.isFileURL && $0.deletingLastPathComponent().standardizedFileURL == parent }) else {
                    throw ArchiveError.invalidSelection
                }
            }

            let sourceSnapshot: ArchiveSourceSnapshot?
            if request.operation == .extractAndDelete {
                let sources = try await ArchiveBrowserService.sourceVolumes(first, password: password)
                sourceSnapshot = try ArchiveSourceSnapshot(sources)
            } else if request.deletesSourcesAfterSuccess {
                sourceSnapshot = try ArchiveSourceSnapshot(request.urls)
            } else {
                sourceSnapshot = nil
            }

            if !request.operation.isExtraction && request.operation == .tarGzip {
                // bsdtar has no native byte percentage, so it still needs size
                // metadata. 7-Zip already scans ZIP/7Z inputs and reports an
                // aggregate percentage; enumerating those trees here would read
                // all metadata twice before useful compression work begins.
                progress.configure(entries: try compressionEntries(request.urls, settings: settings))
            }
            try Task.checkCancellation()
            let staging = parent.appendingPathComponent(".oneclick-archive-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            let result: URL
            let name: String
            let ext: String
            let arguments: [String]
            let useSevenZip: Bool
            if request.operation.isExtraction {
                result = staging.appendingPathComponent("contents", isDirectory: true)
                try fm.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                name = ArchiveFormat.extractionName(for: first)
                ext = ""
                useSevenZip = usesSevenZip(for: first)
                // Keep libarchive's default path traversal / symlink protection.
                // Never use -P (absolute paths) or restore privileged metadata.
                if useSevenZip {
                    // No -p on extraction: 7-Zip prompts on stdin only when the
                    // archive is encrypted. An empty -p would force an empty
                    // password on some versions. snld0 rejects unsafe symlinks.
                    arguments = ["x", "-y", "-bsp1", "-bb0", "-sccUTF-8", "-snld0", "-o" + result.path, "--", first.path]
                } else {
                    arguments = ["-xvf", first.path, "-C", result.path, "--safe-writes",
                                 "--no-same-owner", "--no-same-permissions", "--no-acls", "--no-xattrs", "--no-fflags"]
                }
            } else {
                useSevenZip = request.operation != .tarGzip
                result = staging.appendingPathComponent(useSevenZip ? "archive." + request.operation.fileExtension : "archive")
                name = request.urls.count == 1 ? first.lastPathComponent : AppLocalization.localized("Archive")
                ext = "." + request.operation.fileExtension
                let format = request.operation == .zip ? ["--format", "zip"] : ["--format", "pax", "-z"]
                // ./ also prevents bsdtar's special @archive syntax and options
                // from interpreting filenames such as @file or -file.
                if useSevenZip {
                    let isZIP = request.operation == .zip || request.operation == .encryptedZip
                    let formatOptions = [isZIP ? "-tzip" : "-t7z", "-mmt=\(settings.effectiveThreadCount)"]
                    let encryption = request.operation.isEncryptedCompression
                        ? (isZIP ? ["-mem=AES256", "-p"] : ["-mhe=on", "-p"]) : []
                    let level = request.compressionLevel.map { ["-mx=\($0.rawValue)"] } ?? []
                    let exclusions = settings.exclusionPatterns.map { "-xr!" + $0 }
                    let volumes = request.volumeSize.map { ["-v\($0)b"] } ?? []
                    let solid = request.solid.map { [$0 ? "-ms=on" : "-ms=off"] } ?? []
                    arguments = ["a"] + formatOptions + encryption + level + exclusions + volumes + solid + ["-snl", "-y", "-bsp1", "-bb0", "-sccUTF-8", result.path, "--"]
                        + request.urls.map { "./" + $0.lastPathComponent }
                } else {
                    let level = request.compressionLevel.map { ["--options", "gzip:compression-level=\($0.rawValue)"] } ?? []
                    let exclusions = settings.exclusionPatterns.flatMap { ["--exclude", $0] }
                    arguments = ["-cvf", result.path] + format + level + exclusions + ["-C", parent.path, "--"]
                        + request.urls.map { "./" + $0.lastPathComponent }
                }
            }
            if shouldUseParallelZIP(request, settings: settings) {
                let level = request.compressionLevel?.rawValue ?? ArchiveCompressionLevel.normal.rawValue
                try runParallelZIP(arguments: ["-K", "-c", "-A", first.lastPathComponent,
                                               "-p", String(settings.effectiveThreadCount), "-\(level)"],
                                   input: first, output: result, directory: parent, progress: progress)
            } else {
                let executable = useSevenZip ? try sevenZipURL() : URL(fileURLWithPath: "/usr/bin/tar")
                try run(executable: executable, arguments: arguments, directory: parent,
                        password: useSevenZip ? password : nil, progress: progress)
            }
            try Task.checkCancellation()
            if !request.operation.isExtraction && (request.verifyAfterCompression || request.deletesSourcesAfterSuccess) {
                let archive = request.volumeSize == nil ? result : result.appendingPathExtension("001")
                try verifyArchive(at: archive, operation: request.operation, password: password, progress: progress)
                try Task.checkCancellation()
            }
            var deletionError: Error?
            if let sourceSnapshot, !request.operation.isExtraction {
                do {
                    let archive = request.volumeSize == nil ? result : result.appendingPathExtension("001")
                    let entries = try await ArchiveBrowserService.list(archive, password: password)
                    try sourceSnapshot.requireCoverage(in: entries, relativeTo: parent)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A usable archive is still published, but uncertain coverage
                    // must never authorize deleting the originals.
                    deletionError = error
                }
            }
            // Reserve each destination with an exclusive rename. A separate
            // existence check followed by rename can overwrite a concurrent job.
            var published: URL?
            if request.volumeSize != nil {
                published = try publishVolumes(of: result, to: parent, name: name, extension: ext)
            }
            if published == nil {
                for index in 0...10_000 {
                    try Task.checkCancellation()
                    let suffix = index == 0 ? "" : " (\(index + 1))"
                    let destination = parent.appendingPathComponent(name + suffix + ext)
                    do {
                        try moveExclusively(from: result, to: destination)
                        published = destination
                        break
                    } catch let error as CocoaError where error.code == .fileWriteFileExists {
                        continue
                    }
                }
            }
            guard let published else { throw CocoaError(.fileWriteFileExists) }
            progress.complete()
            if request.operation == .extractAndDelete || request.deletesSourcesAfterSuccess {
                do {
                    try Task.checkCancellation()
                    if let deletionError { throw deletionError }
                    try sourceSnapshot?.removeUnchanged()
                } catch is CancellationError {
                    // Published output remains available; cancellation preserves
                    // every source not already removed.
                    return published
                } catch {
                    throw ArchiveError.sourceDeletionFailed(output: published, detail: error.localizedDescription)
                }
            }
            return published
        } onCancel: {
            progress.cancel()
        }
    }

    static func usesSevenZip(for url: URL) -> Bool {
        ["zip", "zip.001", "zipx", "7z", "7z.001", "rar", "jar", "war", "apk", "ipa", "xpi"].contains(ArchiveFormat.suffix(for: url) ?? "")
    }

    private static func compressionEntries(_ urls: [URL], settings: ArchiveCompressionSettings) throws -> [ArchiveEntry] {
        guard let parent = urls.first?.deletingLastPathComponent() else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let exclusions = settings.exclusionPatterns
        let prefix = parent.path == "/" ? "/" : parent.path + "/"
        var entries: [ArchiveEntry] = []
        for source in urls {
            let sourceValues = try? source.resourceValues(forKeys: keys)
            let enumerator = sourceValues?.isDirectory == true && sourceValues?.isSymbolicLink != true
                ? FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys)) : nil
            var next: URL? = source
            while let url = next {
                try Task.checkCancellation()
                let path = String(url.path.dropFirst(prefix.count))
                let excluded = exclusions.contains {
                    fnmatch($0, path, 0) == 0 || fnmatch($0, url.lastPathComponent, 0) == 0
                }
                if excluded {
                    if url == source { break }
                    enumerator?.skipDescendants()
                } else if let values = try? url.resourceValues(forKeys: keys) {
                    entries.append(ArchiveEntry(path: path, size: Int64(values.fileSize ?? 0),
                                                isDirectory: values.isDirectory == true, isLink: values.isSymbolicLink == true))
                    // Progress metadata must remain bounded for huge trees.
                    if entries.count > 200_000 { return [] }
                }
                next = enumerator?.nextObject() as? URL
            }
        }
        return entries
    }

    /// Read and validate every compressed stream before publishing the staged archive.
    /// Split ZIP/7Z archives are tested through their first volume; 7-Zip reads the rest.
    static func verifyArchive(at archive: URL, operation: ArchiveOperation, password: String? = nil,
                              progress: ArchiveProgress = ArchiveProgress()) throws {
        progress.setVerifying(true)
        defer { progress.setVerifying(false) }
        let directory = archive.deletingLastPathComponent()
        do {
            try Task.checkCancellation()
            if operation == .tarGzip {
                // Validate gzip's payload CRC as well as the enclosed TAR structure.
                try run(executable: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-t", "--", archive.path],
                        directory: directory, password: nil, progress: progress)
                try Task.checkCancellation()
                try run(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-tf", archive.path],
                        directory: directory, password: nil, progress: progress)
            } else {
                try run(executable: sevenZipURL(), arguments: ["t", "-y", "-bsp1", "-bb0", "-sccUTF-8", "--", archive.path],
                        directory: directory, password: password, progress: progress)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ArchiveError.verificationFailed(error.localizedDescription)
        }
    }

    private static func moveExclusively(from source: URL, to destination: URL) throws {
        // Staging is a sibling of the destination, so this never crosses devices.
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw CocoaError(.fileWriteFileExists) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    private static func publishVolumes(of archive: URL, to parent: URL, name: String, extension ext: String) throws -> URL {
        let fm = FileManager.default
        let prefix = archive.lastPathComponent + "."
        let volumes = try fm.contentsOfDirectory(at: archive.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
        guard volumes.first?.lastPathComponent == prefix + "001" else {
            throw ArchiveError.failed("No archive volumes were produced.")
        }
        for index in 0...10_000 {
            try Task.checkCancellation()
            let suffix = index == 0 ? "" : " (\(index + 1))"
            let base = name + suffix + ext
            // An existing later volume also reserves the name, even if .001
            // was removed. Never mix a new set with an older incomplete set.
            let existing = try fm.contentsOfDirectory(atPath: parent.path)
            if existing.contains(where: { entry in
                if entry.compare(base, options: .caseInsensitive) == .orderedSame { return true }
                guard entry.range(of: base + ".", options: [.anchored, .caseInsensitive]) != nil else { return false }
                let number = entry.dropFirst(base.count + 1)
                return number.count >= 3 && number.utf8.allSatisfy { (48...57).contains($0) }
            }) { continue }
            var moved: [(source: URL, destination: URL)] = []
            do {
                for volume in volumes {
                    try Task.checkCancellation()
                    let number = String(volume.lastPathComponent.dropFirst(prefix.count))
                    let destination = parent.appendingPathComponent(base + "." + number)
                    try moveExclusively(from: volume, to: destination)
                    moved.append((volume, destination))
                }
                try Task.checkCancellation()
                return moved[0].destination
            } catch {
                // Roll back only files this job moved. Returning them to staging
                // allows a collision retry; the outer defer cleans up failures.
                for item in moved.reversed() {
                    try moveExclusively(from: item.destination, to: item.source)
                }
                if let error = error as? CocoaError, error.code == .fileWriteFileExists { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func isValidZIPPassword(_ password: String) -> Bool {
        !password.isEmpty && password.utf8.count <= 99 && password.utf8.allSatisfy { (0x20...0x7e).contains($0) }
    }

    static func sevenZipURL() throws -> URL {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw ArchiveError.toolUnavailable }
        return url
    }

    static func pigzURL() throws -> URL {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pigz")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw ArchiveError.toolUnavailable }
        return url
    }

    /// pigz 2.8 writes a standard single-entry DEFLATE ZIP, but not ZIP64 or
    /// Unix mode metadata. Keep the parallel path deliberately narrow and use
    /// 7-Zip for every input whose behaviour could differ.
    static func shouldUseParallelZIP(_ request: ArchiveRequest, settings: ArchiveCompressionSettings) -> Bool {
        guard request.operation == .zip, request.urls.count == 1,
              request.compressionLevel != .store, request.volumeSize == nil,
              settings.exclusionPatterns.isEmpty, (try? pigzURL()) != nil,
              let source = request.urls.first else { return false }
        var info = stat()
        guard lstat(source.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) == 0 else { return false }
        let size = UInt64(max(0, info.st_size))
        return size >= 8 * 1_048_576 && size < UInt64(UInt32.max) - 1_048_576
    }

    private static func runParallelZIP(arguments: [String], input: URL, output: URL, directory: URL,
                                       progress: ArchiveProgress) throws {
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ArchiveError.failed("Could not create the staged ZIP archive.")
        }
        let destination = try FileHandle(forWritingTo: output)
        defer { try? destination.close() }
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() }
        let inputSize = Double(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let process = Process()
        process.executableURL = try pigzURL()
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        // The child and parent share the same open-file description. Polling
        // its offset provides total input progress without copying bytes through
        // another pipe, while fstat() in pigz still sees the source modification time.
        process.standardInput = source
        process.standardOutput = destination
        let pipe = Pipe()
        process.standardError = pipe
        try progress.launch(process)
        try? pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        do {
            while process.isRunning {
                if inputSize > 0, let offset = try? source.offset() {
                    // Reading can finish slightly before the compression queue
                    // drains, so reserve the final 5% for flushing and publish.
                    progress.reportFraction(min(0.95, Double(offset) / inputSize * 0.95))
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                progress.append(Data(buffer.prefix(count)))
            }
        } catch {
            progress.cancel()
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        try progress.finish()
        guard process.terminationStatus == 0 else { throw ArchiveError.failed(progress.detail) }
    }

    private static func run(executable: URL, arguments: [String], directory: URL,
                            password: String?, progress: ArchiveProgress) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        let input: Pipe?
        if let password {
            let pipe = Pipe()
            // Preload a bounded line before spawning. This avoids a broken-pipe
            // signal if the tool exits before it reads the password.
            try pipe.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
            try pipe.fileHandleForWriting.close()
            process.standardInput = pipe.fileHandleForReading
            input = pipe
        } else {
            input = nil
        }
        defer { try? input?.fileHandleForReading.close() }
        // A single pipe is continuously drained to avoid stdout/stderr deadlocks.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try progress.launch(process)
        // Close our writer, so EOF is delivered once the child exits.
        try? pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        do {
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                // A POSIX pipe read returns as soon as any output is available.
                // FileHandle.read(upToCount:) may wait to fill its entire buffer,
                // delaying activity until the archive operation has finished.
                let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                progress.append(Data(buffer.prefix(count)))
            }
        } catch {
            progress.cancel()
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        try progress.finish()
        guard process.terminationStatus == 0 else {
            if progress.passwordFailure {
                throw password == nil ? ArchiveError.passwordRequired : ArchiveError.incorrectPassword
            }
            throw ArchiveError.failed(progress.detail)
        }
    }
}
