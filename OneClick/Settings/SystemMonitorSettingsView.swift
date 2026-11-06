import Kit
import SwiftUI

@available(macOS 27, *)
struct SystemMonitorSettingsView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var stats = StatsMenuBarModules.shared
    @Environment(\.isSettingsPageActive) private var isPageActive
    @State private var selectedModule: StatsModuleID?
    @State private var previewModules: Set<StatsModuleID> = []

    @AppStorage(Key.systemMonitorRefreshInterval, store: .group) private var refreshInterval = 2.0
    @AppStorage(Key.systemMonitorCPUMenuBarItem, store: .group) private var cpuMenuBarItem = true
    @AppStorage(Key.systemMonitorMemoryMenuBarItem, store: .group) private var memoryMenuBarItem = true
    @AppStorage(Key.systemMonitorNetworkMenuBarItem, store: .group) private var networkMenuBarItem = true
    @AppStorage(Key.systemMonitorDiskMenuBarItem, store: .group) private var diskMenuBarItem = false
    @AppStorage(Key.systemMonitorGPUMenuBarItem, store: .group) private var gpuMenuBarItem = false
    @AppStorage(Key.systemMonitorBatteryMenuBarItem, store: .group) private var batteryMenuBarItem = false

    var body: some View {
        VStack(spacing: 0) {
            Picker(AppLocalization.localized("System Monitor"), selection: $selectedModule) {
                Text(appLocalized: "Overview").tag(nil as StatsModuleID?)
                ForEach(StatsModuleID.allCases) { id in
                    Text(AppLocalization.localized(id.titleKey)).tag(Optional(id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            if let id = selectedModule {
                moduleSettings(for: id)
            } else {
                overview
            }
        }
        .onAppear {
            monitor.start()
            stats.start()
        }
    }

    @ViewBuilder
    private func moduleSettings(for id: StatsModuleID) -> some View {
        if let module = stats.module(for: id), module.available {
            HStack {
                Toggle(AppLocalization.localized("Show in menu bar"), isOn: Binding(
                    get: { module.enabled },
                    set: { stats.setEnabled($0, for: id) }
                ))
                .toggleStyle(.switch)
                Spacer()
                if module.config.hasPreview {
                    Toggle(AppLocalization.localized("Live Preview"), isOn: Binding(
                        get: { previewModules.contains(id) },
                        set: { visible in
                            if visible { previewModules.insert(id) }
                            else { previewModules.remove(id) }
                        }
                    ))
                    .toggleStyle(.button)
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 12)

            StatsModuleSettingsView(
                module: module,
                isActive: isPageActive,
                showsPreview: previewModules.contains(id)
            )
            .padding(.horizontal, 10)
        } else {
            ContentUnavailableView {
                Label(AppLocalization.localized(id.titleKey), systemImage: "gauge.with.dots.needle.50percent")
            } description: {
                Text(appLocalized: "This monitoring module is not available on this Mac.")
            }
        }
    }

    private var overview: some View {
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
