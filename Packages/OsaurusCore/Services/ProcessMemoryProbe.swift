//
//  ProcessMemoryProbe.swift
//  OsaurusCore
//
//  Public, dependency-free reader for the current process's physical
//  memory footprint. Mirrors `SystemMonitorService.getAppMemoryMB()`
//  (which is private to the monitor actor) but is exposed as a free
//  function so out-of-process tooling — the eval harness peak-RAM
//  sampler in particular — can poll the same number Activity Monitor's
//  "Memory" column reports without standing up the whole monitor.
//

import Darwin
import Foundation

/// Reads `task_vm_info.phys_footprint` for the calling process. This is
/// the value the `AGENTS.md` RAM gate is written against: it tracks the
/// real physical footprint (resident + compressed + IOKit), not virtual
/// size, so a low-RAM model that paths into full-model territory shows
/// up here even when generation looks coherent.
public enum ProcessMemoryProbe {
    /// Current physical footprint in megabytes, or `nil` when the kernel
    /// query fails (never throws — callers treat a failed probe as
    /// "no sample" rather than a hard error in a measurement loop).
    public static func currentPhysFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / (1024 * 1024)
    }
}
