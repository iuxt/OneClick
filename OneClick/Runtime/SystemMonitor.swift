//
//  SystemMonitor.swift
//  OneClick
//
//  System resource monitoring inspired by exelban/Stats (MIT).
//  The implementation is native to OneClick so it remains compatible with
//  the app sandbox and its Swift concurrency model.
//

import Darwin
import Combine
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

nonisolated struct SystemMonitorSnapshot: Equatable, Sendable {
    struct CPU: Equatable, Sendable {
        let total: Double
        let user: Double
        let system: Double

        nonisolated static let zero = CPU(total: 0, user: 0, system: 0)
    }

    struct Memory: Equatable, Sendable {
        let used: UInt64
        let total: UInt64
        let pressure: Pressure

        enum Pressure: String, Equatable, Sendable {
            case normal
            case warning
            case critical
        }

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(used) / Double(total)))
        }

        nonisolated static let zero = Memory(used: 0, total: 0, pressure: .normal)
    }

    struct Disk: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let used: UInt64
        let total: UInt64
        let isRemovable: Bool

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(used) / Double(total)))
        }
    }

    struct Network: Equatable, Sendable {
        struct Interface: Equatable, Identifiable, Sendable {
            let id: String
            let downloadBytesPerSecond: UInt64
            let uploadBytesPerSecond: UInt64
            let totalDownloaded: UInt64
            let totalUploaded: UInt64
            let isPrimary: Bool
        }

        let downloadBytesPerSecond: UInt64
        let uploadBytesPerSecond: UInt64
        let totalDownloaded: UInt64
        let totalUploaded: UInt64
        let primaryInterface: String?
        let interfaces: [Interface]

        nonisolated static let zero = Network(
            downloadBytesPerSecond: 0,
            uploadBytesPerSecond: 0,
            totalDownloaded: 0,
            totalUploaded: 0,
            primaryInterface: nil,
            interfaces: []
        )
    }

    struct ProcessMetric: Equatable, Identifiable, Sendable {
        let id: Int32
        let name: String
        let cpuUsage: Double
        let memoryBytes: UInt64
    }

    struct Battery: Equatable, Sendable {
        let level: Double
        let isCharging: Bool
        let isCharged: Bool
        let timeRemainingMinutes: Int?
    }

    struct GPU: Equatable, Sendable {
        let utilization: Double
        let model: String?
    }

    let cpu: CPU
    let memory: Memory
    let disks: [Disk]
    let network: Network
    let battery: Battery?
    let gpu: GPU?
    let topCPUProcesses: [ProcessMetric]
    let topMemoryProcesses: [ProcessMetric]
    let sampledAt: Date

    nonisolated static let empty = SystemMonitorSnapshot(
        cpu: .zero,
        memory: .zero,
        disks: [],
        network: .zero,
        battery: nil,
        gpu: nil,
        topCPUProcesses: [],
        topMemoryProcesses: [],
        sampledAt: .distantPast
    )
}

nonisolated struct SystemMonitorHistory: Equatable, Sendable {
    private(set) var cpu: [Double] = []
    private(set) var memory: [Double] = []
    private(set) var download: [Double] = []
    private(set) var upload: [Double] = []

    mutating func append(_ snapshot: SystemMonitorSnapshot, limit: Int = 60) {
        cpu.append(snapshot.cpu.total)
        memory.append(snapshot.memory.fraction)
        download.append(Double(snapshot.network.downloadBytesPerSecond))
        upload.append(Double(snapshot.network.uploadBytesPerSecond))

        cpu = Array(cpu.suffix(limit))
        memory = Array(memory.suffix(limit))
        download = Array(download.suffix(limit))
        upload = Array(upload.suffix(limit))
    }
}

nonisolated struct SystemMonitorModules: Equatable, Sendable {
    let cpu: Bool
    let gpu: Bool
    let memory: Bool
    let disk: Bool
    let network: Bool
    let battery: Bool

    nonisolated static let all = SystemMonitorModules(
        cpu: true,
        gpu: true,
        memory: true,
        disk: true,
        network: true,
        battery: true
    )
}

