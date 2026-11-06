import AppKit
import Kit
import Testing
@testable import OneClick

@MainActor
@Suite(.serialized)
struct StatsSettingsTests {
    @Test func embeddedSettingsPreserveControlsAndStopPreviewWhenInactive() async throws {
        let stats = StatsMenuBarModules.shared
        stats.start()
        let cpu = try #require(stats.module(for: .cpu))
        let memory = try #require(stats.module(for: .memory))
        let cpuSettings = try #require(cpu.window)
        let memorySettings = try #require(memory.window)
        let container = StatsSettingsContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        let probe = StatsVisibilityProbe()
        NotificationCenter.default.addObserver(probe, selector: #selector(StatsVisibilityProbe.receive), name: .openWindow, object: container)
        defer {
            container.detach()
            window.close()
            NotificationCenter.default.removeObserver(probe)
        }

        container.configure(module: cpu, isActive: true, showsPreview: false)
        window.orderFront(nil)
        for _ in 0..<50 {
            if probe.moduleName == cpu.name { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.moduleName == cpu.name)
        #expect(cpuSettings.superview === container)
        #expect(cpuSettings.subviews.first?.isHidden == false)
        let controls = cpuSettings.subviews.first

        // Switching a cached OneClick page must release Stats' visible readers.
        container.configure(module: cpu, isActive: false, showsPreview: false)
        #expect(probe.moduleName == nil)
        container.configure(module: cpu, isActive: true, showsPreview: true)
        #expect(probe.moduleName == cpu.name)
        #expect(cpuSettings.subviews.first?.isHidden == cpu.config.hasPreview)
        container.configure(module: cpu, isActive: true, showsPreview: false)
        #expect(cpuSettings.subviews.first === controls)

        container.configure(module: memory, isActive: true, showsPreview: false)
        #expect(probe.moduleName == memory.name)
        #expect(cpuSettings.superview == nil)
        #expect(memorySettings.superview === container)
        window.close()
        #expect(probe.moduleName == nil)
    }

    @Test func moduleControlsAndUpstreamWidgetActivationShareVisibility() async throws {
        let stats = StatsMenuBarModules.shared
        stats.start()
        let id = StatsModuleID.cpu
        let module = try #require(stats.module(for: id))
        let originalState = module.enabled
        let originalPreference = UserDefaults.group.object(forKey: id.preferenceKey)
        defer {
            stats.setEnabled(originalState, for: id)
            if let originalPreference { UserDefaults.group.set(originalPreference, forKey: id.preferenceKey) }
            else { UserDefaults.group.removeObject(forKey: id.preferenceKey) }
        }

        stats.setEnabled(false, for: id)
        #expect(!module.enabled)
        #expect(!UserDefaults.group.bool(forKey: id.preferenceKey))
        NotificationCenter.default.post(name: .toggleModule, object: nil, userInfo: ["module": module.name, "state": true])
        for _ in 0..<50 {
            if UserDefaults.group.bool(forKey: id.preferenceKey) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(module.enabled)
        #expect(UserDefaults.group.bool(forKey: id.preferenceKey))
        stats.syncVisibility()
        #expect(module.enabled)
    }
}

@MainActor
private final class StatsVisibilityProbe: NSObject {
    var moduleName: String?

    @objc func receive(_ notification: Notification) {
        moduleName = notification.userInfo?["module"] as? String
    }
}
