//
//  ModelOverride.swift
//  OsaurusEvalsKit
//
//  Sets the core model identifier for an eval run by writing into
//  `ChatConfigurationStore`, then restores the previous value when the
//  scope ends. `CoreModelService.generate` reads the identifier off
//  the store on every call, so the override naturally affects every
//  preflight call inside the scope without touching inference plumbing.
//
//  The CLI accepts a few shorthand forms ("foundation", "auto",
//  `provider/name`); we expand them here so the runner code stays
//  ignorant of CLI argument shape.
//

import Foundation
import OsaurusCore

public enum ModelSelection: Sendable {
    /// Use whatever `ChatConfigurationStore` currently has — the
    /// "don't touch anything" path. Useful for matching the
    /// production behaviour the user is currently running with.
    case keepCurrent
    /// Force Apple's on-device Foundation Models for the run.
    case foundation
    /// Explicit provider/name pair. Slash-form (`openai/gpt-4o-mini`,
    /// `mlx-community/Qwen3-4B-MLX-4bit`) is parsed; bare names route
    /// to the local catalog (see `CoreModelService.generate`).
    case explicit(provider: String?, name: String)

    /// Parse a CLI value into a `ModelSelection`. `auto` and the empty
    /// string both map to `.keepCurrent` so callers can use either
    /// idiom interchangeably.
    public static func parse(_ raw: String?) -> ModelSelection {
        guard let raw, !raw.isEmpty else { return .keepCurrent }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "auto" { return .keepCurrent }
        if trimmed.lowercased() == "foundation" { return .foundation }
        // First slash splits provider from name. Everything after
        // belongs to the name (HF repos like `mlx-community/Qwen3...`
        // contain a slash but the *first* slash is still the
        // provider/name boundary as far as routing is concerned).
        if let slash = trimmed.firstIndex(of: "/") {
            let provider = String(trimmed[..<slash])
            let name = String(trimmed[trimmed.index(after: slash)...])
            return .explicit(provider: provider.isEmpty ? nil : provider, name: name)
        }
        return .explicit(provider: nil, name: trimmed)
    }
}

@MainActor
public enum ModelOverride {

    /// Apply `selection` to `ChatConfigurationStore`, run `body`, and
    /// restore the prior config in a `defer` even if `body` throws —
    /// mirrors the contract callers expect from `withResource`-style
    /// helpers. Returns whatever `body` returns.
    public static func withSelection<T>(
        _ selection: ModelSelection,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let prior = ChatConfigurationStore.load()
        defer { ChatConfigurationStore.save(prior) }

        switch selection {
        case .keepCurrent:
            break
        case .foundation:
            // The local Foundation service handles the literal id
            // "foundation" (see `ModelServiceRouter.resolve` /
            // `FoundationModelService.handles(requestedModel:)`).
            var updated = prior
            updated.coreModelProvider = nil
            updated.coreModelName = "foundation"
            ChatConfigurationStore.save(updated)
        case .explicit(let provider, let name):
            var updated = prior
            updated.coreModelProvider = provider
            updated.coreModelName = name
            ChatConfigurationStore.save(updated)
        }

        return try await body()
    }

    /// Convenience for log lines / report metadata.
    public static func describe(_ selection: ModelSelection) -> String {
        switch selection {
        case .keepCurrent:
            return ChatConfigurationStore.load().coreModelIdentifier ?? "(unset)"
        case .foundation:
            return "foundation"
        case .explicit(let provider, let name):
            if let provider, !provider.isEmpty { return "\(provider)/\(name)" }
            return name
        }
    }
}
