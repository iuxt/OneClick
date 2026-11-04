import Foundation
import SwiftData
import Testing

@testable import OneClick

/// `BookmarkManager.covers` 决定一个已授权的目录是否覆盖某条路径。
///
/// 它原先用字符串前缀做匹配，于是悄悄坏掉了用户在"怎么授权都不管用"时最会去试的
/// 那一个目录：`/`。`dirPath + "/"` 对根目录拼出 `"//"`，没有任何路径以它开头，
/// 所以把 `/` 加进授权列表等于什么都没加 —— 用户越授权越用不了（Issue #155）。
///
/// 入参约定是"已解析符号链接"的路径（调用点负责），所以这里直接喂普通路径即可。
struct BookmarkAccessTests {
    private func at(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func rootCoversEverything() {
        #expect(BookmarkManager.covers(at("/"), at("/Users/lixu/Desktop")))
        #expect(BookmarkManager.covers(at("/"), at("/Volumes/Installer")))
        #expect(BookmarkManager.covers(at("/"), at("/")))
    }

    @Test func folderCoversItselfAndItsDescendants() {
        #expect(BookmarkManager.covers(at("/Users/lixu"), at("/Users/lixu")))
        #expect(BookmarkManager.covers(at("/Users/lixu"), at("/Users/lixu/Desktop")))
        #expect(BookmarkManager.covers(at("/Users/lixu/Desktop"), at("/Users/lixu/Desktop/a.txt")))
    }

    @Test func folderDoesNotCoverSiblingsOrAncestors() {
        #expect(!BookmarkManager.covers(at("/Users/lixu/Desktop"), at("/Users/lixu/Movies")))
        #expect(!BookmarkManager.covers(at("/Users/lixu/Desktop"), at("/Users/lixu")))
        #expect(!BookmarkManager.covers(at("/Users/lixu/Desktop"), at("/")))
    }

    /// 按分量比较不能比原来按字符串比较更松：共享前缀的兄弟目录必须仍然不覆盖。
    @Test func siblingSharingAPrefixIsNotCovered() {
        #expect(!BookmarkManager.covers(at("/Users/lixu"), at("/Users/lixu2")))
        #expect(!BookmarkManager.covers(at("/Volumes/Disk"), at("/Volumes/Disk2/file")))
    }

    @MainActor
    @Test func testHostUsesAnIsolatedDatabase() {
        #expect(ProcessInfo.processInfo.environment["ONECLICK_TESTING"] == "1")
        let configurations = SharedDataManager.sharedModelContainer.configurations
        #expect(!configurations.isEmpty)
        for configuration in configurations { #expect(configuration.isStoredInMemoryOnly) }
    }

    @MainActor
    @Test func failedRestorationKeepsPersistedBookmarksForLaterLaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-bookmarks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: BookmarkEntity.self, configurations:
            ModelConfiguration(url: root.appendingPathComponent("store.sqlite"), cloudKitDatabase: .none))
        let context = ModelContext(container)
        // Invalid data reliably exercises the resolution error path without
        // requiring real folder permissions or changing the user's grants.
        let entities = [
            BookmarkEntity(bookmarkData: Data([0, 1, 2]), pathString: root.appendingPathComponent("first").path),
            BookmarkEntity(bookmarkData: Data([3, 4, 5]), pathString: root.appendingPathComponent("second").path),
        ]
        let expectedData = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0.bookmarkData) })
        let expectedPaths = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0.pathString) })
        for entity in entities { context.insert(entity) }
        try context.save()

        // Fresh managers and contexts simulate repeated launches. A failed
        // resolution must neither erase the saved grant nor activate access.
        for _ in 0..<2 {
            let manager = BookmarkManager()
            manager.restoreBookmarks(context: ModelContext(container))
            let verificationContext = ModelContext(container)
            let saved = try verificationContext.fetch(FetchDescriptor<BookmarkEntity>())
            #expect(Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.bookmarkData) }) == expectedData)
            #expect(Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.pathString) }) == expectedPaths)
            #expect(manager.authorizedDirectories.isEmpty)
            for path in expectedPaths.values {
                #expect(!manager.hasAccess(to: URL(fileURLWithPath: path)))
            }
        }
    }
}
