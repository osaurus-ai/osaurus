//
//  ModelManager.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Combine
import Foundation
import Hub
import SwiftUI

/// Manages MLX model downloads and storage
@MainActor
final class ModelManager: NSObject, ObservableObject {
  static let shared = ModelManager()

  // MARK: - Published Properties
  @Published var availableModels: [MLXModel] = []
  @Published var downloadStates: [String: DownloadState] = [:]
  @Published var isLoadingModels: Bool = false
  @Published var suggestedModels: [MLXModel] = ModelManager.curatedSuggestedModels

  // MARK: - Properties
  /// Current models directory (uses DirectoryPickerService for user selection)
  var modelsDirectory: URL {
    return DirectoryPickerService.shared.effectiveModelsDirectory
  }

  private var activeDownloadTasks: [String: Task<Void, Never>] = [:]  // modelId -> Task
  private var downloadTokens: [String: UUID] = [:]  // modelId -> token to gate progress/state updates
  private var cancellables = Set<AnyCancellable>()

  // MARK: - Initialization
  override init() {
    super.init()

    loadAvailableModels()
  }

  // MARK: - Public Methods

  /// Load popular MLX models
  func loadAvailableModels() {
    // Simplified: rely solely on curated suggestions for reliability
    availableModels = Self.curatedSuggestedModels
    downloadStates = [:]
    for model in availableModels {
      downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
    }
    for sm in suggestedModels {
      downloadStates[sm.id] = sm.isDownloaded ? .completed : .notStarted
    }
    isLoadingModels = false
  }

  /// Resolve or construct an MLXModel by Hugging Face repo id (e.g., "mlx-community/Qwen3-1.7B-4bit").
  /// Returns nil if the repo id does not appear MLX-compatible.
  func resolveModel(byRepoId repoId: String) -> MLXModel? {
    let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // Validate MLX compatibility heuristically: org contains "mlx" or id contains "mlx"
    let lower = trimmed.lowercased()
    guard lower.contains("mlx") || lower.hasPrefix("mlx-community/") || lower.contains("-mlx")
    else {
      return nil
    }

    // If already present in available or suggested, return that instance
    if let existing = availableModels.first(where: { $0.id == trimmed }) {
      return existing
    }
    if let existing = suggestedModels.first(where: { $0.id == trimmed }) {
      return existing
    }

    // Construct a minimal MLXModel entry
    let name = Self.friendlyName(from: trimmed)
    let model = MLXModel(
      id: trimmed,
      name: name,
      description: "Imported from deeplink",
      size: 0,
      downloadURL: "https://huggingface.co/\(trimmed)",
      requiredFiles: Self.curatedRequiredFiles
    )
    // Add to available list for UI visibility
    availableModels.insert(model, at: 0)
    // Initialize download state entry
    downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
    return model
  }

  /// Kick off a download for a given Hugging Face repo id if resolvable to MLX.
  func downloadModel(withRepoId repoId: String) {
    guard let model = resolveModel(byRepoId: repoId) else { return }
    downloadModel(model)
  }

  /// Windowed: prefetch model detail (e.g., sizes) when an item becomes visible
  func prefetchModelDetailsIfNeeded(for model: MLXModel) {
    // Simplified: no-op to avoid network detail fetches
    _ = model.id
  }

