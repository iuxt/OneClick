import Foundation
import Testing
@testable import OneClick

@MainActor
private final class FakeInputMethods: InputMethodProviding {
    var current = "english"
    var selected: [String] = []
    func sources() -> [InputMethodSource] { [InputMethodSource(id: "english", name: "English"), InputMethodSource(id: "chinese", name: "Chinese")] }
    func currentID() -> String? { current }
    func select(_ id: String) -> Bool { selected.append(id); current = id; return true }
}

@MainActor
struct InputMethodServiceTests {
    @Test func rulePriorityAndFallback() {
        var config = InputMethodConfiguration(enabled: true, defaultSourceID: "english", remember: true,
                                            rules: [InputMethodRule(bundleID: "editor", name: "Editor", sourceID: "chinese")],
                                            rememberedSources: ["editor": "english", "chat": "chinese"])
        #expect(config.target(for: "editor") == "chinese")
        #expect(config.target(for: "chat") == "chinese")
        #expect(config.target(for: "other") == "english")
        config.remember = false
        #expect(config.target(for: "chat") == "english")
        config.defaultSourceID = ""
        #expect(config.target(for: "other") == nil)
    }

    @Test func cancelledSwitchDoesNotApplyToNextApplication() async throws {
        let name = "oneclick-input-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeInputMethods()
        let service = InputMethodService(defaults: defaults, provider: provider, secureInputEnabled: { false })
        service.update { $0.enabled = true; $0.rules = [InputMethodRule(bundleID: "editor", name: "Editor", sourceID: "chinese")] }
        service.activate(bundleID: "editor")
        service.activate(bundleID: "unconfigured")
        try await Task.sleep(for: .milliseconds(350))
        #expect(provider.selected.isEmpty)
        service.activate(bundleID: "editor")
        let deadline = ContinuousClock.now + .seconds(3)
        while provider.selected.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(provider.selected == ["chinese"])
        service.stop()
        let restored = InputMethodService(defaults: defaults, provider: provider, secureInputEnabled: { false })
        #expect(restored.configuration.enabled)
        #expect(restored.configuration.target(for: "editor") == "chinese")
    }

    @Test func disabledServiceNeverSwitches() async throws {
        let name = "oneclick-input-disabled-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeInputMethods()
        let service = InputMethodService(defaults: defaults, provider: provider, secureInputEnabled: { false })
        service.update { $0.defaultSourceID = "chinese" }
        service.activate(bundleID: "editor")
        try await Task.sleep(for: .milliseconds(300))
        #expect(provider.selected.isEmpty)
        service.stop()
    }

    @Test func secureInputPreventsSwitching() async throws {
        let name = "oneclick-input-secure-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = FakeInputMethods()
        let service = InputMethodService(defaults: defaults, provider: provider, secureInputEnabled: { true })
        service.update { $0.enabled = true; $0.defaultSourceID = "chinese" }
        service.activate(bundleID: "editor")
        try await Task.sleep(for: .milliseconds(350))
        #expect(provider.selected.isEmpty)
        service.stop()
    }
}
