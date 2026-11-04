import SwiftUI
import UniformTypeIdentifiers

@available(macOS 27, *)
struct AddApplicationSheetView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var applications: [InstalledApplication] = []
    @State private var isLoading = true
    @State private var search = ""
    @State private var selection: URL?
    @State private var browsing = false

    private var addedPaths: Set<String> {
        Set(appState.apps.map { $0.url.standardizedFileURL.path })
    }

    private var filteredApplications: [InstalledApplication] {
        applications.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    private var canAddSelection: Bool {
        guard let selection else { return false }
        return filteredApplications.contains { $0.url == selection } && !addedPaths.contains(selection.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(appLocalized: "Add App")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 12)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(AppLocalization.localized("Search Apps"), text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            Divider()
            List(selection: $selection) {
                ForEach(filteredApplications) { application in
                    HStack(spacing: 10) {
                        SettingsIcon(source: .application(application.url))
                            .frame(width: 24, height: 24)
                        Text(application.name).lineLimit(1)
                        Spacer()
                        if addedPaths.contains(application.url.path) {
                            Text(appLocalized: "Added").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(application.url)
                }
            }
            .listStyle(.inset)
            .overlay {
                if isLoading {
                    ProgressView()
                } else if filteredApplications.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            Divider()
            HStack {
                Button(AppLocalization.localized("Browse…")) { browsing = true }
                Spacer()
                Button(AppLocalization.localized("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.localized("Add")) {
                    if let selection { add(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAddSelection)
            }
            .padding(16)
        }
        .frame(width: 520, height: 460)
        .task {
            let loaded = await InstalledApplication.discover()
            guard !Task.isCancelled else { return }
            applications = loaded
            isLoading = false
        }
        .fileImporter(isPresented: $browsing, allowedContentTypes: [.application]) { result in
            if case .success(let url) = result { add(url) }
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
        .fileDialogCustomizationID("OneClick.AddApplication")
    }

    private func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        if !addedPaths.contains(path) { appState.addApp(item: OpenWithApp(appURL: url)) }
        dismiss()
    }
}
