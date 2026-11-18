import SwiftUI

struct ActionSettingsTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var confirmingRestore = false

    var body: some View {
        SettingsSection {
            SettingsRow {
                SettingsSwitch("Collapse actions menu", isOn: $appState.foldActionsMenu)
                    .onChange(of: appState.foldActionsMenu) {
                        NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                    }
            }
        }

        ActionSettingsList(archives: false) {
            Button(AppLocalization.localized("Restore Defaults")) { confirmingRestore = true }
        }
        .alert(Text(appLocalized: "Restore Default Actions?"), isPresented: $confirmingRestore) {
            Button(AppLocalization.localized("Cancel"), role: .cancel) {}
            Button(AppLocalization.localized("Restore Defaults"), role: .destructive) {
                appState.resetActionItems(archives: false)
            }
        } message: {
            Text(appLocalized: "This resets which actions are enabled and restores their original order.")
        }
    }
}

struct ActionSettingsList<Actions: View>: View {
    @EnvironmentObject private var appState: AppState
    let archives: Bool
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        SettingsCollection(
            title: "Menu Items",
            items: appState.actions.filter { $0.isArchive == archives },
            move: { appState.moveActions(from: $0, to: $1, archives: archives) },
            actions: actions
        ) { item, reordering in
            SettingsItemLabel(title: item.displayName) {
                Image(systemName: item.icon).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !reordering {
                Toggle(item.displayName, isOn: Binding(
                    get: { appState.getActionItem(rid: item.id)?.enabled ?? item.enabled },
                    set: { enabled in
                        guard let index = appState.actions.firstIndex(where: { $0.id == item.id }) else { return }
                        appState.actions[index].enabled = enabled
                        appState.toggleActionItem()
                    }
                ))
                .labelsHidden()
            }
        }
    }
}
