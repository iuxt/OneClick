//
//  Messager.swift
//  RClick
//
//  进程间通信（IPC）管理器
//  Authenticated local stream + Codable protocol
//

import Foundation
import OSLog
import AppKit

// MARK: - 消息类型枚举

/// 主程序发送给 Extension 的消息类型
enum MainToExtensionAction: String, Codable {
    /// 发送完整菜单配置
    case menuConfig = "menu-config"
    /// 主程序启动通知
    case running = "running"
    /// 主程序退出通知
    case quit = "quit"
    /// 确认已收到点击事件（用于扩展判断主程序是否可通信）
    case actionAck = "action-ack"
}

/// Extension 发送给主程序的消息类型
enum ExtensionToMainAction: String, Codable {
    /// 菜单点击事件
    case click = "click"
    /// 心跳消息
    case heartbeat = "heartbeat"
    /// 请求菜单配置
    case requestConfig = "request-config"
}

// MARK: - 消息载荷

/// 菜单配置消息载荷
struct MenuConfigPayload: Codable {
    /// 菜单版本号，用于防重复和防乱序
    let version: Int
    /// 动作菜单项列表
    let actions: [ActionMenuItem]
    /// 应用菜单项列表
    let apps: [AppMenuItem]
    /// 新建文件菜单项列表
    let newFiles: [NewFileMenuItem]
    /// 常用目录菜单项列表
    let commonDirs: [CommonDirMenuItem]
    /// 是否折叠动作菜单（默认 false）
    let actionsCollapsed: Bool
    let archivesCollapsed: Bool
    /// 是否折叠应用菜单（默认 false）
    let appsCollapsed: Bool
    /// 是否折叠新建文件菜单（默认 true）
    let newFilesCollapsed: Bool
    /// 是否折叠常用目录菜单（默认 true）
    let commonDirsCollapsed: Bool
    /// 应用图标样式：0=无图标 1=简单图标（单色 template） 2=原始图标（默认）
    let iconStyle: Int

    init(
        version: Int = 1,
        actions: [ActionMenuItem] = [],
        apps: [AppMenuItem] = [],
        newFiles: [NewFileMenuItem] = [],
        commonDirs: [CommonDirMenuItem] = [],
        actionsCollapsed: Bool = false,
        archivesCollapsed: Bool = false,
        appsCollapsed: Bool = false,
        newFilesCollapsed: Bool = true,
        commonDirsCollapsed: Bool = true,
        iconStyle: Int = RCAppIconStyle.simple.rawValue
    ) {
        self.version = version
        self.actions = actions
        self.apps = apps
        self.newFiles = newFiles
        self.commonDirs = commonDirs
        self.actionsCollapsed = actionsCollapsed
        self.archivesCollapsed = archivesCollapsed
        self.appsCollapsed = appsCollapsed
        self.newFilesCollapsed = newFilesCollapsed
        self.commonDirsCollapsed = commonDirsCollapsed
        self.iconStyle = iconStyle
    }

    private enum CodingKeys: String, CodingKey {
        case version, actions, apps, newFiles, commonDirs
        case actionsCollapsed, archivesCollapsed, appsCollapsed, newFilesCollapsed, commonDirsCollapsed
        case iconStyle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        actions = try values.decode([ActionMenuItem].self, forKey: .actions)
        apps = try values.decode([AppMenuItem].self, forKey: .apps)
        newFiles = try values.decode([NewFileMenuItem].self, forKey: .newFiles)
        commonDirs = try values.decode([CommonDirMenuItem].self, forKey: .commonDirs)
        actionsCollapsed = try values.decode(Bool.self, forKey: .actionsCollapsed)
        archivesCollapsed = try values.decodeIfPresent(Bool.self, forKey: .archivesCollapsed) ?? false
        appsCollapsed = try values.decode(Bool.self, forKey: .appsCollapsed)
        newFilesCollapsed = try values.decode(Bool.self, forKey: .newFilesCollapsed)
        commonDirsCollapsed = try values.decode(Bool.self, forKey: .commonDirsCollapsed)
        // Payloads produced before icon styles existed used original app icons.
        iconStyle = try values.decodeIfPresent(Int.self, forKey: .iconStyle) ?? RCAppIconStyle.original.rawValue
    }

}

/// 点击事件消息载荷
struct ClickEventPayload: Codable {
    /// 点击的菜单项 ID
    let itemId: String
    /// 菜单项类型
    let itemType: MenuItemType
    /// Native file/directory paths from URL.path, never URL-encoded strings.
    let target: [String]
    /// 触发来源
    let trigger: MenuTrigger
    /// 点击时是否按住 Option。「直接删除」据此跳过确认
    let optionKeyPressed: Bool?

    init(
        itemId: String,
        itemType: MenuItemType,
        target: [String] = [],
        trigger: MenuTrigger,
        optionKeyPressed: Bool? = nil
    ) {
        self.itemId = itemId
        self.itemType = itemType
        self.target = target
        self.trigger = trigger
        self.optionKeyPressed = optionKeyPressed
    }
}

// MARK: - 辅助类型

/// 运行状态消息载荷（用于通知 Extension 主程序运行状态）
struct RunningPayload: Codable {
    /// 监听目录列表
    let directories: [String]

    init(directories: [String] = []) {
        self.directories = directories
    }
}

/// 菜单项类型
enum MenuItemType: String, Codable {
    case action = "action"  // 动作菜单
    case app = "app"  // 应用菜单
    case newFile = "new-file"  // 新建文件
    case commonDir = "common-dir"  // 常用目录
}

