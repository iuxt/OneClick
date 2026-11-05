import Foundation

nonisolated enum FileCreationPolicy {
    enum Failure: LocalizedError {
        case templateRequired
        var errorDescription: String? {
            AppLocalization.localized("This file type requires a template. Choose a valid template in New File settings.")
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
}
