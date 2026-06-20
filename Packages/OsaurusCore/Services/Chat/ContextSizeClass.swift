//
//  ContextSizeClass.swift
//  osaurus
//
//  Per-model context-window classification used to auto-disable
//  prompt features that don't fit into very small windows. Apple's
//  Foundation model ships a 4K window on the macOS 26.x baseline (8K on
//  27.0+ hardware); at 4K, even before any user message the always-loaded
//  tool schemas push past it. The Foundation window is read live from
//  `SystemLanguageModel.contextSize` (back-deployed to 26.0) rather than
//  assumed, so newer hardware with a larger window auto-upgrades from
//  `.tiny` to `.small`. The system-prompt composer reads this resolver at
//  compose time and ORs the result into the agent's effective tools/memory
//  disable flags so we never ship a request that's already over budget.
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
    /// to take credit for). Named factory so the "should this surface
    /// to the popover?" predicate lives at the constructor boundary
    /// instead of being smuggled inside a failable `init?` — callers
    /// that just want to model the disable info pass concrete flags
    /// to the regular initialiser.
    public static func from(
        sizeClass: ContextSizeClass,
        modelId: String?,
        contextLength: Int?,
        agentToolsOff: Bool,
        agentMemoryOff: Bool
    ) -> ContextDisableInfo? {
        let disabledTools = sizeClass.disablesTools && !agentToolsOff
        let disabledMemory = sizeClass.disablesMemory && !agentMemoryOff
        guard sizeClass != .normal, disabledTools || disabledMemory else { return nil }
        return ContextDisableInfo(
            sizeClass: sizeClass,
            modelId: modelId,
            contextLength: contextLength,
            disabledTools: disabledTools,
            disabledMemory: disabledMemory
        )
    }
}

// MARK: - ContextWindowInfo

/// `(sizeClass, contextLength)` pair returned by `ContextSizeResolver`.
/// Replaces the bare tuple so call sites read field names instead of
/// destructuring an anonymous pair, and so the type can grow new
/// fields (model family, raw provider hint) without breaking every
/// `let (a, b) = resolve(...)` site.
public struct ContextWindowInfo: Sendable, Equatable {
    public let sizeClass: ContextSizeClass
    public let contextLength: Int?

    /// Whether the prompt should render in its compact form (ids-only
    /// manifest, small SOUL budget, compact family guidance, no plugin-creator
    /// recipe). True for small/tiny windows (existing behaviour) AND for local
    /// models small enough that the per-step tokenization cost of a verbose
    /// prompt outweighs the prose — even when their window is large. Kept on
    /// the SAME resolver as `sizeClass` (not a parallel classifier) but
    /// DISTINCT from the disable axis: a roomy local 12B prefers compaction
    /// without losing memory/tools the way `.small`/`.tiny` do. Session-constant
    /// (derived from the model id) → KV-cache safe.
    public let prefersCompactPrompt: Bool

    public init(
        sizeClass: ContextSizeClass,
        contextLength: Int?,
        prefersCompactPrompt: Bool = false
    ) {
        self.sizeClass = sizeClass
        self.contextLength = contextLength
        self.prefersCompactPrompt = prefersCompactPrompt
    }

    /// Conservative default returned when the model id is unknown or
    /// blank — keeps tools and memory enabled so we never hide them
    /// speculatively before the picker has resolved a model. Verbose by
    /// default (cloud / unresolved models handle a full prompt fine).
    public static let unknown = ContextWindowInfo(sizeClass: .normal, contextLength: nil)
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

    /// Local models at or under this parameter count prefer the compact
    /// prompt even on a large context window. The bottleneck is prompt-size
    /// tokenization on the user's own hardware (re-run every agent-loop step),
    /// so this is a cost/benefit ceiling, not a capability one. Tunable;
    /// default covers the common local fleet (8B–12B) with headroom.
    public static let compactParamCeilingBillions: Double = 20

    /// Pure window→class mapping shared by the Foundation probe and the
    /// MLX `config.json` path. Each ceiling is inclusive (`tinyCeiling`
    /// itself is `.tiny`; one token past it pivots to `.small`). Kept as a
    /// standalone function so the boundary policy can be unit-tested without
    /// an installed model or a Foundation-capable device.
    public static func sizeClass(forContextLength contextLength: Int) -> ContextSizeClass {
        if contextLength <= tinyCeiling { return .tiny }
        if contextLength <= smallCeiling { return .small }
        return .normal
    }

    /// Resolve the size class for a given model id.
    /// - Parameter modelId: The picker / API model identifier. May
    ///   be `nil` when the chat hasn't picked a model yet (preview
    ///   composer on a fresh window) — in that case the caller
    ///   doesn't know the budget, so we conservatively return
    ///   `.normal` to avoid hiding tools speculatively.
    public static func resolve(modelId: String?) -> ContextWindowInfo {
        guard let modelId, !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .unknown }

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
            // Probe the *real* on-device window rather than assuming 4096.
            // `FoundationModelService.defaultModelContextSize` reads the
            // back-deployed `SystemLanguageModel.contextSize` (memoized): 4096 on
            // the macOS 26.x baseline keeps tools/memory off, but an 8192 window
            // on 27.0+ hardware reclassifies to `.small`, which turns tools back
            // on with the compact prompt and memory still off. Falls back to the
            // tiny ceiling when Foundation is unavailable. Foundation is always a
            // small on-device model, so it always prefers the compact prompt.
            let ctx = FoundationModelService.defaultModelContextSize ?? tinyCeiling
            return ContextWindowInfo(
                sizeClass: sizeClass(forContextLength: ctx),
                contextLength: ctx,
                prefersCompactPrompt: true
            )
        }

        // Cache-only: `resolve` runs synchronously inside chat view getters
        // during layout, where `ModelInfo.load`'s cold-miss disk probe has hung
        // the UI. A cold miss warms the memo off-main and reads as `.unknown`
        // for this pass; a later render resolves the real window.
        guard let info = ModelInfo.loadCachedOrWarm(modelId: modelId),
            let ctx = info.model.contextLength
        else { return .unknown }

        let bucket = sizeClass(forContextLength: ctx)
        if bucket != .normal {
            return ContextWindowInfo(sizeClass: bucket, contextLength: ctx, prefersCompactPrompt: true)
        }
        // Large window, local model: prefer compact when the model is small
        // enough that verbose-prompt tokenization isn't worth it. Unknown size
        // on a local model also compacts (the fleet skews small, and compaction
        // only drops prose — never a capability id or a tool from the schema).
        let billions = ModelMetadataParser.parameterCountBillions(from: trimmed)
        let prefersCompact = billions.map { $0 <= compactParamCeilingBillions } ?? true
        return ContextWindowInfo(
            sizeClass: .normal,
            contextLength: ctx,
            prefersCompactPrompt: prefersCompact
        )
    }
}