  /// Download a model using Hugging Face Hub snapshot API
  func downloadModel(_ model: MLXModel) {
    // Define patterns here so we can also check for missing optional files (top-up)
    let patterns = [
      "config.json",
      "tokenizer.json",
      "tokenizer_config.json",
      "special_tokens_map.json",
      "generation_config.json",
      "chat_template.jinja",
      "*.safetensors",
    ]

    // If core assets are present but optional files from patterns are missing, we'll top-up.
    let needsTopUp = Self.isMissingExactPatternFiles(at: model.localDirectory, patterns: patterns)
    if model.isDownloaded && !needsTopUp {
      downloadStates[model.id] = .completed
      return
    }
    let state = downloadStates[model.id] ?? .notStarted
    switch state {
    case .downloading, .completed:
      return
    default:
      break
    }

    // Reset any previous task
    activeDownloadTasks[model.id]?.cancel()
    // Create a new token for this download session
    let token = UUID()
    downloadTokens[model.id] = token

    downloadStates[model.id] = .downloading(progress: 0.0)

    // Ensure local directory exists
    do {
      try FileManager.default.createDirectory(
        at: model.localDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      downloadStates[model.id] = .failed(
        error: "Failed to create directory: \(error.localizedDescription)")
      return
    }

    // Start snapshot download task
    let task = Task { [weak self] in
      guard let self = self else { return }
      let repo = Hub.Repo(id: model.id)

      do {
        // Download a snapshot to a temporary location managed by Hub
        let snapshotDirectory = try await Hub.snapshot(
          from: repo,
          matching: patterns,
          progressHandler: { progress in
            Task { @MainActor [weak self] in
              guard let self = self else { return }
              // Ignore progress updates from stale/canceled tasks
              guard self.downloadTokens[model.id] == token else { return }
              // Clamp to [0, 1]
              let fraction = max(0.0, min(1.0, progress.fractionCompleted))
              self.downloadStates[model.id] = .downloading(progress: fraction)
            }
          }
        )

        // Copy snapshot contents into our managed models directory
        try self.copyContents(of: snapshotDirectory, to: model.localDirectory)

        // Attempt to remove the Hub snapshot cache directory to free disk space
        // This directory is a cached snapshot; we've already copied the contents
        // into our app-managed models directory above, so it's safe to delete.
        do {
          try FileManager.default.removeItem(at: snapshotDirectory)
        } catch {
          // Non-fatal cleanup failure
          print(
            "Warning: failed to remove Hub snapshot cache at \(snapshotDirectory.path): \(error)")
        }

        // Verify
        let completed = model.isDownloaded
        await MainActor.run {
          // Only update state if this session is still current
          if self.downloadTokens[model.id] == token {
            self.downloadStates[model.id] =
              completed ? .completed : .failed(error: "Downloaded snapshot incomplete")
            self.downloadTokens[model.id] = nil
          }
        }
      } catch is CancellationError {
        await MainActor.run {
          if self.downloadTokens[model.id] == token {
            self.downloadStates[model.id] = .notStarted
            self.downloadTokens[model.id] = nil
          }
        }
      } catch {
        await MainActor.run {
          if self.downloadTokens[model.id] == token {
            self.downloadStates[model.id] = .failed(error: error.localizedDescription)
            self.downloadTokens[model.id] = nil
          }
        }
      }

      await MainActor.run {
        self.activeDownloadTasks[model.id] = nil
      }
    }

    activeDownloadTasks[model.id] = task
  }

  /// Cancel a download
  func cancelDownload(_ modelId: String) {
    // Cancel active snapshot task if any
    activeDownloadTasks[modelId]?.cancel()
    activeDownloadTasks[modelId] = nil
    downloadTokens[modelId] = nil
    downloadStates[modelId] = .notStarted
  }

  /// Delete a downloaded model
  func deleteModel(_ model: MLXModel) {
    // Cancel any active download task and reset state first
    activeDownloadTasks[model.id]?.cancel()
    activeDownloadTasks[model.id] = nil
    downloadTokens[model.id] = nil
    downloadStates[model.id] = .notStarted

    // Remove local files if present
    let fm = FileManager.default
    let path = model.localDirectory.path
    if fm.fileExists(atPath: path) {
      do {
        try fm.removeItem(atPath: path)
      } catch {
        // Log but keep state reset
        print("Failed to delete model: \(error)")
      }
    }
  }

  /// Get download progress for a model
  func downloadProgress(for modelId: String) -> Double {
    switch downloadStates[modelId] {
    case .downloading(let progress):
      return progress
    case .completed:
      return 1.0
    default:
      return 0.0
    }
  }

  /// Get total size of downloaded models
  var totalDownloadedSize: Int64 {
    // Build a unique list of models by id from both available and suggested
    let combined = (availableModels + suggestedModels)
    let uniqueById: [String: MLXModel] = combined.reduce(into: [:]) { dict, model in
      if dict[model.id] == nil { dict[model.id] = model }
    }
    // Sum actual on-disk sizes for models that are fully downloaded
    return uniqueById.values
      .filter { $0.isDownloaded }
      .reduce(Int64(0)) { partial, model in
        partial + (Self.directoryAllocatedSize(at: model.localDirectory) ?? 0)
      }
  }

  /// Effective state for a model combining in-memory state with on-disk detection
  func effectiveDownloadState(for model: MLXModel) -> DownloadState {
    if case .downloading = downloadStates[model.id] {
      return downloadStates[model.id] ?? .notStarted
    }
    return model.isDownloaded ? .completed : (downloadStates[model.id] ?? .notStarted)
  }

  var totalDownloadedSizeString: String {
    ByteCountFormatter.string(fromByteCount: totalDownloadedSize, countStyle: .file)
  }

  // MARK: - Private Methods

  private func copyContents(of sourceDirectory: URL, to destinationDirectory: URL) throws {
    let fileManager = FileManager.default

    // Ensure destination exists (do not wipe; we will merge/overwrite files)
    if !fileManager.fileExists(atPath: destinationDirectory.path) {
      try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    }

    // Copy/overwrite all items
    let items = try fileManager.contentsOfDirectory(atPath: sourceDirectory.path)
    for item in items {
      let src = sourceDirectory.appendingPathComponent(item)
      let dst = destinationDirectory.appendingPathComponent(item)

      var isDir: ObjCBool = false
      fileManager.fileExists(atPath: src.path, isDirectory: &isDir)

      if isDir.boolValue {
        // Ensure directory exists at destination, then recurse
        if !fileManager.fileExists(atPath: dst.path) {
          try fileManager.createDirectory(at: dst, withIntermediateDirectories: true)
        }
        try copyContents(of: src, to: dst)
      } else {
        // If a file exists at destination, remove it before copying to allow overwrite
        if fileManager.fileExists(atPath: dst.path) {
          try fileManager.removeItem(at: dst)
        }
        try fileManager.copyItem(at: src, to: dst)
      }
    }
  }

  /// Check for any missing exact files from the provided patterns.
  /// Only exact filenames are considered (globs like *.safetensors are ignored here).
  private static func isMissingExactPatternFiles(at directory: URL, patterns: [String]) -> Bool {
    let fileManager = FileManager.default
    let exactNames = patterns.filter { !$0.contains("*") && !$0.contains("?") }
    for name in exactNames {
      let path = directory.appendingPathComponent(name).path
      if !fileManager.fileExists(atPath: path) {
        return true
      }
    }
    return false
  }

  /// Compute allocated size on disk for a directory (recursively)
  /// Falls back to logical file size when allocated size is unavailable
  private static func directoryAllocatedSize(at url: URL) -> Int64? {
    let fileManager = FileManager.default
    var total: Int64 = 0
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [
          .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey,
        ], options: [], errorHandler: nil)
    else {
      return nil
    }
    for case let fileURL as URL in enumerator {
      do {
        let resourceValues = try fileURL.resourceValues(forKeys: [
          .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        ])
        guard resourceValues.isRegularFile == true else { continue }
        if let allocated = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize
        {
          total += Int64(allocated)
        } else if let size = resourceValues.fileSize {
          total += Int64(size)
        }
      } catch {
        continue
      }
    }
    return total
  }
}

