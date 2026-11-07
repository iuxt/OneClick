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
    var pageTitleKey: String { titleKey }

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

    var icon: String {
        switch self {
        case .rightClickTools: "cursorarrow.click.2"
        case .archives: "archivebox"
        case .inputMethods: "character.bubble"
        case .general: "gearshape"
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
    @State private var isModuleExpanded = true
    @State private var rememberedTabs: [SettingsModule: Tabs] = [:]
    @EnvironmentObject var appState: AppState

    private var selectedModule: SettingsModule { selectedTab.module }

    private func selectModule(_ module: SettingsModule) {
        guard module != selectedModule else {
            isModuleExpanded.toggle()
            return
        }
        isModuleExpanded = true
        selectTab(rememberedTabs[module] ?? module.defaultTab)
    }

    private func selectTab(_ tab: Tabs) {
        guard tab != selectedTab else { return }
        rememberedTabs[selectedModule] = selectedTab
        rememberedTabs[tab.module] = tab

        // Keep controls, focus and scroll positions stable while switching pages.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { selectedTab = tab }
    }

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
            sidebar
                .frame(width: 238)
            Divider()
            VStack(spacing: 0) {
                pageHeader
                Divider().padding(.horizontal, 28)
                SettingsPageStack(selection: selectedTab) { page(for: $0) }
                    .frame(maxWidth: 980, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .buttonStyle(.glass)
            }
            .frame(minWidth: 640)
            .background(Color(nsColor: .windowBackgroundColor))
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
            HStack(spacing: 10) {
                Image("Logo")
                    .resizable().scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OneClick").font(.headline)
                    Text(appLocalized: "Settings")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized: "Feature Modules")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                    ForEach(SettingsModule.allCases) { module in
                        if module == .general {
                            Divider().padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        moduleGroup(module)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .background(.regularMaterial)
    }

    private func moduleGroup(_ module: SettingsModule) -> some View {
        VStack(spacing: 3) {
            SettingsNavigationButton(isSelected: selectedModule == module && !isModuleExpanded) { selectModule(module) } label: {
                HStack(spacing: 10) {
                    Image(systemName: module.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 27, height: 27)
                        .background(module.color.gradient, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                    Text(AppLocalization.localized(module.titleKey))
                        .font(.system(size: 13, weight: selectedModule == module ? .semibold : .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: selectedModule == module && isModuleExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .accessibilityValue(AppLocalization.localized(selectedModule == module && isModuleExpanded ? "Expanded" : "Collapsed"))

            if selectedModule == module && isModuleExpanded {
                VStack(spacing: 2) {
                    ForEach(module.tabs) { tab in
                        SettingsNavigationButton(isSelected: selectedTab == tab) { selectTab(tab) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 12))
                                    .frame(width: 16)
                                    .accessibilityHidden(true)
                                Text(AppLocalization.localized(tab.pageTitleKey))
                                    .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.bottom, 6)
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.localized(selectedModule.titleKey))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: selectedTab.icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(selectedModule.color)
                    .accessibilityHidden(true)
                Text(AppLocalization.localized(selectedTab.pageTitleKey))
                    .font(.system(size: 25, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 22)
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
