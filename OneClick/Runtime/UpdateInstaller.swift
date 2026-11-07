import Darwin
import Foundation

/// Prepare and validate beside the installed app, then publish with one atomic
/// rename. Copy/validation/rename failures always leave the old app in place.
nonisolated enum UpdateInstaller {
    @concurrent
    static func install(_ app: URL, to destination: URL, bundleIdentifier: String) async throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".oneclick-update-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let prepared = staging.appendingPathComponent(destination.lastPathComponent)
        try fm.copyItem(at: app, to: prepared)
        try validate(prepared, bundleIdentifier: bundleIdentifier)
        try Task.checkCancellation()

        // RENAME_SWAP leaves the previous app in staging only after successful
        // replacement. RENAME_EXCL handles a first install without overwriting
        // another concurrent installer. Both paths stay on the same filesystem.
        if renamex_np(prepared.path, destination.path, UInt32(RENAME_SWAP)) != 0 {
            guard errno == ENOENT else { throw posixError() }
            guard renamex_np(prepared.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
        }
        return destination
    }

    private static func validate(_ app: URL, bundleIdentifier: String) throws {
        let contents = app.appendingPathComponent("Contents")
        let data = try Data(contentsOf: contents.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != "..",
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS").appendingPathComponent(executable).path) else {
            throw UpdateManager.InstallationError.invalidAppBundle(
                AppLocalization.localized("The application bundle is invalid or damaged."))
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

nonisolated enum UpdateRelauncher {
    /// Launch only after the old process has exited. Passing paths as positional
    /// arguments preserves spaces and shell metacharacters without interpolation.
    @discardableResult
    static func schedule(application: URL, processID: pid_t,
                         launcher: URL = URL(fileURLWithPath: "/usr/bin/open")) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            attempt=0
            while /bin/kill -0 "$1" 2>/dev/null; do
                [ "$attempt" -lt 600 ] || exit 1
                /bin/sleep 0.1
                attempt=$((attempt + 1))
            done
            exec "$3" -a "$2"
            """, "oneclick-relaunch", String(processID), application.path, launcher.path]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
