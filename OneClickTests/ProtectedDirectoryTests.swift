import Foundation
import Testing
@testable import OneClick

@MainActor
struct ProtectedDirectoryTests {
    @Test(arguments: ["/", "/Applications", "/Applications/", "/System", "/System/", "/Library", "/Users", "/usr", "/bin", "/sbin", "/var", "/private/var", "/Applications/../System"])
    func protectedDirectorySpellingsAreBlocked(path: String) {
        #expect(Utils.isProtectedFolder(path))
    }

    @Test func symlinkToProtectedDirectoryIsBlockedWithoutBlockingOrdinaryDescendants() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("oneclick-protection-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let link = root.appendingPathComponent("applications-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Applications"))
        #expect(Utils.isProtectedFolder(link.path))
        #expect(!Utils.isProtectedFolder(root.appendingPathComponent("Applications").path))
        #expect(!Utils.isProtectedFolder("/Applications/OneClick.app"))
        #expect(!Utils.isProtectedFolder(Constants.HomedirPath + "/Desktop/file.txt"))
        #expect(Utils.isProtectedFolder(Constants.HomedirPath + "/Desktop"))
    }
}
