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
    @Test func batchInspectionKeepsSymlinkProtectionAndChecksumTargets() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("oneclick-inspect-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let system = root.appendingPathComponent("system-link")
        try fm.createSymbolicLink(at: system, withDestinationURL: URL(fileURLWithPath: "/Applications"))
        let file = root.appendingPathComponent("actual/file.txt")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        let link = root.appendingPathComponent("file-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        let inspected = await FileActionWorker.inspect([system.path, link.path], checkProtection: true)
        #expect(inspected.map(\.isProtected) == [true, false])
        // Delete the link in its own directory; checksum the linked file's directory.
        #expect(inspected[1].directory.path == root.resolvingSymlinksInPath().path)
        let checksummed = await FileActionWorker.inspect([link.path], access: .resolvedParent)
        #expect(checksummed.first?.directory == file.deletingLastPathComponent().resolvingSymlinksInPath())
        #expect(checksummed.first?.url.path == link.path)
    }

}
