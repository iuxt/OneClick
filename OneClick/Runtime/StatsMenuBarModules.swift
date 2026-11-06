import Battery
import CPU
import Disk
import GPU
import Kit
import Net
import RAM

/// Owns the upstream Stats modules that OneClick exposes as independent menu
/// bar items. The modules keep their original NSStatusItem, reader, widget and
/// NSPanel implementations; OneClick only maps its existing visibility toggles
/// to Stats' public Module lifecycle.
@MainActor
final class StatsMenuBarModules {
    static let shared = StatsMenuBarModules()

    private struct Entry {
        let preferenceKey: String
        let defaultValue: Bool
        let module: Module
    }

    private var entries: [Entry] = []

    private init() {}

    func start() {
        guard entries.isEmpty else {
            syncVisibility()
            return
        }

        entries = [
            Entry(preferenceKey: Key.systemMonitorCPUMenuBarItem, defaultValue: true, module: CPU()),
            Entry(preferenceKey: Key.systemMonitorMemoryMenuBarItem, defaultValue: true, module: RAM()),
            Entry(preferenceKey: Key.systemMonitorNetworkMenuBarItem, defaultValue: true, module: Network()),
            Entry(preferenceKey: Key.systemMonitorDiskMenuBarItem, defaultValue: false, module: Disk()),
            Entry(preferenceKey: Key.systemMonitorGPUMenuBarItem, defaultValue: false, module: GPU()),
            Entry(preferenceKey: Key.systemMonitorBatteryMenuBarItem, defaultValue: false, module: Battery()),
        ]

        // Preserve Stats' lifecycle contract: mount starts readers and installs
        // widgets for modules whose own persisted state is already enabled.
        entries.forEach { $0.module.mount() }
        syncVisibility()
    }

    func syncVisibility(defaults: UserDefaults = .group) {
        for entry in entries {
            let enabled = defaults.object(forKey: entry.preferenceKey) as? Bool ?? entry.defaultValue
            guard enabled != entry.module.enabled else { continue }
            if enabled {
                entry.module.enable()
            } else {
                entry.module.disable()
            }
        }
    }

    func stop() {
        entries.forEach { $0.module.terminate() }
        entries.removeAll()
    }
}
