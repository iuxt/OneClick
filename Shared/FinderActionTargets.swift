import Foundation

nonisolated enum FinderActionTargets {
    static func resolve(trigger: MenuTrigger, selected: [URL], container: URL?) -> [String] {
        if trigger == .contextualContainer { return container.map { [$0.path] } ?? [] }
        return selected.map(\.path)
    }

    static func openApp(trigger: MenuTrigger, selected: [URL], container: URL?) -> [String] {
        let paths = resolve(trigger: trigger, selected: selected, container: container)
        if paths.isEmpty && trigger == .toolbar { return container.map { [$0.path] } ?? [] }
        return paths
    }
}
