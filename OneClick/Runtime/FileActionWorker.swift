import Foundation

/// Only values cross the actor boundary; permission prompts and Finder stay on main.
nonisolated enum FileActionWorker {
    struct Failure: Sendable {
        let url: URL
        let message: String
    }

    @concurrent
    static func targetDirectory(_ paths: [String]) async -> String? {
        guard let path = paths.first else { return nil }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        return path
    }

    @concurrent
    static func remove(_ paths: [String]) async -> [Failure] {
        var failures: [Failure] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            do { try FileManager.default.removeItem(at: url) }
            catch { failures.append(Failure(url: url, message: error.localizedDescription)) }
        }
        return failures
    }

    @concurrent
    static func setHidden(_ hidden: Bool, urls: [URL], contentsOfDirectories: Bool) async -> [Failure] {
        var failures: [Failure] = []
        for url in urls {
            do {
                let targets = contentsOfDirectories
                    ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    : [url]
                for var target in targets where !Utils.isProtectedFolder(target.path) {
                    do {
                        var values = URLResourceValues()
                        values.isHidden = hidden
                        try target.setResourceValues(values)
                    } catch { failures.append(Failure(url: target, message: error.localizedDescription)) }
                }
            } catch { failures.append(Failure(url: url, message: error.localizedDescription)) }
        }
        return failures
    }

    @concurrent
    static func create(in directory: URL, extension ext: String, template: URL?, baseName: String) async throws -> URL {
        // Reject separators rather than accidentally creating files outside the chosen folder.
        guard !ext.contains("/"), !ext.contains("\\"), !ext.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        for counter in 0..<100_000 {
            let name = baseName + (counter == 0 ? "" : String(counter)) + ext
            let destination = directory.appendingPathComponent(name)
            do {
                if let template {
                    try FileManager.default.copyItem(at: template, to: destination)
                } else {
                    try Data().write(to: destination, options: .withoutOverwriting)
                }
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
