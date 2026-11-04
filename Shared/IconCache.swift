//
//  IconCache.swift
//  OneClick
//
//  统一的图标缓存管理器
//

import AppKit
import Foundation

/// 统一的图标缓存管理器
/// 为 Main App 和 Extension 提供共享的图标缓存服务
@MainActor
public class IconCache {
    public static let shared = IconCache()

    private var memoryCache: [String: NSImage] = [:]
    private let iconSize = CGSize(width: 32, height: 32)

    private init() {}

    /// 获取文件图标
    /// - Parameter url: 文件 URL
    /// - Returns: 缩放后的图标图片
    public func icon(for url: URL) -> NSImage {
        let cacheKey = url.path
        if let cached = memoryCache[cacheKey] {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = iconSize
        memoryCache[cacheKey] = icon
        return icon
    }

    /// Settings rows must not block their first layout on LaunchServices or disk.
    public func loadIcon(for url: URL) async -> NSImage {
        if let cached = memoryCache[url.path] { return cached }
        let image = await Self.workspaceIcon(for: url)
        if let cached = memoryCache[url.path] { return cached }
        image.size = iconSize
        memoryCache[url.path] = image
        return image
    }

    @concurrent
    nonisolated private static func workspaceIcon(for url: URL) async -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// 预加载图标
    /// - Parameter urls: 需要预加载的 URL 列表
    public func preloadIcons(for urls: [URL]) {
        for url in urls {
            _ = icon(for: url)
        }
    }

    /// 清除缓存
    public func clearCache() {
        memoryCache.removeAll()
    }

    /// 缓存中的图标数量
    public var cacheSize: Int {
        memoryCache.count
    }
}
