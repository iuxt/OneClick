import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct ArchiveAssociationFormat: Identifiable, Sendable {
    let id: String
    let typeID: String
    static let all: [Self] = [
        Self(id: "ZIP", typeID: "public.zip-archive"),
        Self(id: "7Z", typeID: "org.7-zip.7-zip-archive"),
        Self(id: "RAR", typeID: "com.rarlab.rar-archive"),
        Self(id: "TAR", typeID: "public.tar-archive"),
        Self(id: "TGZ", typeID: "org.gnu.gnu-zip-tar-archive"),
    ]

    @concurrent
    static func associatedFormats(bundleID: String) async -> Set<String> {
        Set(all.filter { format in
            guard let handler = LSCopyDefaultRoleHandlerForContentType(format.typeID as CFString, .viewer)?.takeRetainedValue() else { return false }
            return (handler as String).caseInsensitiveCompare(bundleID) == .orderedSame
        }.map(\.id))
    }
}

@available(macOS 27, *)
struct ArchiveAssociationView: View {
    @Environment(\.isSettingsPageActive) private var isActive
    @State private var selected: Set<String> = ["ZIP", "7Z", "RAR"]
    @State private var associated: Set<String> = []
    @State private var associating = false
    @State private var result: String?

    var body: some View {
        SettingsSection(
            title: "Archive Formats",
            footer: "Choose formats to open with OneClick by default. Double-clicking an associated archive opens the file browser and preview window."
        ) {
            Button(AppLocalization.localized("Associate Selected Formats"), systemImage: "link") { associate() }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || associating)
        } content: {
            ForEach(ArchiveAssociationFormat.all) { format in
                SettingsRow {
                    Toggle(format.id, isOn: Binding(
                        get: { selected.contains(format.id) },
                        set: { if $0 { selected.insert(format.id) } else { selected.remove(format.id) } }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(associating)
                    Spacer()
                    if associated.contains(format.id) {
                        Label(AppLocalization.localized("Associated"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if associating {
                SettingsRow {
                    ProgressView().controlSize(.small)
                    Text(appLocalized: "Working on settings…")
                }
            }
            if let result {
                SettingsRow { Text(result).font(.callout).textSelection(.enabled) }
            }
        }
        .task(id: isActive) {
            if isActive { await refresh() }
        }
    }

    private func refresh() async {
        let formats = await ArchiveAssociationFormat.associatedFormats(bundleID: Bundle.main.bundleIdentifier ?? "")
        guard !Task.isCancelled else { return }
        associated = formats
    }

    private func associate() {
        associating = true
        result = nil
        let formats = selected
        Task {
            var failures: [String] = []
            var updated: Set<String> = []
            for format in ArchiveAssociationFormat.all where formats.contains(format.id) {
                guard let type = UTType(format.typeID) else { failures.append(format.id); continue }
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
                    updated.insert(format.id)
                }
                catch { failures.append(format.id + ": " + error.localizedDescription) }
            }
            await refresh()
            // An accepted request is not sufficient: verify the effective handler.
            failures += updated.subtracting(associated).sorted()
            associating = false
            result = failures.isEmpty ? AppLocalization.localized("File associations updated.")
                : AppLocalization.localized("Some file associations could not be updated:") + "\n" + failures.joined(separator: "\n")
        }
    }
}
