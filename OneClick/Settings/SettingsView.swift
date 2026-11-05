//
//  SettingsView.swift
//  OneClick
//
//  Created by 李旭 on 2024/4/4.
//

import SwiftUI

enum Tabs: String, CaseIterable, Identifiable {
    case home = "Toolbox"
    case general = "General"
    case apps = "Apps"
    case actions = "Actions"
    case archives = "Compression & Extraction"
    case inputMethods = "Input Method Switching"
    case newFile = "New File"
    case cdirs = "Common Dir"
    case about = "About"

    var id: String { self.rawValue }

    var titleKey: String {
        self == .archives ? "Archive Tools" : rawValue
    }

    var sidebarTitleKey: String {
        switch self {
        case .archives: "Archive Settings"
        case .inputMethods: "Input Method Settings"
        default: titleKey
        }
    }

    var icon: String {
        switch self {
        case .home: "square.grid.2x2"
        case .inputMethods: "character.bubble"
        case .general: "gearshape"
        case .apps: "app.badge"
        case .actions: "bolt.square"
        case .archives: "archivebox"
        case .newFile: "doc.badge.plus"
        case .cdirs: "folder.badge.gearshape"
        case .about: "info.circle"
        }
    }
}

@available(macOS 27, *)
struct SettingsView: View {
    @State private var selectedTab: Tabs = .home
    @EnvironmentObject var appState: AppState

    private var tabSelection: Binding<Tabs> {
        Binding(get: { selectedTab }, set: { tab in
            // Selection feedback and page visibility change in the same transaction.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { selectedTab = tab }
        })
    }

    private var sidebar: some View {
        // Use system selection, keyboard navigation and Liquid Glass sidebar chrome.
        // No outer padding or custom background: the column meets the window edges.
        List(selection: tabSelection) {
            sidebarRow(.home)
            Section {
                ForEach([Tabs.actions, .apps, .newFile, .cdirs]) { sidebarRow($0) }
            } header: {
                Text(appLocalized: "Right-click Tools")
            }
            Section {
                sidebarRow(.archives)
            } header: {
                Text(appLocalized: "Archive Tools")
            }
            Section {
                sidebarRow(.inputMethods)
            } header: {
                Text(appLocalized: "Input Method Switching")
            }
            Section {
                sidebarRow(.general)
                sidebarRow(.about)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 280)
        .navigationTitle("OneClick")
    }

    private func sidebarRow(_ tab: Tabs) -> some View {
        Label(AppLocalization.localized(tab.sidebarTitleKey), systemImage: tab.icon)
            .symbolRenderingMode(.monochrome)
            .tag(tab)
    }

    @ViewBuilder private func page(for tab: Tabs) -> some View {
        switch tab {
        case .home:
            ToolboxHomeView { tabSelection.wrappedValue = $0 }
        case .inputMethods:
            InputMethodSettingsView()
        case .general:
            GeneralSettingsTabView()
        case .apps:
            AppsSettingsTabView()
        case .actions:
            ActionSettingsTabView()
        case .archives:
            ArchiveSettingsTabView()
        case .newFile:
            NewFileSettingsTabView()
        case .cdirs:
            CommonDirsSettingTabView()
        case .about:
            AboutSettingsTabView()
        }
    }

    var body: some View {
        NavigationSplitView {
            self.sidebar
        } detail: {
            SettingsPageStack(selection: selectedTab) { page(for: $0) }
                .frame(minWidth: 450)
                .navigationTitle(AppLocalization.localized(selectedTab.titleKey))
        }
        .navigationSplitViewStyle(.balanced)
        // A failed write used to be invisible: the change stayed on screen but was
        // never stored, so the only way to notice was losing it on the next launch.
        .alert(
            Text(appLocalized: "Settings could not be saved"),
            isPresented: Binding(
                get: { appState.lastSaveError != nil },
                set: { if !$0 { appState.clearSaveError() } }
            )
        ) {
            Button(AppLocalization.localized("OK"), role: .cancel) { appState.clearSaveError() }
        } message: {
            Text(appState.lastSaveError ?? "")
        }
    }
}

#Preview {
    SettingsView()
}
