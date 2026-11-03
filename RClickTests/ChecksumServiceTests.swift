import CryptoKit
import Foundation
import Testing
@testable import RClick

@MainActor
struct ChecksumServiceTests {
    private func withFile(_ data: Data, body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-\(UUID())-%20.bin")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    @Test func standardKnownVectors() async throws {
        let vectors: [(Data, [String])] = [
            (Data(), [
                "d41d8cd98f00b204e9800998ecf8427e",
                "da39a3ee5e6b4b0d3255bfef95601890afd80709",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            ]),
            (Data("abc".utf8), [
                "900150983cd24fb0d6963f7d28e17f72",
                "a9993e364706816aba3e25717850c26c9cd0d89d",
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            ])
        ]
        for (data, expected) in vectors {
            try await withFile(data) { url in
                var completed: [Int: String] = [:]
                await ChecksumService.calculate(inputs: [ChecksumInput(url: url)]) { update in
                    #expect(update.error == nil)
                    if let digest = update.digest { completed[update.index] = digest }
                }
                #expect((0..<3).compactMap { completed[$0] } == expected)
            }
        }
    }

    @Test func streamingAcrossChunksAndMultipleFilesKeepsResultsOrdered() async throws {
        let data = Data((0..<(ChecksumService.chunkSize * 2 + 73)).map { UInt8($0 % 251) })
        let expected = [
            Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        ]
        try await withFile(data) { url in
            var completed: [Int: String] = [:]
            var active: Set<Int> = []
            var peak = 0
            await ChecksumService.calculate(inputs: [ChecksumInput(url: url), ChecksumInput(url: url)], maxConcurrentJobs: 2) { update in
                if let digest = update.digest {
                    completed[update.index] = digest
                    active.remove(update.index)
                } else {
                    active.insert(update.index)
                    peak = max(peak, active.count)
                }
                #expect(update.error == nil)
            }
            #expect((0..<6).compactMap { completed[$0] } == expected + expected)
            #expect(peak == 2)
        }
    }

    @Test func invalidFilesAndDeniedAccessDoNotAbortOtherFiles() async throws {
        try await withFile(Data("abc".utf8)) { url in
            let missing = url.appendingPathExtension("missing")
            let inputs = [
                ChecksumInput(url: missing),
                ChecksumInput(url: url, error: "denied"),
                ChecksumInput(url: FileManager.default.temporaryDirectory),
                ChecksumInput(url: url)
            ]
            var results: [Int: ChecksumUpdate] = [:]
            await ChecksumService.calculate(inputs: inputs) { update in
                if update.fraction == 1 { results[update.index] = update }
            }
            #expect(results.count == 12)
            #expect((0..<9).allSatisfy { results[$0]?.error != nil && results[$0]?.digest == nil })
            #expect((3..<6).allSatisfy { results[$0]?.error == "denied" })
            #expect((9..<12).allSatisfy { results[$0]?.digest != nil })
        }
    }

    @Test func cancelledBatchDoesNotStartWork() async throws {
        try await withFile(Data("abc".utf8)) { url in
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await ChecksumService.calculate(inputs: [ChecksumInput(url: url)]) { _ in
                    Issue.record("Cancelled batch should not emit results")
                }
            }
            await task.value
        }
    }

    @Test func cancellingRunningBatchStopsWorkersBeforePublishingDigests() async throws {
        try await withFile(Data(repeating: 0x61, count: ChecksumService.chunkSize * 4)) { url in
            var running: Task<Void, Never>?
            var started = false
            running = Task {
                await ChecksumService.calculate(inputs: [ChecksumInput(url: url)]) { update in
                    started = true
                    #expect(update.digest == nil)
                    running?.cancel()
                }
            }
            await running?.value
            #expect(started)
        }
    }
}
