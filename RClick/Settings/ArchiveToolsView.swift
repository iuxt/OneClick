import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveLaunchControls: View {
    @State private var choosingArchive = false
    @State private var choosingFiles = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 12) {
            Button(AppLocalization.localized("Open Archive…"), systemImage: "archivebox") { choosingArchive = true }
                .buttonStyle(.borderedProminent)
            Button(AppLocalization.localized("Create Archive"), systemImage: "plus") { choosingFiles = true }
        }
        .controlSize(.large)
        .fileImporter(isPresented: $choosingArchive, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls { ArchiveBrowserPresenter.shared.open(url) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await RCRuntime.shared.actionService.showArchives(urls.map(\.path), operation: .compress) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .alert(AppLocalization.localized("Archives"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(AppLocalization.localized("OK"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

nonisolated struct ArchiveAssociationFormat: Identifiable {
    let id: String
    let typeID: String
    static let all: [Self] = [
        Self(id: "ZIP", typeID: "public.zip-archive"),
        Self(id: "7Z", typeID: "org.7-zip.7-zip-archive"),
        Self(id: "RAR", typeID: "com.rarlab.rar-archive"),
        Self(id: "TAR", typeID: "public.tar-archive"),
        Self(id: "TGZ", typeID: "org.gnu.gnu-zip-tar-archive"),
    ]
}

struct ArchiveAssociationView: View {
    @State private var selected: Set<String> = ["ZIP", "7Z", "RAR"]
    @State private var associated: Set<String> = []
    @State private var associating = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                ForEach(ArchiveAssociationFormat.all) { format in
                    Toggle(format.id, isOn: Binding(
                        get: { selected.contains(format.id) },
                        set: { if $0 { selected.insert(format.id) } else { selected.remove(format.id) } }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            Text(appLocalized: "Choose formats to open with RClick by default. Double-clicking an associated archive opens the file browser and preview window.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(AppLocalization.localized("Associate Selected Formats"), systemImage: "link") { associate() }
                    .disabled(selected.isEmpty || associating)
                if associating { ProgressView().controlSize(.small) }
                Spacer()
                if !associated.isEmpty {
                    Text(AppLocalization.localized("Associated") + ": " + associated.sorted().joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result { Text(result).font(.caption).textSelection(.enabled) }
        }
        .task { refresh() }
    }

    private func refresh() {
        associated = Set(ArchiveAssociationFormat.all.filter { format in
            guard let handler = LSCopyDefaultRoleHandlerForContentType(format.typeID as CFString, .viewer)?.takeRetainedValue() else { return false }
            return (handler as String).caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") == .orderedSame
        }.map(\.id))
    }

    private func associate() {
        associating = true
        result = nil
        Task {
            var failures: [String] = []
            for format in ArchiveAssociationFormat.all where selected.contains(format.id) {
                guard let type = UTType(format.typeID) else { failures.append(format.id); continue }
                do { try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) }
                catch { failures.append(format.id + ": " + error.localizedDescription) }
            }
            refresh()
            associating = false
            result = failures.isEmpty ? AppLocalization.localized("File associations updated.")
                : AppLocalization.localized("Some file associations could not be updated:") + "\n" + failures.joined(separator: "\n")
        }
    }
}
