import Foundation
import Testing
@testable import OneClick

struct UpdateInstallerTests {
    private let bundleIdentifier = "test.oneclick.update-install"

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-installer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func app(at url: URL, version: String, identifier: String? = nil) throws {
        let fm = FileManager.default
        let contents = url.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier ?? bundleIdentifier, "CFBundleExecutable": "Probe",
                    "CFBundlePackageType": "APPL", "CFBundleVersion": version]
        try PropertyListEncoder().encode(info).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/Probe")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(version.utf8).write(to: contents.appendingPathComponent("version"))
    }

    @Test func validUpdateReplacesInPlaceAndCleansStaging() async throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let installed = root.appendingPathComponent("My App.app")
        let incoming = root.appendingPathComponent("Incoming.app")
        try app(at: installed, version: "old")
        try app(at: incoming, version: "new")
        let result = try await UpdateInstaller.install(incoming, to: installed, bundleIdentifier: bundleIdentifier)
        #expect(result == installed)
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/version"), encoding: .utf8) == "new")
        #expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == ["Incoming.app", "My App.app"])
    }

    @Test(arguments: ["wrong-identifier", "missing-executable", "missing-source"])
    func failedPreparationPreservesTheInstalledApplication(failure: String) async throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let installed = root.appendingPathComponent("Installed.app")
        let incoming = root.appendingPathComponent("Incoming.app")
        try app(at: installed, version: "old")
        if failure != "missing-source" {
            try app(at: incoming, version: "new", identifier: failure == "wrong-identifier" ? "unrelated.app" : nil)
            if failure == "missing-executable" { try fm.removeItem(at: incoming.appendingPathComponent("Contents/MacOS/Probe")) }
        }
        await #expect(throws: (any Error).self) {
            try await UpdateInstaller.install(incoming, to: installed, bundleIdentifier: bundleIdentifier)
        }
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/version"), encoding: .utf8) == "old")
        #expect(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".oneclick-update-") })
    }

    @Test(.timeLimit(.minutes(1)))
    func relaunchWaitsForOldProcessAndPreservesLiteralApplicationPath() async throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let launcher = root.appendingPathComponent("launcher")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.result\"\n".utf8).write(to: launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let oldProcess = Process()
        oldProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldProcess.arguments = ["30"]
        try oldProcess.run()
        defer { if oldProcess.isRunning { oldProcess.terminate(); oldProcess.waitUntilExit() } }
        let application = root.appendingPathComponent("App with spaces;$(literal).app")
        let helper = try UpdateRelauncher.schedule(application: application, processID: oldProcess.processIdentifier, launcher: launcher)
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        let result = URL(fileURLWithPath: launcher.path + ".result")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!fm.fileExists(atPath: result.path))
        oldProcess.terminate()
        oldProcess.waitUntilExit()
        let deadline = ContinuousClock.now + .seconds(5)
        while helper.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!helper.isRunning)
        #expect(helper.terminationStatus == 0)
        #expect(try String(contentsOf: result, encoding: .utf8) == "-a\n" + application.path + "\n")
    }
}
