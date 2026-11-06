import AppKit
import Battery
import Combine
import CPU
import Disk
import GPU
import Kit
import Net
import RAM

enum StatsModuleID: String, CaseIterable, Identifiable {
    case cpu, memory, network, disk, gpu, battery

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .gpu: "GPU"
        case .battery: "Battery"
        }
    }

    var preferenceKey: String {
        switch self {
        case .cpu: Key.systemMonitorCPUMenuBarItem
        case .memory: Key.systemMonitorMemoryMenuBarItem
        case .network: Key.systemMonitorNetworkMenuBarItem
        case .disk: Key.systemMonitorDiskMenuBarItem
        case .gpu: Key.systemMonitorGPUMenuBarItem
        case .battery: Key.systemMonitorBatteryMenuBarItem
        }
    }

    var defaultValue: Bool { self == .cpu || self == .memory || self == .network }
}

/// Shares the original Stats readers, widgets, panels and settings views.
@MainActor
final class StatsMenuBarModules: NSObject, ObservableObject {
    static let shared = StatsMenuBarModules()

    private struct Entry {
        let id: StatsModuleID
        let module: Module
    }

    private var entries: [Entry] = []

    private override init() { super.init() }

    func start() {
        guard entries.isEmpty else {
            syncVisibility()
            return
        }

        entries = [
            Entry(id: .cpu, module: CPU()),
            Entry(id: .memory, module: RAM()),
            Entry(id: .network, module: Network()),
            Entry(id: .disk, module: Disk()),
            Entry(id: .gpu, module: GPU()),
            Entry(id: .battery, module: Battery()),
        ]

        // Mount before syncing to preserve Stats' persisted widget lifecycle.
        entries.forEach { $0.module.mount() }
        syncVisibility()
        NotificationCenter.default.addObserver(self, selector: #selector(moduleToggled), name: .toggleModule, object: nil)
    }

    func module(for id: StatsModuleID) -> Module? {
        entries.first { $0.id == id }?.module
    }

    func setEnabled(_ enabled: Bool, for id: StatsModuleID, defaults: UserDefaults = .group) {
        guard let module = module(for: id), module.available else { return }
        defaults.set(enabled, forKey: id.preferenceKey)
        syncVisibility(defaults: defaults)
    }

    func syncVisibility(defaults: UserDefaults = .group) {
        objectWillChange.send()
        for entry in entries {
            let enabled = defaults.object(forKey: entry.id.preferenceKey) as? Bool ?? entry.id.defaultValue
            guard enabled != entry.module.enabled else { continue }
            if enabled {
                entry.module.enable()
            } else {
                entry.module.disable()
            }
        }
    }

    @objc private func moduleToggled(_ notification: Notification) {
        // Widget selection and the disabled-preview Enable button can also
        // enable a module. Persist explicit intent synchronously so a pending
        // overview onChange cannot restore the previous visibility preference.
        guard let name = notification.userInfo?["module"] as? String,
              let entry = entries.first(where: { $0.module.name == name }) else { return }
        let requestedState = notification.userInfo?["state"] as? Bool
        if let requestedState {
            UserDefaults.group.set(requestedState && entry.module.available, forKey: entry.id.preferenceKey)
        }
        Task { @MainActor [weak self] in
            guard let self, let entry = entries.first(where: { $0.module.name == name }) else { return }
            objectWillChange.send()
            if requestedState == nil {
                UserDefaults.group.set(entry.module.enabled, forKey: entry.id.preferenceKey)
            }
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: .toggleModule, object: nil)
        entries.forEach { $0.module.terminate() }
        entries.removeAll()
    }
}
