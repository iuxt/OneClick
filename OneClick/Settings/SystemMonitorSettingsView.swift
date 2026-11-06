import SwiftUI

@available(macOS 27, *)
struct SystemMonitorSettingsView: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    @AppStorage(Key.systemMonitorRefreshInterval, store: .group) private var refreshInterval = 2.0
    @AppStorage(Key.systemMonitorShowCPU, store: .group) private var showCPU = true
    @AppStorage(Key.systemMonitorShowGPU, store: .group) private var showGPU = true
    @AppStorage(Key.systemMonitorShowMemory, store: .group) private var showMemory = true
    @AppStorage(Key.systemMonitorShowDisk, store: .group) private var showDisk = true
    @AppStorage(Key.systemMonitorShowNetwork, store: .group) private var showNetwork = true
    @AppStorage(Key.systemMonitorShowBattery, store: .group) private var showBattery = true
    @AppStorage(Key.systemMonitorCPUMenuBarItem, store: .group) private var cpuMenuBarItem = true
    @AppStorage(Key.systemMonitorMemoryMenuBarItem, store: .group) private var memoryMenuBarItem = true
    @AppStorage(Key.systemMonitorNetworkMenuBarItem, store: .group) private var networkMenuBarItem = true
    @AppStorage(Key.systemMonitorDiskMenuBarItem, store: .group) private var diskMenuBarItem = false
    @AppStorage(Key.systemMonitorGPUMenuBarItem, store: .group) private var gpuMenuBarItem = false
    @AppStorage(Key.systemMonitorBatteryMenuBarItem, store: .group) private var batteryMenuBarItem = false
    @AppStorage(Key.systemMonitorCPUMenuBarStyle, store: .group) private var cpuStyle = CPUMenuBarStyle.percentage.rawValue
    @AppStorage(Key.systemMonitorMemoryMenuBarStyle, store: .group) private var memoryStyle = MemoryMenuBarStyle.percentage.rawValue
    @AppStorage(Key.systemMonitorNetworkMenuBarStyle, store: .group) private var networkStyle = NetworkMenuBarStyle.both.rawValue
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
                menuBarItem(
                    "CPU",
                    icon: "cpu",
                    isOn: $cpuMenuBarItem,
                    style: $cpuStyle,
                    styles: CPUMenuBarStyle.allCases.map { ($0.rawValue, $0.title) }
                )
                menuBarItem(
                    "Memory",
                    icon: "memorychip",
                    isOn: $memoryMenuBarItem,
                    style: $memoryStyle,
                    styles: MemoryMenuBarStyle.allCases.map { ($0.rawValue, $0.title) }
                )
                menuBarItem(
                    "Network",
                    icon: "network",
                    isOn: $networkMenuBarItem,
                    style: $networkStyle,
                    styles: NetworkMenuBarStyle.allCases.map { ($0.rawValue, $0.title) }
                )
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
            Section {
                moduleToggle("CPU", icon: "cpu", isOn: $showCPU)
                moduleToggle("GPU", icon: "display", isOn: $showGPU)
                moduleToggle("Memory", icon: "memorychip", isOn: $showMemory)
                moduleToggle("Disk", icon: "internaldrive", isOn: $showDisk)
                moduleToggle("Network", icon: "network", isOn: $showNetwork)
                moduleToggle("Battery", icon: "battery.100percent", isOn: $showBattery)
            } header: {
                Text(appLocalized: "Overview Panel")
            } footer: {
                Text(appLocalized: "GPU and battery cards appear only when the hardware exposes those metrics.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent {
                    Text(SystemMonitorFormatting.percent(monitor.snapshot.cpu.total))
                        .monospacedDigit()
                } label: {
                    Label(AppLocalization.localized("CPU"), systemImage: "cpu")
                }

                LabeledContent {
                    Text("\(SystemMonitorFormatting.bytes(monitor.snapshot.memory.used)) / \(SystemMonitorFormatting.bytes(monitor.snapshot.memory.total))")
                        .monospacedDigit()
                } label: {
                    Label(AppLocalization.localized("Memory"), systemImage: "memorychip")
                }

                LabeledContent {
                    Text("↓ \(SystemMonitorFormatting.speed(monitor.snapshot.network.downloadBytesPerSecond))  ↑ \(SystemMonitorFormatting.speed(monitor.snapshot.network.uploadBytesPerSecond))")
                        .monospacedDigit()
                } label: {
                    Label(AppLocalization.localized("Network"), systemImage: "network")
                }
            } header: {
                Text(appLocalized: "Live Preview")
            }
        }
        .formStyle(.grouped)
        .onAppear { monitor.start() }
        .onChange(of: refreshInterval) {
            monitor.configurationDidChange()
        }
    }

    private func moduleToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(AppLocalization.localized(title), systemImage: icon)
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
