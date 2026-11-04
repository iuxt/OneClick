import Foundation
import Testing
@testable import OneClick

struct InstalledApplicationTests {
    @Test func discoveryIncludesNestedFoldersButSkipsAppContentsAndHiddenApps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Editor.app/Contents/Helper.app", "Utilities/Terminal.app", ".Hidden.app", "Document.txt"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let applications = await InstalledApplication.discover(in: [root, root, root.appendingPathComponent("missing")])
        #expect(applications.map(\.name) == ["Editor", "Terminal"])
        #expect(Set(applications.map(\.url)).count == 2)
    }
}
