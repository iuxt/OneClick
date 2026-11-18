import SwiftUI
import UniformTypeIdentifiers

struct CommonDirsSettingTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var choosingFolder = false
    @State private var folderError: String?

    var body: some View {
        SettingsSection {
            SettingsRow {
                SettingsSwitch("Enable common folders", isOn: $appState.showCommonDirs)
                    .onChange(of: appState.showCommonDirs) { updateMenu() }
            }
            SettingsRow {
                SettingsSwitch("Collapse common folders menu", isOn: $appState.foldCommonDirMenu)
                    .disabled(!appState.showCommonDirs)
                    .onChange(of: appState.foldCommonDirMenu) { updateMenu() }
            }
        }

        SettingsCollection(
            title: "Added Folders",
            items: appState.cdirs,
            emptyTitle: "No Folders Added",
            emptyIcon: "folder",
            move: { source, destination in
                appState.cdirs.move(fromOffsets: source, toOffset: destination)
                appState.sync()
            }
        ) {
            Button(AppLocalization.localized("Add Folder"), systemImage: "plus") { choosingFolder = true }
                .buttonStyle(.borderedProminent)
        } row: { folder, reordering in
            SettingsItemLabel(title: folder.displayName, detail: folder.url.path) {
                Image(systemName: folder.icon.isEmpty ? "folder" : folder.icon)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !reordering {
                SettingsIconButton(title: "Remove Folder", symbol: "trash", subject: folder.displayName) {
                    appState.cdirs.removeAll { $0.id == folder.id }
                    appState.sync()
                }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.directory]) { result in
            switch result {
            case .success(let url):
                let folderURL = url.standardizedFileURL
                guard !appState.cdirs.contains(where: { $0.url.standardizedFileURL == folderURL }) else {
                    folderError = AppLocalization.localized("This folder has already been added.")
                    return
                }
                appState.cdirs.append(CommonDir(
                    id: UUID().uuidString, name: folderURL.lastPathComponent, url: folderURL, icon: iconForDirectory(url: folderURL)
                ))
                appState.sync()
            case .failure(let error):
                folderError = error.localizedDescription
            }
        }
        .alert(Text(appLocalized: "Add Folder"), isPresented: Binding(
            get: { folderError != nil }, set: { if !$0 { folderError = nil } }
        )) {
            Button(AppLocalization.localized("OK"), role: .cancel) { folderError = nil }
        } message: { Text(folderError ?? "") }
    }

    private func updateMenu() {
        NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
    }
}
