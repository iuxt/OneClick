import Foundation
import Testing
@testable import OneClick

struct UpdateArchiveExtractorTests {
    @Test(.timeLimit(.minutes(1)))
    func verboseSizedAppPackageExtractsWithoutBlockingAndUsesSeparateStaging() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("oneclick-update-test-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("OneClick.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        for index in 0..<2_000 {
            try Data("resource \(index)".utf8).write(to: resources.appendingPathComponent("long-resource-file-name-\(index).txt"))
        }
        let zip = root.appendingPathComponent("update.app.zip")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        pack.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        pack.standardOutput = FileHandle.nullDevice
        pack.standardError = FileHandle.nullDevice
        try pack.run()
        pack.waitUntilExit()
        try #require(pack.terminationStatus == 0)

        async let firstJob = UpdateArchiveExtractor.extract(zipURL: zip)
        async let secondJob = UpdateArchiveExtractor.extract(zipURL: zip)
        let (first, second) = try await (firstJob, secondJob)
        defer {
            try? fm.removeItem(at: first.deletingLastPathComponent())
            try? fm.removeItem(at: second.deletingLastPathComponent())
        }
        #expect(first != second)
        for extracted in [first, second] {
            let contents = extracted.appendingPathComponent("Contents/Resources")
            #expect(try fm.contentsOfDirectory(atPath: contents.path).count == 2_000)
            #expect(try String(contentsOf: contents.appendingPathComponent("long-resource-file-name-1999.txt"), encoding: .utf8) == "resource 1999")
        }
    }

    @Test func malformedPackageFailsWithADiagnostic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-invalid-update-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("invalid.app.zip")
        try Data("invalid zip".utf8).write(to: zip)
        do {
            _ = try await UpdateArchiveExtractor.extract(zipURL: zip)
            Issue.record("Invalid update package unexpectedly succeeded")
        } catch let error as UpdateManager.InstallationError {
            guard case .zipExtractionFailed(let detail) = error else {
                Issue.record("Expected an extraction error")
                return
            }
            #expect(!detail.isEmpty)
        }
    }
}
