import Foundation

/// Runs outside the main actor. stdout is discarded and stderr is continuously
/// drained with bounded retention, so verbose/invalid packages cannot fill a pipe
/// while the parent waits for unzip to finish.
nonisolated enum UpdateArchiveExtractor {
    @concurrent
    static func extract(zipURL: URL) async throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        let extractionDir = fm.temporaryDirectory.appendingPathComponent("rclick-update-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: extractionDir, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: extractionDir) } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", zipURL.path, "-d", extractionDir.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        defer {
            try? errors.fileHandleForReading.close()
            try? errors.fileHandleForWriting.close()
        }
        try process.run()
        try? errors.fileHandleForWriting.close()
        var diagnostic = Data()
        do {
            while let data = try errors.fileHandleForReading.read(upToCount: 8_192), !data.isEmpty {
                diagnostic.append(data)
                if diagnostic.count > 8_192 { diagnostic = Data(diagnostic.suffix(8_192)) }
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: diagnostic, as: UTF8.self)
            throw UpdateManager.InstallationError.zipExtractionFailed(
                String(format: AppLocalization.localized("Extraction failed: %@"), detail)
            )
        }
        let contents = try fm.contentsOfDirectory(at: extractionDir, includingPropertiesForKeys: [.isDirectoryKey])
        guard let appURL = try contents.first(where: { url in
            guard url.pathExtension == "app" else { return false }
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }) else {
            throw UpdateManager.InstallationError.noAppFound(
                AppLocalization.localized("No .app application was found in the ZIP file.")
            )
        }
        succeeded = true
        return appURL
    }
}
