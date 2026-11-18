//
//  SettingsView.swift
//  OneClick
//
//  Created by 李旭 on 2024/4/4.
//

import SwiftUI

enum Tabs: String, CaseIterable, Identifiable {
    case general = "Startup & Menu Bar"
    case permissions = "Permissions"
    case management = "Settings Management"
    case apps = "Apps"
    case actions = "Actions"
    case archives = "Compression"
    case archiveMenu = "Context Menu"
    case archiveAssociations = "File Associations"
    case inputMethods = "Switching Preferences"
    case inputRules = "Application Rules"
    case newFile = "New File"
    case cdirs = "Common Dir"
    case about = "About"

    var id: String { rawValue }
    var titleKey: String { rawValue }

    var icon: String {
        switch self {
        case .inputMethods: "character.bubble"
        case .inputRules: "app.badge"
        case .general: "power"
        case .permissions: "lock.shield"
        case .management: "externaldrive"
        case .apps: "app.badge"
        case .actions: "bolt"
        case .archives: "archivebox"
        case .archiveMenu: "list.bullet"
        case .archiveAssociations: "doc.zipper"
        case .newFile: "doc.badge.plus"
        case .cdirs: "folder"
        case .about: "info.circle"
        }
    }

    var module: SettingsModule {
        switch self {
        case .actions, .apps, .newFile, .cdirs: .rightClickTools
        case .archives, .archiveMenu, .archiveAssociations: .archives
        case .inputMethods, .inputRules: .inputMethods
        case .general, .permissions, .management, .about: .general
        }
    }
}

enum SettingsModule: String, CaseIterable, Identifiable {
    case rightClickTools, archives, inputMethods, general

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .rightClickTools: "Right-click Tools"
        case .archives: "Archive Tools"
        case .inputMethods: "Input Method Switching"
        case .general: "General"
        }
    }

    var color: Color {
        switch self {
        case .rightClickTools: .blue
        case .archives: .orange
        case .inputMethods: .purple
        case .general: .gray
        }
    }

    var tabs: [Tabs] {
        switch self {
        case .rightClickTools: [.actions, .apps, .newFile, .cdirs]
        case .archives: [.archives, .archiveMenu, .archiveAssociations]
        case .inputMethods: [.inputMethods, .inputRules]
        case .general: [.general, .permissions, .management, .about]
        }
    }

    var defaultTab: Tabs { tabs[0] }
}

@available(macOS 27, *)
struct SettingsView: View {
    @State private var selectedTab: Tabs = .actions
    @EnvironmentObject private var appState: AppState

    @ViewBuilder private func page(for tab: Tabs) -> some View {
        switch tab {
        case .inputMethods:
            InputMethodSettingsView(section: .preferences)
        case .inputRules:
            InputMethodSettingsView(section: .applicationRules)
        case .general:
            GeneralSettingsTabView(section: .startup)
        case .permissions:
            GeneralSettingsTabView(section: .permissions)
        case .management:
            GeneralSettingsTabView(section: .management)
        case .apps:
            AppsSettingsTabView()
        case .actions:
            ActionSettingsTabView()
        case .archives:
            ArchiveSettingsTabView(section: .compression)
        case .archiveMenu:
            ArchiveSettingsTabView(section: .contextMenu)
        case .archiveAssociations:
            ArchiveSettingsTabView(section: .associations)
        case .newFile:
            NewFileSettingsTabView()
        case .cdirs:
            CommonDirsSettingTabView()
        case .about:
            AboutSettingsTabView()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 236)
            Divider()
            VStack(spacing: 0) {
                pageHeader
                Divider()
                SettingsPageStack(selection: selectedTab) { tab in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            page(for: tab)
                        }
                        .frame(maxWidth: 780, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 22)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity)
                    }
                }
                .background(.primary.opacity(0.025))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .buttonStyle(.bordered)
            .toggleStyle(.switch)
            .pickerStyle(.menu)
            .labeledContentStyle(SettingsValueStyle())
        }
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image("Logo")
                    .resizable().scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(appLocalized: "Settings")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(SettingsModule.allCases) { module in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appLocalized: module.titleKey)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 9)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)

                            ForEach(module.tabs) { tab in
                                SettingsNavigationButton(isSelected: selectedTab == tab) {
                                    selectedTab = tab
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: tab.icon)
                                            .foregroundStyle(selectedTab == tab ? Color.accentColor : module.color)
                                            .frame(width: 18)
                                            .accessibilityHidden(true)
                                        Text(appLocalized: tab.titleKey)
                                            .fontWeight(selectedTab == tab ? .semibold : .regular)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .defaultScrollAnchor(.top)
        }
        .background(.regularMaterial)
    }

    private var pageHeader: some View {
        HStack(spacing: 13) {
            OneClickHeaderIcon(symbol: selectedTab.icon, color: selectedTab.module.color)
            Text(appLocalized: selectedTab.titleKey)
                .font(.system(size: 24, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: 780, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsNavigationButton<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(isHovering ? 0.05 : 0))
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
        .frame(width: 1020, height: 720)
}
