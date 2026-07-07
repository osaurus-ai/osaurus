//
//  ModelPickerItemDecodeEstimateTests.swift
//  osaurusTests
//
//  Covers the item-level decode-speed estimate the picker row surfaces
//  ("… · ~120 tok/s"): the pure computation (dense vs name-derived MoE
//  fraction, suppression when a config-declared MoE has no derivable
//  fraction, no-bandwidth fallback) and the subtitle append. SwiftUI/AppKit
//  rendering is intentionally not exercised — the row just displays the
//  string produced here.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelPickerItemDecodeEstimateTests {

    /// M5 Max-shaped profile with an explicit measured bandwidth so no test
    /// depends on the host machine or the user's calibration file.
    private func profile(brand: String = "Apple M5 Max", measured: Double? = 411) -> ChipProfile {
        ChipProfile(
            brandString: brand,
            generation: 5,
            tier: .max,
            physicalMemoryBytes: 64 << 30,
            gpuCoreCount: nil,
            recommendedMaxWorkingSetBytes: nil,
            measuredBandwidthGBps: measured
        )
    }

    // MARK: - Pure computation

    @Test func denseModelUsesFullWeights() throws {
        let tps = try #require(
            ModelPickerItem.estimatedDecodeTps(
                weightsBytes: 18_200_000_000,
                repoId: "OsaurusAI/gemma-4-31B-it-qat-MXFP4",
                isConfigDeclaredMoE: false,
                profile: profile()))
        #expect(abs(tps - 411e9 * 0.7 / 18.2e9) < 1e-9)
    }

    @Test func moeNameScalesByActiveFraction() throws {
        // 23.1 GB, 35B total, A3B active → ÷ (23.1 GB × 3/35).
        let weights: Int64 = 23_100_000_000
        let tps = try #require(
            ModelPickerItem.estimatedDecodeTps(
                weightsBytes: weights,
                repoId: "OsaurusAI/Qwen3.6-35B-A3B-MXFP4-MTP",
                isConfigDeclaredMoE: true,
                profile: profile()))
        // Grouped as the implementation computes it: total × (active/total).
        let activeBytes = Double(Int64(Double(weights) * (3.0 / 35.0)))
        #expect(abs(tps - 411e9 * 0.7 / activeBytes) < 1e-9)
        // Sanity: the MoE estimate is severalfold above the dense floor.
        let dense = try #require(
            ModelPickerItem.estimatedDecodeTps(
                weightsBytes: weights,
                repoId: "OsaurusAI/dense-23B",
                isConfigDeclaredMoE: false,
                profile: profile()))
        #expect(tps > dense * 5)
    }

    @Test func configDeclaredMoEWithoutNameFractionIsSuppressed() {
        // Same rule as `osaurus show`: a dense-formula number would
        // understate a MoE model severalfold — worse than no estimate.
        #expect(
            ModelPickerItem.estimatedDecodeTps(
                weightsBytes: 23_100_000_000,
                repoId: "org/some-moe-model",
                isConfigDeclaredMoE: true,
                profile: profile()) == nil)
    }

    @Test func noBandwidthMeansNoEstimate() {
        // Unknown chip, never calibrated → nil, never a garbage number.
        #expect(
            ModelPickerItem.estimatedDecodeTps(
                weightsBytes: 18_200_000_000,
                repoId: "OsaurusAI/gemma-4-31B-it-qat-MXFP4",
                isConfigDeclaredMoE: false,
                profile: profile(brand: "Intel(R) Xeon(R)", measured: nil)) == nil)
    }

    @Test func zeroWeightsMeansNoEstimate() {
        #expect(
            ModelPickerItem.estimatedDecodeTps(
                weightsBytes: 0,
                repoId: "OsaurusAI/gemma-4-31B-it-qat-MXFP4",
                isConfigDeclaredMoE: false,
                profile: profile()) == nil)
    }

    // MARK: - Disk-facing wrapper

    @Test func localDecodeEstimateRequiresInstalledBundle() throws {
        // Not on disk → nil regardless of sizes/params.
        let missing = MLXModel(
            id: "org/not-installed-7b",
            name: "Not Installed",
            description: "fixture",
            downloadURL: "https://example.invalid/x",
            downloadSizeBytes: 4_000_000_000,
            rootDirectory: nil,
            bundleDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("osu-decode-missing-\(UUID().uuidString)")
        )
        #expect(ModelPickerItem.localDecodeEstimate(for: missing, profile: profile()) == nil)
    }

    @Test func localDecodeEstimateReadsTheBundleForTheMoEDeclaration() throws {
        // A complete on-disk MoE bundle whose id has no A<k>B token: the
        // config declaration must suppress the estimate even though a size
        // is known.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-decode-moe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONSerialization.data(
            withJSONObject: ["model_type": "qwen3_5_moe", "num_experts": 128]
        ).write(to: dir.appendingPathComponent("config.json"))
        try Data(count: 8).write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data(count: 1_024).write(to: dir.appendingPathComponent("model.safetensors"))

        let moe = MLXModel(
            id: "org/mystery-moe-30b",
            name: "Mystery MoE",
            description: "fixture",
            downloadURL: "https://example.invalid/moe",
            downloadSizeBytes: 23_100_000_000,
            bundleDirectory: dir
        )
        #expect(moe.isDownloaded)
        #expect(ModelPickerItem.localDecodeEstimate(for: moe, profile: profile()) == nil)

        // Flip the config to dense: the same bundle now gets an estimate
        // from its explicit size.
        try JSONSerialization.data(withJSONObject: ["model_type": "qwen3"])
            .write(to: dir.appendingPathComponent("config.json"))
        let dense = MLXModel(
            id: "org/mystery-dense-30b",
            name: "Mystery Dense",
            description: "fixture",
            downloadURL: "https://example.invalid/dense",
            downloadSizeBytes: 23_100_000_000,
            bundleDirectory: dir
        )
        let tps = try #require(
            ModelPickerItem.localDecodeEstimate(for: dense, profile: profile()))
        #expect(abs(tps - 411e9 * 0.7 / 23.1e9) < 1e-9)
    }

    // MARK: - Subtitle append

    @Test func subtitleAppendsEstimateToExistingDescription() {
        let item = ModelPickerItem(
            id: "OsaurusAI/Qwen3.6-35B-A3B-MXFP4-MTP",
            displayName: "Qwen 3.6 35B",
            source: .local,
            description: "Fast MoE flagship",
            estimatedDecodeTps: 119.9
        )
        #expect(item.formattedDecodeEstimate == "~120 tok/s")
        #expect(item.pickerSubtitle == "Fast MoE flagship · ~120 tok/s")
    }

    @Test func subtitleIsEstimateAloneWithoutDescription() {
        let bare = ModelPickerItem(
            id: "org/dense-7b",
            displayName: "Dense 7B",
            source: .local,
            estimatedDecodeTps: 34.2
        )
        #expect(bare.pickerSubtitle == "~34 tok/s")

        let empty = ModelPickerItem(
            id: "org/dense-7b",
            displayName: "Dense 7B",
            source: .local,
            description: "",
            estimatedDecodeTps: 34.2
        )
        #expect(empty.pickerSubtitle == "~34 tok/s")
    }

    @Test func subtitleUnchangedWithoutEstimate() {
        let item = ModelPickerItem(
            id: "openai/gpt-4o",
            displayName: "gpt-4o",
            source: .remote(providerName: "OpenAI", providerId: UUID()),
            description: "Remote model"
        )
        #expect(item.estimatedDecodeTps == nil)
        #expect(item.pickerSubtitle == "Remote model")

        // Sub-0.5 tok/s would render as "~0 tok/s" — omitted instead.
        let tiny = ModelPickerItem(
            id: "org/huge-model",
            displayName: "Huge",
            source: .local,
            description: "desc",
            estimatedDecodeTps: 0.2
        )
        #expect(tiny.pickerSubtitle == "desc")
    }
}
