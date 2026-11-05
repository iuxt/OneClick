//
//  MenuBarView.swift
//  OneClick
//
//  Created by 李旭 on 2024/4/4.
//

import AppKit
import Combine
import SwiftUI

// MARK: - 打开设置窗口

/// 调出设置窗口：不存在则由 SwiftUI 创建，已存在则前置，最后激活 App——
/// LSUIElement 应用不会自己抢焦点，必须显式 activate。
@MainActor
func showSettingsWindow(openWindow: OpenWindowAction) {
    openWindow(id: Constants.settingsWindowID)

    if let existingWindow = NSApplication.shared.windows.first(where: {
        $0.identifier?.rawValue == Constants.settingsWindowID
    }) {
        existingWindow.makeKeyAndOrderFront(nil)
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
}

/// Owned by the settings Scene, so hiding the menu bar icon or closing the last
/// window never removes the receiver for a manual launch/reopen request.
@MainActor
final class SettingsWindowRequests: ObservableObject {
    @Published private(set) var generation = 0
    private var subscription: AnyCancellable?

    init(center: NotificationCenter = .default) {
        subscription = center.publisher(for: .openSettingsRequested)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.generation += 1
                }
            }
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) var openWindow: OpenWindowAction

    let messager = Messager.shared

    var body: some View {
        VStack {
            Button(action: actionSettings) {
                Text(appLocalized: "Settings")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button(action: actionQuit) {
                Text(appLocalized: "Quit")
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    @MainActor
    private func actionSettings() {
        showSettingsWindow(openWindow: openWindow)
    }

    @MainActor
    private func actionQuit() {
        messager.sendQuitNotification()

        // 等一拍让菜单栏弹出面板收起，再退出。
        //
        // 这里唯一的抛出是任务被取消；用户点的是"退出"，不该因为一次取消就被留在这里，
        // 所以显式吞掉取消、继续走完 —— 而不是让错误悄悄丢掉（这条警告说的正是后者）。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))

            NSApplication.shared.terminate(self)
        }
    }
}

#Preview {
    MenuBarView()
}
