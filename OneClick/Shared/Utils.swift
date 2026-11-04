import Foundation

public class Utils {
    nonisolated public static func isProtectedFolder(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        if target == ["/"] { return true }
        return Constants.protectedDirs.contains { protectedPath in
            let protected = URL(fileURLWithPath: protectedPath).standardizedFileURL.resolvingSymlinksInPath().pathComponents
            // Protect the directory itself. Its descendants remain available
            // for explicitly authorized file operations (e.g. on Desktop).
            return target == protected
        }
    }
    // MARK: 
    nonisolated public static func getRealHomeDir() -> String {
        let fullPath = NSHomeDirectory()
        let components = fullPath.components(separatedBy: "/")
        let limitedComponents = Array(components.prefix(3))  // 取前3个是因为第一个是空字符串（路径以/开头）
        return limitedComponents.joined(separator: "/")
    }
}
