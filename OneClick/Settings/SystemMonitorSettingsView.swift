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
    @AppStorage(Key.systemMonitorDiskMenuBarStyle, store: .group) private var diskStyle = DiskMenuBarStyle.percentage.rawValue

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
                Text(appLocalized: "Resource data stays on this Mac and is not sent to any server.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                simpleMenuBarItem("CPU", icon: "cpu", isOn: $cpuMenuBarItem)
                simpleMenuBarItem("Memory", icon: "memorychip", isOn: $memoryMenuBarItem)
                simpleMenuBarItem("Network", icon: "network", isOn: $networkMenuBarItem)
                menuBarItem(
                    "Disk",
                    icon: "internaldrive",
                    isOn: $diskMenuBarItem,
                    style: $diskStyle,
                    styles: DiskMenuBarStyle.allCases.map { ($0.rawValue, $0.title) }
                )
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
    }

    private func simpleMenuBarItem(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(AppLocalization.localized(title), systemImage: icon)
        }
    }

    private func menuBarItem(
        _ title: String,
        icon: String,
        isOn: Binding<Bool>,
        style: Binding<Int>,
        styles: [(Int, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) {
                Label(AppLocalization.localized(title), systemImage: icon)
            }
            Picker(AppLocalization.localized("Display"), selection: style) {
                ForEach(styles, id: \.0) { value, title in
                    Text(AppLocalization.localized(title)).tag(value)
                }
            }
            .controlSize(.small)
            .disabled(!isOn.wrappedValue)
        }
    }
}

#Preview {
    SystemMonitorSettingsView()
}