actor SystemMetricsSampler {
    private struct CPUTicks: Sendable {
        let user: UInt64
        let system: UInt64
        let nice: UInt64
        let idle: UInt64
    }

    private struct InterfaceCounters: Sendable {
        let received: UInt64
        let sent: UInt64
    }

    private struct NetworkCounters: Sendable {
        let interfaces: [String: InterfaceCounters]
        let sampledAt: ContinuousClock.Instant
    }

    private struct ProcessCounters: Sendable {
        let cpuTimeNanoseconds: UInt64
        let memoryBytes: UInt64
        let name: String
    }

    private var previousCPU: CPUTicks?
    private var previousNetwork: NetworkCounters?
    private var previousProcesses: [Int32: ProcessCounters] = [:]
    private var previousProcessSampleAt: ContinuousClock.Instant?

    func sample(modules: SystemMonitorModules = .all) -> SystemMonitorSnapshot {
        if !modules.cpu { previousCPU = nil }
        if !modules.network { previousNetwork = nil }
        let processes = modules.cpu || modules.memory
            ? sampleProcesses()
            : (cpu: [SystemMonitorSnapshot.ProcessMetric](), memory: [SystemMonitorSnapshot.ProcessMetric]())
        if !modules.cpu && !modules.memory {
            previousProcesses.removeAll()
            previousProcessSampleAt = nil
        }
        return SystemMonitorSnapshot(
            cpu: modules.cpu ? sampleCPU() : .zero,
            memory: modules.memory ? sampleMemory() : .zero,
            disks: modules.disk ? sampleDisks() : [],
            network: modules.network ? sampleNetwork() : .zero,
            battery: modules.battery ? sampleBattery() : nil,
            gpu: modules.gpu ? sampleGPU() : nil,
            topCPUProcesses: modules.cpu ? processes.cpu : [],
            topMemoryProcesses: modules.memory ? processes.memory : [],
            sampledAt: Date()
        )
    }

    private func sampleCPU() -> SystemMonitorSnapshot.CPU {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .zero }

        let current = CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            nice: UInt64(info.cpu_ticks.3),
            idle: UInt64(info.cpu_ticks.2)
        )
        defer { previousCPU = current }
        guard let previousCPU else { return .zero }

        let user = current.user &- previousCPU.user
        let system = current.system &- previousCPU.system
        let nice = current.nice &- previousCPU.nice
        let idle = current.idle &- previousCPU.idle
        let total = user + system + nice + idle
        guard total > 0 else { return .zero }

        let totalDouble = Double(total)
        let userFraction = Double(user + nice) / totalDouble
        let systemFraction = Double(system) / totalDouble
        return .init(
            total: min(1, userFraction + systemFraction),
            user: userFraction,
            system: systemFraction
        )
    }

    private func sampleMemory() -> SystemMonitorSnapshot.Memory {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .zero }

        var kernelPageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &kernelPageSize) == KERN_SUCCESS else { return .zero }
        let pageSize = UInt64(kernelPageSize)
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let external = UInt64(stats.external_page_count) * pageSize
        let reclaimable = min(active + inactive + speculative + wired + compressed, purgeable + external)
        let used = active + inactive + speculative + wired + compressed - reclaimable

        var pressureLevel: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pressureSize, nil, 0)
        let pressure: SystemMonitorSnapshot.Memory.Pressure = switch pressureLevel {
        case 4: .critical
        case 2: .warning
        default: .normal
        }

        return .init(
            used: min(used, ProcessInfo.processInfo.physicalMemory),
            total: ProcessInfo.processInfo.physicalMemory,
            pressure: pressure
        )
    }

    private func sampleDisks() -> [SystemMonitorSnapshot.Disk] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
        ]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let totalValue = values.volumeTotalCapacity,
                  totalValue > 0 else { return nil }

            // Network mounts and synthetic volumes are deliberately skipped. They can
            // block a menu-bar refresh when the remote host is unavailable.
            guard values.volumeIsInternal == true || values.volumeIsRemovable == true else { return nil }
            let total = UInt64(totalValue)
            let available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
            return .init(
                id: url.standardizedFileURL.path,
                name: values.volumeName ?? url.lastPathComponent,
                used: total - min(total, available),
                total: total,
                isRemovable: values.volumeIsRemovable ?? false
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRemovable != rhs.isRemovable { return !lhs.isRemovable }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func sampleNetwork() -> SystemMonitorSnapshot.Network {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return .zero }
        defer { freeifaddrs(addresses) }

        let primaryInterface = Self.primaryInterfaceName()
        var counters: [String: InterfaceCounters] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let dataPointer = current.pointee.ifa_data else { continue }

            let name = String(cString: current.pointee.ifa_name)
            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = InterfaceCounters(
                received: UInt64(data.ifi_ibytes),
                sent: UInt64(data.ifi_obytes)
            )
        }

        let now = ContinuousClock.now
        let current = NetworkCounters(interfaces: counters, sampledAt: now)
        defer { previousNetwork = current }
        let seconds = previousNetwork.map {
            let elapsed = $0.sampledAt.duration(to: now)
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        } ?? 0
        let interfaces = counters.map { name, counter in
            let previous = previousNetwork?.interfaces[name]
            return SystemMonitorSnapshot.Network.Interface(
                id: name,
                downloadBytesPerSecond: Self.rate(current: counter.received, previous: previous?.received ?? counter.received, seconds: seconds),
                uploadBytesPerSecond: Self.rate(current: counter.sent, previous: previous?.sent ?? counter.sent, seconds: seconds),
                totalDownloaded: counter.received,
                totalUploaded: counter.sent,
                isPrimary: name == primaryInterface
            )
        }
        .sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            let lhsRate = $0.downloadBytesPerSecond + $0.uploadBytesPerSecond
            let rhsRate = $1.downloadBytesPerSecond + $1.uploadBytesPerSecond
            return lhsRate == rhsRate ? $0.id < $1.id : lhsRate > rhsRate
        }

        let selected: SystemMonitorSnapshot.Network.Interface?
        if let primaryInterface {
            selected = interfaces.first(where: { $0.id == primaryInterface })
        } else {
            let virtualPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "awdl", "llw"]
            selected = interfaces.first(where: { interface in
                !virtualPrefixes.contains(where: interface.id.hasPrefix)
            })
        }
        return .init(
            downloadBytesPerSecond: selected?.downloadBytesPerSecond ?? 0,
            uploadBytesPerSecond: selected?.uploadBytesPerSecond ?? 0,
            totalDownloaded: selected?.totalDownloaded ?? 0,
            totalUploaded: selected?.totalUploaded ?? 0,
            primaryInterface: selected?.id,
            interfaces: interfaces
        )
    }

    nonisolated static func rate(current: UInt64, previous: UInt64, seconds: Double) -> UInt64 {
        guard current >= previous, seconds > 0, seconds.isFinite else { return 0 }
        let value = Double(current - previous) / seconds
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
    }

    private static func primaryInterfaceName() -> String? {
        guard let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString)
            as? [String: Any] else { return nil }
        return value["PrimaryInterface"] as? String
    }

    private func sampleProcesses() -> (
        cpu: [SystemMonitorSnapshot.ProcessMetric],
        memory: [SystemMonitorSnapshot.ProcessMetric]
    ) {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { return ([], []) }

        var pids = [Int32](repeating: 0, count: Int(requiredBytes) / MemoryLayout<Int32>.stride)
        let actualBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard actualBytes > 0 else { return ([], []) }

        let now = ContinuousClock.now
        let seconds = previousProcessSampleAt.map {
            let elapsed = $0.duration(to: now)
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        } ?? 0
        var current: [Int32: ProcessCounters] = [:]
        var metrics: [SystemMonitorSnapshot.ProcessMetric] = []

        for pid in pids.prefix(Int(actualBytes) / MemoryLayout<Int32>.stride) where pid > 0 {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { continue }

            var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = nameLength > 0
                ? String(decoding: nameBuffer.prefix(Int(nameLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                : "PID \(pid)"
            let cpuTime = usage.ri_user_time &+ usage.ri_system_time
            let process = ProcessCounters(
                cpuTimeNanoseconds: cpuTime,
                memoryBytes: usage.ri_phys_footprint,
                name: name
            )
            current[pid] = process

            let previous = previousProcesses[pid]
            let cpuUsage: Double
            if let previous, cpuTime >= previous.cpuTimeNanoseconds, seconds > 0 {
                cpuUsage = Double(cpuTime - previous.cpuTimeNanoseconds) / 1_000_000_000 / seconds
            } else {
                cpuUsage = 0
            }
            metrics.append(.init(
                id: pid,
                name: name,
                cpuUsage: max(0, cpuUsage),
                memoryBytes: usage.ri_phys_footprint
            ))
        }

        previousProcesses = current
        previousProcessSampleAt = now
        let cpu = metrics.sorted {
            $0.cpuUsage == $1.cpuUsage ? $0.name < $1.name : $0.cpuUsage > $1.cpuUsage
        }
        let memory = metrics.sorted {
            $0.memoryBytes == $1.memoryBytes ? $0.name < $1.name : $0.memoryBytes > $1.memoryBytes
        }
        return (Array(cpu.prefix(10)), Array(memory.prefix(10)))
    }

    private func sampleBattery() -> SystemMonitorSnapshot.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int else { continue }

            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let charged = description[kIOPSIsChargedKey] as? Bool ?? false
            let rawMinutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            let minutes = rawMinutes.flatMap { $0 > 0 ? $0 : nil }
            return .init(
                level: min(1, max(0, Double(capacity) / 100)),
                isCharging: charging,
                isCharged: charged,
                timeRemainingMinutes: minutes
            )
        }
        return nil
    }

    private func sampleGPU() -> SystemMonitorSnapshot.GPU? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var bestUtilization: Double?
        var model: String?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            if model == nil,
               let property = IORegistryEntryCreateCFProperty(
                   service,
                   "model" as CFString,
                   kCFAllocatorDefault,
                   0
               )?.takeRetainedValue() {
                if let value = property as? String {
                    model = value
                } else if let data = property as? Data {
                    model = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
                }
            }

            guard let property = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            let raw = property["Device Utilization %"] as? NSNumber
                ?? property["GPU Activity(%)"] as? NSNumber
            if let raw {
                bestUtilization = max(bestUtilization ?? 0, min(1, max(0, raw.doubleValue / 100)))
            }
        }

        guard let bestUtilization else { return nil }
        return .init(utilization: bestUtilization, model: model)
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var snapshot: SystemMonitorSnapshot = .empty
    @Published private(set) var history = SystemMonitorHistory()
    @Published private(set) var isRefreshing = false

    private let sampler = SystemMetricsSampler()
    private var refreshTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard refreshTask == nil else { return }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await refresh()
                let configured = UserDefaults.group.double(forKey: Key.systemMonitorRefreshInterval)
                let interval = configured > 0 ? min(10, max(1, configured)) : 2
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func configurationDidChange() {
        stop()
        start()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let defaults = UserDefaults.group
        let modules = SystemMonitorModules(
            cpu: Self.enabled(defaults, Key.systemMonitorShowCPU, fallback: true)
                || Self.enabled(defaults, Key.systemMonitorCPUMenuBarItem, fallback: true),
            gpu: Self.enabled(defaults, Key.systemMonitorShowGPU, fallback: true)
                || Self.enabled(defaults, Key.systemMonitorGPUMenuBarItem, fallback: false),
            memory: Self.enabled(defaults, Key.systemMonitorShowMemory, fallback: true)
                || Self.enabled(defaults, Key.systemMonitorMemoryMenuBarItem, fallback: true),
            disk: Self.enabled(defaults, Key.systemMonitorShowDisk, fallback: true)
                || Self.enabled(defaults, Key.systemMonitorDiskMenuBarItem, fallback: false),
            network: Self.enabled(defaults, Key.systemMonitorShowNetwork, fallback: true)
                || Self.enabled(defaults, Key.systemMonitorNetworkMenuBarItem, fallback: true),
            battery: Self.enabled(defaults, Key.systemMonitorShowBattery, fallback: true)
                || Self.enabled(defaults, Key.systemMonitorBatteryMenuBarItem, fallback: false)
        )
        let newSnapshot = await sampler.sample(modules: modules)
        guard !Task.isCancelled else {
            isRefreshing = false
            return
        }
        snapshot = newSnapshot
        history.append(newSnapshot)
        isRefreshing = false
    }

    private static func enabled(_ defaults: UserDefaults, _ key: String, fallback defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

nonisolated enum SystemMonitorFormatting {
    nonisolated static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    nonisolated static func speed(_ value: UInt64) -> String {
        "\(bytes(value))/s"
    }

    nonisolated static func percent(_ value: Double) -> String {
        "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }

    nonisolated static func processPercent(_ value: Double) -> String {
        "\(Int((max(0, value) * 100).rounded()))%"
    }

    nonisolated static func compactBytes(_ value: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1_000, unit < units.count - 1 {
            amount /= 1_000
            unit += 1
        }
        let value = amount >= 100 || unit == 0 ? String(format: "%.0f", amount) : String(format: "%.1f", amount)
        return value + units[unit]
    }

    nonisolated static func compactSpeed(_ value: UInt64) -> String {
        "\(compactBytes(value))/s"
    }
}
