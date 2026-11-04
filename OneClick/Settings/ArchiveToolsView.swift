import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 27, *)
struct ArchiveLaunchControls: View {
    enum Presentation { case inline, toolbar }
    var presentation: Presentation = .inline

    @State private var choosingArchive = false
    @State private var choosingFiles = false
    @State private var error: String?

    var body: some View {
        Group {
            if presentation == .toolbar {
                Menu {
                    // Text-only items keep the native menu quiet and easy to scan.
                    Button(AppLocalization.localized("Open Archive…")) { choosingArchive = true }
                    Button(AppLocalization.localized("Create Archive")) { choosingFiles = true }
                } label: {
                    Label(AppLocalization.localized("Archive Tools"), systemImage: "archivebox")
                }
                .help(AppLocalization.localized("Archive Tools"))
            } else {
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button(AppLocalization.localized("Open Archive…"), systemImage: "archivebox") { choosingArchive = true }
                            .buttonStyle(.glassProminent)
                        Button(AppLocalization.localized("Create Archive"), systemImage: "plus") { choosingFiles = true }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.large)
                }
            }
        }
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
            Text(appLocalized: "Choose formats to open with OneClick by default. Double-clicking an associated archive opens the file browser and preview window.")
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
        .task { await refresh() }
    }

    private func refresh() async {
        let formats = await ArchiveAssociationFormat.associatedFormats(bundleID: Bundle.main.bundleIdentifier ?? "")
        guard !Task.isCancelled else { return }
        associated = formats
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
            await refresh()
            associating = false
            result = failures.isEmpty ? AppLocalization.localized("File associations updated.")
                : AppLocalization.localized("Some file associations could not be updated:") + "\n" + failures.joined(separator: "\n")
        }
    }
}
