//
//  ChipProfile.swift
//  osaurus
//
//  Detects the Apple Silicon chip this process is running on (generation,
//  tier, RAM, GPU core count, Metal working-set budget) so runtime policy can
//  be derived from hardware capability instead of one-size-fits-all
//  constants. Detection is read-only and resolved once per process; nothing
//  in this file changes runtime behavior by itself.
//
//  Why not persist the result: every field is re-derivable in microseconds
//  from sysctl/IOKit/Metal at launch, and a cached file would go stale when a
//  Time Machine / Migration Assistant restore moves the install to different
//  hardware. Persistence becomes worthwhile only for *measured* values
//  (micro-benchmarked bandwidth/FLOPS), which are out of scope here.
//

import Foundation
import IOKit
import Metal
import os.log

private let chipLog = Logger(subsystem: "com.dinoki.osaurus", category: "ChipProfile")

/// Immutable snapshot of the host's compute capability.
struct ChipProfile: Sendable, Equatable {
    /// Performance tier encoded in Apple's chip branding. `unknown` covers
    /// Intel Macs, virtual machines, and future naming schemes; policy code
    /// must treat it as the most conservative tier.
    enum Tier: String, Sendable {
        case base
        case pro
        case max
        case ultra
        case unknown
    }

    /// Marketing name as reported by the kernel, e.g. "Apple M4 Pro".
    let brandString: String
    /// Apple Silicon generation (1 for M1, 5 for M5, …); `nil` when the
    /// brand string is not an "Apple M<n>" chip.
    let generation: Int?
    let tier: Tier
    /// Physical unified memory in bytes (`hw.memsize`).
    let physicalMemoryBytes: UInt64
    /// GPU core count from the IOKit accelerator node; `nil` when the node
    /// or property is missing (VMs, future driver changes).
    let gpuCoreCount: Int?
    /// Metal's per-process working-set recommendation. This is the OS's own
    /// answer to "how much GPU-visible memory may I comfortably use" and is
    /// the anchor for any future wired-memory policy.
    let recommendedMaxWorkingSetBytes: UInt64?
    /// The M5 family embeds matrix units ("Neural Accelerators") in each GPU
    /// core, which shifts the prefill/decode balance materially. Derived
    /// from `generation`, not probed — Metal exposes no direct capability
    /// bit for them at the API level osaurus targets.
    var hasGPUNeuralAccelerators: Bool { (generation ?? 0) >= 5 }

    /// Tier for policy decisions: never `unknown`. Unknown hardware gets
    /// base-tier (most conservative) treatment.
    var policyTier: Tier { tier == .unknown ? .base : tier }

    // MARK: - Resolution

    /// The host's profile, resolved once on first access.
    static let current: ChipProfile = {
        let profile = ChipProfile.detect()
        chipLog.info(
            "resolved: brand=\(profile.brandString, privacy: .public) generation=\(profile.generation.map(String.init) ?? "unknown", privacy: .public) tier=\(profile.tier.rawValue, privacy: .public) ramBytes=\(profile.physicalMemoryBytes, privacy: .public) gpuCores=\(profile.gpuCoreCount.map(String.init) ?? "unknown", privacy: .public) workingSetBytes=\(profile.recommendedMaxWorkingSetBytes.map(String.init) ?? "unknown", privacy: .public) neuralAccelerators=\(profile.hasGPUNeuralAccelerators, privacy: .public)"
        )
        return profile
    }()

    static func detect() -> ChipProfile {
        let brand = sysctlString("machdep.cpu.brand_string") ?? "unknown"
        let identity = parse(brandString: brand)
        return ChipProfile(
            brandString: brand,
            generation: identity.generation,
            tier: identity.tier,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            gpuCoreCount: detectGPUCoreCount(),
            recommendedMaxWorkingSetBytes: MTLCreateSystemDefaultDevice()
                .map { UInt64($0.recommendedMaxWorkingSetSize) }
        )
    }

    // MARK: - Brand-string parsing (pure, unit-tested)

    /// Parses "Apple M<generation>[ Pro|Max|Ultra]" into its components.
    /// Anything else — Intel brand strings, VMs, a renamed future family —
    /// yields `(nil, .unknown)` so callers fall back to conservative policy
    /// rather than guessing.
    static func parse(brandString: String) -> (generation: Int?, tier: Tier) {
        let trimmed = brandString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Anchored so adulterated strings ("VirtualApple M2 …") don't match.
        guard
            let match = trimmed.wholeMatch(
                of: /Apple M(\d+)(?:\s+(Pro|Max|Ultra))?/
            )
        else {
            return (nil, .unknown)
        }
        let generation = Int(match.1)
        let tier: Tier
        switch match.2 ?? "" {
        case "Pro": tier = .pro
        case "Max": tier = .max
        case "Ultra": tier = .ultra
        default: tier = .base
        }
        return (generation, tier)
    }

    // MARK: - /health surface

    /// JSON-object form for the `/health` endpoint's `hardware` block.
    /// Unknown values are surfaced as JSON null (not omitted) so clients can
    /// distinguish "not detectable here" from "old server without the field".
    func healthJSONObject() -> [String: Any] {
        [
            "chip": brandString,
            "generation": generation as Any? ?? NSNull(),
            "tier": tier.rawValue,
            "physical_memory_bytes": physicalMemoryBytes,
            "gpu_core_count": gpuCoreCount as Any? ?? NSNull(),
            "recommended_max_working_set_bytes":
                recommendedMaxWorkingSetBytes as Any? ?? NSNull(),
            "gpu_neural_accelerators": hasGPUNeuralAccelerators,
        ]
    }

    // MARK: - Probes

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Reads `gpu-core-count` from the AGXAccelerator IORegistry node. There
    /// is exactly one such node on Apple Silicon; iterating covers the
    /// (never observed) multi-node case and returns the first match.
    private static func detectGPUCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching("AGXAccelerator"),
                &iterator
            ) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var coreCount: Int? = nil
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if coreCount == nil,
                let value = IORegistryEntryCreateCFProperty(
                    entry,
                    "gpu-core-count" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? Int
            {
                coreCount = value
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return coreCount
    }
}
