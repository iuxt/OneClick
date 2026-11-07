//
//  CommonDirEntity.swift
//  OneClick
//
//  Created by Claude on 2026/01/16.
//

import SwiftData
import Foundation

/// 常用目录实体 - 用于存储快速访问目录
@Model
final class CommonDirEntity {
    @Attribute(.unique) var id: String
    var name: String
    var pathString: String
    var pathEncodingVersion: Int = 0
    var icon: String
    var sortOrder: Int
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         path: URL,
         icon: String = "folder",
         sortOrder: Int = 0,
         isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.pathString = path.path
        self.pathEncodingVersion = 1
        self.icon = icon
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var path: URL {
        get {
            URL(fileURLWithPath: pathEncodingVersion == 0 ? (pathString.removingPercentEncoding ?? pathString) : pathString)
        }
        set {
            pathString = newValue.path
            pathEncodingVersion = 1
        }
    }

    /// Decode old URL.path() storage exactly once, then repair only untouched
    /// built-in shortcuts that still point into this app's sandbox home.
    @discardableResult
    func migratePath(sandboxHome: URL = LegacySandboxMigration.legacyDataDirectory,
                     realHome: URL = SharedAppGroup.realHomeDirectory) -> Bool {
        guard pathEncodingVersion == 0 else { return false }
        path = self.path
        let suffixes = ["home": "", "desktop": "Desktop", "documents": "Documents", "downloads": "Downloads"]
        if sandboxHome.pathComponents != realHome.pathComponents, let suffix = suffixes[id] {
            let old = suffix.isEmpty ? sandboxHome : sandboxHome.appendingPathComponent(suffix)
            if path.standardizedFileURL.pathComponents == old.standardizedFileURL.pathComponents {
                path = suffix.isEmpty ? realHome : realHome.appendingPathComponent(suffix)
            }
        }
        return true
    }

    /// 从 CommonDir 转换
    convenience init(from commonDir: CommonDir) {
        self.init(
            id: commonDir.id,
            name: commonDir.name,
            path: commonDir.url,
            icon: commonDir.icon
        )
    }

    // 预定义常用目录的工厂方法
    static func createDefaultCommonDirs(homeDir: URL = SharedAppGroup.realHomeDirectory) -> [CommonDirEntity] {
        var dirs: [CommonDirEntity] = []

        let desktop = homeDir.appendingPathComponent("Desktop")
        let documents = homeDir.appendingPathComponent("Documents")
        let downloads = homeDir.appendingPathComponent("Downloads")

        dirs.append(CommonDirEntity(id: "desktop", name: "Desktop", path: desktop, icon: iconForDirectory(url: desktop), sortOrder: 0))
        dirs.append(CommonDirEntity(id: "documents", name: "Documents", path: documents, icon: iconForDirectory(url: documents), sortOrder: 1))
        dirs.append(CommonDirEntity(id: "downloads", name: "Downloads", path: downloads, icon: iconForDirectory(url: downloads), sortOrder: 2))
        dirs.append(CommonDirEntity(id: "applications", name: "Applications", path: URL(fileURLWithPath: "/Applications"), icon: iconForDirectory(url: URL(fileURLWithPath: "/Applications")), sortOrder: 3))
        dirs.append(CommonDirEntity(id: "home", name: "Home", path: homeDir, icon: iconForDirectory(url: homeDir), sortOrder: 4))

        return dirs
    }
}
