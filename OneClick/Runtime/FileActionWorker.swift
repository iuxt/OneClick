import Foundation

/// Only values cross the actor boundary; operation UI and Finder stay on main.
nonisolated enum FileActionWorker {
    struct Failure: Sendable {
        let url: URL
        let message: String
    }

    enum AccessDirectory: Sendable {
        case parent, resolvedParent, directory, fileOrDirectory
    }

    struct Target: Sendable {
        let url: URL
        let directory: URL
        let isProtected: Bool
        let exists: Bool
        let isDirectory: Bool
    }

    @concurrent
    static func inspect(_ paths: [String], access: AccessDirectory = .parent,
                        checkProtection: Bool = false, readFileType: Bool = false) async -> [Target] {
        let protected = checkProtection ? Utils.protectedPaths() : []
        var directories: [URL: URL] = [:]
        return paths.map { path in
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            let exists = readFileType || access == .fileOrDirectory
                ? FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) : false
            let resolved = access == .resolvedParent ? url.resolvingSymlinksInPath() : url
            let directory: URL
            switch access {
            case .parent: directory = url.deletingLastPathComponent()
            case .resolvedParent: directory = resolved.deletingLastPathComponent()
            case .directory: directory = url
            case .fileOrDirectory: directory = exists && isDirectory.boolValue ? url : url.deletingLastPathComponent()
            }
            let canonical = directories[directory] ?? directory.resolvingSymlinksInPath()
            directories[directory] = canonical
            return Target(url: url, directory: canonical,
                          isProtected: checkProtection && protected.contains(url.standardizedFileURL.resolvingSymlinksInPath().pathComponents),
                          exists: exists, isDirectory: isDirectory.boolValue)
        }
    }

    @concurrent
    static func resolveDirectory(_ url: URL) async -> URL {
        url.resolvingSymlinksInPath()
    }

    @concurrent
    static func openTargets(appPath: String, explicit: Bool?, paths: [String]) async -> [Target] {
        let urls = AppPresets.resolveOpenTargets(appPath: appPath, explicit: explicit, targetPaths: paths).map(\.url)
        return await inspect(urls.map(\.path), access: .fileOrDirectory)
    }

    @concurrent
    static func importTemplate(from source: URL, into root: URL, existing: URL? = nil) async throws -> URL {
        try Task.checkCancellation()
        if source.standardizedFileURL == existing?.standardizedFileURL { return source }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        try Task.checkCancellation()
        completed = true
        return destination
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
        let protected = Utils.protectedPaths()
        for url in urls {
            do {
                let targets = contentsOfDirectories
                    ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    : [url]
                for var target in targets where !protected.contains(target.standardizedFileURL.resolvingSymlinksInPath().pathComponents) {
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
        let ext = try FileCreationPolicy.normalizedExtension(ext)
        let template = template ?? FileCreationPolicy.builtInTemplate(for: ext)
        if template == nil && FileCreationPolicy.requiresTemplate(ext) {
            throw FileCreationPolicy.Failure.missingBuiltInTemplate
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
