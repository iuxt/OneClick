//
//  ActionSettingsView.swift
//  RClick
//
//  Created by 李旭 on 2024/4/9.
//

import SwiftUI

struct ActionSettingsTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $appState.foldActionsMenu) {
                    Text(appLocalized: "Collapse actions menu")
                }
                    .onChange(of: appState.foldActionsMenu) {
                        NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                    }
            }

            Section {
                ActionSettingsList(archives: false)
            } footer: {
                HStack {
                    Spacer()
                    Button(AppLocalization.localized("Restore Defaults")) {
                        appState.resetActionItems(archives: false)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ActionSettingsList: View {
    @EnvironmentObject var appState: AppState
    let archives: Bool

    var body: some View {
        List {
            ForEach($appState.actions.filter { $0.wrappedValue.isArchive == archives }) { $item in
                LabeledContent {
                    Toggle(AppLocalization.localized("Enabled"), isOn: $item.enabled)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .onChange(of: item.enabled) {
                            appState.toggleActionItem()
                            Messager.shared.sendRunningNotification()
                        }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                        Label(item.displayName, systemImage: item.icon)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 2, bottom: 8, trailing: 2))
            }
            .onMove { source, destination in
                appState.moveActions(from: source, to: destination, archives: archives)
                Messager.shared.sendRunningNotification()
            }
        }
        .frame(minHeight: 180)
    }
}
