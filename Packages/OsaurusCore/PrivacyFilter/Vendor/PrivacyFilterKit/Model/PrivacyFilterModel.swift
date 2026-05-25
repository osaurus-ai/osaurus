//
//  PrivacyFilterModel.swift
//  osaurus / PrivacyFilter (vendored)
//
//  Vendored from https://github.com/kokluch/privacy-filter-swift
//  @ 2bb396cce542155e1923fff1e08520348f1af1c5.
//
//  Osaurus-local rewires:
//    • Loads `model.safetensors` (HF convention) with a fallback to
//      `weights.safetensors` (upstream convention). Matches the file
//      layout we use under
//      `mlx-community/openai-privacy-filter-bf16`.
//    • The forward pass now delegates to `MoETransformer` (a
//      local-only sidecar) which implements the GPT-OSS-style
//      transformer body matching the upstream `openai_privacy_filter`
//      architecture. Upstream kokluch ships a placeholder forward —
//      we replace it because we actually want detection to work.
//
//  Re-apply on every upstream sync; see README-vendoring.md.
//

import Foundation
import MLX

struct PrivacyFilterModel {
    let config: ModelConfig
    private let transformer: MoETransformer

    init(directory: URL, config: ModelConfig) throws {
        self.config = config
        // Prefer the HF-style filename used by
        // `mlx-community/openai-privacy-filter-bf16`. Fall back to
        // `weights.safetensors` (the upstream
        // kokluch/privacy-filter-swift convention) so a hand-built
        // bundle still loads.
        let primary = directory.appendingPathComponent("model.safetensors")
        let legacy = directory.appendingPathComponent("weights.safetensors")
        let weightsURL: URL
        if FileManager.default.fileExists(atPath: primary.path) {
            weightsURL = primary
        } else if FileManager.default.fileExists(atPath: legacy.path) {
            weightsURL = legacy
        } else {
            throw ModelLoaderError.missingFile("model.safetensors")
        }
        let weights = try MLX.loadArrays(url: weightsURL)
        self.transformer = try MoETransformer(weights: weights, config: config)
    }

    /// Forward pass. Returns emission logits of shape `[seqLen][numLabels]`.
    /// Truncates to `MoETransformer.maxSequenceLength` so vanilla RoPE
    /// stays valid — callers needing whole-document classification
    /// should chunk on top.
    func forward(inputIds: [Int]) throws -> [[Float]] {
        let cap = MoETransformer.maxSequenceLength
        let truncated = inputIds.count > cap ? Array(inputIds.prefix(cap)) : inputIds
        return try transformer.forward(inputIds: truncated)
    }
}
