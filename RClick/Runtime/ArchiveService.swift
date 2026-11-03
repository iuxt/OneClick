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

    var title: String {
        let key = switch self {
        case .compress: "Compress…"
        case .zip: "Compress to ZIP"
        case .sevenZip: "Compress to 7Z"
        case .tarGzip: "Compress to TAR.GZ"
        case .encryptedZip: "Compress to Encrypted ZIP…"
        case .encryptedSevenZip: "Compress to Encrypted 7Z…"
        case .extract: "Extract Here"
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
    case fastest = 1, fast = 3, normal = 5, maximum = 9

    var title: String {
        let key = switch self {
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
}

nonisolated enum ArchiveError: LocalizedError, Equatable {
    case invalidSelection, notArchive, configurationRequired, passwordRequired, incorrectPassword, invalidPassword, invalidZIPPassword, encryptionNotSupported, invalidVolumeSize, splittingNotSupported, solidNotSupported, toolUnavailable, failed(String)

    var errorDescription: String? {
        switch self {
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
            AppLocalization.localized("The bundled archive tool is missing. Please reinstall RClick.")
        case .failed(let detail):
            AppLocalization.localized("The archive operation failed. The archive may be damaged or unsupported.") + "\n" + detail
        }
    }
}

/// The worker and UI share only this small, locked state. Output is bounded,
/// including when a damaged archive or a huge directory produces many lines.
nonisolated final class ArchiveProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var output = Data()
    private var askedForPassword = false
    private var reportedWrongPassword = false

    var detail: String {
        lock.withLock { String(decoding: output.suffix(2_048), as: UTF8.self) }
    }

    var isRunning: Bool {
        lock.withLock { process?.isRunning == true }
    }

    fileprivate var passwordFailure: Bool {
        lock.withLock { askedForPassword || reportedWrongPassword }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    fileprivate func launch(_ process: Process) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
            self.process = process
        }
    }

    fileprivate func finish() throws {
        try lock.withLock {
            process = nil
            if cancelled { throw CancellationError() }
        }
    }

    fileprivate func append(_ data: Data) {
        lock.withLock {
            output.append(data)
            let text = String(decoding: output, as: UTF8.self)
            askedForPassword = askedForPassword || text.contains("Enter password")
            reportedWrongPassword = reportedWrongPassword || text.contains("Wrong password")
            if output.count > 16_384 { output = Data(output.suffix(16_384)) }
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
                guard request.operation == .extract || request.operation.isEncryptedCompression else {
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
            if request.operation == .extract {
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

            let staging = parent.appendingPathComponent(".rclick-archive-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            let result: URL
            let name: String
            let ext: String
            let arguments: [String]
            let useSevenZip: Bool
            if request.operation == .extract {
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
                    arguments = ["x", "-y", "-bd", "-bb1", "-snld0", "-o" + result.path, "--", first.path]
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
                    arguments = ["a"] + formatOptions + encryption + level + exclusions + volumes + solid + ["-snl", "-y", "-bd", "-bb1", result.path, "--"]
                        + request.urls.map { "./" + $0.lastPathComponent }
                } else {
                    let level = request.compressionLevel.map { ["--options", "gzip:compression-level=\($0.rawValue)"] } ?? []
                    let exclusions = settings.exclusionPatterns.flatMap { ["--exclude", $0] }
                    arguments = ["-cvf", result.path] + format + level + exclusions + ["-C", parent.path, "--"]
                        + request.urls.map { "./" + $0.lastPathComponent }
                }
            }
            let executable = useSevenZip ? try sevenZipURL() : URL(fileURLWithPath: "/usr/bin/tar")
            try run(executable: executable, arguments: arguments, directory: parent,
                    password: useSevenZip ? password : nil, progress: progress)
            try Task.checkCancellation()
            if request.volumeSize != nil {
                return try publishVolumes(of: result, to: parent, name: name, extension: ext)
            }
            // moveItem refuses existing paths. Retry collisions, including races
            // with other jobs, without replacing the user's files or folders.
            for index in 0...10_000 {
                try Task.checkCancellation()
                let suffix = index == 0 ? "" : " (\(index + 1))"
                let destination = parent.appendingPathComponent(name + suffix + ext)
                do {
                    try fm.moveItem(at: result, to: destination)
                    return destination
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                }
            }
            throw CocoaError(.fileWriteFileExists)
        } onCancel: {
            progress.cancel()
        }
    }

    static func usesSevenZip(for url: URL) -> Bool {
        ["zip", "zip.001", "zipx", "7z", "7z.001", "rar", "jar", "war", "apk", "ipa", "xpi"].contains(ArchiveFormat.suffix(for: url) ?? "")
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
                    try fm.moveItem(at: volume, to: destination)
                    moved.append((volume, destination))
                }
                try Task.checkCancellation()
                return moved[0].destination
            } catch {
                // Roll back only files this job moved. Returning them to staging
                // allows a collision retry; the outer defer cleans up failures.
                for item in moved.reversed() {
                    try fm.moveItem(at: item.destination, to: item.source)
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