// MARK: - Dynamic model discovery (Hugging Face)

extension ModelManager {
  /// Fully curated models with descriptions we control. Order matters.
  fileprivate static let curatedSuggestedModels: [MLXModel] = [
    // GPT-OSS - currently does not work.
    // MLXModel(
    //   id: "lmstudio-community/gpt-oss-20b-MLX-8bit",
    //   name: friendlyName(from: "lmstudio-community/gpt-oss-20b-MLX-8bit"),
    //   description: "GPT-OSS 20B (8-bit MLX) by OpenAI. High-quality general model in MLX format.",
    //   size: 0,
    //   downloadURL: "https://huggingface.co/lmstudio-community/gpt-oss-20b-MLX-8bit",
    //   requiredFiles: curatedRequiredFiles
    // ),

    // MLXModel(
    //   id: "lmstudio-community/gpt-oss-120b-MLX-8bit",
    //   name: friendlyName(from: "lmstudio-community/gpt-oss-120b-MLX-8bit"),
    //   description:
    //     "GPT-OSS 120B (MLX 8-bit). ~117B parameters; premium general assistant with strong reasoning and coding. Optimized for Apple Silicon via MLX; requires 64GB+ unified memory; very large download.",
    //   size: 0,
    //   downloadURL: "https://huggingface.co/lmstudio-community/gpt-oss-120b-MLX-8bit",
    //   requiredFiles: curatedRequiredFiles
    // ),

    // Qwen3 Coder — top pick for coding
    MLXModel(
      id: "lmstudio-community/qwen3-coder-30b-a3b-instruct-mlx-4bit",
      name: friendlyName(from: "lmstudio-community/qwen3-coder-30b-a3b-instruct-mlx-4bit"),
      description:
        "Qwen3 Coder 30B A3B Instruct (MLX 4-bit). Exceptional coding model; very large download and memory usage.",
      size: 0,
      downloadURL:
        "https://huggingface.co/lmstudio-community/qwen3-coder-30b-a3b-instruct-mlx-4bit",
      requiredFiles: curatedRequiredFiles
    ),

    // Qwen family — 3 sizes
    MLXModel(
      id: "mlx-community/Qwen3-1.7B-4bit",
      name: friendlyName(from: "mlx-community/Qwen3-1.7B-4bit"),
      description:
        "Qwen3 1.7B (4-bit). Tiny and fast. Great for quick tests, code helpers, and lightweight tasks.",
      size: 0,
      downloadURL: "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit",
      requiredFiles: curatedRequiredFiles
    ),
    MLXModel(
      id: "mlx-community/Qwen3-4B-4bit",
      name: friendlyName(from: "mlx-community/Qwen3-4B-4bit"),
      description: "Qwen3 4B (4-bit). Modern small model with strong instruction following.",
      size: 0,
      downloadURL: "https://huggingface.co/mlx-community/Qwen3-4B-4bit",
      requiredFiles: curatedRequiredFiles
    ),
    MLXModel(
      id: "mlx-community/Qwen3-235B-A22B-4bit",
      name: friendlyName(from: "mlx-community/Qwen3-235B-A22B-4bit"),
      description: "Qwen3 235B MoE A22B (4-bit). High quality; heavy memory requirements.",
      size: 0,
      downloadURL: "https://huggingface.co/mlx-community/Qwen3-235B-A22B-4bit",
      requiredFiles: curatedRequiredFiles
    ),

    // New additions — Gemma 3, Qwen3, GPT-OSS
    MLXModel(
      id: "lmstudio-community/gemma-3-270m-it-MLX-8bit",
      name: friendlyName(from: "lmstudio-community/gemma-3-270m-it-MLX-8bit"),
      description: "Gemma 3 270M IT (8-bit MLX). Extremely small and fast for experimentation.",
      size: 0,
      downloadURL: "https://huggingface.co/lmstudio-community/gemma-3-270m-it-MLX-8bit",
      requiredFiles: curatedRequiredFiles
    ),

    // Reasoning-focused choices
    MLXModel(
      id: "mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit",
      name: friendlyName(from: "mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit"),
      description:
        "Reasoning-focused distilled model. Good for structured steps and chain-of-thought style prompts.",
      size: 0,
      downloadURL: "https://huggingface.co/mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit",
      requiredFiles: curatedRequiredFiles
    ),

    MLXModel(
      id: "mlx-community/Qwen3-Next-80B-A3B-Thinking-4bit",
      name: friendlyName(from: "mlx-community/Qwen3-Next-80B-A3B-Thinking-4bit"),
      description:
        "Qwen3-Next 80B A3B Thinking (4-bit). Reasoning-focused assistant; heavy memory requirements.",
      size: 0,
      downloadURL: "https://huggingface.co/mlx-community/Qwen3-Next-80B-A3B-Thinking-4bit",
      requiredFiles: curatedRequiredFiles
    ),

    // Popular general models (extra variety)
    MLXModel(
      id: "mlx-community/Mistral-7B-Instruct-4bit",
      name: friendlyName(from: "mlx-community/Mistral-7B-Instruct-4bit"),
      description: "Popular 7B instruct model. Good general assistant with efficient runtime.",
      size: 0,
      downloadURL: "https://huggingface.co/mlx-community/Mistral-7B-Instruct-4bit",
      requiredFiles: curatedRequiredFiles
    ),
    MLXModel(
      id: "mlx-community/Phi-3-mini-4k-instruct-4bit",
      name: friendlyName(from: "mlx-community/Phi-3-mini-4k-instruct-4bit"),
      description: "Very small and speedy. Great for lightweight tasks and constrained devices.",
      size: 0,
      downloadURL: "https://huggingface.co/mlx-community/Phi-3-mini-4k-instruct-4bit",
      requiredFiles: curatedRequiredFiles
    ),

    // Kimi
    MLXModel(
      id: "mlx-community/Kimi-VL-A3B-Thinking-4bit",
      name: friendlyName(from: "mlx-community/Kimi-VL-A3B-Thinking-4bit"),
      description:
        "Kimi VL A3B thinking variant (4-bit). Versatile assistant with strong reasoning.",
      size: 0,
      downloadURL: "https://huggingface.co/mlx-community/Kimi-VL-A3B-Thinking-4bit",
      requiredFiles: curatedRequiredFiles
    ),

    // Llama family
    MLXModel(
      id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
      name: friendlyName(from: "mlx-community/Llama-3.2-1B-Instruct-4bit"),
      description: "Tiny and fast. Great for quick tests, code helpers, and lightweight tasks.",
      size: 0,
      downloadURL: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit",
      requiredFiles: curatedRequiredFiles
    ),
    MLXModel(
      id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
      name: friendlyName(from: "mlx-community/Llama-3.2-3B-Instruct-4bit"),
      description:
        "Great quality/speed balance. Strong general assistant at a small memory footprint.",
      size: 0,
      downloadURL: "https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit",
      requiredFiles: curatedRequiredFiles
    ),
  ]

  fileprivate static let curatedRequiredFiles: [String] = [
    "model.safetensors",
    "config.json",
    "tokenizer_config.json",
    "tokenizer.json",
    "special_tokens_map.json",
  ]
  fileprivate static func friendlyName(from repoId: String) -> String {
    // Take the last path component and title-case-ish
    let last = repoId.split(separator: "/").last.map(String.init) ?? repoId
    let spaced = last.replacingOccurrences(of: "-", with: " ")
    // Keep common tokens uppercase
    return
      spaced
      .replacingOccurrences(of: "llama", with: "Llama", options: .caseInsensitive)
      .replacingOccurrences(of: "qwen", with: "Qwen", options: .caseInsensitive)
      .replacingOccurrences(of: "gemma", with: "Gemma", options: .caseInsensitive)
      .replacingOccurrences(of: "deepseek", with: "DeepSeek", options: .caseInsensitive)
  }
}
