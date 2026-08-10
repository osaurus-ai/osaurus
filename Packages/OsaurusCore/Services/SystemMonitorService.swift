//
//  SystemMonitorService.swift
//  osaurus
//
//  Service for monitoring system resources (CPU and RAM usage)
//

import Combine
import Darwin
import Foundation

@MainActor
class SystemMonitorService: ObservableObject {
    static let shared = SystemMonitorService()

    @Published var cpuUsage: Double = 0.0
    @Published var memoryUsage: Double = 0.0
    @Published var totalMemoryGB: Double = 0.0
    @Published var usedMemoryGB: Double = 0.0

    /// App's own physical memory footprint in MB (via task_vm_info).
    /// Useful for detecting memory leaks in the app process itself.
    @Published var appMemoryMB: Double = 0.0

    @Published var availableStorageGB: Double = 0.0
    @Published var totalStorageGB: Double = 0.0

    private var storagePath: String = NSHomeDirectory()
    private var timer: Timer?

    /// All Mach sampling (host_statistics, task_info) lives here and runs
    /// off the main actor. The calls are usually microseconds, but under
    /// kernel memory pressure they can stall — production hang sampling
    /// caught `getAppMemoryMB` on the main thread (Sentry AppHang culprits
    /// in `SystemMonitorService`). The main actor only receives one
    /// equality-guarded snapshot per tick.
    private nonisolated let sampler = ResourceSampler()

    /// Guards against overlapping sample tasks if one outlives the 2s tick.
    private var isSampling = false

    private init() {
        startMonitoring()
    }

    func startMonitoring() {
        // Update immediately
        updateResourceUsage()

        // Update every 2 seconds to avoid excessive CPU usage
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateResourceUsage()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func updateResourceUsage() {
        if !isSampling {
            isSampling = true
            let sampler = self.sampler
            Task.detached(priority: .utility) {
                let snapshot = sampler.sample()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.publish(snapshot)
                    self.isSampling = false
                }
            }
        }

        // Storage capacity is queried off the main actor (see refreshStorageUsage):
        // the volume-capacity API can block the caller for seconds.
        refreshStorageUsage()
    }

    /// Publish only when a displayed value actually changed. Assigning an
    /// @Published property always fires objectWillChange — even with an
    /// identical value — which re-renders every observing SwiftUI subtree
    /// (the theme-heavy SystemResourceMonitor among them) on every 2s tick.
    /// Guarding each assignment collapses idle ticks to zero re-renders,
    /// removing a steady main-thread render cost seen in app-hang sampling.
    private func publish(_ snapshot: ResourceSnapshot) {
        if cpuUsage != snapshot.cpuUsage { cpuUsage = snapshot.cpuUsage }
        if memoryUsage != snapshot.memoryPercentage { memoryUsage = snapshot.memoryPercentage }
        if totalMemoryGB != snapshot.totalMemoryGB { totalMemoryGB = snapshot.totalMemoryGB }
        if usedMemoryGB != snapshot.usedMemoryGB { usedMemoryGB = snapshot.usedMemoryGB }
        if appMemoryMB != snapshot.appMemoryMB { appMemoryMB = snapshot.appMemoryMB }
    }

    /// Update the path used for storage monitoring (when user selects a custom models directory)
    func updateStoragePath(_ path: String) {
        storagePath = path
        updateResourceUsage()
    }

    /// Guards against overlapping storage queries if one outlives the 2s tick
    /// (the volume-capacity query can itself take seconds).
    private var isRefreshingStorage = false

    /// Query storage capacity off the main actor and publish the result back.
    ///
    /// `OsaurusPaths.volumeFreeBytes` prefers the cheap filesystem free-space
    /// query and falls back to the URL-keyed important-usage capacity only when
    /// needed. This avoids CacheDelete stalls on external model volumes while
    /// still covering sandbox/container zero-free-space reports from bug #964.
    private func refreshStorageUsage() {
        guard !isRefreshingStorage else { return }
        isRefreshingStorage = true
        let path = storagePath
        Task.detached(priority: .utility) {
            // Decimal GB (10^9 bytes) to match how Finder and drive vendors
            // report storage capacity — a "2 TB" SSD should read 2 TB, not
            // the 1.9 TB it comes out to in binary GiB. RAM stays binary.
            let gb = 1_000_000_000.0
            let freeBytes = OsaurusPaths.volumeFreeBytes(forPath: path) ?? 0
            let totalBytes = OsaurusPaths.volumeTotalBytes(forPath: path) ?? 0
            let available = ResourceSampler.rounded(Double(freeBytes) / gb)
            let total = ResourceSampler.rounded(Double(totalBytes) / gb)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.availableStorageGB != available { self.availableStorageGB = available }
                if self.totalStorageGB != total { self.totalStorageGB = total }
                self.isRefreshingStorage = false
            }
        }
    }

}

