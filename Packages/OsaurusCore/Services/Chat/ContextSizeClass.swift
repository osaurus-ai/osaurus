//
//  ContextSizeClass.swift
//  osaurus
//
//  Per-model context-window classification used to auto-disable
//  prompt features that don't fit into very small windows. Apple's
//  Foundation model has a ~4K window; even before any user message
//  the always-loaded tool schemas push past it. The system-prompt
//  composer reads this resolver at compose time and ORs the result
//  into the agent's effective tools/memory disable flags so we never
//  ship a request that's already over budget.
//

import Foundation

// MARK: - ContextSizeClass

/// Coarse classification of a model's nominal context window. Three
/// buckets are enough — the prompt composer only needs to decide
/// whether to disable tools (tiny only) and/or memory (tiny + small).
public enum ContextSizeClass: Sendable, Equatable {
    /// `<= 4096` tokens. Apple Foundation and any equally tight
    /// future model. Tools, memory, and skill suggestions all auto
    /// off — at this size even the always-loaded tool JSON schemas
    /// cost more than the available budget.
    case tiny

    /// `<= 8192` tokens. Fits a reasonable chat schema but not
    /// memory snippets, which are the most volatile dynamic input
    /// and the easiest to drop without breaking the loop.
    case small

    /// Larger than `8192` tokens, or unknown. No auto-overrides.
    case normal

    /// Whether this class auto-disables tools (and the entire
    /// gated-section surface that depends on tools, including
    /// agent-loop guidance, capability discovery, skill suggestions,
    /// and the model-family nudge).
    public var disablesTools: Bool { self == .tiny }

    /// Whether this class auto-disables memory injection. Memory is
    /// the per-turn snippet prepended to the user message, not part
    /// of the system prompt, so disabling it is independent of the
    /// tools axis.
    public var disablesMemory: Bool { self != .normal }
}

// MARK: - ContextDisableInfo

/// Surfaced on `ComposedContext` so the chat UI can render an
/// italic "auto-disabled by context size" notice without re-deriving
/// the decision. `nil` on `ComposedContext` means no override fired.
public struct ContextDisableInfo: Equatable, Sendable {
    public let sizeClass: ContextSizeClass
    public let modelId: String?
    public let contextLength: Int?
    public let disabledTools: Bool
    public let disabledMemory: Bool

    public init(
        sizeClass: ContextSizeClass,
        modelId: String?,
        contextLength: Int?,
        disabledTools: Bool,
        disabledMemory: Bool
    ) {
        self.sizeClass = sizeClass
        self.modelId = modelId
        self.contextLength = contextLength
        self.disabledTools = disabledTools
        self.disabledMemory = disabledMemory
    }

    /// Build the popover-facing summary for a resolved size class.
    /// Returns `nil` when the class is `.normal` or both axes were
    /// already off at the agent level (nothing for the auto-disable
    /// to take credit for). Centralised so `composeChatContext` and
    /// `composePreviewContext` produce identical info.
    public init?(
        sizeClass: ContextSizeClass,
        modelId: String?,
        contextLength: Int?,
        agentToolsOff: Bool,
        agentMemoryOff: Bool
    ) {
        let disabledTools = sizeClass.disablesTools && !agentToolsOff
        let disabledMemory = sizeClass.disablesMemory && !agentMemoryOff
        guard sizeClass != .normal, disabledTools || disabledMemory else { return nil }
        self.init(
            sizeClass: sizeClass,
            modelId: modelId,
            contextLength: contextLength,
            disabledTools: disabledTools,
            disabledMemory: disabledMemory
        )
    }
}

// MARK: - Resolver

/// Resolves a model id to a `ContextSizeClass` and concrete context
/// length. Pure function — no shared mutable state, no main-actor
/// hops — so it's safe to call from `composePreviewContext` (sync)
/// and `composeChatContext` (async) alike.
public enum ContextSizeResolver {

    /// Tiny ceiling. Anything at or below this, including all of
    /// Foundation, is `.tiny`. Matches `FloatingInputCard`'s
    /// hardcoded Foundation cap.
    public static let tinyCeiling: Int = 4096

    /// Small ceiling. Anything at or below this (and above `tinyCeiling`)
    /// is `.small`. Tuned for 8K-window MLX builds (e.g. quantised
    /// Phi-mini, smaller Qwen variants).
    public static let smallCeiling: Int = 8192

    /// Resolve the size class for a given model id.
    /// - Parameter modelId: The picker / API model identifier. May
    ///   be `nil` when the chat hasn't picked a model yet (preview
    ///   composer on a fresh window) — in that case the caller
    ///   doesn't know the budget, so we conservatively return
    ///   `.normal` to avoid hiding tools speculatively.
    public static func resolve(modelId: String?) -> (ContextSizeClass, Int?) {
        guard let modelId, !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return (.normal, nil) }

        // Foundation's nominal context isn't readable through
        // `ModelInfo.load` (no MLX `config.json` on disk). Match the
        // same alias rule as `FoundationModelService.handles` — that
        // method lives on an actor (no shared singleton) so we
        // duplicate the three-line check rather than spin one up just
        // to call it.
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("foundation") == .orderedSame
            || trimmed.caseInsensitiveCompare("default") == .orderedSame
        {
            return (.tiny, tinyCeiling)
        }

        guard let info = ModelInfo.load(modelId: modelId),
            let ctx = info.model.contextLength
        else { return (.normal, nil) }

        if ctx <= tinyCeiling { return (.tiny, ctx) }
        if ctx <= smallCeiling { return (.small, ctx) }
        return (.normal, ctx)
    }
}
