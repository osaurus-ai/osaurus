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

    private var timer: Timer?
    private var previousCPUInfo: host_cpu_load_info?

    /// Cached Mach host port to avoid leaking send rights.
    /// Each call to mach_host_self() allocates a new send right that must be
    /// deallocated with mach_port_deallocate(). Caching avoids the leak entirely.
    private let hostPort: mach_port_t = mach_host_self()

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
        cpuUsage = getCPUUsage()
        let memInfo = getMemoryUsage()
        memoryUsage = memInfo.percentage
        totalMemoryGB = memInfo.totalGB
        usedMemoryGB = memInfo.usedGB
        appMemoryMB = getAppMemoryMB()
        let storageInfo = getStorageUsage()
        availableStorageGB = storageInfo.availableGB
        totalStorageGB = storageInfo.totalGB
    }

    private func getCPUUsage() -> Double {
        var _ = mach_msg_type_number_t()
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

        if let previous = previousCPUInfo {
            let previousUserTicks = Double(previous.cpu_ticks.0)
            let previousSystemTicks = Double(previous.cpu_ticks.1)
            let previousIdleTicks = Double(previous.cpu_ticks.2)
            let previousNiceTicks = Double(previous.cpu_ticks.3)

            let previousTotalTicks =
                previousUserTicks + previousSystemTicks + previousIdleTicks + previousNiceTicks

            let userDiff = userTicks - previousUserTicks
            let systemDiff = systemTicks - previousSystemTicks
            let _ = idleTicks - previousIdleTicks
            let niceDiff = niceTicks - previousNiceTicks

            let totalDiff = totalTicks - previousTotalTicks

            if totalDiff > 0 {
                let usage = ((userDiff + systemDiff + niceDiff) / totalDiff) * 100.0
                previousCPUInfo = cpuInfo
                return min(100.0, max(0.0, usage))
            }
        }

        previousCPUInfo = cpuInfo
        return 0.0
    }

    private func getMemoryUsage() -> (percentage: Double, totalGB: Double, usedGB: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )

        let _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

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
        let freeMemory = Double(vmInfo.free_count) * Double(pageSize)
        let inactiveMemory = Double(vmInfo.inactive_count) * Double(pageSize)
        let _ = Double(vmInfo.wire_count) * Double(pageSize)
        let _ = Double(vmInfo.compressor_page_count) * Double(pageSize)

        let usedMemory = totalMemory - freeMemory - inactiveMemory
        let percentage = (usedMemory / totalMemory) * 100.0

        let totalGB = totalMemory / (1024 * 1024 * 1024)
        let usedGB = usedMemory / (1024 * 1024 * 1024)

        return (min(100.0, max(0.0, percentage)), totalGB, usedGB)
    }

    /// Returns the app's own physical memory footprint in MB.
    /// Uses task_vm_info's phys_footprint which matches Activity Monitor's "Memory" column.
    private func getAppMemoryMB() -> Double {
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

    private func getStorageUsage() -> (availableGB: Double, totalGB: Double) {
        let gb = 1024.0 * 1024.0 * 1024.0
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let total = (attrs[.systemSize] as? NSNumber)?.doubleValue ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
            return (free / gb, total / gb)
        } catch {
            return (0.0, 0.0)
        }
    }

}
