import AppKit
import Combine
import SwiftUI
import Testing
@testable import OneClick

@MainActor
struct SettingsNavigationTests {
    @Test func settingsTabsAreGroupedByFeatureModule() {
        let groupedTabs = SettingsModule.allCases.flatMap(\.tabs)

        #expect(groupedTabs.count == Tabs.allCases.count)
        #expect(Set(groupedTabs) == Set(Tabs.allCases))
        #expect(SettingsModule.rightClickTools.tabs == [.actions, .apps, .newFile, .cdirs])
        #expect(SettingsModule.general.tabs == [.general, .permissions, .management, .about])
        #expect(SettingsModule.archives.tabs == [.archives, .archiveMenu, .archiveAssociations])
        #expect(SettingsModule.inputMethods.tabs == [.inputMethods, .inputRules])
        #expect(SettingsModule.allCases.allSatisfy { module in
            module.tabs.allSatisfy { $0.module == module }
        })
        #expect(SettingsModule.allCases.allSatisfy { $0.defaultTab.module == $0 })
    }

    @Test func settingsRequestsAreDeliveredWithoutMountedViews() async throws {
        // No MenuBarExtra or settings content is mounted. The Scene's receiver
        // must still deliver every manual launch/reopen request.
        let center = NotificationCenter()
        let requests = SettingsWindowRequests(center: center)
        for expected in 1...3 {
            center.post(name: .openSettingsRequested, object: nil)
            for _ in 0..<50 {
                if requests.generation == expected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(requests.generation == expected)
        }
    }

    @Test func navigationRetainsPageStateAndOnlyActivatesTheSelectedPage() async throws {
        let model = NavigationProbe()
        let host = NSHostingView(rootView: NavigationHarness(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        func render(_ tab: Tabs) async throws {
            model.selection = tab
            host.layoutSubtreeIfNeeded()
            // Let SwiftUI finish appearance/environment callbacks between clicks.
            for _ in 0..<50 {
                if model.active[tab] == true && model.active.values.filter({ $0 }).count == 1 { return }
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
            Issue.record("The selected settings page did not become active")
        }

        try await render(.actions)
        let actionState = try #require(model.states[.actions])
        #expect(model.states.count == 1)

        try await render(.archives)
        let archiveState = try #require(model.states[.archives])
        #expect(model.active[.actions] == false)
        #expect(model.states.count == 2)

        try await render(.actions)
        #expect(model.states[.actions] == actionState)
        #expect(model.active[.archives] == false)
        try await render(.archives)
        #expect(model.states[.archives] == archiveState)
        #expect(model.appearances[.actions] == 1)
        #expect(model.appearances[.archives] == 1)
        #expect(model.states.count == 2)
    }
}

@MainActor
private final class NavigationProbe: ObservableObject {
    @Published var selection: Tabs = .actions
    var states: [Tabs: UUID] = [:]
    var active: [Tabs: Bool] = [:]
    var appearances: [Tabs: Int] = [:]
}

private struct NavigationHarness: View {
    @ObservedObject var model: NavigationProbe

    var body: some View {
        SettingsPageStack(selection: model.selection) { tab in
            NavigationProbePage(tab: tab, model: model)
        }
    }
}

private struct NavigationProbePage: View {
    let tab: Tabs
    let model: NavigationProbe
    @State private var state = UUID()
    @Environment(\.isSettingsPageActive) private var isActive

    var body: some View {
        Form { Text(tab.rawValue) }
            .onAppear { model.appearances[tab, default: 0] += 1 }
            .onChange(of: isActive, initial: true) {
                model.active[tab] = isActive
                model.states[tab] = state
            }
    }
}
