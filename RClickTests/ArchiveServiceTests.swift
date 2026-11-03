import Foundation
import Testing
@testable import RClick

struct ArchiveServiceTests {
    @Test(arguments: [ArchiveOperation.zip, .sevenZip, .encryptedZip, .encryptedSevenZip])
    func splitVolumesRespectSizeAndRoundTrip(operation: ArchiveOperation) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("资料.txt")
        let contents = Data((0..<16_384).map { _ in UInt8.random(in: .min ... .max) })
        try contents.write(to: source)
        let password = operation.isEncryptedCompression ? "test-password" : nil
        let request = ArchiveRequest(operation: operation, urls: [source], compressionLevel: .fast,
                                     volumeSize: 1_024)
        // Even an orphaned later volume must reserve the entire archive name.
        let orphan = root.appendingPathComponent("资料.txt." + operation.fileExtension + ".999")
        try Data("keep".utf8).write(to: orphan)
        let archive = try await ArchiveService.perform(request, password: password)
        #expect(archive.lastPathComponent == "资料.txt (2)." + operation.fileExtension + ".001")
        let base = archive.deletingPathExtension().lastPathComponent + "."
        let volumes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix(base) }.sorted { $0.path < $1.path }
        #expect(volumes.count > 1)
        for (index, volume) in volumes.enumerated() {
            let size = try #require(volume.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(size > 0 && size <= 1_024)
            if index < volumes.count - 1 { #expect(size == 1_024) }
        }
        let saved = try volumes.map { try Data(contentsOf: $0) }
        let another = try await ArchiveService.perform(request, password: password)
        #expect(another.lastPathComponent == "资料.txt (3)." + operation.fileExtension + ".001")
        #expect(try volumes.map { try Data(contentsOf: $0) } == saved)
        #expect(try Data(contentsOf: orphan) == Data("keep".utf8))
        if password != nil {
            await #expect(throws: ArchiveError.passwordRequired) {
                try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]))
            }
        }
        let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]), password: password)
        #expect(try Data(contentsOf: output.appendingPathComponent(source.lastPathComponent)) == contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".rclick-archive-") })
    }

    @Test func concurrentSplitJobsPreserveBothVolumeSets() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("same")
        let data = Data((0..<8_192).map { _ in UInt8.random(in: .min ... .max) })
        try data.write(to: source)
        let request = ArchiveRequest(operation: .zip, urls: [source], volumeSize: 1_024)
        async let first = ArchiveService.perform(request)
        async let second = ArchiveService.perform(request)
        let archives = try await [first, second]
        #expect(Set(archives).count == 2)
        for archive in archives {
            let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]))
            #expect(try Data(contentsOf: output.appendingPathComponent("same")) == data)
        }
    }

    @Test(arguments: [false, true])
    func sevenZipSolidSwitchChangesArchiveStructure(solid: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = [root.appendingPathComponent("a.txt"), root.appendingPathComponent("b.txt")]
        for source in sources { try Data(String(repeating: "shared contents\n", count: 1_000).utf8).write(to: source) }
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .sevenZip, urls: sources,
                                                                     compressionLevel: .fast, solid: solid))
        let process = Process()
        process.executableURL = try ArchiveService.sevenZipURL()
        process.arguments = ["l", "-slt", "--", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(listing.contains(solid ? "Solid = +" : "Solid = -"))
        #expect(listing.contains(solid ? "Blocks = 1" : "Blocks = 2"))
        let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]))
        for source in sources {
            #expect(try Data(contentsOf: output.appendingPathComponent(source.lastPathComponent)) == Data(contentsOf: source))
        }
    }

    @Test func invalidVolumeOptionsFailBeforeWriting() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data().write(to: source)
        for size in [UInt64(0), UInt64.max] {
            await #expect(throws: ArchiveError.invalidVolumeSize) {
                try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [source], volumeSize: size))
            }
        }
        await #expect(throws: ArchiveError.splittingNotSupported) {
            try await ArchiveService.perform(ArchiveRequest(operation: .tarGzip, urls: [source], volumeSize: 1_024))
        }
        await #expect(throws: ArchiveError.solidNotSupported) {
            try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [source], solid: true))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source"])
    }

    @Test(arguments: [ArchiveOperation.zip, .sevenZip, .tarGzip, .encryptedZip, .encryptedSevenZip], [false, true])
    func compressionExclusionsApplyRecursively(operation: ArchiveOperation, enabled: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project")
        let files = ["keep.txt", ".DS_Store", "nested/.DS_Store", "nested/cache.tmp", "nested/node_modules/package.js", "nested/keep.txt"]
        for file in files {
            let url = source.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.utf8).write(to: url)
        }
        // Include an explicitly selected matching file as well as nested matches.
        let selected = root.appendingPathComponent("selected.tmp")
        try Data("selected".utf8).write(to: selected)
        let settings = ArchiveCompressionSettings(excludeFiles: enabled,
                                                 exclusionList: " .DS_Store \r\n\nnode_modules\n*.tmp\n.DS_Store", threadCount: 1)
        let password = operation.isEncryptedCompression ? "test-password" : nil
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: operation, urls: [source, selected]),
                                                     password: password, settings: settings)
        // Compression settings must not filter extracted contents.
        var extractionSettings = settings
        extractionSettings.excludeFiles = true
        let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]),
                                                    password: password, settings: extractionSettings)
        for file in files {
            let extracted = output.appendingPathComponent("project").appendingPathComponent(file)
            if !enabled || file.hasSuffix("keep.txt") {
                #expect(try Data(contentsOf: extracted) == Data(file.utf8))
            } else {
                #expect(!FileManager.default.fileExists(atPath: extracted.path))
            }
            #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent(file).path))
        }
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("selected.tmp").path) == !enabled)
        #expect(!enabled || !FileManager.default.fileExists(atPath: output.appendingPathComponent("project/nested/node_modules").path))
    }

    @Test func compressionSettingsUseSavedValuesAndBoundThreadCounts() throws {
        let name = "rclick-compression-settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let initial = ArchiveCompressionSettings.load(from: defaults)
        #expect(!initial.excludeFiles)
        #expect(initial.exclusionList == ArchiveCompressionSettings.defaultExclusionList)
        #expect(initial.threadCount == 0)
        #expect(initial.effectiveThreadCount == ArchiveCompressionSettings.maximumThreadCount)

        defaults.set(true, forKey: "archiveExcludeFiles")
        defaults.set("*.tmp\n\n*.tmp\r\n .DS_Store ", forKey: "archiveExclusionList")
        defaults.set(1, forKey: "archiveCompressionThreads")
        let saved = ArchiveCompressionSettings.load(from: defaults)
        #expect(saved.exclusionPatterns == ["*.tmp", ".DS_Store"])
        #expect(saved.effectiveThreadCount == 1)
        for invalid in [-1, Int.max] {
            defaults.set(invalid, forKey: "archiveCompressionThreads")
            #expect(ArchiveCompressionSettings.load(from: defaults).effectiveThreadCount == ArchiveCompressionSettings.maximumThreadCount)
        }
        defaults.set("", forKey: "archiveExclusionList")
        #expect(ArchiveCompressionSettings.load(from: defaults).exclusionPatterns.isEmpty)
    }

    @Test(arguments: ArchiveCompressionFormat.allCases)
    func compressionLevelChangesOutputAndPreservesContents(format: ArchiveCompressionFormat) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("repeated.txt")
        let text = (0..<20_000).map { "Row \($0 % 997): \($0 % 131) abcdefghijklmnopqrstuvwxyz \($0 % 53)\n" }.joined()
        let data = Data(text.utf8)
        try data.write(to: source)
        let fastest = try await ArchiveService.perform(ArchiveRequest(operation: format.operation(encrypted: false), urls: [source], compressionLevel: .fastest))
        let maximum = try await ArchiveService.perform(ArchiveRequest(operation: format.operation(encrypted: false), urls: [source], compressionLevel: .maximum))
        // This mixed sample exercises different match lengths. Uniform repeated
        // text can produce equal-sized ZIP output at different levels.
        #expect(try Data(contentsOf: maximum).count != Data(contentsOf: fastest).count)
        for archive in [fastest, maximum] {
            let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]))
            #expect(try Data(contentsOf: output.appendingPathComponent("repeated.txt")) == data)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rclick-archives-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: [ArchiveOperation.zip, .tarGzip, .encryptedZip, .encryptedSevenZip])
    func roundTripPreservesContentsAndUnusualNames(operation: ArchiveOperation) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("资料 %20 @测试")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let data = Data("中文内容\nhello\0world".utf8)
        let file = folder.appendingPathComponent(".hidden.txt")
        try data.write(to: file)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: ".hidden.txt")
        let special = root.appendingPathComponent("@-literal%20.txt")
        try Data("literal".utf8).write(to: special)
        let option = root.appendingPathComponent("--help")
        try Data().write(to: option)

        let password: String? = operation.isEncryptedCompression
            ? (operation == .encryptedSevenZip ? "中文 password %20 $() '\"" : "password %20 $() '\"") : nil
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: operation, urls: [folder, special, option]), password: password)
        let output = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [archive]), password: password)
        #expect(try Data(contentsOf: output.appendingPathComponent(folder.lastPathComponent).appendingPathComponent(".hidden.txt")) == data)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: output.appendingPathComponent(folder.lastPathComponent).appendingPathComponent("link").path) == ".hidden.txt")
        #expect(try output.appendingPathComponent(folder.lastPathComponent).appendingPathComponent("empty").resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(try Data(contentsOf: output.appendingPathComponent(special.lastPathComponent)) == Data("literal".utf8))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("--help").path))
        #expect(try Data(contentsOf: file) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".rclick-archive-") })
    }

    @Test func existingFilesAndExtractionFoldersArePreserved() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file.txt")
        let data = Data("original".utf8)
        try data.write(to: source)
        let request = ArchiveRequest(operation: .zip, urls: [source])
        let first = try await ArchiveService.perform(request)
        let originalArchive = try Data(contentsOf: first)
        let second = try await ArchiveService.perform(request)
        #expect(second.lastPathComponent == "file.txt (2).zip")
        #expect(try Data(contentsOf: first) == originalArchive)
        let folder = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [first]))
        #expect(folder.lastPathComponent == "file.txt (2)") // original file.txt exists
        let marker = folder.appendingPathComponent("keep")
        try data.write(to: marker)
        let another = try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [first]))
        #expect(another.lastPathComponent == "file.txt (3)")
        #expect(try Data(contentsOf: marker) == data)
    }

    @Test func concurrentJobsNeverReplaceEachOther() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("same")
        try Data("content".utf8).write(to: source)
        let request = ArchiveRequest(operation: .zip, urls: [source])
        async let first = ArchiveService.perform(request)
        async let second = ArchiveService.perform(request)
        let outputs = try await [first, second]
        #expect(Set(outputs).count == 2)
        #expect(outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func corruptInputFailsAndCleansStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("broken.zip")
        try Data("not an archive".utf8).write(to: source)
        await #expect(throws: (any Error).self) {
            try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [source]))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["broken.zip"])
    }

    @Test(arguments: [ArchiveOperation.zip, .encryptedZip], [false, true])
    func cancelledWorkDoesNotPublishOrLeaveStaging(operation: ArchiveOperation, split: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large")
        // Enough incompressible input to let cancellation interrupt a live child.
        let handle = FileManager.default.createFile(atPath: source.path, contents: nil)
        #expect(handle)
        let file = try FileHandle(forWritingTo: source)
        let chunk = Data((0..<1_048_576).map { _ in UInt8.random(in: .min ... .max) })
        for _ in 0..<32 { try file.write(contentsOf: chunk) }
        try file.close()
        let progress = ArchiveProgress()
        let worker = Task {
            try await ArchiveService.perform(ArchiveRequest(operation: operation, urls: [source], volumeSize: split ? 65_536 : nil),
                                             password: operation.isEncryptedCompression ? "test-password" : nil, progress: progress)
        }
        // 7-Zip can buffer its output until completion. Observe the live child
        // instead of waiting for text that may arrive after the archive is done.
        for _ in 0..<200 {
            if progress.isRunning { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(progress.isRunning)
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["large"])
    }

    @Test func unrelatedDirectoriesAreRejectedBeforeCreatingOutput() async throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let a = first.appendingPathComponent("a")
        let b = second.appendingPathComponent("b")
        try Data().write(to: a)
        try Data().write(to: b)
        await #expect(throws: ArchiveError.self) {
            try await ArchiveService.perform(ArchiveRequest(operation: .zip, urls: [a, b]))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.path) == ["a"])
    }

    @Test(arguments: ["traversal", "symlink", "hardlink"], ["tar", "zip"])
    func maliciousArchivesCannotWriteOutsideExtractionRoot(attack: String, suffix: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("safe".utf8).write(to: sentinel)
        // Both backends detect real content, so use the same adversarial USTAR
        // bytes under each suffix to exercise bsdtar and bundled 7-Zip.
        let source = root.appendingPathComponent("attack." + suffix)
        let entries: [TarEntry]
        switch attack {
        case "symlink":
            entries = [.init(name: "link", type: "2", link: "../../outside"), .init(name: "link/sentinel", body: "overwritten")]
        case "hardlink":
            entries = [.init(name: "link", type: "1", link: "../../outside/sentinel"), .init(name: "link", body: "overwritten")]
        default:
            entries = [.init(name: "../../outside/sentinel", body: "overwritten")]
        }
        try tarFixture(entries).write(to: source)
        if suffix == "tar" {
            await #expect(throws: (any Error).self) {
                try await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [source]))
            }
        } else {
            // 7-Zip may safely sanitize traversal paths instead of rejecting the
            // archive. In either case, nothing outside extraction may change.
            _ = try? await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [source]))
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "safe")
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(names.isSubset(of: ["outside", source.lastPathComponent, "attack"]))
    }

    @Test func absoluteArchivePathsAreConfinedToOutputFolder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = URL(fileURLWithPath: "/tmp/rclick-absolute-\(UUID())")
        defer { try? FileManager.default.removeItem(at: outside) }
        let source = root.appendingPathComponent("absolute.tar")
        try tarFixture([.init(name: outside.path, body: "payload")]).write(to: source)
        // bsdtar strips the leading slash, placing this path inside staging.
        _ = try? await ArchiveService.perform(ArchiveRequest(operation: .extract, urls: [source]))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func compoundArchiveNamesAndCaseAreRecognized() {
        #expect(ArchiveFormat.extractionName(for: URL(fileURLWithPath: "/tmp/中文.TAR.GZ")) == "中文")
        #expect(ArchiveFormat.suffix(for: URL(fileURLWithPath: "/tmp/test.RAR")) == "rar")
        #expect(ArchiveFormat.suffix(for: URL(fileURLWithPath: "/tmp/plain.txt")) == nil)
        for suffix in ["ZIP.001", "7Z.001"] {
            let url = URL(fileURLWithPath: "/tmp/中文." + suffix)
            #expect(ArchiveFormat.suffix(for: url) == suffix.lowercased())
            #expect(ArchiveFormat.extractionName(for: url) == "中文")
            #expect(ArchiveService.usesSevenZip(for: url))
        }
        #expect(ArchiveFormat.suffix(for: URL(fileURLWithPath: "/tmp/test.zip.002")) == nil)
    }

    @Test func encryptedZIPRequiresCorrectPasswordAndUsesAES256() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("secret.txt")
        let contents = Data("private contents".utf8)
        try contents.write(to: source)
        let password = "only-in-memory-test-123"
        let progress = ArchiveProgress()
        let archive = try await ArchiveService.perform(ArchiveRequest(operation: .encryptedZip, urls: [source]), password: password, progress: progress)
        #expect(!progress.detail.contains(password))
        let bytes = try Data(contentsOf: archive)
        // ZIP local header's encryption bit, AES method 99 and the WinZip AES
        // extra field with strength value 3 (AES-256).
        #expect(bytes.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))
        #expect(bytes[6] & 1 == 1)
        #expect(bytes[8] == 99)
        #expect(bytes.range(of: Data([0x01, 0x99, 0x07, 0x00, 0x02, 0x00, 0x41, 0x45, 0x03])) != nil)
        let extract = ArchiveRequest(operation: .extract, urls: [archive])
        await #expect(throws: ArchiveError.passwordRequired) { try await ArchiveService.perform(extract) }
        await #expect(throws: ArchiveError.incorrectPassword) { try await ArchiveService.perform(extract, password: "wrong") }
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == ["secret.txt", "secret.txt.zip"])
        let output = try await ArchiveService.perform(extract, password: password)
        #expect(try Data(contentsOf: output.appendingPathComponent("secret.txt")) == contents)
        #expect(try Data(contentsOf: source) == contents)
    }

    @Test(arguments: ["中文密码", String(repeating: "a", count: 100), "tab\tpassword"])
    func ZIPPasswordRestrictionsAreReportedBeforeLaunching(password: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file")
        try Data().write(to: source)
        await #expect(throws: ArchiveError.invalidZIPPassword) {
            try await ArchiveService.perform(ArchiveRequest(operation: .encryptedZip, urls: [source]), password: password)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file"])
    }

    @Test(arguments: Array(EncryptedRARFixtures.archives.keys).sorted())
    func encryptedRAR4AndRAR5SupportSolidDataAndEncryptedHeaders(name: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent(name)
        try #require(EncryptedRARFixtures.archives[name]).write(to: archive)
        let request = ArchiveRequest(operation: .extract, urls: [archive])
        await #expect(throws: ArchiveError.passwordRequired) { try await ArchiveService.perform(request) }
        await #expect(throws: ArchiveError.incorrectPassword) { try await ArchiveService.perform(request, password: "wrong") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [name])
        let output = try await ArchiveService.perform(request, password: "password")
        for file in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            #expect(try String(contentsOf: output.appendingPathComponent(file), encoding: .utf8) == "This is from " + file)
        }
    }

    @Test(arguments: ["", "line\nbreak", "line\rbreak", "null\0byte", String(repeating: "a", count: 1_025)])
    func invalidPasswordsNeverCreateUnencryptedOutput(password: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file")
        try Data("data".utf8).write(to: source)
        await #expect(throws: ArchiveError.invalidPassword) {
            try await ArchiveService.perform(ArchiveRequest(operation: .encryptedZip, urls: [source]), password: password)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file"])
    }

    @Test func missingPasswordAndUnsupportedEncryptionAreRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file")
        try Data().write(to: source)
        await #expect(throws: ArchiveError.passwordRequired) {
            try await ArchiveService.perform(ArchiveRequest(operation: .encryptedZip, urls: [source]))
        }
        await #expect(throws: ArchiveError.encryptionNotSupported) {
            try await ArchiveService.perform(ArchiveRequest(operation: .tarGzip, urls: [source]), password: "test")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["file"])
    }

    @Test(arguments: [false, true])
    func encrypted7zExtractsWithAndWithoutEncryptedHeaders(headerEncryption: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("data.txt")
        try Data("encrypted 7z content".utf8).write(to: source)
        let archive = root.appendingPathComponent("encrypted.7z")
        let password = "7z-中文-password"
        try make7zFixture(source: source, archive: archive, password: password, headerEncryption: headerEncryption)
        let request = ArchiveRequest(operation: .extract, urls: [archive])
        await #expect(throws: ArchiveError.passwordRequired) { try await ArchiveService.perform(request) }
        await #expect(throws: ArchiveError.incorrectPassword) { try await ArchiveService.perform(request, password: "wrong") }
        let output = try await ArchiveService.perform(request, password: password)
        #expect(try Data(contentsOf: output.appendingPathComponent("data.txt")) == Data(contentsOf: source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".rclick-archive-") })
    }

    @Test func legacyZipCryptoArchivesAreCompatible() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy.txt")
        try Data("legacy encrypted ZIP".utf8).write(to: source)
        let archive = root.appendingPathComponent("legacy.zip")
        // Independent producer: this is a public fixture password, not a user
        // credential. Production code always transmits credentials over stdin.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", "-P", "test-password", archive.path, source.lastPathComponent]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let request = ArchiveRequest(operation: .extract, urls: [archive])
        await #expect(throws: ArchiveError.passwordRequired) { try await ArchiveService.perform(request) }
        await #expect(throws: ArchiveError.incorrectPassword) { try await ArchiveService.perform(request, password: "wrong") }
        let output = try await ArchiveService.perform(request, password: "test-password")
        #expect(try Data(contentsOf: output.appendingPathComponent("legacy.txt")) == Data(contentsOf: source))
    }

    private func make7zFixture(source: URL, archive: URL, password: String, headerEncryption: Bool) throws {
        let process = Process()
        process.executableURL = try ArchiveService.sevenZipURL()
        process.arguments = ["a", "-t7z", "-p", "-mhe=" + (headerEncryption ? "on" : "off"), "-mx=1", "-mmt=1", "-md=1m", archive.path, "--", source.path]
        let input = Pipe()
        try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
        try input.fileHandleForWriting.close()
        process.standardInput = input.fileHandleForReading
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try input.fileHandleForReading.close()
        #expect(process.terminationStatus == 0)
    }

    /// Minimal independent USTAR fixtures, including entry types that normal
    /// compression tools deliberately refuse to create from unsafe paths.
    private struct TarEntry {
        let name: String
        var type = "0"
        var link = ""
        var body = ""
    }

    private func tarFixture(_ entries: [TarEntry]) -> Data {
        var archive = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ string: String, at offset: Int, count: Int) {
                for (index, byte) in string.utf8.prefix(count).enumerated() { header[offset + index] = byte }
            }
            let body = Data(entry.body.utf8)
            put(entry.name, at: 0, count: 100)
            put("0000644\0", at: 100, count: 8)
            put("0000000\0", at: 108, count: 8)
            put("0000000\0", at: 116, count: 8)
            put(String(format: "%011o", body.count), at: 124, count: 11)
            put("00000000000", at: 136, count: 11)
            put("        ", at: 148, count: 8)
            put(entry.type, at: 156, count: 1)
            put(entry.link, at: 157, count: 100)
            put("ustar\0", at: 257, count: 6)
            put("00", at: 263, count: 2)
            put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", at: 148, count: 8)
            archive.append(contentsOf: header)
            archive.append(body)
            archive.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
        }
        archive.append(Data(repeating: 0, count: 1_024))
        return archive
    }
}
