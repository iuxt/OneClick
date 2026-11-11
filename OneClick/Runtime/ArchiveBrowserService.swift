import Darwin
import Foundation

nonisolated enum ArchiveBrowserError: LocalizedError, Equatable {
    case listingTooLarge, previewTooLarge, entryUnavailable, invalidListing
    var errorDescription: String? {
        switch self {
        case .listingTooLarge: AppLocalization.localized("This archive has too many entries to browse. Extract it to view all files.")
        case .previewTooLarge: AppLocalization.localized("Preview is limited to files up to 64 MiB. Extract the archive to open this file.")
        case .entryUnavailable: AppLocalization.localized("This entry cannot be previewed. Folders, links, duplicate names and unsafe paths are excluded.")
        case .invalidListing: AppLocalization.localized("The archive directory could not be read safely.")
        }
    }
}

nonisolated struct ArchiveEntry: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
    let isDirectory: Bool
    var isLink = false
    var encrypted = false
    var modifiedDate: Date? = nil
    var createdDate: Date? = nil

    var normalizedPath: String {
        var result = path
        while result.hasPrefix("./") { result.removeFirst(2) }
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
    var name: String { normalizedPath.components(separatedBy: "/").last ?? path }
    var parent: String { normalizedPath.components(separatedBy: "/").dropLast().joined(separator: "/") }
    var canPreview: Bool {
        !isDirectory && !isLink && !normalizedPath.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.contains("\0") && !normalizedPath.components(separatedBy: "/").contains("..")
    }
}

