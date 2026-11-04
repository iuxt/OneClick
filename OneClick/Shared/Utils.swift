import Foundation

public class Utils {
    nonisolated public static func isProtectedFolder(_ path: String) -> Bool {
        protectedPaths().contains(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().pathComponents)
    }

    /// Resolve once per batch, never indefinitely cache paths whose symlinks can change.
    nonisolated static func protectedPaths() -> Set<[String]> {
        Set([["/"]] + Constants.protectedDirs.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        })
    }
    // MARK: 
    nonisolated public static func getRealHomeDir() -> String {
        let fullPath = NSHomeDirectory()
        let components = fullPath.components(separatedBy: "/")
        let limitedComponents = Array(components.prefix(3))  // 取前3个是因为第一个是空字符串（路径以/开头）
        return limitedComponents.joined(separator: "/")
    }
}
