import SwiftUI

struct NewFileSettingsTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editingFile: NewFile?
    @State private var fileToDelete: NewFile?
    @State private var confirmingRestore = false

    var body: some View {
        SettingsSection {
            SettingsRow {
                SettingsSwitch("Collapse new file menu", isOn: $appState.foldNewFileMenu)
                    .onChange(of: appState.foldNewFileMenu) {
                        NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                    }
            }
        }

        SettingsCollection(
            title: "File Types",
            items: appState.newFiles,
            emptyTitle: "No File Types",
            emptyIcon: "doc",
            move: appState.moveNewFiles(from:to:)
        ) {
            Button(AppLocalization.localized("Restore Defaults")) { confirmingRestore = true }
            Button(AppLocalization.localized("Add File Type"), systemImage: "plus") {
                editingFile = NewFile(ext: "", name: "", idx: appState.newFiles.count)
            }
            .buttonStyle(.borderedProminent)
        } row: { file, reordering in
            SettingsItemLabel(title: file.displayName, detail: file.ext) {
                SettingsIcon(source: file.openApp.map { .application($0) } ?? .fileType(file.ext, fallback: file.icon))
            }
            Spacer(minLength: 8)
            if !reordering {
                SettingsIconButton(title: "Edit File Type", symbol: "pencil", subject: file.displayName) { editingFile = file }
                SettingsIconButton(title: "Delete File Type", symbol: "trash", subject: file.displayName) { fileToDelete = file }
                Toggle(file.displayName, isOn: Binding(
                    get: { appState.getFileType(rid: file.id)?.enabled ?? file.enabled },
                    set: { enabled in
                        guard let index = appState.newFiles.firstIndex(where: { $0.id == file.id }) else { return }
                        appState.newFiles[index].enabled = enabled
                        appState.sync()
                    }
                ))
                .labelsHidden()
            }
        }
        .sheet(item: $editingFile) { EditFileTypeSheetView(file: $0, appState: appState) }
        .alert(
            Text(appLocalized: "Restore Default File Types?"),
            isPresented: $confirmingRestore
        ) {
            Button(AppLocalization.localized("Restore Defaults"), role: .destructive) {
                appState.resetFiletypeItems()
            }
            Button(AppLocalization.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(appLocalized: "This replaces all file types with the defaults, removing custom types and resetting names, templates, icons, app choices and enabled states. This cannot be undone.")
        }
        .alert(
            Text(appLocalized: "Delete File Type"),
            isPresented: Binding(
                get: { fileToDelete != nil },
                set: { if !$0 { fileToDelete = nil } }
            ),
            presenting: fileToDelete
        ) { file in
            Button(AppLocalization.localized("Delete"), role: .destructive) {
                appState.deleteNewFile(id: file.id)
            }
            Button(AppLocalization.localized("Cancel"), role: .cancel) {
                fileToDelete = nil
            }
        } message: { file in
            Text(String(format: AppLocalization.localized("Are you sure you want to delete \"%@\" (%@)? This action cannot be undone."), file.displayName, file.ext))
        }
    }
}
