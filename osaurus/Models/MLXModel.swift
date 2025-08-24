//
//  MLXModel.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation

/// Represents an MLX-compatible LLM that can be downloaded and used
struct MLXModel: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let size: Int64 // Size in bytes
    let downloadURL: String
    let requiredFiles: [String] // Files needed for the model

    // Capture the models root directory at initialization time to avoid
    // relying on a mutable global during tests or concurrent execution.
    private let rootDirectory: URL

    init(
        id: String,
        name: String,
        description: String,
        size: Int64,
        downloadURL: String,
        requiredFiles: [String],
        rootDirectory: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.size = size
        self.downloadURL = downloadURL
        self.requiredFiles = requiredFiles
        self.rootDirectory = rootDirectory ?? DirectoryPickerService.shared.effectiveModelsDirectory
    }
    
    /// Human-readable size string
    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    /// Local directory where this model should be stored
    var localDirectory: URL {
        // Build the path using each component of the repository id separately.
        let components = id.split(separator: "/").map(String.init)
        return components.reduce(rootDirectory) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }
    
    /// Check if model is downloaded
    var isDownloaded: Bool {
        let fileManager = FileManager.default

        // Required JSON metadata files commonly used by transformers
        let requiredJsonFiles = [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json"
        ]

        // All JSON files must exist
        let jsonOk = requiredJsonFiles.allSatisfy { fileName in
            let filePath = localDirectory.appendingPathComponent(fileName).path
            return fileManager.fileExists(atPath: filePath)
        }
        guard jsonOk else { return false }

        // At least one weights file must exist
        if let items = try? fileManager.contentsOfDirectory(at: localDirectory, includingPropertiesForKeys: nil) {
            let hasWeights = items.contains { $0.pathExtension == "safetensors" }
            return hasWeights
        }
        return false
    }
}

/// Download state for tracking progress
enum DownloadState: Equatable {
    case notStarted
    case downloading(progress: Double)
    case completed
    case failed(error: String)
}
