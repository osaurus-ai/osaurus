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

/// The curated AppleScript model repo, as an `MLXModel` entry. The size is the
/// HF Hub `usedStorage` for the repo (the real download footprint); the UI
/// folds in any live size refresh on top. `modelType` is intentionally left
/// `nil` even though the bundle is `gemma4` — the runtime auto-detects the
/// real architecture (and its native tool-call format) from the downloaded
/// `config.json`, and leaving it nil keeps this text-only AppleScript bundle
/// from ever being mis-detected as a VLM pre-download.
enum AppleScriptModelCatalog {
    /// Repo-id prefix shared by every curated AppleScript bundle. Used to keep
    /// these repos out of the general chat model picker (they only ever emit
    /// AppleScript, so they aren't useful as a chat model).
    static let repoIdPrefix = "OsaurusAI/Osaurus-AppleScript-"

    /// The curated AppleScript model: a Gemma-4 16B-A4B MoE build (~12 GB).
    static let model16BId = "OsaurusAI/Osaurus-AppleScript-16B-A4B-JANG_4M"

    /// Curated catalog: a single Gemma-4 16B-A4B MoE model (the Top Pick and
    /// seamless default for on-device AppleScript automation).
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
        )
    ]

    /// Whether a repo id is one of the curated AppleScript models. Matches the
    /// shared prefix case-insensitively so a canonical or differently-cased id
    /// still resolves.
    static func isAppleScriptModel(id: String) -> Bool {
        id.range(of: repoIdPrefix, options: [.caseInsensitive, .anchored]) != nil
    }

    /// The catalog entries that are installed on disk (cheap, cache-backed
    /// `isDownloaded`).
    static func installedModels() -> [MLXModel] {
        models.filter { $0.isDownloaded }
    }

    /// Whether ANY curated AppleScript model is installed. Cheap enough for the
    /// system-prompt compose hot path (each `isDownloaded` reads the warmed
    /// `MLXModelDownloadCache`, invalidated on `.localModelsChanged`).
    static var hasInstalledModel: Bool {
        models.contains { $0.isDownloaded }
    }

    /// Resolve the model id the AppleScript subagent should load: the
    /// `preferred` id when it is an installed AppleScript bundle (curated, or
    /// any `OsaurusAI/Osaurus-AppleScript-*` repo the user has on disk — an
    /// explicit preference for a non-catalog build like the 8B is honored);
    /// otherwise the first installed catalog model; otherwise `nil` (none
    /// installed → the kind denies before any load). Trimmed so a blank
    /// preference is ignored.
    static func resolveInstalledModelId(preferred: String?) -> String? {
        let trimmed = preferred?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            if let match = models.first(where: { $0.id == trimmed }), match.isDownloaded {
                return match.id
            }
            // A non-catalog AppleScript bundle (matching the curated repo-id
            // prefix) that is installed on disk also resolves — but only via
            // an explicit preference, never as the implicit default.
            if isAppleScriptModel(id: trimmed) {
                let adHoc = MLXModel(
                    id: trimmed,
                    name: trimmed,
                    description: "",
                    downloadURL: "https://huggingface.co/\(trimmed)"
                )
                if adHoc.isDownloaded { return trimmed }
            }
        }
        return installedModels().first?.id
    }
}
