//
//  SettingsView.swift
//  OneClick
//
//  Created by 李旭 on 2024/4/4.
//

import SwiftUI

enum Tabs: String, CaseIterable, Identifiable {
    case general = "General"
    case apps = "Apps"
    case actions = "Actions"
    case archives = "Compression & Extraction"
    case inputMethods = "Input Method Switching"
    case systemMonitor = "System Monitor"
    case newFile = "New File"
    case cdirs = "Common Dir"
    case about = "About"

    var id: String { self.rawValue }

    var titleKey: String {
        self == .archives ? "Archive Tools" : rawValue
    }

    var pageTitleKey: String {
        switch self {
        case .systemMonitor: "System Monitor"
        case .archives: "Archive Settings"
        case .inputMethods: "Input Method Settings"
        default: titleKey
        }
    }

    var icon: String {
        switch self {
        case .systemMonitor: "gauge.with.dots.needle.50percent"
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

    var module: SettingsModule {
        switch self {
        case .actions, .apps, .newFile, .cdirs:
            .rightClickTools
        case .archives:
            .archives
        case .inputMethods:
            .inputMethods
        case .systemMonitor:
            .systemMonitor
        case .general, .about:
            .general
        }
    }
}

enum SettingsModule: String, CaseIterable, Identifiable {
    case rightClickTools
    case archives
    case inputMethods
    case systemMonitor
    case general

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .rightClickTools: "Right-click Tools"
        case .archives: "Archive Tools"
        case .inputMethods: "Input Method Switching"
        case .systemMonitor: "System Monitor"
        case .general: "General"
        }
    }

    var icon: String {
        switch self {
        case .rightClickTools: "cursorarrow.click.2"
        case .archives: "archivebox"
        case .inputMethods: "character.bubble"
        case .systemMonitor: "gauge.with.dots.needle.50percent"
        case .general: "gearshape"
        }
    }

    var tabs: [Tabs] {
        switch self {
        case .rightClickTools: [.actions, .apps, .newFile, .cdirs]
        case .archives: [.archives]
        case .inputMethods: [.inputMethods]
        case .systemMonitor: [.systemMonitor]
        case .general: [.general, .about]
        }
    }

    var defaultTab: Tabs { tabs[0] }
}

@available(macOS 27, *)
struct SettingsView: View {
    @State private var selectedTab: Tabs = .actions
    @State private var rememberedTabs: [SettingsModule: Tabs] = [:]
    @EnvironmentObject var appState: AppState

    private var selectedModule: SettingsModule { selectedTab.module }

    private var moduleSelection: Binding<SettingsModule> {
        Binding(get: { selectedModule }, set: selectModule)
    }

    private var tabSelection: Binding<Tabs> {
        Binding(get: { selectedTab }, set: selectTab)
    }

    private func selectModule(_ module: SettingsModule) {
        guard module != selectedModule else { return }
        rememberedTabs[selectedModule] = selectedTab
        selectTab(rememberedTabs[module] ?? module.defaultTab)
    }

    private func selectTab(_ tab: Tabs) {
        guard tab != selectedTab else { return }
        rememberedTabs[tab.module] = tab

        // Keep controls, focus and scroll positions stable while switching pages.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { selectedTab = tab }
    }

    @ViewBuilder private func page(for tab: Tabs) -> some View {
        switch tab {
        case .systemMonitor:
            SystemMonitorSettingsView()
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
        VStack(spacing: 0) {
            SettingsModuleTabBar(selection: moduleSelection)

            Divider()

            if selectedModule.tabs.count > 1 {
                SettingsSubtabBar(tabs: selectedModule.tabs, selection: tabSelection)
            }

            SettingsPageStack(selection: selectedTab) { page(for: $0) }
                .frame(minWidth: 620)
                .buttonStyle(.glass)
        }
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

@available(macOS 27, *)
private struct SettingsModuleTabBar: View {
    @Binding var selection: SettingsModule

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SettingsModule.allCases) { module in
                SettingsModuleTabButton(
                    module: module,
                    isSelected: module == selection,
                    action: { selection = module }
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

@available(macOS 27, *)
private struct SettingsModuleTabButton: View {
    let module: SettingsModule
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: module.icon)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

                Text(AppLocalization.localized(module.titleKey))
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundStyle)
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(.tint)
                .frame(width: 24, height: 3)
                .padding(.bottom, 3)
                .opacity(isSelected ? 1 : 0)
        }
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint.opacity(0.12)) }
        if isHovering { return AnyShapeStyle(.primary.opacity(0.05)) }
        return AnyShapeStyle(.clear)
    }
}

@available(macOS 27, *)
private struct SettingsSubtabBar: View {
    let tabs: [Tabs]
    @Binding var selection: Tabs

    var body: some View {
        Picker(AppLocalization.localized("Settings"), selection: $selection) {
            ForEach(tabs) { tab in
                Label(AppLocalization.localized(tab.pageTitleKey), systemImage: tab.icon)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 560)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

#Preview {
    SettingsView()
}
