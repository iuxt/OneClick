import SwiftUI

enum SystemMonitorModule: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case network
    case disk
    case gpu
    case battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .gpu: "GPU"
        case .battery: "Battery"
        }
    }

    var icon: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "network"
        case .disk: "internaldrive"
        case .gpu: "display"
        case .battery: "battery.100percent"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: .blue
        case .memory: .orange
        case .network: .cyan
        case .disk: .green
        case .gpu: .purple
        case .battery: .mint
        }
    }
}

enum CPUMenuBarStyle: Int, CaseIterable, Identifiable {
    case percentage
    case iconAndPercentage

    var id: Int { rawValue }
    var title: String { self == .percentage ? "Percentage" : "Icon and percentage" }
}

enum MemoryMenuBarStyle: Int, CaseIterable, Identifiable {
    case percentage
    case used

    var id: Int { rawValue }
    var title: String { self == .percentage ? "Percentage" : "Used memory" }
}

enum NetworkMenuBarStyle: Int, CaseIterable, Identifiable {
    case both
    case download
    case upload

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .both: "Download and upload"
        case .download: "Download only"
        case .upload: "Upload only"
        }
    }
}

enum DiskMenuBarStyle: Int, CaseIterable, Identifiable {
    case percentage
    case free

    var id: Int { rawValue }
    var title: String { self == .percentage ? "Percentage" : "Free space" }
}

struct SystemMonitorModuleLabel: View {
    let module: SystemMonitorModule

    @ObservedObject private var monitor = SystemMonitor.shared
    @AppStorage(Key.systemMonitorCPUMenuBarStyle, store: .group) private var cpuStyle = CPUMenuBarStyle.percentage.rawValue
    @AppStorage(Key.systemMonitorMemoryMenuBarStyle, store: .group) private var memoryStyle = MemoryMenuBarStyle.percentage.rawValue
    @AppStorage(Key.systemMonitorNetworkMenuBarStyle, store: .group) private var networkStyle = NetworkMenuBarStyle.both.rawValue
    @AppStorage(Key.systemMonitorDiskMenuBarStyle, store: .group) private var diskStyle = DiskMenuBarStyle.percentage.rawValue

    var body: some View {
        Group {
            switch module {
            case .cpu:
                cpuLabel
            case .memory:
                memoryLabel
            case .network:
                networkLabel
            case .disk:
                diskLabel
            case .gpu:
                metricLabel(icon: "display", value: monitor.snapshot.gpu.map {
                    SystemMonitorFormatting.percent($0.utilization)
                } ?? "--")
            case .battery:
                metricLabel(
                    icon: monitor.snapshot.battery?.isCharging == true ? "battery.100percent.bolt" : "battery.100percent",
                    value: monitor.snapshot.battery.map { SystemMonitorFormatting.percent($0.level) } ?? "--"
                )
            }
        }
        .monospacedDigit()
        .accessibilityLabel(AppLocalization.localized(module.title))
        .onAppear { monitor.start() }
    }

    @ViewBuilder private var cpuLabel: some View {
        let value = SystemMonitorFormatting.percent(monitor.snapshot.cpu.total)
        if CPUMenuBarStyle(rawValue: cpuStyle) == .iconAndPercentage {
            metricLabel(icon: "cpu", value: value)
        } else {
            Text(value)
        }
    }

    @ViewBuilder private var memoryLabel: some View {
        if MemoryMenuBarStyle(rawValue: memoryStyle) == .used {
            Text(SystemMonitorFormatting.compactBytes(monitor.snapshot.memory.used))
        } else {
            Text(SystemMonitorFormatting.percent(monitor.snapshot.memory.fraction))
        }
    }

    @ViewBuilder private var networkLabel: some View {
        let network = monitor.snapshot.network
        switch NetworkMenuBarStyle(rawValue: networkStyle) ?? .both {
        case .both:
            VStack(alignment: .trailing, spacing: -2) {
                Text("↓\(SystemMonitorFormatting.compactSpeed(network.downloadBytesPerSecond))")
                Text("↑\(SystemMonitorFormatting.compactSpeed(network.uploadBytesPerSecond))")
            }
            .font(.system(size: 9, weight: .medium))
        case .download:
            Text("↓\(SystemMonitorFormatting.compactSpeed(network.downloadBytesPerSecond))")
        case .upload:
            Text("↑\(SystemMonitorFormatting.compactSpeed(network.uploadBytesPerSecond))")
        }
    }

    @ViewBuilder private var diskLabel: some View {
        if let disk = monitor.snapshot.disks.first {
            if DiskMenuBarStyle(rawValue: diskStyle) == .free {
                Text(SystemMonitorFormatting.compactBytes(disk.total - disk.used))
            } else {
                Text(SystemMonitorFormatting.percent(disk.fraction))
            }
        } else {
            Text("--")
        }
    }

    private func metricLabel(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(value)
        }
    }
}

