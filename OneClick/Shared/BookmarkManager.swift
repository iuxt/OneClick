//
//  BookmarkManager.swift
//  OneClick
//
//  Created by Claude on 2026/07/12.
//

import Foundation
import SwiftData
import OSLog
import AppKit
import Combine

/// Security-Scoped Bookmark 管理器
///
/// 职责：
/// - 启动时恢复持久化的 bookmark 并 startAccessing
/// - 运行时检查文件路径是否在已授权目录下
/// - 未授权时弹出 NSOpenPanel 引导用户授权
/// - 提供设置页所需的目录管理接口
@MainActor
final class BookmarkManager: ObservableObject {
    /// 当前已授权并激活访问的目录
    @Published var authorizedDirectories: [URL] = []

    private struct ActiveGrant {
        let scopedURL: URL
        let directory: URL
    }
    private var activeGrants: [String: ActiveGrant] = [:]
    private var context: ModelContext?
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void
    private let resolve: (Data) throws -> (URL, Bool)

    init(context: ModelContext? = nil,
         startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         resolve: @escaping (Data) throws -> (URL, Bool) = { data in
             var stale = false
             let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                               relativeTo: nil, bookmarkDataIsStale: &stale)
             return (url, stale)
         }) {
        self.context = context
        self.startAccess = startAccess
        self.stopAccess = stopAccess
        self.resolve = resolve
    }

    private var persistenceContext: ModelContext {
        if let context { return context }
        let context = ModelContext(SharedDataManager.sharedModelContainer)
        self.context = context
        return context
    }

    private var isPrompting = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OneClick",
        category: "BookmarkManager"
    )

    // MARK: - 恢复

    /// 从 SwiftData 恢复所有 bookmark 并 startAccessing
    func restoreBookmarks(context: ModelContext) {
        self.context = context
        guard let entities = try? context.fetch(FetchDescriptor<BookmarkEntity>()) else { return }
        for entity in entities where activeGrants[entity.id] == nil {
            do {
                let (url, stale) = try resolve(entity.bookmarkData)
                guard startAccess(url) else { continue }
                let normalized = url.resolvingSymlinksInPath()
                activeGrants[entity.id] = ActiveGrant(scopedURL: url, directory: normalized)
                if stale {
                    // Keep the old bookmark if refreshing fails; access is still active.
                    if let data = try? url.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil, relativeTo: nil) {
                        entity.bookmarkData = data
                    }
                }
                entity.pathString = normalized.path
                if !authorizedDirectories.contains(normalized) { authorizedDirectories.append(normalized) }
            } catch {
                // An unavailable volume or changed signature is not a revocation.
                logger.error("恢复 bookmark 失败，保留记录供下次重试：\(entity.pathString) — \(error.localizedDescription)")
            }
        }
        do { try context.save() }
        catch {
            context.rollback()
            logger.error("保存 bookmark 路径失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 访问检查

    /// 检查某个文件/目录是否在已授权的目录下
    func hasAccess(to url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath()
        return authorizedDirectories.contains { Self.covers($0, target) }
    }

    /// `directory` 是否覆盖 `url`（自身，或 `url` 的某个祖先）。
    ///
    /// 按路径分量比较，而不是把路径拼成字符串做前缀匹配。字符串前缀在根目录上会
    /// 失效：`dirPath + "/"` 对 `/` 拼出 `"//"`，而没有任何路径以 `//` 开头 ——
    /// 于是"把 `/` 加进授权目录"恰好命中唯一一个永远不匹配的边界，用户越授权越
    /// 用不了（Issue #155）。分量比较天然处理它：`/` 的 `pathComponents` 是 `["/"]`。
    ///
    /// 按分量比较同时也挡住了字符串前缀的另一个坑：`/Users/lixu` 不该覆盖
    /// `/Users/lixu2`，而 `hasPrefix("/Users/lixu")` 会误判为覆盖。
    ///
    /// 两个入参都必须是**已解析符号链接**的路径 —— 调用点负责这一步
    /// （`authorizedDirectories` 在写入时就已 `resolvingSymlinksInPath`）。
    /// 这样这个函数是纯函数，可以脱离 `@MainActor` 状态直接单测。
    nonisolated static func covers(_ directory: URL, _ url: URL) -> Bool {
        let dirParts = directory.pathComponents
        let targetParts = url.pathComponents
        guard targetParts.count >= dirParts.count else { return false }
        return Array(targetParts.prefix(dirParts.count)) == dirParts
    }

    // MARK: - 授权弹窗

    /// 弹出 NSOpenPanel 请求用户授权访问某个目录
    /// - Returns: 用户授权的 URL，用户取消时返回 nil
    func promptForPermission(for url: URL) async -> URL? {
        guard !isPrompting else { return nil }
        isPrompting = true
        defer { isPrompting = false }

        let panel = NSOpenPanel()
        panel.message = AppLocalization.localized("OneClick needs access to this folder to delete, create, and modify files. Choose this folder or a broader parent folder to cover its subfolders. You can manage these grants in Settings → Folder Permissions.")
        panel.prompt = AppLocalization.localized("Grant Access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = url

        // 菜单栏应用需要激活才能弹出面板
        NSApp.activate(ignoringOtherApps: true)

        let response = panel.runModal()

        guard response == .OK, let chosenURL = panel.url else {
            return nil
        }

        // 保存 bookmark
        saveBookmark(for: chosenURL)
        return chosenURL
    }

    // MARK: - 持久化

    /// 保存目录的 security-scoped bookmark
    func saveBookmark(for url: URL) {
        let normalized = url.resolvingSymlinksInPath()
        guard !activeGrants.values.contains(where: { $0.directory == normalized }) else { return }
        let context = persistenceContext
        var started = false
        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                           includingResourceValuesForKeys: nil, relativeTo: nil)
            guard startAccess(url) else { return }
            started = true
            let entity = BookmarkEntity(bookmarkData: data, pathString: normalized.path)
            context.insert(entity)
            try context.save()
            activeGrants[entity.id] = ActiveGrant(scopedURL: url, directory: normalized)
            if !authorizedDirectories.contains(normalized) { authorizedDirectories.append(normalized) }
        } catch {
            context.rollback()
            if started { stopAccess(url) }
            logger.error("保存 bookmark 失败：\(url.path) — \(error.localizedDescription)")
        }
    }

    /// Delete by the stable IDs of resolved bookmarks, including duplicate grants.
    /// Commit first so a failed save cannot silently restore permission next launch.
    func removeDirectory(_ url: URL) {
        let normalized = url.resolvingSymlinksInPath()
        let ids = Set(activeGrants.filter { $0.value.directory == normalized }.map(\.key))
        let context = persistenceContext
        do {
            let entities = try context.fetch(FetchDescriptor<BookmarkEntity>())
            for entity in entities where ids.contains(entity.id)
                || URL(fileURLWithPath: entity.pathString).resolvingSymlinksInPath() == normalized {
                context.delete(entity)
            }
            try context.save()
            for id in ids {
                if let grant = activeGrants.removeValue(forKey: id) { stopAccess(grant.scopedURL) }
            }
            authorizedDirectories.removeAll { $0 == normalized }
        } catch {
            context.rollback()
            logger.error("移除 bookmark 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 设置页工具

    /// 从设置页添加目录（弹出 NSOpenPanel）
    func addDirectory() async -> URL? {
        guard !isPrompting else { return nil }
        isPrompting = true
        defer { isPrompting = false }

        let panel = NSOpenPanel()
        panel.message = AppLocalization.localized("Choose a folder for OneClick to access.")
        panel.prompt = AppLocalization.localized("Grant Access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false

        NSApp.activate(ignoringOtherApps: true)

        let response = panel.runModal()

        guard response == .OK, let chosenURL = panel.url else {
            return nil
        }

        saveBookmark(for: chosenURL)
        return chosenURL
    }
}