/// 触发来源
enum MenuTrigger: String, Codable {
    /// 选中文件/文件夹右键
    case contextualItems = "ctx-items"
    /// 空白处右键
    case contextualContainer = "ctx-container"
    /// 侧边栏右键
    case contextualSidebar = "ctx-sidebar"
    /// 工具栏
    case toolbar = "toolbar"
}

/// 项目类型（文件/文件夹）
enum ItemType: String, Codable {
    case file = "file"
    case folder = "folder"
    case unknown = "unknown"
}

// MARK: - Logger

/// Logger for Messager operations
private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "RClick",
    category: "Messager"
)

// MARK: - 消息管理器

/// 消息管理器 - 处理主程序和 Extension 之间的通信
class Messager: @unchecked Sendable {
    static let shared = Messager()

    // 消息处理器存储
    // Registration and dispatch use the main queue; the lock also protects lifecycle changes.
    // Swift 6 严格并发下用锁保护，避免数据竞争（原 nonisolated(unsafe) 无同步）。
    private let handlersLock = NSLock()
    nonisolated(unsafe) private var mainToExtensionHandlers: [MainToExtensionAction: (Data?) -> Void] = [:]
    nonisolated(unsafe) private var extensionToMainHandlers: [ExtensionToMainAction: (Data?) -> Void] = [:]

    private let isExtension: Bool
    private let inbox: IPCInbox
    private var transport: LocalIPCTransport?

    private init() {
        isExtension = Bundle.main.bundleIdentifier?.hasSuffix(".FinderSyncExt") == true
        inbox = IPCInbox(direction: isExtension ? .mainToExtension : .extensionToMain)
        do {
            transport = try LocalIPCTransport(isExtension: isExtension, receive: { [weak self] data in
                DispatchQueue.main.async { self?.receiveVerifiedFrame(data) }
            }, connected: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isExtension {
                        self.requestMenuConfig()
                    } else {
                        self.sendRunningNotification()
                        self.handlersLock.lock()
                        let configuration = self.extensionToMainHandlers[.requestConfig]
                        self.handlersLock.unlock()
                        configuration?(nil)
                    }
                }
            }, disconnected: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.isExtension else { return }
                    self.handlersLock.lock()
                    let offline = self.mainToExtensionHandlers[.quit]
                    self.handlersLock.unlock()
                    offline?(nil)
                }
            })
            transport?.start()
        } catch {
            logger.error("Cannot start authenticated IPC: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 主程序发送消息给 Extension
    func sendToExtension<T: Codable>(_ action: MainToExtensionAction, data: T? = nil) {
        guard !isExtension else { return }
        send(direction: .mainToExtension, action: action.rawValue, data: data)
    }

    /// Extension 发送消息给主程序
    func sendToMain<T: Codable>(_ action: ExtensionToMainAction, data: T? = nil) {
        guard isExtension else { return }
        send(direction: .extensionToMain, action: action.rawValue, data: data)
    }

    private func send<T: Encodable>(direction: IPCDirection, action: String, data: T?) {
        do {
            let payload = try data.map { try JSONEncoder().encode($0) }
            let frame = IPCEnvelope(direction: direction, action: action, payload: payload)
            transport?.send(try JSONEncoder().encode(frame))
        } catch {
            logger.error("Failed to encode IPC message: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 注册处理器

    /// Extension 注册主程序消息处理器
    func onMainMessage(_ action: MainToExtensionAction, handler: @escaping (Data?) -> Void) {
        handlersLock.lock()
        mainToExtensionHandlers[action] = handler
        handlersLock.unlock()
    }

    /// 主程序注册 Extension 消息处理器
    func onExtensionMessage(_ action: ExtensionToMainAction, handler: @escaping (Data?) -> Void) {
        handlersLock.lock()
        extensionToMainHandlers[action] = handler
        handlersLock.unlock()
    }

    // Called exclusively by the transport after kernel peer identity and code
    // signature validation. No notification observer or public selector exists.
    private func receiveVerifiedFrame(_ data: Data) {
        do {
            let frame = try inbox.decode(data)
            handlersLock.lock()
            let handler: ((Data?) -> Void)?
            if isExtension, let action = MainToExtensionAction(rawValue: frame.action) {
                handler = mainToExtensionHandlers[action]
            } else if !isExtension, let action = ExtensionToMainAction(rawValue: frame.action) {
                handler = extensionToMainHandlers[action]
            } else {
                handler = nil
            }
            handlersLock.unlock()
            handler?(frame.payload)
        } catch {
            logger.warning("Rejected IPC frame: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 便捷方法

    /// 主程序发送菜单配置给 Extension
    func sendMenuConfig(_ config: MenuConfigPayload) {
        sendToExtension(.menuConfig, data: config)
    }

    /// 发送主程序启动通知
    func sendRunningNotification(directories: [String] = []) {
        let payload = RunningPayload(directories: directories)
        sendToExtension(.running, data: payload)
    }

    /// 发送主程序退出通知
    func sendQuitNotification() {
        sendToExtension(.quit, data: Optional<Int>.none)
    }

    /// 发送点击事件确认（主程序已收到 click，供扩展判断可通信性）
    func sendActionAck() {
        sendToExtension(.actionAck, data: Optional<Int>.none)
    }

    /// Extension 发送心跳
    func sendHeartbeat() {
        sendToMain(.heartbeat, data: Optional<Int>.none)
    }

    /// 请求菜单配置
    func requestMenuConfig() {
        sendToMain(.requestConfig, data: Optional<Int>.none)
    }

    /// Extension 发送点击事件
    func sendClickEvent(_ event: ClickEventPayload) {
        sendToMain(.click, data: event)
    }

    // MARK: - 解码辅助

    /// Decode only the payload received from the verified peer connection.
    func decode<T: Codable>(_ data: Data?, as type: T.Type = T.self) -> T? {
        guard let data = data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

}
