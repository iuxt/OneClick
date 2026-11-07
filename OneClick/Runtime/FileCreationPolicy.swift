import Foundation

nonisolated enum FileCreationPolicy {
    enum Failure: LocalizedError {
        case missingBuiltInTemplate
        var errorDescription: String? {
            AppLocalization.localized("The built-in template is missing. Reinstall OneClick and try again.")
        }
    }

    static func normalizedExtension(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("/"), !value.contains("\\"), !value.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if value.isEmpty { return "" }
        let suffix = String(value.drop(while: { $0 == "." }))
        guard !suffix.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        return "." + suffix
    }

    static func requiresTemplate(_ ext: String) -> Bool {
        [".docx", ".pptx", ".xlsx", ".pages", ".key", ".numbers"].contains(ext.lowercased())
    }

    /// Templates are ordinary bundle resources, not asset-catalog data sets.
    static func builtInTemplate(for ext: String, bundle: Bundle = .main) -> URL? {
        guard let normalized = try? normalizedExtension(ext), requiresTemplate(normalized) else { return nil }
        return bundle.url(forResource: "template", withExtension: String(normalized.dropFirst()).lowercased())
    }
}
