import CryptoKit
import Foundation

nonisolated enum ChecksumAlgorithm: String, CaseIterable, Sendable {
    case md5 = "MD5"
    case sha1 = "SHA1"
    case sha256 = "SHA256"
}

nonisolated struct ChecksumInput: Sendable {
    let url: URL
    var error: String? = nil
}

nonisolated struct ChecksumUpdate: Sendable {
    let index: Int
    var fraction: Double = 0
    var digest: String? = nil
    var error: String? = nil
}

nonisolated enum ChecksumError: LocalizedError {
    case notRegularFile, fileChanged

    var errorDescription: String? {
        switch self {
        case .notRegularFile: AppLocalization.localized("Only regular files can be checksummed.")
        case .fileChanged: AppLocalization.localized("The file changed during calculation. Please try again.")
        }
    }
}

/// Standard digests require ordered bytes within each algorithm. Parallelize
/// independent (file, algorithm) jobs instead of combining incompatible chunk
/// hashes. Each worker streams 1 MiB at a time; concurrency and memory are bounded.
nonisolated enum ChecksumService {
    static let chunkSize = 1_048_576
    static var workerLimit: Int { max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8)) }

    @concurrent
    static func calculate(
        inputs: [ChecksumInput],
        maxConcurrentJobs: Int = workerLimit,
        onUpdate: @escaping @MainActor @Sendable (ChecksumUpdate) -> Void
    ) async {
        let algorithms = ChecksumAlgorithm.allCases
        let count = inputs.count * algorithms.count
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let input = inputs[index / algorithms.count]
                let algorithm = algorithms[index % algorithms.count]
                group.addTask {
                    await calculateJob(input: input, algorithm: algorithm, index: index, onUpdate: onUpdate)
                }
            }
            let limit = min(count, max(1, maxConcurrentJobs))
            for _ in 0..<limit {
                guard !Task.isCancelled else { break }
                enqueue(next)
                next += 1
            }
            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if next < count {
                    enqueue(next)
                    next += 1
                }
            }
        }
    }

    @concurrent
    private static func calculateJob(
        input: ChecksumInput, algorithm: ChecksumAlgorithm, index: Int,
        onUpdate: @escaping @MainActor @Sendable (ChecksumUpdate) -> Void
    ) async {
        do {
            try Task.checkCancellation()
            if let error = input.error {
                await onUpdate(ChecksumUpdate(index: index, fraction: 1, error: error))
                return
            }
            await onUpdate(ChecksumUpdate(index: index))
            let digest: String
            switch algorithm {
            case .md5:
                digest = try await hash(input.url, using: Insecure.MD5.self, index: index, onUpdate: onUpdate)
            case .sha1:
                digest = try await hash(input.url, using: Insecure.SHA1.self, index: index, onUpdate: onUpdate)
            case .sha256:
                digest = try await hash(input.url, using: SHA256.self, index: index, onUpdate: onUpdate)
            }
            try Task.checkCancellation()
            await onUpdate(ChecksumUpdate(index: index, fraction: 1, digest: digest))
        } catch is CancellationError {
            // The owner marks unfinished rows as cancelled, preserving results.
        } catch {
            await onUpdate(ChecksumUpdate(index: index, fraction: 1, error: error.localizedDescription))
        }
    }

    @concurrent
    private static func hash<H: HashFunction>(
        _ url: URL, using: H.Type, index: Int,
        onUpdate: @escaping @MainActor @Sendable (ChecksumUpdate) -> Void
    ) async throws -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        let before = try url.resourceValues(forKeys: keys)
        // Reject directories and special files before opening (a FIFO can block).
        guard before.isRegularFile == true else { throw ChecksumError.notRegularFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = H()
        var bytesRead: Int64 = 0
        let size = Int64(before.fileSize ?? 0)
        var lastUpdate = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            let data = try autoreleasepool { try handle.read(upToCount: chunkSize) ?? Data() }
            if data.isEmpty { break }
            hasher.update(data: data)
            bytesRead += Int64(data.count)
            if lastUpdate.duration(to: .now) >= .milliseconds(100) {
                let fraction = size > 0 ? min(0.99, Double(bytesRead) / Double(size)) : 0
                await onUpdate(ChecksumUpdate(index: index, fraction: fraction))
                lastUpdate = .now
            }
        }
        try Task.checkCancellation()
        // Re-read uncached metadata: don't display a digest for a file that was
        // modified or replaced while streaming it.
        let after = try URL(fileURLWithPath: url.path).resourceValues(forKeys: keys)
        guard before.fileSize == after.fileSize,
              before.contentModificationDate == after.contentModificationDate,
              (before.fileResourceIdentifier as? NSObject) == (after.fileResourceIdentifier as? NSObject),
              bytesRead == size else { throw ChecksumError.fileChanged }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
