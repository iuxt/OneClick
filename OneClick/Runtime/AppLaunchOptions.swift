import AppKit

/// Keep the same options for the initial launch and a permission retry.
struct AppLaunchOptions {
    let arguments: [String]
    let environment: [String: String]
    let opensNewInstance: Bool

    init(app: OpenWithApp, defaults: UserDefaults = .group) {
        let globalArguments = (defaults.string(forKey: Key.globalApplicationArgumentsString) ?? "")
            .components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        arguments = (app.inheritFromGlobalArguments ? globalArguments : []) + app.arguments
        var variables: [String: String] = [:]
        if app.inheritFromGlobalEnvironment {
            let value = defaults.string(forKey: Key.globalApplicationEnvironmentString) ?? ""
            for line in value.components(separatedBy: .newlines) {
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2 {
                    let key = pair[0].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { variables[key] = pair[1].trimmingCharacters(in: .whitespaces) }
                }
            }
        }
        environment = variables.merging(app.environment) { _, appValue in appValue }
        opensNewInstance = app.opensNewInstance
    }

    func configuration() -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        config.environment = environment
        config.createsNewApplicationInstance = opensNewInstance
        return config
    }
}
