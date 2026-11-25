//
//  ComputerUseModelCatalog.swift
//  OsaurusCore — Computer Use
//
//  The curated on-device models offered under Local Models → Computer Use.
//  They are ordinary MLX chat bundles: they download, install, and load
//  through `ModelManager` like every other local model, and any installed chat
//  model can still be picked for Computer Use. This list only decides which
//  bundles the Computer Use tab recommends.
//

import Foundation

enum ComputerUseModelCatalog {
    /// One candidate bundle and the runtime proof that admitted it.
    struct Candidate: Sendable {
        let model: MLXModel
        /// Where the passing runtime proof row is recorded (load, token/s, an
        /// executed `agent_action` call with parseable arguments, multi-turn,
        /// physical footprint). `nil` keeps the bundle off the tab.
        let proof: String?
    }

    static let qwen3VL8BId = "mlx-community/Qwen3-VL-8B-Instruct-4bit"
    static let qwen3VL4BId = "mlx-community/Qwen3-VL-4B-Instruct-4bit"

    /// Every bundle under evaluation, in display order. Osaurus-published
    /// bundles go first, as top picks, once they exist. Models trained on their
    /// own action syntax (UI-TARS, Holo1) are not candidates: the loop speaks
    /// `agent_action` through the bundle's tool-calling template, and their
    /// bundles carry no metadata naming another syntax.
    static let candidates: [Candidate] = [
        Candidate(
            model: MLXModel(
                id: qwen3VL8BId,
                name: "Qwen3-VL 8B",
                description:
                    "Vision-language model with GUI grounding. Reads the screen and calls Computer Use "
                    + "actions through its own tool-calling template.",
                downloadURL: "https://huggingface.co/\(qwen3VL8BId)",
                isTopSuggestion: true,
                useCase: .vision
            ),
            proof: "docs/COMPUTER_USE.md#local-model-proof"
        ),
        Candidate(
            model: MLXModel(
                id: qwen3VL4BId,
                name: "Qwen3-VL 4B",
                description:
                    "Smaller Qwen3-VL for Macs with less memory. Same tool-calling template as the 8B.",
                downloadURL: "https://huggingface.co/\(qwen3VL4BId)",
                useCase: .vision
            ),
            proof: nil
        ),
    ]

    /// The admitted bundles the Computer Use tab lists.
    static var models: [MLXModel] {
        candidates.compactMap { $0.proof == nil ? nil : $0.model }
    }

    /// Admitted bundles found on disk, in the Models Directory or a folder
    /// registered under Storage → External Models.
    static func installedModels() -> [MLXModel] {
        models.compactMap(installedCopy)
    }

    /// The model as installed (with its external location when it lives
    /// outside the Models Directory), or `nil` when it is not on disk.
    static func installedCopy(of model: MLXModel) -> MLXModel? {
        if model.isDownloaded { return model }
        guard let externalDirectory = ExternalModelLocator.path(forId: model.id) else { return nil }
        let external = MLXModel(
            id: model.id,
            name: model.name,
            description: model.description,
            downloadURL: model.downloadURL,
            isTopSuggestion: model.isTopSuggestion,
            useCase: model.useCase,
            bundleDirectory: externalDirectory,
            externalSource: ExternalModelLocator.Source.customModelFolder.rawValue
        )
        return external.isDownloaded ? external : nil
    }
}
