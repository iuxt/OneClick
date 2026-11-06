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

enum DiskMenuBarStyle: Int, CaseIterable, Identifiable {
    case percentage
    case free

    var id: Int { rawValue }
    var title: String { self == .percentage ? "Percentage" : "Free space" }
}

/// The label SwiftUI installs into the real macOS status bar for each module.
struct SystemMonitorStatusBarLabel: View {
    let module: SystemMonitorModule

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var monitor = SystemMonitor.shared
    @AppStorage(Key.systemMonitorDiskMenuBarStyle, store: .group) private var diskStyle = DiskMenuBarStyle.percentage.rawValue

    var body: some View {
        StatusBarRasterizedLabel {
            rawLabel
                .fixedSize(horizontal: true, vertical: true)
                .monospacedDigit()
                .environment(\.colorScheme, colorScheme)
        }
        .accessibilityLabel(AppLocalization.localized(module.title))
        .onAppear { monitor.start() }
    }

    @ViewBuilder private var rawLabel: some View {
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

    private var cpuLabel: some View {
        CPUMenuBarGraph(
            values: monitor.history.cpu,
            currentValue: monitor.snapshot.cpu.total
        )
    }

    private var memoryLabel: some View {
        MemoryMenuBarLabel(fraction: monitor.snapshot.memory.fraction)
    }

    private var networkLabel: some View {
        let network = monitor.snapshot.network
        return NetworkMenuBarLabel(
            downloadHistory: monitor.history.download,
            uploadHistory: monitor.history.upload,
            downloadBytesPerSecond: network.downloadBytesPerSecond,
            uploadBytesPerSecond: network.uploadBytesPerSecond
        )
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

/// `MenuBarExtra` applies a standard single-line layout to its label. Rendering
/// the tiny status view into an original-color image preserves two-line labels,
/// custom graphs and their exact intrinsic width in the real macOS status bar.
private struct StatusBarRasterizedLabel<Content: View>: View {
    private let content: Content
    private let scale: CGFloat = 2

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder var body: some View {
        let renderer = ImageRenderer(content: content)
        let _ = renderer.scale = scale
        if let image = renderer.cgImage {
            Image(decorative: image, scale: scale, orientation: .up)
                .renderingMode(.original)
        } else {
            content
        }
    }
}

struct CPUMenuBarGraph: View {
    let values: [Double]
    let currentValue: Double

    private var plottedValues: [Double] {
        values.isEmpty ? [currentValue] : values
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(.white)

            GeometryReader { proxy in
                Path { path in
                    let values = plottedValues
                    guard let first = values.first else { return }

                    let firstY = proxy.size.height * CGFloat(1 - min(1, max(0, first)))
                    path.move(to: CGPoint(x: 0, y: firstY))

                    if values.count == 1 {
                        path.addLine(to: CGPoint(x: proxy.size.width, y: firstY))
                    } else {
                        for (index, value) in values.dropFirst().enumerated() {
                            let pointIndex = index + 1
                            let x = proxy.size.width * CGFloat(pointIndex) / CGFloat(values.count - 1)
                            let y = proxy.size.height * CGFloat(1 - min(1, max(0, value)))
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }

                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                    path.addLine(to: CGPoint(x: 0, y: proxy.size.height))
                    path.closeSubpath()
                }
                .fill(Color(red: 0.08, green: 0.55, blue: 1))
            }
            .padding(.horizontal, 1)
            .padding(.top, 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(.primary.opacity(0.35), lineWidth: 1)
        }
        .frame(width: 33, height: 19)
        .accessibilityElement()
        .accessibilityValue(SystemMonitorFormatting.percent(currentValue))
    }
}

struct MemoryMenuBarLabel: View {
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text("RAM")
                .font(.system(size: 8, weight: .medium))
            Text(SystemMonitorFormatting.percent(fraction))
                .font(.system(size: 13, weight: .semibold))
        }
        .lineLimit(1)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.localized("Memory"))
        .accessibilityValue(SystemMonitorFormatting.percent(fraction))
    }
}

struct NetworkMenuBarLabel: View {
    let downloadHistory: [Double]
    let uploadHistory: [Double]
    let downloadBytesPerSecond: UInt64
    let uploadBytesPerSecond: UInt64

