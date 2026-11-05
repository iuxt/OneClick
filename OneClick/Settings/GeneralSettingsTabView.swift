//
//  GeneralSettingsTabView.swift
//  OneClick
//
//  Created by 李旭 on 2024/4/10.
//

import AppKit
import Cocoa
import Combine
import FinderSync
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 27, *)
struct GeneralSettingsTabView: View {
    @Environment(\.isSettingsPageActive) private var isActive
    @AppLog(category: "settings-general")
    private var logger

    @EnvironmentObject private var appState: AppState
    @State private var managingSettings = false
    @State private var managementMessage: String?
    @State private var managementFailed = false

    @AppStorage(Key.showMenuBarExtra, store: .group) private var showMenuBarExtra = true
    @ObservedObject private var bookmarkManager = AppState.shared.bookmarkManager

    @State private var finderSyncStatus: PermissionStatus = .unknown
    @State private var accessibilityStatus: PermissionStatus = .unknown
    @State private var showFolderPermissionsSheet = false

    @State private var showDirImporter = false
    @State private var wrongFold = false
    @State private var showAlert = false

    let messager = Messager.shared

    var body: some View {
        Form {
            // MARK: - 第一组：主要控制
            Section {
                LaunchAtLogin.Toggle {
                    Text(appLocalized: "Launch at login")
                }

                Toggle(isOn: $showMenuBarExtra) {
                    Text(appLocalized: "Show icon in menu bar")
                }
            } header: {
                Text(appLocalized: "Main Controls")
            }

            // MARK: - 第二组：权限
            Section {
                // Finder 扩展状态
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(finderSyncStatus.description)
                            .foregroundColor(.secondary)
                        Button(AppLocalization.localized("Settings…")) {
                            openFinderExtensionSettings()
                        }
                    }
                } label: {
                    Label(AppLocalization.localized("Finder Extension"), systemImage: finderSyncStatus.icon)
                        .foregroundColor(finderSyncStatus.color)
                }

                // 辅助功能权限（行标签跟随系统设置的实际叫法：
                // macOS 26 前叫"辅助功能"，27 起叫"设备控制和数据访问"）
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(accessibilityStatus.description)
                            .foregroundStyle(.secondary)
                        Button(AppLocalization.localized("Settings…")) {
                            openAccessibilitySettings()
                        }
                    }
                } label: {
                    Label(SystemSettingsNaming.accessibilitySection, systemImage: accessibilityStatus.icon)
                        .foregroundColor(accessibilityStatus.color)
                }

                // 文件夹权限（Bookmark）
                LabeledContent {
                    HStack(spacing: 8) {
                        Text("\(bookmarkManager.authorizedDirectories.count)")
                            .foregroundColor(.secondary)
                        Button(AppLocalization.localized("Manage…")) {
                            showFolderPermissionsSheet = true
                        }
                    }
                } label: {
                    Label(AppLocalization.localized("Folder Permissions"), systemImage: "folder.badge.gearshape")
                }
            } header: {
                Text(appLocalized: "Permissions")
            } footer: {
                // 条目名按系统版本取实际叫法（27+ 的「扩展」「隐私与安全」「设备控制和数据访问」，
                // 15/26 的「访达」「隐私与安全性」「辅助功能」）
                Text(String(
                    format: AppLocalization.localized(
                        "Finder extension: enable \"OneClick\" under System Settings > General > Login Items & Extensions > %@. Accessibility: %@ > %@."
                    ),
                    SystemSettingsNaming.finderExtensionRow,
                    SystemSettingsNaming.privacySecuritySection,
                    SystemSettingsNaming.accessibilitySection
                ))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: - 第三组：设置管理
            Section {
                // 备份
                LabeledContent {
                    HStack(spacing: 12) {
                        Button(AppLocalization.localized("Export…")) {
                            exportSettings()
                        }
                        Button(AppLocalization.localized("Import…")) {
                            importSettings()
                        }
                    }
                } label: {
                    Text(appLocalized: "Backup")
                }

                // 日志
                LabeledContent {
                    Button(AppLocalization.localized("Export Logs…")) {
                        exportLogs()
                    }
                } label: {
                    Text(appLocalized: "Logs")
                }

                // 重置所有设置
                HStack {
                    Spacer()
                    Button(AppLocalization.localized("Reset All Settings…")) {
                        resetAllSettings()
                    }
                    .foregroundColor(.red)
                }
            } header: {
                Text(appLocalized: "Settings Management")
            } footer: {
                Text(appLocalized: "Backups include app settings and templates. Folder permissions, login items and file associations are managed separately.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(managingSettings)
            if managingSettings {
                ProgressView(AppLocalization.localized("Working on settings…"))
            }
        }
        .formStyle(.grouped)
        .onForeground {
            if isActive { updatePermissionStatus() }
        }
        // 权限状态挂在定时器上：授权发生在系统设置里（本应用在后台），
        // macOS 的 scenePhase 对窗口级焦点切换不可靠，回到本应用时 onForeground
        // 不保证触发。仅在当前页面可见时每 2 秒检测，切走后取消轮询。
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                updatePermissionStatus()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
        // 从系统设置切回时立即刷新（窗口重新成为 key window 的那一刻），
        // 不等下一个 2 秒轮询
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if isActive { updatePermissionStatus() }
        }
        .alert(
            Text(appLocalized: "Invalid Folder"),
            isPresented: $wrongFold
        ) {
            Button(AppLocalization.localized("OK")) {
                showDirImporter = true
            }
        } message: {
            Text(appLocalized: "The selected folder is a subfolder of an already selected folder. Please choose a different folder.")
        }
        .alert(
            Text(appLocalized: "Unauthorized Folder"),
            isPresented: $showAlert
        ) {
            Button(AppLocalization.localized("OK")) {
                showDirImporter = true
            }
        } message: {
            Text(appLocalized: "Folder access permission is required to use this feature.")
        }
        .alert(Text(appLocalized: managementFailed ? "Settings operation failed" : "Settings"), isPresented: Binding(
            get: { managementMessage != nil }, set: { if !$0 { managementMessage = nil } }
        )) {
            Button(AppLocalization.localized("OK"), role: .cancel) { managementMessage = nil }
        } message: { Text(managementMessage ?? "") }
        .sheet(isPresented: $showFolderPermissionsSheet) {
            FolderPermissionsSheetView(bookmarkManager: bookmarkManager)
        }
    }

    // MARK: - 权限状态检测

    private func updatePermissionStatus() {
        // Finder 扩展状态
        finderSyncStatus = FIFinderSyncController.isExtensionEnabled ? .enabled : .disabled

        // 辅助功能权限检测
        accessibilityStatus = PermissionChecker.hasAccessibilityPermission() ? .enabled : .disabled
    }

    private func hasAccessibilityPermission() -> Bool {
        return PermissionChecker.hasAccessibilityPermission()
    }

    // MARK: - 权限设置打开

    private func openFinderExtensionSettings() {
        // macOS 13+ 的系统设置：Finder 扩展开关在"通用 → 登录项与扩展"面板里
        // （扩展区域底部）。旧锚点 com.apple.AppleFileProvider 在新版设置里无效。
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    private func openAccessibilitySettings() {
        PermissionChecker.openAccessibilitySettings()
    }

    // MARK: - 设置管理

    private func exportSettings() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.propertyList]
        savePanel.nameFieldStringValue = "OneClick_Settings.plist"
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            performManagement(at: url) {
                let snapshot = AppConfigData(apps: appState.apps, actions: appState.actions,
                                             newFiles: appState.newFiles, commonDirs: appState.cdirs)
                try await SettingsManagementService(config: appState.configService).export(snapshot, to: url)
                return AppLocalization.localized("Settings exported.")
            }
        }
    }

    private func importSettings() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.propertyList]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.message = AppLocalization.localized("Importing a backup replaces the current app settings.")
        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else { return }
            performManagement(at: url) {
                let snapshot = try await SettingsManagementService(config: appState.configService).restore(from: url)
                appState.applyConfiguration(snapshot)
                InputMethodService.shared.reloadConfiguration()
                return AppLocalization.localized("Settings imported.")
            }
        }
    }

    private func exportLogs() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "OneClick_Log.txt"
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            performManagement(at: url) {
                try await SettingsBackupIO.exportLogs(to: url)
                return AppLocalization.localized("Logs exported.")
            }
        }
    }

    private func resetAllSettings() {
        let alert = NSAlert()
        alert.messageText = AppLocalization.localized("Reset All Settings?")
        alert.informativeText = AppLocalization.localized("This restores default app settings. Folder permissions, login items and file associations are kept. This action cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppLocalization.localized("Reset"))
        alert.addButton(withTitle: AppLocalization.localized("Cancel"))
        alert.buttons[0].hasDestructiveAction = true

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performManagement {
                let snapshot = try SettingsManagementService(config: appState.configService).reset()
                appState.applyConfiguration(snapshot)
                InputMethodService.shared.reloadConfiguration()
                return AppLocalization.localized("Default settings restored.")
            }
        }
    }
    private func performManagement(at url: URL? = nil, operation: @escaping @MainActor () async throws -> String) {
        guard !managingSettings else { return }
        managingSettings = true
        Task { @MainActor in
            let scoped = url?.startAccessingSecurityScopedResource() ?? false
            defer {
                if scoped { url?.stopAccessingSecurityScopedResource() }
                managingSettings = false
            }
            do {
                managementMessage = try await operation()
                managementFailed = false
            } catch {
                managementMessage = error.localizedDescription
                managementFailed = true
                logger.error("Settings operation failed: \(error.localizedDescription)")
            }
        }
    }

}

// MARK: - 权限状态枚举

enum PermissionStatus {
    case enabled
    case disabled
    case unknown

    var icon: String {
        switch self {
        case .enabled:
            return "checkmark.circle.fill"
        case .disabled:
            return "circle"
        case .unknown:
            return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .enabled:
            return .green
        case .disabled:
            return .gray
        case .unknown:
            return .yellow
        }
    }

    var description: String {
        switch self {
        case .enabled:
            return AppLocalization.localized("Authorized")
        case .disabled:
            return AppLocalization.localized("Not Authorized")
        case .unknown:
            return AppLocalization.localized("Unknown")
        }
    }
}
