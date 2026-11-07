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
        SharedAppGroup.realHomeDirectory.path
    }
}