    var body: some View {
        HStack(spacing: 16) {
            NetworkMenuBarGraph(
                downloadValues: downloadHistory,
                uploadValues: uploadHistory
            )

            HStack(spacing: 7) {
                VStack(spacing: 3) {
                    Circle()
                        .fill(NetworkMenuBarGraph.uploadColor)
                        .frame(width: 6, height: 6)
                    Circle()
                        .fill(NetworkMenuBarGraph.downloadColor)
                        .frame(width: 6, height: 6)
                }

                VStack(alignment: .trailing, spacing: -2) {
                    Text(SystemMonitorFormatting.menuBarSpeed(uploadBytesPerSecond))
                    Text(SystemMonitorFormatting.menuBarSpeed(downloadBytesPerSecond))
                }
            }
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.localized("Network"))
        .accessibilityValue(
            "\(AppLocalization.localized("Upload")) \(SystemMonitorFormatting.menuBarSpeed(uploadBytesPerSecond)), "
                + "\(AppLocalization.localized("Download")) \(SystemMonitorFormatting.menuBarSpeed(downloadBytesPerSecond))"
        )
    }
}

struct NetworkMenuBarGraph: View {
    static let uploadColor = Color(red: 1, green: 0.27, blue: 0.25)
    static let downloadColor = Color(red: 0.04, green: 0.57, blue: 1)

    let downloadValues: [Double]
    let uploadValues: [Double]

