import Foundation
import Testing
@testable import OneClick

struct SystemMonitorTests {
    @Test func byteRateHandlesNormalResetAndInvalidIntervals() {
        #expect(SystemMetricsSampler.rate(current: 3_000, previous: 1_000, seconds: 2) == 1_000)
        #expect(SystemMetricsSampler.rate(current: 1_000, previous: 3_000, seconds: 2) == 0)
        #expect(SystemMetricsSampler.rate(current: 3_000, previous: 1_000, seconds: 0) == 0)
        #expect(SystemMetricsSampler.rate(current: 3_000, previous: 1_000, seconds: .infinity) == 0)
    }

    @Test func historyRetainsOnlyTheConfiguredWindow() {
        var history = SystemMonitorHistory()
        for index in 0..<8 {
            history.append(snapshot(cpu: Double(index) / 10), limit: 3)
        }

        #expect(history.cpu == [0.5, 0.6, 0.7])
        #expect(history.memory.count == 3)
        #expect(history.download.count == 3)
        #expect(history.upload.count == 3)
    }

    @Test func menuBarSpeedUsesCompactDecimalUnits() {
        #expect(SystemMonitorFormatting.menuBarSpeed(7_000) == "7 KB/s")
        #expect(SystemMonitorFormatting.menuBarSpeed(239_000) == "239 KB/s")
        #expect(SystemMonitorFormatting.menuBarSpeed(1_500_000) == "1.5 MB/s")
    }

    @Test func samplerReturnsBoundedLocalMetrics() async throws {
        let sampler = SystemMetricsSampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .milliseconds(50))
        let sample = await sampler.sample()

        #expect((0...1).contains(sample.cpu.total))
        #expect(sample.cpu.loadAverage.count == 3)
        #expect(sample.cpu.perCore.allSatisfy { (0...1).contains($0) })
        #expect((0...1).contains(sample.memory.fraction))
        #expect(sample.memory.total > 0)
        #expect(sample.memory.used <= sample.memory.total)
        #expect(sample.memory.available == sample.memory.total - sample.memory.used)
        #expect(sample.disks.allSatisfy { $0.used <= $0.total })
        #expect(sample.battery.map { (0...1).contains($0.level) } ?? true)
        #expect(sample.gpu.map { (0...1).contains($0.utilization) } ?? true)
        #expect(zip(sample.topCPUProcesses, sample.topCPUProcesses.dropFirst()).allSatisfy {
            $0.cpuUsage >= $1.cpuUsage
        })
        #expect(zip(sample.topMemoryProcesses, sample.topMemoryProcesses.dropFirst()).allSatisfy {
            $0.memoryBytes >= $1.memoryBytes
        })
    }

    @Test func disabledModulesAreNotSampled() async {
        let sampler = SystemMetricsSampler()
        let sample = await sampler.sample(modules: .init(
            cpu: false,
            gpu: false,
            memory: false,
            disk: false,
            network: false,
            battery: false
        ))

        #expect(sample.cpu == .zero)
        #expect(sample.memory == .zero)
        #expect(sample.disks.isEmpty)
        #expect(sample.network == .zero)
        #expect(sample.battery == nil)
        #expect(sample.gpu == nil)
        #expect(sample.topCPUProcesses.isEmpty)
        #expect(sample.topMemoryProcesses.isEmpty)
    }

    private func snapshot(cpu: Double) -> SystemMonitorSnapshot {
        SystemMonitorSnapshot(
            cpu: .init(
                total: cpu,
                user: cpu,
                system: 0,
                perCore: [cpu],
                loadAverage: [cpu, cpu, cpu],
                frequencyMHz: nil
            ),
            memory: .init(
                used: 50,
                total: 100,
                app: 20,
                wired: 15,
                compressed: 15,
                available: 50,
                swapUsed: 0,
                pressure: .normal
            ),
            disks: [],
            network: .init(
                downloadBytesPerSecond: 10,
                uploadBytesPerSecond: 20,
                totalDownloaded: 100,
                totalUploaded: 200,
                primaryInterface: "en0",
                interfaces: []
            ),
            battery: nil,
            gpu: nil,
            topCPUProcesses: [],
            topMemoryProcesses: [],
            sampledAt: Date()
        )
    }
}
