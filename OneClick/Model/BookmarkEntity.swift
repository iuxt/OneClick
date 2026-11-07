//
//  BookmarkEntity.swift
//  OneClick
//
//  Created by Claude on 2026/07/12.
//

import Foundation
import SwiftData

/// Legacy sandbox grants retained only for compatibility with existing stores.
/// The non-sandboxed host neither restores nor requires these records.
@Model
final class BookmarkEntity {
    /// 唯一标识
    @Attribute(.unique) var id: String
    /// 安全作用域 bookmark 二进制数据
    var bookmarkData: Data
    /// 目录路径（展示 + 匹配）
    var pathString: String
    /// 创建时间
    var createdAt: Date

    init(id: String = UUID().uuidString, bookmarkData: Data, pathString: String, createdAt: Date = Date()) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.pathString = pathString
        self.createdAt = createdAt
    }
}
