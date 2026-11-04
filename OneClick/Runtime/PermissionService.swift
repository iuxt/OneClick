//
//  PermissionService.swift
//  OneClick
//
//  权限服务层：对上层（ActionService 等）隐藏 Bookmark 的实现细节。
//  今天是 Security-Scoped Bookmark，未来可能是 User Selected / Container /
//  V3 非沙盒的 Direct File Access —— 上层不应感知实现。
//

import Foundation

/// 权限服务协议（供 ActionService 注入 mock，便于单测）
@MainActor
protocol PermissionProviding: AnyObject {
    /// 检查某个文件/目录是否在已授权目录下
    func hasAccess(to url: URL) -> Bool
    /// The caller resolves symlinks off main before using this batch check.
    func hasAccess(toResolvedURL url: URL) -> Bool
    /// 弹出 NSOpenPanel 请求目录访问权限
    func promptForPermission(for url: URL) async -> URL?
    /// 保存目录的 security-scoped bookmark
    func saveBookmark(for url: URL)
}

extension PermissionProviding {
    func hasAccess(toResolvedURL url: URL) -> Bool { hasAccess(to: url) }
}

/// 权限服务：内部委托 BookmarkManager
@MainActor
final class PermissionService: PermissionProviding {
    private let bookmarkManager: BookmarkManager

    init(bookmarkManager: BookmarkManager) {
        self.bookmarkManager = bookmarkManager
    }

    func hasAccess(to url: URL) -> Bool {
        bookmarkManager.hasAccess(to: url)
    }

    func hasAccess(toResolvedURL url: URL) -> Bool {
        bookmarkManager.authorizedDirectories.contains { BookmarkManager.covers($0, url) }
    }

    func promptForPermission(for url: URL) async -> URL? {
        await bookmarkManager.promptForPermission(for: url)
    }

    func saveBookmark(for url: URL) {
        bookmarkManager.saveBookmark(for: url)
    }
}
