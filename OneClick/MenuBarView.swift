//
//  MenuBarView.swift
//  OneClick
//
//  Created by 李旭 on 2024/4/4.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Open settings window

/// Brings the settings window forward. OneClick is an LSUIElement app, so it
/// must activate itself explicitly after opening the window.
@MainActor
func showSettingsWindow(openWindow: OpenWindowAction) {
    openWindow(id: Constants.settingsWindowID)

    if let existingWindow = NSApplication.shared.windows.first(where: {
        $0.identifier?.rawValue == Constants.settingsWindowID
    }) {
        existingWindow.makeKeyAndOrderFront(nil)
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
}

/// Owned by the settings Scene, so hiding the menu bar icon or closing the last
/// window never removes the receiver for a manual launch/reopen request.
@MainActor
final class SettingsWindowRequests: ObservableObject {
    @Published private(set) var generation = 0
    private var subscription: AnyCancellable?

    init(center: NotificationCenter = .default) {
        subscription = center.publisher(for: .openSettingsRequested)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.generation += 1
                }
            }
    }
}

struct SystemMonitorMenuBarLabel: View {
    var body: some View {
        Image("MenuBar")
        .accessibilityLabel(AppLocalization.localized("OneClick System Monitor"))
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var monitor = SystemMonitor.shared

    @AppStorage(Key.systemMonitorShowCPU, store: .group) private var showCPU = true
    @AppStorage(Key.systemMonitorShowGPU, store: .group) private var showGPU = true
    @AppStorage(Key.systemMonitorShowMemory, store: .group) private var showMemory = true
    @AppStorage(Key.systemMonitorShowDisk, store: .group) private var showDisk = true
    @AppStorage(Key.systemMonitorShowNetwork, store: .group) private var showNetwork = true
    @AppStorage(Key.systemMonitorShowBattery, store: .group) private var showBattery = true

    private let messager = Messager.shared

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    if showCPU { cpuCard }
                    if showGPU, let gpu = monitor.snapshot.gpu { gpuCard(gpu) }
                    if showMemory { memoryCard }
                    if showDisk { diskCard }
                    if showNetwork { networkCard }
                    if showBattery, let battery = monitor.snapshot.battery { batteryCard(battery) }
                }
                .padding(12)
            }
            .frame(maxHeight: 480)

            Divider()
            footer
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .onAppear { monitor.start() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(appLocalized: "System Monitor")
                    .font(.headline)
                if monitor.snapshot.sampledAt != .distantPast {
                    Text(monitor.snapshot.sampledAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await monitor.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(monitor.isRefreshing)
            .help(AppLocalization.localized("Refresh"))
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: actionSettings) {
                Label(AppLocalization.localized("Settings"), systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Spacer()

            Button(action: actionQuit) {
                Label(AppLocalization.localized("Quit"), systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    private var cpuCard: some View {
        MonitorCard(title: "CPU", icon: "cpu", tint: .blue) {
            MonitorUsageRow(
                value: monitor.snapshot.cpu.total,
                detail: SystemMonitorFormatting.percent(monitor.snapshot.cpu.total),
                tint: .blue
            )
            MonitorSparkline(values: monitor.history.cpu, color: .blue)
        }
    }

    private func gpuCard(_ gpu: SystemMonitorSnapshot.GPU) -> some View {
        MonitorCard(title: "GPU", icon: "display", tint: .purple) {
            MonitorUsageRow(
                value: gpu.utilization,
                detail: SystemMonitorFormatting.percent(gpu.utilization),
                tint: .purple
            )
            if let model = gpu.model, !model.isEmpty {
                Text(model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var memoryCard: some View {
        MonitorCard(title: "Memory", icon: "memorychip", tint: .orange) {
            MonitorUsageRow(
                value: monitor.snapshot.memory.fraction,
                detail: "\(SystemMonitorFormatting.bytes(monitor.snapshot.memory.used)) / \(SystemMonitorFormatting.bytes(monitor.snapshot.memory.total))",
                tint: .orange
            )
            MonitorSparkline(values: monitor.history.memory, color: .orange)
        }
    }

    @ViewBuilder private var diskCard: some View {
        MonitorCard(title: "Disk", icon: "internaldrive", tint: .green) {
            if monitor.snapshot.disks.isEmpty {
                Text(appLocalized: "No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(monitor.snapshot.disks.prefix(3))) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(disk.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(SystemMonitorFormatting.bytes(disk.used)) / \(SystemMonitorFormatting.bytes(disk.total))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        ProgressView(value: disk.fraction)
                            .tint(.green)
                    }
                }
            }
        }
    }

    private var networkCard: some View {
        MonitorCard(title: "Network", icon: "network", tint: .cyan) {
            HStack {
                Label(SystemMonitorFormatting.speed(monitor.snapshot.network.downloadBytesPerSecond), systemImage: "arrow.down")
                Spacer()
                Label(SystemMonitorFormatting.speed(monitor.snapshot.network.uploadBytesPerSecond), systemImage: "arrow.up")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            MonitorNetworkSparkline(
                download: monitor.history.download,
                upload: monitor.history.upload
            )
        }
    }

    private func batteryCard(_ battery: SystemMonitorSnapshot.Battery) -> some View {
        MonitorCard(title: "Battery", icon: battery.isCharging ? "battery.100percent.bolt" : "battery.100percent", tint: .mint) {
            MonitorUsageRow(
                value: battery.level,
                detail: SystemMonitorFormatting.percent(battery.level),
                tint: .mint
            )
            if let minutes = battery.timeRemainingMinutes {
                Text(Self.durationText(minutes: minutes, charging: battery.isCharging))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func durationText(minutes: Int, charging: Bool) -> String {
        let duration = Duration.seconds(minutes * 60)
        let formatted = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        let key = charging ? "%@ until full" : "%@ remaining"
        return String(format: AppLocalization.localized(key), formatted)
    }

    @MainActor
    private func actionSettings() {
        showSettingsWindow(openWindow: openWindow)
    }

    @MainActor
    private func actionQuit() {
        messager.sendQuitNotification()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            NSApplication.shared.terminate(self)
        }
    }
}

private struct MonitorCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    init(title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppLocalization.localized(title), systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

private struct MonitorUsageRow: View {
    let value: Double
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: min(1, max(0, value)))
                .tint(tint)
            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

private struct MonitorSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = proxy.size.height * CGFloat(1 - min(1, max(0, value)))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }
}

private struct MonitorNetworkSparkline: View {
    let download: [Double]
    let upload: [Double]

    private var maximum: Double { max(1, (download + upload).max() ?? 1) }

    var body: some View {
        ZStack {
            MonitorSparkline(values: download.map { $0 / maximum }, color: .cyan)
            MonitorSparkline(values: upload.map { $0 / maximum }, color: .pink)
        }
    }
}

#Preview {
    MenuBarView()
}