struct SystemMonitorModuleDetailView: View {
    let module: SystemMonitorModule

    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detail
                }
                .padding(14)
            }
            .frame(maxHeight: 520)
            Divider()
            Button {
                showSettingsWindow(openWindow: openWindow)
            } label: {
                Label(AppLocalization.localized("System Monitor Settings"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 360)
        .background(.regularMaterial)
        .onAppear { monitor.start() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: module.icon)
                .font(.title2)
                .foregroundStyle(module.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.localized(module.title))
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
        }
        .padding(12)
    }

    @ViewBuilder private var detail: some View {
        switch module {
        case .cpu:
            cpuDetail
        case .memory:
            memoryDetail
        case .network:
            networkDetail
        case .disk:
            diskDetail
        case .gpu:
            gpuDetail
        case .battery:
            batteryDetail
        }
    }

    private var cpuDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary(
                value: SystemMonitorFormatting.percent(monitor.snapshot.cpu.total),
                secondary: "\(AppLocalization.localized("User")) \(SystemMonitorFormatting.percent(monitor.snapshot.cpu.user))  ·  \(AppLocalization.localized("System")) \(SystemMonitorFormatting.percent(monitor.snapshot.cpu.system))"
            )
            DetailSparkline(values: monitor.history.cpu, color: .blue)
            rankingHeader("Top Processes")
            ForEach(Array(monitor.snapshot.topCPUProcesses.enumerated()), id: \.element.id) { index, process in
                ProcessRankingRow(
                    rank: index + 1,
                    process: process,
                    value: SystemMonitorFormatting.processPercent(process.cpuUsage),
                    fraction: min(1, process.cpuUsage / Double(max(1, ProcessInfo.processInfo.processorCount))),
                    tint: .blue
                )
            }
        }
    }

    private var memoryDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary(
                value: SystemMonitorFormatting.percent(monitor.snapshot.memory.fraction),
                secondary: "\(SystemMonitorFormatting.bytes(monitor.snapshot.memory.used)) / \(SystemMonitorFormatting.bytes(monitor.snapshot.memory.total))"
            )
            DetailSparkline(values: monitor.history.memory, color: .orange)
            rankingHeader("Top Processes")
            ForEach(Array(monitor.snapshot.topMemoryProcesses.enumerated()), id: \.element.id) { index, process in
                ProcessRankingRow(
                    rank: index + 1,
                    process: process,
                    value: SystemMonitorFormatting.bytes(process.memoryBytes),
                    fraction: monitor.snapshot.memory.total > 0
                        ? Double(process.memoryBytes) / Double(monitor.snapshot.memory.total)
                        : 0,
                    tint: .orange
                )
            }
        }
    }

    private var networkDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                summary(value: "↓ \(SystemMonitorFormatting.speed(monitor.snapshot.network.downloadBytesPerSecond))", secondary: "Download")
                Spacer()
                summary(value: "↑ \(SystemMonitorFormatting.speed(monitor.snapshot.network.uploadBytesPerSecond))", secondary: "Upload")
            }
            DetailNetworkSparkline(download: monitor.history.download, upload: monitor.history.upload)
            rankingHeader("Interface Ranking")
            ForEach(Array(monitor.snapshot.network.interfaces.enumerated()), id: \.element.id) { index, interface in
                InterfaceRankingRow(rank: index + 1, interface: interface)
            }
        }
    }

    private var diskDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            rankingHeader("Volume Usage")
            ForEach(Array(monitor.snapshot.disks.enumerated()), id: \.element.id) { index, disk in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(index + 1)")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Image(systemName: disk.isRemovable ? "externaldrive" : "internaldrive")
                        Text(disk.name).lineLimit(1)
                        Spacer()
                        Text(SystemMonitorFormatting.percent(disk.fraction)).monospacedDigit()
                    }
                    ProgressView(value: disk.fraction).tint(.green)
                    Text("\(SystemMonitorFormatting.bytes(disk.used)) / \(SystemMonitorFormatting.bytes(disk.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder private var gpuDetail: some View {
        if let gpu = monitor.snapshot.gpu {
            summary(
                value: SystemMonitorFormatting.percent(gpu.utilization),
                secondary: gpu.model ?? AppLocalization.localized("GPU utilization")
            )
        } else {
            ContentUnavailableView(AppLocalization.localized("No data"), systemImage: "display")
        }
    }

    @ViewBuilder private var batteryDetail: some View {
        if let battery = monitor.snapshot.battery {
            summary(
                value: SystemMonitorFormatting.percent(battery.level),
                secondary: battery.isCharging
                    ? AppLocalization.localized("Charging")
                    : AppLocalization.localized("On battery")
            )
            ProgressView(value: battery.level).tint(.mint)
        } else {
            ContentUnavailableView(AppLocalization.localized("No battery"), systemImage: "battery.0percent")
        }
    }

    private func summary(value: String, secondary: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(AppLocalization.localized(secondary))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rankingHeader(_ title: String) -> some View {
        Text(AppLocalization.localized(title))
            .font(.subheadline.weight(.semibold))
    }
}

private struct ProcessRankingRow: View {
    let rank: Int
    let process: SystemMonitorSnapshot.ProcessMetric
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                Text(process.name)
                    .lineLimit(1)
                Spacer()
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            ProgressView(value: min(1, max(0, fraction))).tint(tint)
        }
    }
}

private struct InterfaceRankingRow: View {
    let rank: Int
    let interface: SystemMonitorSnapshot.Network.Interface

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(interface.id)
                    if interface.isPrimary {
                        Text(appLocalized: "Primary")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .background(.cyan.opacity(0.15), in: Capsule())
                    }
                }
                Text("↓ \(SystemMonitorFormatting.speed(interface.downloadBytesPerSecond))  ↑ \(SystemMonitorFormatting.speed(interface.uploadBytesPerSecond))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
            Spacer()
        }
    }
}

private struct DetailSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.primary.opacity(0.04))
                Path { path in
                    guard values.count > 1 else { return }
                    for (index, value) in values.enumerated() {
                        let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                        let y = proxy.size.height * CGFloat(1 - min(1, max(0, value)))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(height: 90)
        .accessibilityHidden(true)
    }
}

private struct DetailNetworkSparkline: View {
    let download: [Double]
    let upload: [Double]

    private var maximum: Double { max(1, (download + upload).max() ?? 1) }

    var body: some View {
        ZStack {
            DetailSparkline(values: download.map { $0 / maximum }, color: .cyan)
            DetailSparkline(values: upload.map { $0 / maximum }, color: .pink)
        }
    }
}
