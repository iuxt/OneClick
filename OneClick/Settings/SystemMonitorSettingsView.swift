import SwiftUI

@available(macOS 27, *)
struct SystemMonitorSettingsView: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    @AppStorage(Key.systemMonitorRefreshInterval, store: .group) private var refreshInterval = 2.0
    @AppStorage(Key.systemMonitorCPUMenuBarItem, store: .group) private var cpuMenuBarItem = true
    @AppStorage(Key.systemMonitorMemoryMenuBarItem, store: .group) private var memoryMenuBarItem = true
    @AppStorage(Key.systemMonitorNetworkMenuBarItem, store: .group) private var networkMenuBarItem = true
    @AppStorage(Key.systemMonitorDiskMenuBarItem, store: .group) private var diskMenuBarItem = false
    @AppStorage(Key.systemMonitorGPUMenuBarItem, store: .group) private var gpuMenuBarItem = false
    @AppStorage(Key.systemMonitorBatteryMenuBarItem, store: .group) private var batteryMenuBarItem = false

    var body: some View {
        Form {
            Section {
                Picker(AppLocalization.localized("Update interval"), selection: $refreshInterval) {
                    Text(appLocalized: "Every second").tag(1.0)
                    Text(appLocalized: "Every 2 seconds").tag(2.0)
                    Text(appLocalized: "Every 5 seconds").tag(5.0)
                }
            } header: {
                Text(appLocalized: "System Monitor")
            } footer: {
                Text(appLocalized: "Overview metrics are processed locally. Stats network checks may contact the configured host.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                simpleMenuBarItem("CPU", icon: "cpu", isOn: $cpuMenuBarItem)
                simpleMenuBarItem("Memory", icon: "memorychip", isOn: $memoryMenuBarItem)
                simpleMenuBarItem("Network", icon: "network", isOn: $networkMenuBarItem)
                simpleMenuBarItem("Disk", icon: "internaldrive", isOn: $diskMenuBarItem)
                simpleMenuBarItem("GPU", icon: "display", isOn: $gpuMenuBarItem)
                simpleMenuBarItem("Battery", icon: "battery.100percent", isOn: $batteryMenuBarItem)
            } header: {
                Text(appLocalized: "Menu Bar Items")
            } footer: {
                Text(appLocalized: "Each enabled item appears separately in the menu bar. Click an item to see its history and rankings.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { monitor.start() }
        .onChange(of: refreshInterval) {
            monitor.configurationDidChange()
        }
        .onChange(of: cpuMenuBarItem) { StatsMenuBarModules.shared.syncVisibility() }
        .onChange(of: memoryMenuBarItem) { StatsMenuBarModules.shared.syncVisibility() }
        .onChange(of: networkMenuBarItem) { StatsMenuBarModules.shared.syncVisibility() }
        .onChange(of: diskMenuBarItem) { StatsMenuBarModules.shared.syncVisibility() }
        .onChange(of: gpuMenuBarItem) { StatsMenuBarModules.shared.syncVisibility() }
        .onChange(of: batteryMenuBarItem) { StatsMenuBarModules.shared.syncVisibility() }
    }

    private func simpleMenuBarItem(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(AppLocalization.localized(title), systemImage: icon)
        }
    }

}

#Preview {
    SystemMonitorSettingsView()
}
