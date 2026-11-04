//
//  SettingsWindow.swift
//  OneClick
//
//  Created by 李旭 on 2024/9/25.
//

import SwiftUI

@available(macOS 27, *)
struct SettingsWindow: Scene {
    @ObservedObject var appState: AppState
    
    @EnvironmentObject var updateManager: UpdateManager
    
    let onAppear: () -> Void

    var body: some Scene {
        Window("OneClick", id: Constants.settingsWindowID) {
            SettingsView()
                .environmentObject(appState)
                .onAppear {
                    onAppear()
                }
                .frame(minWidth: 880, minHeight: 620)
                .sheet(isPresented: $updateManager.showUpdateSheet) {
                    UpdateView(updateManager: updateManager)
                }
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 720)
        .windowToolbarStyle(.unified)
        // 压缩包打开事件由 AppDelegate 交给 ArchiveBrowserPresenter 处理。
        // 禁止 SwiftUI 同时为文件打开事件创建主窗口；启动抑制不覆盖这条路径。
        .handlesExternalEvents(matching: [])
        // SwiftUI Window scene 默认随 App 启动自动打开——常驻后台工具不该如此。
        // 抑制启动时自动弹出，设置窗口只经由菜单栏图标（openWindow(id:)）
        // 或手动打开 App 时展示；离线提示启动保持静默。
        // restorationBehavior 进一步禁止系统还原
        // 上次会话的窗口状态。
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
    
}
