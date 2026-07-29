//
//  AppleScriptModelCatalog.swift
//  OsaurusCore — AppleScript Computer Use
//
//  The curated set of on-device AppleScript models plus the per-agent
//  execution-mode policy that gates how a generated script runs.
//
//  AppleScript models are ordinary MLX bundles, so they download, install, and
//  load through the SAME stack as every other local LLM (`ModelManager` +
//  `ModelDownloadService`, stored under the standard models directory, loaded
//  by repo id). This catalog only names the curated repos so the Computer Use
//  → Models tab can present them and the `applescript` subagent can resolve an
//  installed one — there is no separate download/runtime path.
//

import Foundation

/// How a generated AppleScript is gated before it runs. Per-agent (and a
/// global default for the Default / main chat agent). `confirmEach` is the
/// safe default: every state-CHANGING script is shown in the live chat feed
/// for explicit approval before it executes (classified read-only scripts
/// auto-run — they change nothing). `autoRunWithWarning` runs each mutating
/// script automatically but emits a prominent warning event (showing the
/// script) so the user can still see exactly what ran.
public enum AppleScriptExecutionMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Pause and show each state-changing AppleScript for explicit approval
    /// before it runs (default, safest). Read-only scripts auto-run.
    case confirmEach
    /// Run automatically, emitting a prominent warning (showing the script)
    /// before each mutating run.
    case autoRunWithWarning

    /// The conservative default applied when nothing is configured.
    public static var `default`: AppleScriptExecutionMode { .confirmEach }

    /// Tolerant decode of a stored raw value so a malformed/legacy string
    /// resolves to the safe default rather than refusing the whole config.
    public init(storedValue raw: String?) {
        self = raw.flatMap(AppleScriptExecutionMode.init(rawValue:)) ?? .default
    }

    /// Short label for pickers.
    public var displayName: String {
        switch self {
        case .confirmEach: return L("Confirm each script")
        case .autoRunWithWarning: return L("Auto-run with warning")
        }
    }

    /// One-line caption describing the safety trade-off.
    public var caption: String {
        switch self {
        case .confirmEach:
            return L(
                "Each script that changes anything is shown for your approval before it runs. Read-only scripts run automatically."
            )
        case .autoRunWithWarning:
            return L(
                "Scripts run automatically. A warning showing the script appears in the chat each time."
            )
        }
    }
}

/// The curated AppleScript model repos, as `MLXModel` entries. Each size is
/// the repo's main-revision download footprint on the HF Hub; the UI folds in
/// any live size refresh on top. `modelType` is intentionally left
/// `nil` even though the bundles are Gemma-family — the runtime auto-detects the
/// real architecture (and its native tool-call format) from the downloaded
/// `config.json`, and leaving it nil keeps this text-only AppleScript bundle
/// from ever being mis-detected as a VLM pre-download.
enum AppleScriptModelCatalog {
    /// Repo-id prefix shared by every curated AppleScript bundle. Used to keep
    /// these repos out of the general chat model picker (they only ever emit
    /// AppleScript, so they aren't useful as a chat model).
    static let repoIdPrefix = "OsaurusAI/Osaurus-AppleScript-"

    /// Upstream publisher prefix used by the original dedicated AppleScript
    /// task-model bundles that users may register through External Models.
    static let upstreamRepoIdPrefix = "JANGQ-AI/AppleScript-"

    /// The flagship curated AppleScript model: a Gemma-4 16B-A4B MoE build (~12 GB).
    static let model16BId = "OsaurusAI/Osaurus-AppleScript-16B-A4B-JANG_4M"

    /// The lighter curated AppleScript model: an 8B dense build (~8 GB).
    static let model8BId = "OsaurusAI/Osaurus-AppleScript-8B-JANG_6M"

