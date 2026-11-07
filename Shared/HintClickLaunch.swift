import Foundation
import Darwin

/// 「离线提示点击启动」标记，经共享目录在扩展与主程序之间传递。
///
/// 扩展在拉起主程序前触碰标记文件；主程序据此识别这次启动/reopen 来自提示点击，
/// 保持静默（不打开设置窗口）。标记文件直接位于双方获授权的目录内，
/// 不依赖 UserDefaults 的跨进程刷新；只读写文件修改时间，无需解析内容。
enum HintClickLaunch {
    /// 覆盖「退出收尾约 1 秒、启动后菜单刷新前 1-2 秒」空窗的判定窗口
    static let window: TimeInterval = 5

    private static var fileURL: URL? {
        // 与主程序数据库共用同一目录。
        SharedAppGroup.containerURL?
            .appendingPathComponent("hintClickLaunchAt")
    }

    /// 扩展侧：拉起主程序前调用
    static func mark() {
        guard let url = fileURL else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    /// 主程序侧：是否处于提示点击后的静默窗口
    static func isRecent(now: Date = Date()) -> Bool {
        guard let url = fileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attributes[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(modifiedAt) < window
    }
}


/// Shared by both targets so launch markers and the host settings use one ID.
nonisolated enum SharedAppGroup {
    // Keep the pre-OneClick identifier and storage path so existing settings and
    // folder permissions remain available after the product rename.
    static let identifier = "group.cn.wflixu.RClick"

    static let realHomeDirectory: URL = {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }()

    /// 本地签名无法获得 App Group 授权，改用双方明确获准访问的普通目录。
    /// getpwuid 返回真实用户目录；沙盒内的 homeDirectoryForCurrentUser 指向应用容器。
    static var containerURL: URL? {
#if RC_LOCAL_BUILD
        return realHomeDirectory
            .appendingPathComponent("Library/Application Support/RClickLocal", isDirectory: true)
#else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
#endif
    }
}
