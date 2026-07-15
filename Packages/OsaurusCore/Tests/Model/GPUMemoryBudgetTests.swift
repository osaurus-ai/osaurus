//
//  GPUMemoryBudgetTests.swift
//  OsaurusCoreTests
//
//  Model fit is judged against the GPU working set, not physical RAM.
//

import Testing

@testable import OsaurusCore

@Suite("GPU memory budget")
struct GPUMemoryBudgetTests {

    private static let bytesPerGB: Double = 1024 * 1024 * 1024

    private static func model(_ name: String, gbOnDisk: Double) -> MLXModel {
        MLXModel(
            id: "test/\(name)",
            name: name,
            description: "",
            downloadURL: "https://example.com/\(name)",
            downloadSizeBytes: Int64(gbOnDisk * bytesPerGB)
        )
    }

    // MARK: - Budget

    @Test("Machines at or below 36 GB hold back proportionally more for the OS")
    func smallMachinesReserveMore() {
        #expect(GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 16) == 16 * (2.0 / 3.0))
        #expect(GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 36) == 36 * (2.0 / 3.0))
        #expect(GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 48) == 36.0)
        #expect(GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 128) == 96.0)
    }

    @Test("No physical memory yields no budget")
    func zeroMemoryYieldsZeroBudget() {
        #expect(GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 0) == 0)
        #expect(GPUMemoryBudget.budgetGB(physicalMemoryGB: 0) == 0)
    }

    /// Metal is consulted only for the host, and only ever to lower the
    /// budget. Whatever machine this runs on, the verdict can never be more
    /// optimistic than the conservative default split.
    @Test("Metal can only tighten the host budget, never loosen it")
    func metalOnlyTightens() {
        let host = GPUMemoryBudget.hostPhysicalMemoryGB
        #expect(
            GPUMemoryBudget.budgetGB(physicalMemoryGB: host)
                <= GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: host)
        )
    }

    /// A hypothetical RAM size must resolve identically regardless of the
    /// machine the catalog math happens to run on.
    @Test("Hypothetical RAM sizes ignore the host's Metal device")
    func hypotheticalSizesAreHostIndependent() {
        for ram in [8.0, 16.0, 24.0, 32.0, 64.0, 192.0] where abs(ram - GPUMemoryBudget.hostPhysicalMemoryGB) >= 1.0 {
            #expect(
                GPUMemoryBudget.budgetGB(physicalMemoryGB: ram)
                    == GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: ram)
            )
        }
    }

    // MARK: - Fit

    /// The reported regression: Ornith-1.0-35B-MXFP8 is 34.17 GiB on disk,
    /// so ~42.7 GB resident. On a 48 GB Mac that is 89% of RAM — which the
    /// old physical-RAM ratio scored as a merely `.tight` fit and offered for
    /// download — but 119% of the 36 GB the GPU can hold. macOS pages the
    /// weights and decode collapses to about a character every ten seconds.
    @Test("A 35B MXFP8 bundle is too large for a 48 GB Mac")
    func ornith35BMXFP8DoesNotFit48GB() {
        let ornith = Self.model("ornith-35b-mxfp8", gbOnDisk: 34.17)
        #expect(ornith.compatibility(totalMemoryGB: 48) == .tooLarge)
    }

    @Test("The same bundle is tight at 64 GB and comfortable at 96 GB and up")
    func ornith35BMXFP8FitsLargerMachines() {
        let ornith = Self.model("ornith-35b-mxfp8", gbOnDisk: 34.17)
        #expect(ornith.compatibility(totalMemoryGB: 64) == .tight)
        #expect(ornith.compatibility(totalMemoryGB: 96) == .compatible)
        #expect(ornith.compatibility(totalMemoryGB: 128) == .compatible)
    }

    @Test("Small bundles stay comfortable on base-RAM Macs")
    func smallModelsRemainCompatible() {
        // A ~2 GB 4-bit bundle: 2.5 GB resident against a 5.33 GB budget.
        #expect(Self.model("e2b", gbOnDisk: 2.0).compatibility(totalMemoryGB: 8) == .compatible)
        #expect(Self.model("e2b", gbOnDisk: 2.0).compatibility(totalMemoryGB: 16) == .compatible)
        // A ~4.7 GB 8B-4bit bundle: 5.9 GB resident against 10.67 GB.
        #expect(Self.model("8b-4bit", gbOnDisk: 4.7).compatibility(totalMemoryGB: 16) == .compatible)
    }

    @Test("A model with no size information stays unknown rather than blocked")
    func unsizedModelIsUnknown() {
        let unsized = MLXModel(
            id: "test/unsized",
            name: "unsized",
            description: "",
            downloadURL: "https://example.com/unsized"
        )
        #expect(unsized.compatibility(totalMemoryGB: 48) == .unknown)
    }

    @Test("Compatibility is unknown before the memory monitor reports")
    func unknownBeforeMonitorReports() {
        #expect(Self.model("any", gbOnDisk: 2.0).compatibility(totalMemoryGB: 0) == .unknown)
    }
}