nonisolated enum ArchiveBrowserService {
    static let previewLimit = 64 * 1_024 * 1_024

    @concurrent
    static func verify(_ url: URL, password: String? = nil,
                       progress: ArchiveProgress = ArchiveProgress()) async throws {
        try await withTaskCancellationHandler {
            try validate(url, password: password)
            let operation: ArchiveOperation = ["tar.gz", "tgz"].contains(ArchiveFormat.suffix(for: url) ?? "") ? .tarGzip : .extract
            try ArchiveService.testArchive(at: url, operation: operation, password: password, progress: progress)
            try Task.checkCancellation()
        } onCancel: { progress.cancel() }
    }

    /// Ask the split-container reader how many parts belong to this archive;
    /// unrelated or orphaned numbered files must never be swept up by a glob.
    @concurrent
    static func sourceVolumes(_ url: URL, password: String? = nil,
                              progress: ArchiveProgress = ArchiveProgress()) async throws -> [URL] {
        guard ["zip.001", "7z.001"].contains(ArchiveFormat.suffix(for: url) ?? "") else { return [url] }
        return try await withTaskCancellationHandler {
            try validate(url, password: password)
            let data = try capture(url: url, arguments: ["l", "-slt", "-sccUTF-8", "-bd", "--", url.path],
                                   password: password, limit: 32 * 1_024 * 1_024, progress: progress)
            let header = String(decoding: data, as: UTF8.self).components(separatedBy: "\n----------")[0]
            guard let line = header.components(separatedBy: .newlines).first(where: { $0.hasPrefix("Volumes = ") }),
                  let count = Int(line.dropFirst("Volumes = ".count)), (1...100_000).contains(count) else {
                throw ArchiveBrowserError.invalidListing
            }
            let base = url.deletingPathExtension()
            return (1...count).map { base.appendingPathExtension(String(format: "%03d", $0)) }
        } onCancel: { progress.cancel() }
    }

    @concurrent
    static func list(_ url: URL, password: String? = nil, progress: ArchiveProgress = ArchiveProgress()) async throws -> [ArchiveEntry] {
        try await withTaskCancellationHandler {
            try validate(url, password: password)
            let entries: [ArchiveEntry]
            if ["7z", "7z.001", "zip.001", "rar"].contains(ArchiveFormat.suffix(for: url) ?? "") {
                let data = try capture(url: url, arguments: ["l", "-slt", "-ba", "-sccUTF-8", "-bd", "--", url.path],
                                       password: password, limit: 32 * 1_024 * 1_024, progress: progress)
                entries = try parseSevenZipListing(String(decoding: data, as: UTF8.self))
            } else {
                entries = try SystemArchiveReader.list(url)
            }
            try Task.checkCancellation()
            return entries
        } onCancel: { progress.cancel() }
    }

    @concurrent
    static func preview(_ url: URL, entry: ArchiveEntry, password: String? = nil,
                        progress: ArchiveProgress = ArchiveProgress()) async throws -> Data {
        try await withTaskCancellationHandler {
            try validate(url, password: password)
            guard entry.canPreview else { throw ArchiveBrowserError.entryUnavailable }
            guard entry.size <= previewLimit else { throw ArchiveBrowserError.previewTooLarge }
            if ArchiveService.usesSevenZip(for: url) {
                // stdout only: archive paths never become filesystem destinations.
                // -spd disables wildcard expansion, so a literal '*' selects one entry.
                return try capture(url: url, arguments: ["x", "-so", "-spd", "-bd", "-bb0", "--", url.path, entry.path],
                                   password: password, limit: previewLimit, progress: progress)
            }
            return try SystemArchiveReader.read(url, entry: entry, limit: previewLimit)
        } onCancel: { progress.cancel() }
    }

    static func parseSevenZipListing(_ listing: String) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var fields: [String: String] = [:]
        // 7-Zip prints entry times in the local time zone, with optional
        // fractional seconds. Missing times are common (especially creation).
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.isLenient = false
        func date(_ text: String?) -> Date? {
            guard let text, !text.isEmpty else { return nil }
            let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts[0].count == 19, let base = dateFormatter.date(from: String(parts[0])) else { return nil }
            guard parts.count == 2 else { return base }
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let fraction = Double("0." + parts[1]) else { return nil }
            return base.addingTimeInterval(fraction)
        }
        func finish() throws {
            guard !fields.isEmpty else { return }
            guard let path = fields["Path"], let sizeText = fields["Size"], let size = Int64(sizeText), size >= 0 else {
                throw ArchiveBrowserError.invalidListing
            }
            guard entries.count < 100_000 else { throw ArchiveBrowserError.listingTooLarge }
            entries.append(ArchiveEntry(path: path, size: size,
                                        isDirectory: fields["Folder"] == "+" || fields["Attributes"]?.hasPrefix("D") == true,
                                        isLink: fields["Symbolic Link"] != nil || fields["Hard Link"] != nil
                                            || fields["Attributes"]?.contains("lrwx") == true,
                                        encrypted: fields["Encrypted"] == "+",
                                        modifiedDate: date(fields["Modified"]),
                                        createdDate: date(fields["Created"])))
            fields = [:]
        }
        for line in listing.components(separatedBy: "\n") {
            if line.isEmpty || line == "\r" { try finish(); continue }
            if entries.isEmpty && fields.isEmpty && line == "Enter password:" { continue }
            guard let separator = line.range(of: " = ") else { throw ArchiveBrowserError.invalidListing }
            let key = String(line[..<separator.lowerBound])
            guard fields[key] == nil else { throw ArchiveBrowserError.invalidListing }
            fields[key] = String(line[separator.upperBound...]).trimmingCharacters(in: .newlines)
        }
        try finish()
        return entries
    }

    private static func validate(_ url: URL, password: String?) throws {
        try Task.checkCancellation()
        guard url.isFileURL, ArchiveFormat.suffix(for: url) != nil,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ArchiveError.notArchive }
        if let password, password.isEmpty || password.utf8.count > 1_024 || password.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) {
            throw ArchiveError.invalidPassword
        }
    }

    private static func capture(url: URL, arguments: [String], password: String?, limit: Int, progress: ArchiveProgress) throws -> Data {
        let process = Process()
        process.executableURL = try ArchiveService.sevenZipURL()
        process.arguments = arguments
        process.currentDirectoryURL = url.deletingLastPathComponent()
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let output = Pipe(), diagnostics = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = diagnostics
        if let password { try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8)) }
        try input.fileHandleForWriting.close()
        process.standardInput = input
        defer {
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? diagnostics.fileHandleForReading.close()
            try? diagnostics.fileHandleForWriting.close()
        }
        try progress.launch(process)
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        let drain = DispatchGroup()
        drain.enter()
        // A concurrent batch can occupy every cooperative worker while reading
        // stdout. Give stderr its own thread so draining cannot be starved by
        // those workers waiting for this group to finish.
        let drainThread = Thread {
            defer { drain.leave() }
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = Darwin.read(diagnostics.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                progress.append(Data(buffer.prefix(count)))
            }
        }
        drainThread.qualityOfService = .userInitiated
        drainThread.start()
        var result = Data()
        do {
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard result.count + count <= limit else {
                    throw limit == previewLimit ? ArchiveBrowserError.previewTooLarge : ArchiveBrowserError.listingTooLarge
                }
                result.append(contentsOf: buffer.prefix(count))
            }
            process.waitUntilExit()
            drain.wait()
            try progress.finish()
            guard process.terminationStatus == 0 else {
                let text = progress.detail + String(decoding: result.prefix(4_096), as: UTF8.self)
                if progress.passwordFailure || text.localizedCaseInsensitiveContains("password")
                    || (password == nil && process.terminationStatus == 255) {
                    throw password == nil ? ArchiveError.passwordRequired : ArchiveError.incorrectPassword
                }
                throw ArchiveError.failed(progress.detail)
            }
            try Task.checkCancellation()
            return result
        } catch {
            progress.cancel()
            process.waitUntilExit()
            drain.wait()
            throw error
        }
    }
}
