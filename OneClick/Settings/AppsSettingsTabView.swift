import SwiftUI

struct AppsSettingsTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingPicker = false
    @State private var editingApp: OpenWithApp?
    @State private var appToDelete: OpenWithApp?

    var body: some View {
        SettingsCollection(
            title: "Added Apps",
            items: appState.apps,
            emptyTitle: "No Apps Added",
            emptyIcon: "app",
            move: appState.moveApps(from:to:)
        ) {
            Button(AppLocalization.localized("Add App"), systemImage: "plus") { showingPicker = true }
                .buttonStyle(.borderedProminent)
        } row: { app, reordering in
            SettingsItemLabel(title: app.name, detail: placement(for: app)) {
                SettingsIcon(source: .application(app.url))
            }
            Spacer(minLength: 8)
            if !reordering {
                Menu(AppLocalization.localized("Show In")) {
                    Toggle(AppLocalization.localized("Toolbar"), isOn: visibility(app, \.showInToolbar))
                    Toggle(AppLocalization.localized("Context Menu"), isOn: visibility(app, \.showInContextMenu))
                }
                .fixedSize()
                .accessibilityLabel(app.name + " · " + AppLocalization.localized("Show In"))

                SettingsIconButton(title: "Edit App", symbol: "pencil", subject: app.name) { editingApp = app }
                SettingsIconButton(title: "Delete App", symbol: "trash", subject: app.name) { appToDelete = app }
            }
        }
        .sheet(isPresented: $showingPicker) { AddApplicationSheetView(appState: appState) }
        .sheet(item: $editingApp) { EditAppSheetView(app: $0, appState: appState) }
        .alert(Text(appLocalized: "Delete App"), isPresented: Binding(
            get: { appToDelete != nil },
            set: { if !$0 { appToDelete = nil } }
        ), presenting: appToDelete) { app in
            Button(AppLocalization.localized("Cancel"), role: .cancel) {}
            Button(AppLocalization.localized("Delete"), role: .destructive) {
                guard let index = appState.apps.firstIndex(where: { $0.id == app.id }) else { return }
                appState.deleteApp(index: index)
            }
        } message: { app in
            Text(String(format: AppLocalization.localized("Remove %@ from OneClick?"), app.name))
        }

        AppIconStyleSection()
    }

    private func placement(for app: OpenWithApp) -> String {
        var places: [String] = []
        if app.showInToolbar { places.append(AppLocalization.localized("Toolbar")) }
        if app.showInContextMenu { places.append(AppLocalization.localized("Context Menu")) }
        return places.isEmpty ? AppLocalization.localized("Hidden in Finder") : places.joined(separator: " · ")
    }

    private func visibility(_ app: OpenWithApp, _ keyPath: WritableKeyPath<OpenWithApp, Bool>) -> Binding<Bool> {
        Binding {
            (appState.getAppItem(rid: app.id) ?? app)[keyPath: keyPath]
        } set: { value in
            guard var current = appState.getAppItem(rid: app.id) else { return }
            current[keyPath: keyPath] = value
            appState.updateAppVisibility(
                id: current.id, showInToolbar: current.showInToolbar, showInContextMenu: current.showInContextMenu
            )
        }
    }
}
