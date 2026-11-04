//
//  SettingsView.swift
//  RClick
//
//  Created by 李旭 on 2024/4/4.
//

import AppKit
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

    /// 每个 tab 图标对应的圆角色块颜色
    var iconColor: Color {
        switch self {
        case .home: .teal
        case .inputMethods: .purple
        case .general: .blue
        case .apps: .indigo
        case .actions: .orange
        case .archives: .brown
        case .newFile: .green
        case .cdirs: .teal
        case .about: .purple
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: Tabs = .home
    @EnvironmentObject var appState: AppState
    @State var showSelectApp = false

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // 顶部品牌区：图标 + 名字 + 版本号
            HStack(spacing: 12) {
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("RClick").font(.title3.weight(.semibold))
                    Text(appLocalized: "Everyday Mac Toolkit").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            // 侧边栏 tab 垂直排列。
            ScrollView {
                VStack(spacing: 4) {
                    sidebarButton(.home)
                    sidebarHeading("Tools")
                    ForEach([Tabs.actions, .archives, .inputMethods]) { sidebarButton($0) }
                    sidebarHeading("Finder Settings")
                    ForEach([Tabs.apps, .newFile, .cdirs]) { sidebarButton($0) }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 4) {
                sidebarButton(.general)
                sidebarButton(.about)
                Text("RClick · v\(getAppVersion())")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.vertical, 12)
            }.padding(.horizontal, 12)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 260)
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(appLocalized: title).font(.caption.weight(.medium)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).padding(.top, 18).padding(.bottom, 6)
    }

    /// 侧边栏单个 tab：选中时行背景为图标色的半透明色（如绿色图标 → 半透明绿）
    private func sidebarButton(_ tab: Tabs) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tab.iconColor)
                    )

                Text(appLocalized: tab == .actions ? "Right-click Tools" : tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? tab.iconColor.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder var detailView: some View {
        // 右侧内容
        Group {
            switch self.selectedTab {
            case .home:
                ToolboxHomeView { selectedTab = $0 }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 450)
        .safeAreaPadding(.top, 12)
    }

    var body: some View {
        NavigationSplitView {
            self.sidebar
        } detail: {
            self.detailView
        }
        .navigationTitle(AppLocalization.localized(selectedTab == .actions ? "Right-click Tools" : selectedTab.rawValue))
        .background(Color(NSColor.windowBackgroundColor))
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

    func getAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return AppLocalization.localized("Unknown")
    }
}


#Preview {
    SettingsView()
}
