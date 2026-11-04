import Foundation

nonisolated enum FinderActionTargets {
    static func resolve(trigger: MenuTrigger, selected: [URL], container: URL?) -> [String] {
        if trigger == .contextualContainer { return container.map { [$0.path] } ?? [] }
        return selected.map(\.path)
    }
}
