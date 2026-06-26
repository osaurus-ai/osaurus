//
//  MLXModel.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import SwiftUI

/// Represents an MLX-compatible LLM that can be downloaded and used
struct MLXModel: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let downloadURL: String

    /// Whether this model should appear at the top of the suggested models list
    let isTopSuggestion: Bool

    /// Approximate download size in bytes (optional, for display purposes)
    let downloadSizeBytes: Int64?

    /// The model_type from config.json (e.g. "gemma4", "qwen3_5_moe").
    /// Set on curated entries to enable pre-download VLM detection via VLMTypeRegistry.
    let modelType: String?

    /// HF Hub `lastModified` timestamp for this repo, when known.
    /// Used to sort the Recommended tab so newer releases appear near the top.
    let releasedAt: Date?

    /// HF Hub `downloads` count for this repo, when known. Drives the
    /// "Sort by Downloads" option so the most popular models surface first.
    let downloads: Int?

    /// Editorial category for the colored use-case pill (onboarding +
    /// main download grid). Set on curated entries; `nil` on HF
    /// auto-discovered ones, which suppresses the pill.
    let useCase: ModelUseCase?

    // When non-nil, pins the model to a specific directory (used by tests).
    // When nil, `localDirectory` resolves dynamically so that user-selected
    // storage path changes are always respected.
    private let rootDirectory: URL?

    /// Absolute path to an externally-discovered model bundle (Hugging Face
    /// cache snapshot, LM Studio, etc.). When set, `localDirectory` returns
    /// it directly instead of reducing the id under the models directory —
    /// external layouts (e.g. `models--org--repo/snapshots/<rev>/`) don't
    /// match the `<root>/<org>/<repo>` shape. The runtime path resolvers
    /// also consult `ExternalModelLocator` for these ids.
    let bundleDirectory: URL?

    /// Human-readable provenance for externally-discovered models
    /// (e.g. "Hugging Face cache", "LM Studio"). `nil` for normal catalog
    /// and Osaurus-downloaded entries.
    let externalSource: String?

    init(
        id: String,
        name: String,
        description: String,
        downloadURL: String,
        isTopSuggestion: Bool = false,
        downloadSizeBytes: Int64? = nil,
        modelType: String? = nil,
        releasedAt: Date? = nil,
        downloads: Int? = nil,
        useCase: ModelUseCase? = nil,
        rootDirectory: URL? = nil,
        bundleDirectory: URL? = nil,
        externalSource: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.downloadURL = downloadURL
        self.isTopSuggestion = isTopSuggestion
        self.downloadSizeBytes = downloadSizeBytes
        self.modelType = modelType
        self.releasedAt = releasedAt
        self.downloads = downloads
        self.useCase = useCase
        self.rootDirectory = rootDirectory
        self.bundleDirectory = bundleDirectory
        self.externalSource = externalSource
    }

    /// Returns a copy with `downloadSizeBytes` overridden. Used to fold in
    /// the per-repo `usedStorage` value HF returns from
    /// `/api/models/<id>?expand[]=usedStorage`, so the size chip renders
    /// for repo ids whose names don't carry a parseable parameter token.
    func withDownloadSize(_ bytes: Int64?) -> MLXModel {
        guard let bytes else { return self }
        return MLXModel(
            id: id,
            name: name,
            description: description,
            downloadURL: downloadURL,
            isTopSuggestion: isTopSuggestion,
            downloadSizeBytes: bytes,
            modelType: modelType,
            releasedAt: releasedAt,
            downloads: downloads,
            useCase: useCase,
            rootDirectory: rootDirectory,
            bundleDirectory: bundleDirectory,
            externalSource: externalSource
        )
    }

    /// Returns a copy with the HF Hub `downloads` count populated. Used to
    /// fold in stats from the OsaurusAI org listing onto curated entries
    /// without rewriting their hand-tuned descriptions / Top Pick flags
    func withDownloads(_ count: Int?) -> MLXModel {
        MLXModel(
            id: id,
            name: name,
            description: description,
            downloadURL: downloadURL,
            isTopSuggestion: isTopSuggestion,
            downloadSizeBytes: downloadSizeBytes,
            modelType: modelType,
            releasedAt: releasedAt,
            downloads: count,
            useCase: useCase,
            rootDirectory: rootDirectory,
            bundleDirectory: bundleDirectory,
            externalSource: externalSource
        )
    }

    /// A jargon-light version of `name` for first-run surfaces (the onboarding
    /// model chooser). The HF-derived `name` carries technical tokens —
    /// instruction-tuned (`it`), quant/precision (`MXFP8`, `MXFP4`, `qat`,
    /// `4bit`, `bf16`, `JANGTQ`, `JANG_4M`), MoE active-params (`A1B`/`A4B`),
    /// and speculative-decode (`MTP`) — which make the title read like a
    /// filename. Stripping them yields a product-style title ("Gemma 4 12B").
    /// The dropped precision is re-surfaced as a separate chip in the chooser so
    /// same-size variants stay distinguishable. Falls back to `name` when
    /// stripping would leave nothing.
    var simplifiedName: String {
        func isJargon(_ token: String) -> Bool {
            let t = token.lowercased()
            if t == "it" || t == "qat" || t == "mtp" { return true }
            // Precision / quantization tokens.
            if t.range(of: #"^mxfp\d+$"#, options: .regularExpression) != nil { return true }
            if t.range(of: #"^\d+-?bit$"#, options: .regularExpression) != nil { return true }
            if t == "fp16" || t == "bf16" || t == "fp32" { return true }
            if t.range(of: #"^jangtq\d*$"#, options: .regularExpression) != nil { return true }
            if t.range(of: #"^jang_?\d+[a-z]?$"#, options: .regularExpression) != nil { return true }
            // MoE active-parameter token (e.g. "A1B", "A4B", "A3B").
            if t.range(of: #"^a\d+b$"#, options: .regularExpression) != nil { return true }
            return false
        }
        let kept = name.split(separator: " ").map(String.init).filter { !isJargon($0) }
        let result = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? name : result
    }

    /// Formatted download size string (e.g., "3.9 GB").
    ///
    /// Uses the value-type `ByteCountFormatStyle` rather than allocating a
    /// `ByteCountFormatter` per call: the size string is read from SwiftUI body
    /// getters once per model row, and the format style is cheap and
    /// concurrency-safe.
    var formattedDownloadSize: String? {
        guard let bytes = totalSizeEstimateBytes else { return nil }
        return bytes.formatted(.byteCount(style: .file, allowedUnits: [.gb, .mb]))
    }

    /// Abbreviated HF Hub download (popularity) count for the card footer
    /// (e.g. 1_234_567 -> "1.2M", 12_345 -> "12.3K", 842 -> "842"). Nil when
    /// the count is unknown or zero so the footer can omit it.
    var formattedDownloads: String? {
        guard let downloads, downloads > 0 else { return nil }
        func abbreviate(_ value: Double, _ suffix: String) -> String {
            let rendered = String(format: "%.1f", value)
            let trimmed = rendered.hasSuffix(".0") ? String(rendered.dropLast(2)) : rendered
            return trimmed + suffix
        }
        switch downloads {
        case 1_000_000...:
            return abbreviate(Double(downloads) / 1_000_000, "M")
        case 1_000...:
            return abbreviate(Double(downloads) / 1_000, "K")
        default:
            return "\(downloads)"
        }
    }

    /// Best estimate of the total model size in bytes.
    /// Uses explicit downloadSizeBytes if available, otherwise estimates based on parameters/quantization.
    var totalSizeEstimateBytes: Int64? {
        if let bytes = downloadSizeBytes { return bytes }

        // Estimate based on params and quantization (without the runtime overhead multiplier)
        if let params = parameterCountBillions {
            return Int64(params * bytesPerParameter * 1024 * 1024 * 1024)
        }

        return nil
    }

    /// Local directory where this model should be stored.
    /// Resolves against the current effective models directory unless an
    /// explicit `rootDirectory` was provided at init (e.g. in tests).
    var localDirectory: URL {
        // Externally-discovered bundles live at an arbitrary absolute path
        // that doesn't follow the `<root>/<org>/<repo>` layout, so return it
        // verbatim.
        if let bundleDirectory { return bundleDirectory }
        let baseDir = rootDirectory ?? DirectoryPickerService.effectiveModelsDirectory()
        let components = id.split(separator: "/").map(String.init)
        return components.reduce(baseDir) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    /// Check if model is downloaded
    /// A model is considered complete if:
    /// - Core config exists: config.json
    /// - Tokenizer assets exist in ANY of the supported variants:
    ///   - tokenizer.json (HF consolidated JSON)
    ///   - BPE: merges.txt + (vocab.json OR vocab.txt)
    ///   - SentencePiece: tokenizer.model OR spiece.model
    /// - At least one *.safetensors file exists (weights)
    ///
    /// Production callers (rootDirectory == nil) hit a process-wide cache
    /// keyed by model id. The cache is invalidated whenever a download
    /// completes or a model is deleted (both already post
    /// `.localModelsChanged`). Tests with an explicit `rootDirectory`
    /// always bypass the cache so the on-disk fixture is consulted.
    /// Without this cache, every SwiftUI body that asked
    /// `filter { $0.isDownloaded }` over the model list paid for 1 + N
    /// `FileManager.fileExists` calls plus an enumerator open per model
    /// — the dominant cost of the Models tab badge and grid recomputes.
    var isDownloaded: Bool {
        // Bypass the id-keyed cache for pinned (`rootDirectory`) and
        // external (`bundleDirectory`) bundles so a same-id Osaurus entry
        // can't shadow their on-disk state.
        let usesSharedCache = rootDirectory == nil && bundleDirectory == nil
        if usesSharedCache, let cached = MLXModelDownloadCache.value(for: id) {
            return cached
        }
        let value = computeIsDownloadedFromDisk()
        if usesSharedCache {
            MLXModelDownloadCache.set(value, for: id)
        }
        return value
    }

    /// Direct disk check used by `isDownloaded`. Kept exposed so callers
    /// that need a freshness guarantee (e.g. immediately after a manual
    /// file mutation) can bypass the cache.
    func computeIsDownloadedFromDisk() -> Bool {
        let directory = localDirectory

        // Enumerate the bundle directory once and test membership against the
        // resulting set, rather than issuing a `fileExists` probe per
        // candidate filename. The previous approach could fire well over 250
        // `lstat` syscalls on a cache miss — the sharded-weights check alone
        // probed shard counts 2...256 — and `isDownloaded` is read straight
        // from SwiftUI body getters, enough to trip the main-thread hang
        // watchdog on a cold or slow disk.
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else {
            return false
        }
        let entries = Set(names)

        guard entries.contains("config.json") else { return false }

        let hasTokenizerJSON = entries.contains("tokenizer.json")
        let hasBPE =
            entries.contains("merges.txt")
            && (entries.contains("vocab.json") || entries.contains("vocab.txt"))
        let hasSentencePiece =
            entries.contains("tokenizer.model") || entries.contains("spiece.model")
        let hasTokenizerAssets = hasTokenizerJSON || hasBPE || hasSentencePiece
        guard hasTokenizerAssets else { return false }

        let directWeightSentinels: Set<String> = [
            "model.safetensors",
            "weights.safetensors",
            "model-00001-of-00001.safetensors",
            "weights-00001-of-00001.safetensors",
        ]
        if !entries.isDisjoint(with: directWeightSentinels) {
            return true
        }
        if entries.contains("model.safetensors.index.json")
            || entries.contains("pytorch_model.safetensors.index.json")
        {
            return true
        }
        // Any first shard of a multi-file safetensors export
        // (model-00001-of-NNNNN.safetensors) is sufficient proof of weights.
        return entries.contains { name in
            name.hasPrefix("model-00001-of-") && name.hasSuffix(".safetensors")
        }
    }

    /// Approximate download timestamp based on directory creation/modification time
    /// Newer downloads should have more recent dates.
    ///
    /// Hits the same id-keyed process cache as `isDownloaded` (invalidated on
    /// `.localModelsChanged`). Read straight from SwiftUI body getters, the
    /// underlying `resourceValues` stat is enough to trip the main-thread hang
    /// watchdog on a cold or slow disk when the Models grid renders many rows.
    var downloadedAt: Date? {
        // Bypass the shared cache for pinned (`rootDirectory`) and external
        // (`bundleDirectory`) bundles so a same-id Osaurus entry can't shadow
        // their on-disk timestamp — mirrors `isDownloaded`.
        let usesSharedCache = rootDirectory == nil && bundleDirectory == nil
        if usesSharedCache {
            let cached = MLXModelDownloadCache.cachedDate(for: id)
            if cached.hit { return cached.value }
        }
        let value = computeDownloadedAtFromDisk()
        if usesSharedCache {
            MLXModelDownloadCache.setDate(value, for: id)
        }
        return value
    }

    /// Direct disk stat used by `downloadedAt`. Exposed so callers needing a
    /// freshness guarantee can bypass the cache.
    func computeDownloadedAtFromDisk() -> Date? {
        let directory = localDirectory
        let values = try? directory.resourceValues(forKeys: [
            .creationDateKey, .contentModificationDateKey,
        ])
        return values?.creationDate ?? values?.contentModificationDate
    }

    // MARK: - Metadata Extraction

    var parameterCount: String? { ModelMetadataParser.parameterCount(from: id) }
    var quantization: String? { ModelMetadataParser.quantization(from: id) }

    /// Whether this model supports vision/multimodal input.
    /// For downloaded models, checks vision_config in config.json.
    /// For undownloaded models, checks modelType against VLMTypeRegistry.
    var isVLM: Bool {
        // Memoize: the `isDownloaded` branch below reads `config.json` off
        // disk, which trips the main-thread hang watchdog when the grid
        // evaluates this per row. Bypass the shared cache for pinned
        // (`rootDirectory`) and external (`bundleDirectory`) bundles, matching
        // `isDownloaded`, so a same-id Osaurus entry can't shadow their state.
        let usesSharedCache = rootDirectory == nil && bundleDirectory == nil
        if usesSharedCache, let cached = MLXModelDownloadCache.cachedVLM(for: id) {
            return cached
        }
        let value = computeIsVLM()
        if usesSharedCache {
            MLXModelDownloadCache.setVLM(value, for: id)
        }
        return value
    }

    /// Direct (uncached) VLM detection used by `isVLM`.
    func computeIsVLM() -> Bool {
        if ModelFamilyNames.isStepFamily(id) || ModelFamilyNames.isStepFamily(name) {
            // Step 3.7 bundles can carry upstream vision metadata, but this
            // Osaurus/vMLX path is the Step text runtime. Keep picker
            // capability detection text-only until Step VLM is wired and
            // proven, and avoid blocking picker rebuilds on large external
            // bundle metadata reads.
            return false
        }
        if (ModelFamilyNames.isNemotronThinkingFamily(id)
            || ModelFamilyNames.isNemotronThinkingFamily(name))
            && !(ModelFamilyNames.isNemotronOmniFamily(id)
                || ModelFamilyNames.isNemotronOmniFamily(name))
        {
            return false
        }
        if ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(id)
            || ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(name)
        {
            return false
        }
        if isDownloaded { return VLMDetection.isVLM(at: localDirectory) }
        if let mt = modelType { return VLMDetection.isVLM(modelType: mt) }
        return VLMDetection.isVLM(modelId: id)
    }

    /// Whether the on-disk bundle is in MLX format and therefore loadable by
    /// the local engine (vmlx). Catalog entries that aren't on disk yet return
    /// `true` — they're curated MLX builds and there's nothing to inspect; the
    /// check only matters for downloaded/external bundles co-mingled in a
    /// shared model store. Verdict is cached per directory by
    /// `ModelFormatDetection` (dropped on `.localModelsChanged`), so reading it
    /// per row stays cheap.
    var isMLXFormat: Bool {
        guard isDownloaded else { return true }
        // First-party OsaurusAI bundles are always MLX by construction. Trust
        // provenance unconditionally so a pipeline that omits the `format: mlx`
        // tag (e.g. an unquantized first-party build) can never be greyed out.
        if id.lowercased().hasPrefix("osaurusai/") { return true }
        return ModelFormatDetection.isMLXFormat(at: localDirectory)
    }

    /// Whether this bundle is an embedding/encoder-only model (BERT family,
    /// model2vec, etc.) that cannot generate chat completions. Detected from
    /// the on-disk config.json; bundles that aren't on disk return false.
    /// Used to keep embedding repos imported from the HF cache / LM Studio
    /// out of chat surfaces while leaving them available to `/v1/embeddings`.
    var isEmbedding: Bool {
        EmbeddingDetection.isEmbedding(at: localDirectory)
    }

    /// Extracts the model family from the name/id (e.g., "Llama", "Qwen", "Gemma", "Phi")
    var family: String {
        let name = self.name.lowercased()

        // 1. Check for common families first (strong matches)
        let strongMatches = [
            "llama": "Llama",
            "qwen": "Qwen",
            "gemma": "Gemma",
            "phi": "Phi",
            "mistral": "Mistral",
            "mixtral": "Mixtral",
            "deepseek": "DeepSeek",
            "nemotron": "Nemotron",
            "command-r": "Command-R",
            "grok": "Grok",
            "yi": "Yi",
            "falcon": "Falcon",
            "internlm": "InternLM",
            "stablelm": "StableLM",
            "smollm": "SmolLM",
            "hermes": "Hermes",
            "liquid": "Liquid",
            "lfm": "Liquid",
            "starcoder": "StarCoder",
            "granite": "Granite",
            "exat": "Exat",
            "opcoder": "OpCoder",
            "opencoder": "OpenCoder",
        ]

        for (key, value) in strongMatches {
            if name.contains(key) { return value }
        }

        // 2. Fallback heuristic: clean up the name and take the first part
        // Remove common vendor prefixes
        var cleaned = self.name
        let prefixes = [
            "Meta-", "Google-", "Mistral-", "MistralAI-", "Microsoft-", "NousResearch-", "Qwen-", "DeepSeek-",
        ]
        for prefix in prefixes {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                break
            }
        }

        // Take first semantic part (before dash or dot)
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: "-. "))
        if let first = parts.first, !first.isEmpty {
            // Filter out junk or purely numeric parts
            if first.rangeOfCharacter(from: .letters) != nil {
                return first.capitalized
            }
        }

        return "Other"
    }

    // MARK: - Memory Estimation & Hardware Compatibility

    private static let bytesPerGB: Double = 1024 * 1024 * 1024
    /// Runtime headroom over raw weight size — covers KV cache, activations,
    /// and Metal/runtime buffers. Bumped from 1.2 → 1.25 so the onboarding
    /// default leaves more slack and stops landing users on a model that
    /// "fits" the estimate but chokes once a long-context KV cache grows.
    private static let overheadMultiplier: Double = 1.25

    /// Numeric parameter count in billions (e.g. "7B" -> 7.0, "270M" -> 0.27)
    var parameterCountBillions: Double? {
        ModelMetadataParser.parameterCountBillions(from: id)
    }

    /// Bytes per parameter based on the quantization extracted from the model name.
    private var bytesPerParameter: Double {
        guard let quant = quantization?.lowercased() else { return 0.5 }

        // MXFP / FP8 precision formats encode the bit-width in the suffix and
        // don't carry an "N-bit" substring. MXFP8 is an 8-bit-class format
        // (~1.0 byte/param); the old `8-bit` substring check missed `mxfp8`
        // and under-estimated every MXFP8 model at ~half its real footprint.
        if quant.contains("mxfp8") || quant.contains("fp8") { return 1.0 }
        if quant.contains("mxfp4") { return 0.5 }

        let bitWidths: [(String, Double)] = [
            ("2-bit", 0.25), ("3-bit", 0.375), ("4-bit", 0.5),
            ("5-bit", 0.625), ("6-bit", 0.75), ("8-bit", 1.0),
        ]
        for (label, bytes) in bitWidths {
            if quant.contains(label) { return bytes }
        }

        switch quant {
        case "fp16", "bf16": return 2.0
        case "fp32": return 4.0
        default: return 0.5
        }
    }

    /// Estimated memory required to run this model (in GB), including overhead
    /// for KV cache, activations, and runtime buffers.
    ///
    /// Prefers the **measured** on-disk size (folded in from `ModelSizeCache`
    /// via `withDownloadSize`) when known — weights dominate the footprint, so
    /// the real byte count plus the headroom multiplier is more honest than
    /// the `params × bytesPerParameter` constant heuristic. The heuristic is
    /// only the fallback for entries we haven't sized yet.
    var estimatedMemoryGB: Double? {
        if let dlBytes = downloadSizeBytes, dlBytes > 0 {
            return Double(dlBytes) * Self.overheadMultiplier / Self.bytesPerGB
        }
        if let params = parameterCountBillions {
            return params * bytesPerParameter * 1e9 * Self.overheadMultiplier / Self.bytesPerGB
        }
        return nil
    }

    // MARK: - Onboarding auto-default classification
    //
    // The onboarding default (`ConfigureAIState.recommendedLocalPick`) draws
    // only from the dense Gemma 4 QAT line, with the E-series 8-bit builds as
    // a gated small-tier fallback. These flags name those sets so the policy
    // lives next to the metadata it reads, not buried in the view.

    /// True when the id is a Gemma 4 E-series edge build (`E2B`/`E4B`/...).
    private var isGemma4ESeries: Bool {
        id.range(of: #"gemma-4-e\d"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// True when the id carries an MoE active-param token (e.g. `-A4B`),
    /// marking a mixture-of-experts build rather than a dense one.
    private var hasMoEActiveParamToken: Bool {
        id.range(of: #"-a\d+(\.\d+)?b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// True for the **dense** Gemma 4 QAT builds (12B/31B `qat-MXFP4`) that
    /// form the onboarding auto-default spine. Excludes the E-series (gated on
    /// the 8-bit-vs-QAT-4bit retention A/B) and the 26B-A4B QAT MoE (its
    /// footprint is the 36%-bounce risk) — both stay selectable Top Picks but
    /// are never auto-selected.
    var isDenseGemmaQATAutoDefault: Bool {
        let lower = id.lowercased()
        guard lower.contains("gemma-4"), lower.contains("qat") else { return false }
        if isGemma4ESeries { return false }
        if hasMoEActiveParamToken { return false }
        return true
    }

    /// True for the Gemma 4 E-series 8-bit retention builds
    /// (`gemma-4-E2B/E4B-it-8bit`) — the gated small-tier auto-default until
    /// the QAT-4bit-vs-8bit bounce A/B clears.
    var isGemmaESeries8bitAutoDefault: Bool {
        guard isGemma4ESeries else { return false }
        let lower = id.lowercased()
        return lower.contains("8bit") || lower.contains("8-bit")
    }

    /// Formatted estimated memory string (e.g. "~3.5 GB")
    var formattedEstimatedMemory: String? {
        guard let gb = estimatedMemoryGB else { return nil }
        return gb < 1.0
            ? String(format: "~%.0f MB", gb * 1024)
            : String(format: "~%.1f GB", gb)
    }

    /// Assess whether this model can run on the given hardware.
    func compatibility(totalMemoryGB: Double) -> ModelCompatibility {
        guard let required = estimatedMemoryGB, totalMemoryGB > 0 else { return .unknown }
        let ratio = required / totalMemoryGB
        if ratio < 0.75 { return .compatible }
        if ratio < 0.95 { return .tight }
        return .tooLarge
    }

    /// Compact "MMM yyyy" form of `releasedAt`, e.g. "Apr 2026". Locale
    /// is pinned to `en_US_POSIX` so the format stays stable; the
    /// localized prefix ("Released …") lives at the call site.
    var formattedReleaseMonth: String? {
        guard let date = releasedAt else { return nil }
        return MLXModel.releaseMonthFormatter.string(from: date)
    }

    private static let releaseMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM yyyy"
        return f
    }()
}

/// Hardware compatibility assessment for a model.
enum ModelCompatibility {
    case compatible
    case tight
    case tooLarge
    case unknown
}

// MARK: - Use Case

/// Editorial category for the colored "use case" pill so users can scan
/// the curated catalog by intent rather than decoding model ids. Set on
/// curated entries only; HF auto-discovered entries leave it `nil`.
enum ModelUseCase: String, Codable, CaseIterable {
    /// Daily chat / writing — the everyday default.
    case general
    /// Multimodal (images, video, audio) — the VLM family.
    case vision
    /// Chain-of-thought / agentic — Nemotron-3 et al.
    case reasoning
    /// Agentic-coding tuned (Laguna).
    case coding
    /// Sub-~6 GB — runs on base-RAM Macs.
    case smallest
    /// Premium tier — top of the catalog, needs 64 GB+ unified memory.
    case bestQuality

    /// Localized label rendered inside the badge chip.
    var displayName: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .vision: return "Vision"
        case .reasoning: return "Reasoning"
        case .coding: return "Coding"
        case .smallest: return "Runs Anywhere"
        case .bestQuality: return "Best Quality"
        }
    }

    /// SF Symbol used as the leading icon on the badge.
    var iconName: String {
        switch self {
        case .general: return "bubble.left.and.bubble.right.fill"
        case .vision: return "eye.fill"
        case .reasoning: return "brain.head.profile"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .smallest: return "leaf.fill"
        case .bestQuality: return "sparkles"
        }
    }

    /// Tint for the badge chrome. Vision reuses the existing VLM purple
    /// so the visual language stays consistent with
    /// `ModelRowView.modelTypeBadge`.
    var tintColor: Color {
        switch self {
        case .general: return Color(hex: "3B82F6")  // blue
        case .vision: return Color(hex: "A855F7")  // purple (matches VLM pill)
        case .reasoning: return Color(hex: "F97316")  // orange
        case .coding: return Color(hex: "22C55E")  // green
        case .smallest: return Color(hex: "14B8A6")  // teal
        case .bestQuality: return Color(hex: "EAB308")  // gold
        }
    }
}

/// Download state for tracking progress
enum DownloadState: Equatable {
    case notStarted
    case downloading(progress: Double)
    /// Paused mid-download. The orchestration task has been cancelled, but
    /// the partial bytes on disk are kept and (when supported by the server)
    /// `URLSession`-level resume data is held in memory by the download
    /// service so that `resume(_:)` can pick up from the same byte offset.
    case paused(progress: Double)
    case completed
    case failed(error: String)
}
