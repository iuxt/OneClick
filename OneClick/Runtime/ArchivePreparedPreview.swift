import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ArchivePreparedPreview: Sendable {
    let directory: URL
    let file: URL
    let text: String?
    let image: CGImage?

    @concurrent
    static func prepare(_ url: URL, entry: ArchiveEntry, password: String?) async throws -> Self {
        let data = try await ArchiveBrowserService.preview(url, entry: entry, password: password)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneclick-preview-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        let ext = (entry.name as NSString).pathExtension
        let safeExtension = ext.count <= 20 && ext.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) ? ext : ""
        let file = directory.appendingPathComponent("Preview" + (safeExtension.isEmpty ? "" : "." + safeExtension))
        try data.write(to: file, options: .atomic)
        try Task.checkCancellation()
        let type = UTType(filenameExtension: safeExtension)
        var image: CGImage?
        if type?.conforms(to: .image) == true,
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_600,
            ] as CFDictionary)
        }
        var text: String?
        if data.count <= 2 * 1_024 * 1_024,
           type?.conforms(to: .text) == true || ["md", "json", "yaml", "yml", "swift", "js", "ts", "py", "sh", "log", "csv", "xml", "toml"].contains(safeExtension.lowercased()) {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        }
        try Task.checkCancellation()
        completed = true
        return Self(directory: directory, file: file, text: text, image: image)
    }

    @concurrent
    static func removeDirectory(_ directory: URL) async {
        try? FileManager.default.removeItem(at: directory)
    }
}
