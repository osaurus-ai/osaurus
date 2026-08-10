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

    @Test("Picker and runtime share the exact chat working-set estimate")
    func pickerAndRuntimeWorkingSetMatch() throws {
        let onDiskBytes = Int64(12.48 * Self.bytesPerGB)
        let model = Self.model("gemma-12b-mxfp8", gbOnDisk: 12.48)
        let pickerGB = try #require(model.estimatedMemoryGB)
        let runtimeBytes = try #require(
            ModelRuntime.estimatedMemorySafetyWorkingSetBytes(
                loadFootprintBytes: onDiskBytes,
                physicalMemoryBytes: UInt64(128 * Self.bytesPerGB)
            )
        )

        #expect(abs(pickerGB - Double(runtimeBytes) / Self.bytesPerGB) < 0.001)
        #expect(abs(pickerGB - 15.6) < 0.001)
    }

    @Test("Reported Gemma uses measured files and runs comfortably on 96 GB")
    func reportedGemmaUsesResolvedSize() throws {
        // Hugging Face reports a 16.87 GB decimal download for this repo.
        // That is ~15.71 GiB of files and ~19.64 GiB after the shared 1.25×
        // running-memory allowance — nowhere near the stale 63.9 GB shown in
        // the original detail sheet.
        let gemma = MLXModel(
            id: "mlx-community/gemma-3-27b-it-qat-4bit",
            name: "Gemma 3 27B QAT 4-bit",
            description: "",
            downloadURL: "https://huggingface.co/mlx-community/gemma-3-27b-it-qat-4bit",
            downloadSizeBytes: 16_870_000_000
        )

        let assessment = gemma.memoryAssessment(totalMemoryGB: 96)
        let runningGB = try #require(assessment.estimatedRunningMemoryGB)

        #expect(assessment.sizeSource == .measured)
        #expect(abs(runningGB - 19.64) < 0.02)
        #expect(abs(assessment.gpuWorkingSetBudgetGB - 72) < 0.001)
        #expect(abs(assessment.comfortableModelBudgetGB - 61.2) < 0.001)
        #expect(assessment.compatibility == .compatible)
    }

    @Test("Measured size replaces metadata fallback throughout the assessment")
    func measuredSizeReplacesFallback() throws {
        let fallback = MLXModel(
            id: "mlx-community/gemma-3-27b-it-qat-4bit",
            name: "Gemma 3 27B QAT 4-bit",
            description: "",
            downloadURL: "https://huggingface.co/mlx-community/gemma-3-27b-it-qat-4bit"
        )
        let resolved = fallback.withDownloadSize(16_870_000_000)

        #expect(fallback.sizeEstimateSource == .metadataFallback)
        #expect(resolved.sizeEstimateSource == .measured)
        #expect(fallback.totalSizeEstimateBytes == Int64(13.5 * Self.bytesPerGB))
        #expect(resolved.totalSizeEstimateBytes == 16_870_000_000)
        let resolvedMemory = try #require(resolved.estimatedMemoryGB)
        let fallbackMemory = try #require(fallback.estimatedMemoryGB)
        #expect(resolvedMemory > fallbackMemory)
        let formatted = try #require(resolved.formattedEstimatedMemory)
        #expect(!formatted.hasPrefix("~"))
    }

    @Test("Assessment boundaries use the same comfortable and advisory limits")
    func assessmentBoundaries() {
        // 16 GB yields a 10.67 GiB Metal budget. Convert desired running
        // memory back to model bytes by dividing by the shared 1.25× factor.
        let budget = GPUMemoryBudget.defaultBudgetGB(physicalMemoryGB: 16)
        func assessment(ratio: Double) -> ModelMemoryAssessment {
            let runningGB = budget * ratio
            let modelBytes = Int64(runningGB / 1.25 * Self.bytesPerGB)
            return GPUMemoryBudget.assessment(
                modelSizeBytes: modelBytes,
                sizeSource: .measured,
                physicalMemoryGB: 16
            )
        }

        #expect(assessment(ratio: 0.84).compatibility == .compatible)
        #expect(assessment(ratio: 0.90).compatibility == .tight)
        #expect(assessment(ratio: 1.11).compatibility == .tooLarge)
    }

    @Test("Selection surfaces share one plain-language verdict vocabulary")
    func sharedVerdictVocabulary() {
        #expect(ModelCompatibility.compatible.displayName == "Runs well")
        #expect(ModelCompatibility.tight.displayName == "Memory may be tight")
        #expect(ModelCompatibility.tooLarge.displayName == "Not recommended")
        #expect(ModelCompatibility.unknown.displayName == "Not enough information")
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