    /// Curated catalog: the Gemma-4 16B-A4B MoE model (the Top Pick and
    /// seamless default for on-device AppleScript automation) plus a lighter
    /// 8B build for Macs with less memory.
    static let models: [MLXModel] = [
        MLXModel(
            id: model16BId,
            name: "Osaurus AppleScript 16B",
            description:
                "On-device mixture-of-experts model fine-tuned to write executable AppleScript for "
                + "macOS automation. Built for reliable scripts on harder automation tasks.",
            downloadURL: "https://huggingface.co/\(model16BId)",
            isTopSuggestion: true,
            downloadSizeBytes: 11_687_493_907,
            modelType: nil,
            useCase: .coding
        ),
        MLXModel(
            id: model8BId,
            name: "Osaurus AppleScript 8B",
            description:
                "Lighter on-device model fine-tuned to write executable AppleScript for macOS "
                + "automation. A smaller download that fits Macs with less memory.",
            downloadURL: "https://huggingface.co/\(model8BId)",
            isTopSuggestion: false,
            downloadSizeBytes: 7_950_377_360,
            modelType: nil,
            useCase: .coding
        ),
    ]

    /// Whether a repo id is an AppleScript-only task model. The current curated
    /// repos use `OsaurusAI/Osaurus-AppleScript-*`; earlier/upstream JANGQ bundles
    /// use `JANGQ-AI/AppleScript-*`. Both are dedicated automation models that
    /// emit scripts rather than normal chat replies, so both must be excluded
    /// from the chat picker and made available to the dedicated selector.
    static func isAppleScriptModel(id: String) -> Bool {
        id.range(of: repoIdPrefix, options: [.caseInsensitive, .anchored]) != nil
            || id.range(of: upstreamRepoIdPrefix, options: [.caseInsensitive, .anchored]) != nil
    }

    /// Whether a catalog/ad-hoc AppleScript bundle is available either in the
    /// Osaurus models directory or through the user's external-model registry.
    /// Runtime loading already resolves external bundles in place; the
    /// availability gate must use the same source of truth or a valid model in
    /// a Settings-selected folder is shown as installed but rejected at call
    /// time.
    private static func isInstalled(_ model: MLXModel) -> Bool {
        if model.isDownloaded { return true }
        guard let externalDirectory = ExternalModelLocator.path(forId: model.id) else {
            return false
        }
        let external = MLXModel(
            id: model.id,
            name: model.name,
            description: model.description,
            downloadURL: model.downloadURL,
            bundleDirectory: externalDirectory,
            externalSource: ExternalModelLocator.Source.customModelFolder.rawValue
        )
        return external.isDownloaded
    }

    /// The catalog entries that are installed on disk, including bundles the
    /// user placed in the primary Models Directory or registered in Settings
    /// -> Storage -> External Models. Use the shared non-blocking local-model
    /// snapshot so this selector sees the same merged inventory as the normal
    /// model picker without ever starting a synchronous disk scan on the main
    /// thread.
    static func installedModels() -> [MLXModel] {
        let curated = models.filter(isInstalled)
        let curatedIds = Set(curated.map { $0.id.lowercased() })
        let discovered = ModelManager.localModelsSnapshotNonBlocking()
            .filter { isAppleScriptModel(id: $0.id) }
            .filter { !curatedIds.contains($0.id.lowercased()) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        return curated + discovered
    }

    /// Whether any curated or externally registered dedicated AppleScript
    /// model is installed.
    static var hasInstalledModel: Bool {
        !installedModels().isEmpty
    }

    /// Resolve the model id the AppleScript subagent should load: the
    /// `preferred` id when it is an installed AppleScript bundle (curated, or
    /// any recognized OsaurusAI/JANGQ AppleScript repo the user has on disk —
    /// an explicit preference for a non-catalog build is honored);
    /// otherwise the first installed catalog model; otherwise `nil` (none
    /// installed → the kind denies before any load). Trimmed so a blank
    /// preference is ignored.
    static func resolveInstalledModelId(preferred: String?) -> String? {
        let trimmed = preferred?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            if let match = installedModels().first(where: {
                $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return match.id
            }
            // A non-catalog AppleScript bundle (matching the dedicated bundle
            // naming contract) that is installed on disk also resolves — but
            // only via an explicit preference, never as the implicit default.
            if isAppleScriptModel(id: trimmed) {
                let adHoc = MLXModel(
                    id: trimmed,
                    name: trimmed,
                    description: "",
                    downloadURL: "https://huggingface.co/\(trimmed)"
                )
                if isInstalled(adHoc) { return trimmed }
            }
        }
        // Automatic selection remains curated-only. Upstream/ad-hoc bundles
        // are available in the visible picker but are never silently selected
        // just because they happen to exist in an external folder.
        return models.first(where: isInstalled)?.id
    }
}
