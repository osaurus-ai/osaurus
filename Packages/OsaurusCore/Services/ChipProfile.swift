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

    /// Enclosure class. Laptops (especially fanless Airs) throttle under
    /// sustained GPU load where desktops don't, so thermal-aware policy
    /// needs to know which one it's on. `unknown` covers VMs and future
    /// identifiers; policy code must treat it like a laptop (conservative).
    enum Chassis: String, Sendable {
        case laptop
        case desktop
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
    /// Enclosure class derived from `hw.model` (with an IOKit product-name
    /// fallback for opaque "Mac14,12"-style identifiers).
    let chassis: Chassis
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
            "resolved: brand=\(profile.brandString, privacy: .public) generation=\(profile.generation.map(String.init) ?? "unknown", privacy: .public) tier=\(profile.tier.rawValue, privacy: .public) ramBytes=\(profile.physicalMemoryBytes, privacy: .public) gpuCores=\(profile.gpuCoreCount.map(String.init) ?? "unknown", privacy: .public) workingSetBytes=\(profile.recommendedMaxWorkingSetBytes.map(String.init) ?? "unknown", privacy: .public) neuralAccelerators=\(profile.hasGPUNeuralAccelerators, privacy: .public) chassis=\(profile.chassis.rawValue, privacy: .public)"
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
                .map { UInt64($0.recommendedMaxWorkingSetSize) },
            chassis: detectChassis()
        )
    }

    /// Two-stage chassis detection: the model identifier alone classifies
    /// every pre-2022 machine; the IOKit product-name probe only runs for
    /// the opaque "Mac14,12"-style identifiers, keeping the common path a
    /// single sysctl.
    private static func detectChassis() -> Chassis {
        let model = sysctlString("hw.model") ?? ""
        let fromModel = parseChassis(modelIdentifier: model)
        if fromModel != .unknown { return fromModel }
        return parseChassis(
            modelIdentifier: model,
            productName: platformProductName()
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

    // MARK: - Chassis parsing (pure, unit-tested)

    /// Classifies a `hw.model` identifier (e.g. "MacBookPro18,3") into a
    /// chassis class, optionally falling back to the IOKit marketing
    /// product name (e.g. "MacBook Pro") for the opaque "Mac14,12"-style
    /// identifiers Apple ships since 2022, which encode nothing about the
    /// enclosure. Anything unclassifiable — VMs, Xserve, future naming —
    /// yields `.unknown` so policy falls back to the conservative
    /// (laptop-like) treatment rather than guessing.
    static func parseChassis(modelIdentifier: String, productName: String? = nil) -> Chassis {
        if let chassis = classifyChassis(modelIdentifier) { return chassis }
        if let productName, let chassis = classifyChassis(productName) { return chassis }
        return .unknown
    }

    /// Shared matcher for both identifier styles. Lowercased and
    /// de-spaced so "Mac mini" (product name) and "Macmini9,1" (hw.model)
    /// hit the same token. Laptop is checked first so "macbookpro" can
    /// never substring-match the desktop "macpro" token.
    private static func classifyChassis(_ raw: String) -> Chassis? {
        let normalized = raw.lowercased().replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }
        // "book" covers MacBook / MacBookPro / MacBookAir — the only
        // battery-powered, thermally constrained enclosures Apple ships.
        if normalized.contains("book") { return .laptop }
        let desktopTokens = ["macmini", "macstudio", "macpro", "imac"]
        if desktopTokens.contains(where: { normalized.contains($0) }) { return .desktop }
        return nil
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
            "chassis": chassis.rawValue,
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

    /// Reads the marketing `product-name` ("MacBook Pro (14-inch, M5 Max)",
    /// "Mac mini", …). Only consulted when `hw.model` is an opaque
    /// "Mac14,12"-style identifier. On current Apple Silicon the property
    /// lives on the device tree's `product` node (verified on Mac17,7);
    /// IOPlatformExpertDevice is probed second for older firmware layouts.
    /// Missing on Intel and most VMs, in which case chassis stays `.unknown`.
    private static func platformProductName() -> String? {
        if let name = productNameProperty(
            of: IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        ) {
            return name
        }
        return productNameProperty(
            of: IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("IOPlatformExpertDevice")
            )
        )
    }

    /// Extracts the `product-name` string from `entry`, releasing the entry
    /// (callers hand over ownership; MACH_PORT_NULL is tolerated so lookup
    /// failures need no separate guard).
    private static func productNameProperty(of entry: io_registry_entry_t) -> String? {
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            "product-name" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }
        if let name = value as? String { return name }
        guard let data = value as? Data else { return nil }
        // The registry value is commonly a NUL-terminated C string in CFData.
        return String(bytes: data.prefix { $0 != 0 }, encoding: .utf8)
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

        var coreCount: Int?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if coreCount == nil,
                let value = IORegistryEntryCreateCFProperty(
                    entry,
                    "gpu-core-count" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? Int {
                coreCount = value
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return coreCount
    }
}
