//
//  MacProfile.swift
//  osaurus
//
//  What the first-run opening says about this Mac: its marketing name, its
//  chip, and its memory. Read from the system, never asked for.
//

import Foundation
import IOKit

public struct MacProfile: Sendable, Equatable {
    /// "MacBook Air", "Mac mini". Never empty: "Mac" when unknown.
    public var modelName: String
    /// "M4", "M3 Pro". Nil off Apple Silicon.
    public var chip: String?
    public var memoryGB: Int

    public init(modelName: String, chip: String?, memoryGB: Int) {
        self.modelName = modelName
        self.chip = chip
        self.memoryGB = memoryGB
    }

    @MainActor
    public static func current() -> MacProfile {
        let chipProfile = ChipProfile.current
        let sampled = SystemMonitorService.shared.totalMemoryGB
        let memory =
            sampled > 0 ? sampled : Double(chipProfile.physicalMemoryBytes) / 1_073_741_824
        return MacProfile(
            modelName: marketingName(productName: productName()) ?? "Mac",
            chip: chipName(brandString: chipProfile.brandString),
            memoryGB: Int(memory.rounded())
        )
    }

    /// "MacBook Air (15-inch, M3, 2024)" reads as "MacBook Air".
    static func marketingName(productName: String?) -> String? {
        guard let productName else { return nil }
        let name = productName.split(separator: "(").first.map(String.init) ?? productName
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Apple M4 Pro" reads as "M4 Pro".
    static func chipName(brandString: String) -> String? {
        guard ChipProfile.parse(brandString: brandString).generation != nil else { return nil }
        return brandString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "Apple ", with: "")
    }

    /// The `product-name` property of the device tree's product node, which
    /// Apple Silicon Macs fill with the marketing name.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard
            let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data
        else { return nil }
        let bytes = data.prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)
    }
}