/// One tick's worth of resource readings, rounded to display precision.
private struct ResourceSnapshot: Sendable {
    let cpuUsage: Double
    let memoryPercentage: Double
    let totalMemoryGB: Double
    let usedMemoryGB: Double
    let appMemoryMB: Double
}

/// Off-main Mach sampling. `@unchecked Sendable`: `previousCPUInfo` is
/// guarded by `lock`; `hostPort` is immutable after init.
private final class ResourceSampler: @unchecked Sendable {
    /// Cached Mach host port to avoid leaking send rights.
    /// Each call to mach_host_self() allocates a new send right that must be
    /// deallocated with mach_port_deallocate(). Caching avoids the leak entirely.
    private let hostPort: mach_port_t = mach_host_self()

    private let lock = NSLock()
    private var previousCPUInfo: host_cpu_load_info?

    func sample() -> ResourceSnapshot {
        let memInfo = memoryUsage()
        return ResourceSnapshot(
            cpuUsage: Self.rounded(cpuUsage()),
            memoryPercentage: Self.rounded(memInfo.percentage),
            totalMemoryGB: Self.rounded(memInfo.totalGB),
            usedMemoryGB: Self.rounded(memInfo.usedGB),
            appMemoryMB: Self.rounded(appMemoryMB())
        )
    }

    /// Round to one decimal place — the precision shown in the UI — so
    /// sub-pixel jitter on an otherwise-idle machine doesn't count as a
    /// change when the main actor compares snapshots.
    static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func cpuUsage() -> Double {
        var cpuInfo: host_cpu_load_info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0.0 }

        let userTicks = Double(cpuInfo.cpu_ticks.0)
        let systemTicks = Double(cpuInfo.cpu_ticks.1)
        let idleTicks = Double(cpuInfo.cpu_ticks.2)
        let niceTicks = Double(cpuInfo.cpu_ticks.3)

        let totalTicks = userTicks + systemTicks + idleTicks + niceTicks

        lock.lock()
        let previous = previousCPUInfo
        previousCPUInfo = cpuInfo
        lock.unlock()

        if let previous {
            let previousUserTicks = Double(previous.cpu_ticks.0)
            let previousSystemTicks = Double(previous.cpu_ticks.1)
            let previousIdleTicks = Double(previous.cpu_ticks.2)
            let previousNiceTicks = Double(previous.cpu_ticks.3)

            let previousTotalTicks =
                previousUserTicks + previousSystemTicks + previousIdleTicks + previousNiceTicks

            let userDiff = userTicks - previousUserTicks
            let systemDiff = systemTicks - previousSystemTicks
            let niceDiff = niceTicks - previousNiceTicks

            let totalDiff = totalTicks - previousTotalTicks

            if totalDiff > 0 {
                let usage = ((userDiff + systemDiff + niceDiff) / totalDiff) * 100.0
                return min(100.0, max(0.0, usage))
            }
        }

        return 0.0
    }

    private func memoryUsage() -> (percentage: Double, totalGB: Double, usedGB: Double) {
        var vmInfo = vm_statistics64()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<natural_t>.size
        )

        let vmResult = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &vmCount)
            }
        }

        guard vmResult == KERN_SUCCESS else { return (0.0, 0.0, 0.0) }

        var rawPage: vm_size_t = 0
        host_page_size(hostPort, &rawPage)
        let pageSize = rawPage
        let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
        // "Available" mirrors the RAM feasibility gate in `ModelRuntime`
        // (free + inactive + speculative + purgeable), so the percentage
        // shown next to the tight-fit banner is the complement of the same
        // number the gate compares against. Counting speculative/purgeable
        // (largely file cache) as used overstated pressure versus Activity
        // Monitor, which treats cached files as available.
        let availableMemory =
            (Double(vmInfo.free_count)
                + Double(vmInfo.inactive_count)
                + Double(vmInfo.speculative_count)
                + Double(vmInfo.purgeable_count)) * Double(pageSize)

        let usedMemory = max(0.0, totalMemory - availableMemory)
        let percentage = (usedMemory / totalMemory) * 100.0

        let totalGB = totalMemory / (1024 * 1024 * 1024)
        let usedGB = usedMemory / (1024 * 1024 * 1024)

        return (min(100.0, max(0.0, percentage)), totalGB, usedGB)
    }

    /// Returns the app's own physical memory footprint in MB.
    /// Uses task_vm_info's phys_footprint which matches Activity Monitor's "Memory" column.
    private func appMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0.0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }
}
