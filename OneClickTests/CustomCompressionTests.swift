import AppKit
import SwiftUI
import Testing
@testable import OneClick

struct CustomCompressionTests {
    @Test func diskImageProgressParsesNativePercentages() {
        let progress = ArchiveProgress()
        progress.append(Data("PERCENT:25.500000\n".utf8))
        #expect(progress.snapshot.fraction == 0.255)
        progress.append(Data("PERCENT:-1.000000\nPERCENT:101.000000\n".utf8))
        #expect(progress.snapshot.fraction == 0.255)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-custom-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @MainActor @Test func volumeSizeAcceptsUnitsAndRejectsInvalidOrOverflowingValues() {
        #expect(ArchiveFormState.parseVolumeSize("5 MB") == 5_000_000)
        #expect(ArchiveFormState.parseVolumeSize("1.5 GiB") == 1_610_612_736)
        #expect(ArchiveFormState.parseVolumeSize("1024") == 1_024)
        for invalid in ["0 MB", "-1 MB", "1e3 MB", "NaN GB", "1.2.3 GB", "1000000000000 GiB", "0.1 B", "5 XB"] {
            #expect(ArchiveFormState.parseVolumeSize(invalid) == nil)
        }
    }

    @Test(arguments: [false, true])
    func zipEncryptionMethodCreatesReadableArchives(aes: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("secret.txt")
        let data = Data("secret contents".utf8)
        try data.write(to: source)
        let archive = try await ArchiveService.perform(.init(operation: .encryptedZip, urls: [source],
                                                             zipUsesAES256: aes), password: "password")
        let listing = try output(ArchiveService.sevenZipURL(), ["l", "-slt", archive.path])
        #expect(listing.contains(aes ? "AES-256" : "ZipCrypto"))
        let extracted = try await ArchiveService.perform(.init(operation: .extract, urls: [archive]), password: "password")
        #expect(try Data(contentsOf: extracted.appendingPathComponent("secret.txt")) == data)
    }

    @Test(arguments: [false, true])
    func sevenZipHeaderEncryptionHonorsTheOption(encryptedNames: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("secret.txt")
        try Data("secret contents".utf8).write(to: source)
        let archive = try await ArchiveService.perform(.init(operation: .encryptedSevenZip, urls: [source],
                                                             encryptFileNames: encryptedNames), password: "password")
        if encryptedNames {
            await #expect(throws: ArchiveError.passwordRequired) { try await ArchiveBrowserService.list(archive) }
        } else {
            #expect(try await ArchiveBrowserService.list(archive).contains { $0.name == "secret.txt" })
        }
        let extracted = try await ArchiveService.perform(.init(operation: .extract, urls: [archive]), password: "password")
        #expect(try String(contentsOf: extracted.appendingPathComponent("secret.txt"), encoding: .utf8) == "secret contents")
    }

    @Test(arguments: [false, true])
    func windowsExecutableHasRealSFXModuleAndValidPayload(encrypted: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("contents.txt")
        try Data("Windows self-extracting payload".utf8).write(to: source)
        let password = encrypted ? "password" : nil
        let archive = try await ArchiveService.perform(.init(operation: encrypted ? .encryptedSevenZip : .sevenZip,
                                                             urls: [source], windowsSelfExtracting: true), password: password)
        #expect(archive.pathExtension == "exe")
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: 2) == Data([0x4d, 0x5a]))
        try ArchiveService.verifyArchive(at: archive, operation: .sevenZip, password: password)
        let extracted = root.appendingPathComponent("extracted")
        _ = try output(ArchiveService.sevenZipURL(), ["x", "-y", "-o" + extracted.path, archive.path], password: password)
        #expect(try String(contentsOf: extracted.appendingPathComponent("contents.txt"), encoding: .utf8) == "Windows self-extracting payload")
    }

    @Test(arguments: [false, true], [ArchiveOperation.zip, .sevenZip, .tarGzip])
    func macResourceExclusionsArePerRequest(exclude: Bool, operation: ArchiveOperation) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        for name in ["keep.txt", ".DS_Store", "._keep.txt"] {
            try Data(name.utf8).write(to: source.appendingPathComponent(name))
        }
        let archive = try await ArchiveService.perform(.init(operation: operation, urls: [source], excludeMacResourceFiles: exclude))
        let entries = try await ArchiveBrowserService.list(archive)
        #expect(entries.contains { $0.name == "keep.txt" })
        #expect(entries.contains { $0.name == ".DS_Store" } == !exclude)
        // libarchive consumes AppleDouble records as metadata while listing TAR.
        if exclude || operation != .tarGzip {
            #expect(entries.contains { $0.name == "._keep.txt" } == !exclude)
        }
    }

    @Test(.serialized, arguments: ArchiveDiskImageFormat.allCases, [false, true])
    func diskImagesMountWithExpectedContentsAndVolumeName(format: ArchiveDiskImageFormat, encrypted: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("contents.txt")
        try Data("Disk image contents".utf8).write(to: source)
        let password = encrypted ? "测试 password" : nil
        let archive = try await ArchiveService.perform(.init(operation: encrypted ? .encryptedDmg : .dmg, urls: [source],
                                                             verifyAfterCompression: true, diskImageFormat: format,
                                                             volumeName: "Custom Volume"), password: password)
        #expect(archive.pathExtension == "dmg")
        let mount = root.appendingPathComponent("mounted")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        defer { _ = try? output(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", "-force", mount.path]) }
        var args = ["attach", archive.path, "-readonly", "-nobrowse", "-mountpoint", mount.path]
        if encrypted { args.append("-stdinpass") }
        _ = try output(URL(fileURLWithPath: "/usr/bin/hdiutil"), args, password: password, terminator: "\0")
        #expect(try String(contentsOf: mount.appendingPathComponent("contents.txt"), encoding: .utf8) == "Disk image contents")
        #expect(try mount.resourceValues(forKeys: [.volumeNameKey]).volumeName == "Custom Volume")
    }

    @Test func diskImageDeletionRequiresVerifiedReadableImage() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("contents.txt")
        try Data("delete only after verification".utf8).write(to: source)
        let archive = try await ArchiveService.perform(.init(operation: .dmg, urls: [source], deletesSourcesAfterSuccess: true))
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        try ArchiveService.verifyArchive(at: archive, operation: .dmg)
    }

    private func output(_ executable: URL, _ arguments: [String], password: String? = nil, terminator: String = "\n") throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe()
        if let password { try input.fileHandleForWriting.write(contentsOf: Data((password + terminator).utf8)) }
        try input.fileHandleForWriting.close()
        process.standardInput = input.fileHandleForReading
        defer { try? input.fileHandleForReading.close() }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try pipe.fileHandleForReading.close()
        process.waitUntilExit()
        let result = String(decoding: data, as: UTF8.self)
        try #require(process.terminationStatus == 0, "\(result)")
        return result
    }
}