    private var maximum: Double {
        max(1, (downloadValues + uploadValues).max() ?? 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 1.5
            let plotSize = CGSize(
                width: max(0, proxy.size.width - inset * 2),
                height: max(0, proxy.size.height - inset * 2)
            )

            ZStack {
                sparkline(values: uploadValues, in: plotSize)
                    .stroke(Self.uploadColor, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                sparkline(values: downloadValues, in: plotSize)
                    .stroke(Self.downloadColor, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
            .frame(width: plotSize.width, height: plotSize.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(.primary.opacity(0.9), lineWidth: 0.75)
        }
        .frame(width: 30, height: 19)
        .accessibilityHidden(true)
    }

    private func sparkline(values: [Double], in size: CGSize) -> Path {
        Path { path in
            let samples = values.isEmpty ? [0] : values
            guard let first = samples.first else { return }

            let firstY = size.height * CGFloat(1 - min(1, max(0, first / maximum)))
            path.move(to: CGPoint(x: 0, y: firstY))

            if samples.count == 1 {
                path.addLine(to: CGPoint(x: size.width, y: firstY))
                return
            }

            for (index, value) in samples.dropFirst().enumerated() {
                let pointIndex = index + 1
                let x = size.width * CGFloat(pointIndex) / CGFloat(samples.count - 1)
                let y = size.height * CGFloat(1 - min(1, max(0, value / maximum)))
                path.addLine(to: CGPoint(x: x, y: y))
            }
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
            ScrollView {
                detail
                    .padding(.horizontal, 9)
                    .padding(.bottom, 14)
            }
            // A ScrollView has no intrinsic height inside a MenuBarExtra window.
            // Without an explicit ideal/minimum height AppKit is free to collapse
            // it to zero, leaving only the header visible in the popover.
            .frame(minHeight: 320, idealHeight: 600, maxHeight: 790)
        }
        .frame(width: 282)
        .background(.background)
        .onAppear { monitor.start() }
    }

    private var header: some View {
        ZStack {
            Text(AppLocalization.localized(module.title))
                .font(.system(size: 17, weight: .semibold))

            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    showSettingsWindow(openWindow: openWindow)
                } label: {
                    Text("⌘")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(AppLocalization.localized("System Monitor Settings"))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 46)
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
        let cpu = monitor.snapshot.cpu
        return VStack(spacing: 14) {
            HStack(alignment: .center) {
                RingMetric(
                    value: SystemMonitorFormatting.percent(cpu.system),
                    caption: AppLocalization.localized("System"),
                    diameter: 51,
                    segments: [(cpu.system, .red)]
                )
                Spacer()
                RingMetric(
                    value: SystemMonitorFormatting.percent(cpu.total),
                    caption: "CPU",
                    diameter: 72,
                    segments: [(cpu.user, .blue), (cpu.system, .red)]
                )
                Spacer()
                RingMetric(
                    value: String(format: "%.2f", cpu.loadAverage.first ?? 0),
                    caption: AppLocalization.localized("1 minute"),
                    diameter: 51,
                    segments: [(
                        min(1, (cpu.loadAverage.first ?? 0) / Double(max(1, ProcessInfo.processInfo.processorCount))),
                        .blue
                    )]
                )
            }
            .padding(.horizontal, 23)
            .padding(.top, 8)

            PanelSectionHeader(title: "Load History")
            AreaHistoryChart(values: monitor.history.cpu, color: .blue)
                .frame(height: 72)
            CoreUsageBars(values: cpu.perCore)
                .frame(height: 50)

            PanelSectionHeader(title: "Details")
            VStack(spacing: 7) {
                PanelMetricRow(label: "System", value: SystemMonitorFormatting.percent(cpu.system), color: .red)
                PanelMetricRow(label: "User", value: SystemMonitorFormatting.percent(cpu.user), color: .blue)
                PanelMetricRow(
                    label: "Idle",
                    value: SystemMonitorFormatting.percent(max(0, 1 - cpu.total)),
                    color: Color(nsColor: .systemGray)
                )
                PanelMetricRow(label: "Uptime", value: SystemMonitorFormatting.uptime(ProcessInfo.processInfo.systemUptime))
            }

            PanelSectionHeader(title: "Average Load")
            VStack(spacing: 7) {
                PanelMetricRow(label: "1 minute", value: String(format: "%.2f", cpu.loadAverage[safe: 0] ?? 0))
                PanelMetricRow(label: "5 minutes", value: String(format: "%.2f", cpu.loadAverage[safe: 1] ?? 0))
                PanelMetricRow(label: "15 minutes", value: String(format: "%.2f", cpu.loadAverage[safe: 2] ?? 0))
            }

            if let frequencyMHz = cpu.frequencyMHz, frequencyMHz > 0 {
                PanelSectionHeader(title: "Frequency")
                PanelMetricRow(label: "All Cores", value: "\(frequencyMHz) MHz")
            }

            PanelSectionHeader(title: "Top Processes")
            ProcessTable(
                processes: monitor.snapshot.topCPUProcesses,
                value: { SystemMonitorFormatting.processPercent($0.cpuUsage) }
            )
        }
    }

    private var memoryDetail: some View {
        let memory = monitor.snapshot.memory
        return VStack(spacing: 14) {
            HStack {
                MemoryPressureGauge(pressure: memory.pressure)
                    .frame(width: 88, height: 70)
                Spacer()
                RingMetric(
                    value: SystemMonitorFormatting.percent(memory.fraction),
                    caption: AppLocalization.localized("Used"),
                    diameter: 72,
                    segments: memorySegments(memory)
                )
                Spacer().frame(width: 20)
            }
            .padding(.horizontal, 35)
            .padding(.top, 8)

            PanelSectionHeader(title: "Load History")
            AreaHistoryChart(values: monitor.history.memory, color: .blue)
                .frame(height: 90)

            PanelSectionHeader(title: "Details")
            VStack(spacing: 7) {
                PanelMetricRow(label: "Used", value: SystemMonitorFormatting.bytes(memory.used))
                MemoryBreakdownBar(memory: memory)
                    .frame(height: 10)
                PanelMetricRow(label: "App Memory", value: SystemMonitorFormatting.bytes(memory.app), color: .blue)
                PanelMetricRow(label: "Wired Memory", value: SystemMonitorFormatting.bytes(memory.wired), color: .orange)
                PanelMetricRow(label: "Compressed", value: SystemMonitorFormatting.bytes(memory.compressed), color: .pink)
                PanelMetricRow(label: "Available", value: SystemMonitorFormatting.bytes(memory.available), color: Color(nsColor: .systemGray))
                PanelMetricRow(label: "Swap Used", value: SystemMonitorFormatting.bytes(memory.swapUsed))
            }

            PanelSectionHeader(title: "Top Processes")
            ProcessTable(
                processes: monitor.snapshot.topMemoryProcesses,
                value: { SystemMonitorFormatting.bytes($0.memoryBytes) }
            )
        }
    }

    private var networkDetail: some View {
        let network = monitor.snapshot.network
        return VStack(spacing: 14) {
            HStack(spacing: 0) {
                NetworkRateSummary(
                    value: network.downloadBytesPerSecond,
                    label: "Download",
                    color: .blue
                )
                Spacer()
                NetworkRateSummary(
                    value: network.uploadBytesPerSecond,
                    label: "Upload",
                    color: .red
                )
            }
            .padding(.horizontal, 36)
            .padding(.top, 16)

            PanelSectionHeader(title: "Load History")
            NetworkHistoryChart(download: monitor.history.download, upload: monitor.history.upload)
                .frame(height: 90)

            PanelSectionHeader(title: "Connection History")
            ConnectionHistoryGrid(download: monitor.history.download, upload: monitor.history.upload)

            PanelSectionHeader(title: "Interface")
            VStack(spacing: 7) {
                PanelMetricRow(label: "Total Upload", value: SystemMonitorFormatting.bytes(network.totalUploaded), color: .red)
                PanelMetricRow(label: "Total Download", value: SystemMonitorFormatting.bytes(network.totalDownloaded), color: .blue)
                NetworkStatusRow(isUp: network.primaryInterface != nil)
                PanelMetricRow(label: "Interface", value: network.primaryInterface ?? "—")
                if let localAddress = network.interfaces.first(where: \.isPrimary)?.localAddress {
                    PanelMetricRow(label: "Local IP", value: localAddress)
                }
            }

            PanelSectionHeader(title: "Interface Ranking")
            InterfaceTable(interfaces: network.interfaces)
        }
    }

    private func memorySegments(_ memory: SystemMonitorSnapshot.Memory) -> [(Double, Color)] {
        guard memory.total > 0 else { return [] }
        let total = Double(memory.total)
        return [
            (Double(memory.app) / total, .blue),
            (Double(memory.wired) / total, .orange),
            (Double(memory.compressed) / total, .pink),
        ]
    }

    private var diskDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelSectionHeader(title: "Volume Usage")
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
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(AppLocalization.localized(secondary)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PanelSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(AppLocalization.localized(title))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
    }
}

private struct PanelMetricRow: View {
    let label: String
    let value: String
    var color: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let color {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 10, height: 10)
            }
            Text(AppLocalization.localized(label))
            Spacer()
            Text(AppLocalization.localized(value))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

private struct AreaHistoryChart: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let line = historyPath(values: values, size: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.035))
                line
                    .strokedPath(.init(lineWidth: 1, lineJoin: .round))
                    .foregroundStyle(color)
                areaPath(line: line, size: proxy.size)
                    .fill(LinearGradient(colors: [color.opacity(0.8), color.opacity(0.45)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityHidden(true)
    }

    private func historyPath(values: [Double], size: CGSize) -> Path {
        Path { path in
            let samples = values.isEmpty ? [0] : values
            for (index, value) in samples.enumerated() {
                let x = samples.count == 1 ? 0 : size.width * CGFloat(index) / CGFloat(samples.count - 1)
                let y = size.height * CGFloat(1 - min(1, max(0, value)))
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    private func areaPath(line: Path, size: CGSize) -> Path {
        var area = line
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        return area
    }
}

private struct NetworkHistoryChart: View {
    let download: [Double]
    let upload: [Double]

    private var maximum: Double { max(1, (download + upload).max() ?? 1) }

    var body: some View {
        GeometryReader { proxy in
            let middle = proxy.size.height / 2
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.035))
                Rectangle().fill(.secondary.opacity(0.35)).frame(height: 1)
                networkArea(values: upload, size: proxy.size, upward: true)
                    .fill(.red.opacity(0.65))
                networkArea(values: download, size: proxy.size, upward: false)
                    .fill(.blue.opacity(0.8))
                Text(SystemMonitorFormatting.menuBarSpeed(UInt64(maximum)))
                    .font(.system(size: 8))
                    .position(x: 35, y: 9)
                Text(SystemMonitorFormatting.menuBarSpeed(UInt64(maximum)))
                    .font(.system(size: 8))
                    .position(x: 35, y: proxy.size.height - 9)
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(.clear).frame(width: 1, height: middle)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityHidden(true)
    }

    private func networkArea(values: [Double], size: CGSize, upward: Bool) -> Path {
        Path { path in
            let samples = values.isEmpty ? [0] : values
            let middle = size.height / 2
            path.move(to: CGPoint(x: 0, y: middle))
            for (index, value) in samples.enumerated() {
                let x = samples.count == 1 ? 0 : size.width * CGFloat(index) / CGFloat(samples.count - 1)
                let amount = CGFloat(min(1, max(0, value / maximum))) * middle
                path.addLine(to: CGPoint(x: x, y: upward ? middle - amount : middle + amount))
            }
            path.addLine(to: CGPoint(x: size.width, y: middle))
            path.closeSubpath()
        }
    }
}

private struct RingMetric: View {
    let value: String
    let caption: String
    let diameter: CGFloat
    let segments: [(Double, Color)]

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.primary.opacity(0.14), lineWidth: diameter * 0.13)
                ForEach(Array(segmentRanges.enumerated()), id: \.offset) { _, segment in
                    Circle()
                        .trim(from: segment.start, to: segment.end)
                        .stroke(segment.color, style: StrokeStyle(lineWidth: diameter * 0.13, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(value)
                    .font(.system(size: diameter * 0.22, weight: .medium))
                    .monospacedDigit()
            }
            .frame(width: diameter, height: diameter)
            Text(caption)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var segmentRanges: [(start: Double, end: Double, color: Color)] {
        var cursor = 0.0
        return segments.compactMap { fraction, color in
            let bounded = min(1 - cursor, max(0, fraction))
            guard bounded > 0.002 else { return nil }
            let segment = (cursor, cursor + bounded, color)
            cursor += bounded
            return segment
        }
    }
}

private struct MemoryPressureGauge: View {
    let pressure: SystemMonitorSnapshot.Memory.Pressure

    private var value: Double {
        switch pressure {
        case .normal: 0.2
        case .warning: 0.62
        case .critical: 0.9
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Circle()
                    .trim(from: 0.5, to: 1)
                    .stroke(
                        AngularGradient(colors: [.red, .orange, .yellow, .green], center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .frame(width: 68, height: 68)
                Capsule()
                    .fill(.blue)
                    .frame(width: 2, height: 29)
                    .offset(y: -1)
                    .rotationEffect(.degrees(-90 + 180 * value), anchor: .bottom)
            }
            .frame(height: 38)
            Text(AppLocalization.localized(pressure == .normal ? "Normal" : pressure == .warning ? "Warning" : "Critical"))
                .font(.system(size: 10, weight: .semibold))
        }
    }
}

private struct CoreUsageBars: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let samples = values.isEmpty ? Array(repeating: 0.0, count: max(1, ProcessInfo.processInfo.processorCount)) : values
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index < samples.count / 2 ? Color.cyan : Color.indigo)
                        .frame(height: max(3, proxy.size.height * CGFloat(min(1, max(0, value)))))
                }
            }
            .padding(2)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityHidden(true)
    }
}

private struct MemoryBreakdownBar: View {
    let memory: SystemMonitorSnapshot.Memory

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, Double(memory.total))
            HStack(spacing: 0) {
                Rectangle().fill(.blue).frame(width: proxy.size.width * CGFloat(Double(memory.app) / total))
                Rectangle().fill(.orange).frame(width: proxy.size.width * CGFloat(Double(memory.wired) / total))
                Rectangle().fill(.pink).frame(width: proxy.size.width * CGFloat(Double(memory.compressed) / total))
                Rectangle().fill(.primary.opacity(0.12))
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .accessibilityHidden(true)
    }
}

private struct NetworkRateSummary: View {
    let value: UInt64
    let label: String
    let color: Color

    var body: some View {
        let rate = SystemMonitorFormatting.rateParts(value)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(rate.value).font(.system(size: 25, weight: .regular))
                Text(rate.unit).font(.system(size: 12))
            }
            .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 12, height: 12)
                Text(AppLocalization.localized(label)).font(.system(size: 11))
            }
        }
        .monospacedDigit()
    }
}

