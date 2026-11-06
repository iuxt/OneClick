//
//  ActionEntity.swift
//  OneClick
//
//  Created by Claude on 2026/01/16.
//

import SwiftData
import Foundation

/// 动作实体 - 用于存储右键菜单动作配置
@Model
final class ActionEntity {
    @Attribute(.unique) var id: String
    var name: String
    var icon: String
    var isEnabled: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         icon: String,
         isEnabled: Bool = true,
         sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// 从 RCAction 转换
    convenience init(from action: RCAction) {
        self.init(
            id: action.id,
            name: action.name,
            icon: action.icon,
            isEnabled: action.enabled,
            sortOrder: action.idx
        )
    }

    // 预定义动作的工厂方法
    static func createDefaultActions() -> [ActionEntity] {
        return [
            ActionEntity(id: "copy-path", name: "Copy Path", icon: "doc.on.doc", isEnabled: true, sortOrder: 0),
            ActionEntity(id: "delete-direct", name: "Delete Direct", icon: "trash", isEnabled: true, sortOrder: 1),
            ActionEntity(id: "hide", name: "Hide", icon: "eye.slash", isEnabled: false, sortOrder: 2),
            ActionEntity(id: "unhide", name: "Unhide", icon: "eye", isEnabled: false, sortOrder: 3),
            ActionEntity(id: "airdrop", name: "AirDrop", icon: "paperplane", isEnabled: false, sortOrder: 4),
            ActionEntity(id: "checksum", name: "File Checksums", icon: "number.square", isEnabled: true, sortOrder: 5),
            ActionEntity(id: "compress-zip", name: "Compress to ZIP", icon: "archivebox", isEnabled: true, sortOrder: 6),
            ActionEntity(id: "compress-7z", name: "Compress to 7Z", icon: "archivebox", isEnabled: true, sortOrder: 7),
            ActionEntity(id: "compress-targz", name: "Compress to TAR.GZ", icon: "archivebox", isEnabled: true, sortOrder: 8),
            ActionEntity(id: "extract", name: "Extract Here", icon: "shippingbox", isEnabled: true, sortOrder: 9),
            ActionEntity(id: "compress", name: "Compress…", icon: "archivebox", isEnabled: true, sortOrder: 10),
            ActionEntity(id: "compress-zip-separately", name: "Compress to Separate ZIPs", icon: "archivebox", isEnabled: true, sortOrder: 11),
            ActionEntity(id: "compress-7z-separately", name: "Compress to Separate 7Zs", icon: "archivebox", isEnabled: true, sortOrder: 12),
            ActionEntity(id: "compress-zip-and-delete", name: "Compress to ZIP and Delete Originals", icon: "archivebox", isEnabled: true, sortOrder: 13),
            ActionEntity(id: "compress-7z-and-delete", name: "Compress to 7Z and Delete Originals", icon: "archivebox", isEnabled: true, sortOrder: 14),
            ActionEntity(id: "compress-zip-separately-and-delete", name: "Compress to Separate ZIPs and Delete Originals", icon: "archivebox", isEnabled: true, sortOrder: 15),
            ActionEntity(id: "compress-7z-separately-and-delete", name: "Compress to Separate 7Zs and Delete Originals", icon: "archivebox", isEnabled: true, sortOrder: 16),
            ActionEntity(id: "extract-and-delete", name: "Extract and Delete Archive", icon: "shippingbox", isEnabled: true, sortOrder: 17),
        ]
    }
}