private struct NetworkStatusRow: View {
    let isUp: Bool

    var body: some View {
        HStack {
            Text(AppLocalization.localized("Status"))
            Spacer()
            Text(isUp ? "UP" : "DOWN")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 50)
                .padding(.vertical, 1)
                .background(isUp ? Color.green : Color.red, in: RoundedRectangle(cornerRadius: 4))
        }
        .font(.system(size: 12))
    }
}

private struct ConnectionHistoryGrid: View {
    let download: [Double]
    let upload: [Double]

    var body: some View {
        let count = 36
        let combined = Array(zip(download, upload).suffix(count))
        let padded = Array(repeating: (0.0, 0.0), count: max(0, count - combined.count)) + combined
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 12), spacing: 2) {
            ForEach(Array(padded.enumerated()), id: \.offset) { _, sample in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(activityColor(download: sample.0, upload: sample.1))
                    .frame(height: 8)
            }
        }
    }

    private func activityColor(download: Double, upload: Double) -> Color {
        guard download + upload > 0 else { return .primary.opacity(0.08) }
        return upload > download ? .red : .blue
    }
}

private struct ProcessTable: View {
    let processes: [SystemMonitorSnapshot.ProcessMetric]
    let value: (SystemMonitorSnapshot.ProcessMetric) -> String

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(AppLocalization.localized("Process"))
                Spacer()
                Text(AppLocalization.localized("Usage"))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 22)

            ForEach(processes.prefix(8)) { process in
                HStack(spacing: 8) {
                    ProcessIcon()
                    Text(process.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(value(process)).monospacedDigit()
                }
                .font(.system(size: 11.5))
            }
        }
    }
}

private struct ProcessIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.black)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 1) {
                    Circle().fill(.green).frame(width: 1.5, height: 1.5)
                    Circle().fill(.green).frame(width: 1.5, height: 1.5)
                    Circle().fill(.green).frame(width: 1.5, height: 1.5)
                }
                .padding(2)
            }
            .frame(width: 11, height: 11)
    }
}

private struct InterfaceTable: View {
    let interfaces: [SystemMonitorSnapshot.Network.Interface]

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(AppLocalization.localized("Interface"))
                Spacer()
                Text(AppLocalization.localized("Download"))
                Text(AppLocalization.localized("Upload")).frame(width: 55, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)

            ForEach(interfaces.prefix(8)) { interface in
                HStack(spacing: 6) {
                    Circle().fill(interface.isPrimary ? .green : .secondary.opacity(0.3)).frame(width: 7, height: 7)
                    Text(interface.id).lineLimit(1)
                    Spacer()
                    Text(SystemMonitorFormatting.menuBarSpeed(interface.downloadBytesPerSecond))
                    Text(SystemMonitorFormatting.menuBarSpeed(interface.uploadBytesPerSecond))
                        .frame(width: 55, alignment: .trailing)
                }
                .font(.system(size: 10.5).monospacedDigit())
            }
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
