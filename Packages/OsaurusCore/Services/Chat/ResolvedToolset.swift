//
//  ResolvedToolset.swift
//  osaurus
//
//  Bundle of every tool-axis decision the composer makes for a single
//  request: which tools landed in the schema, which always-loaded names made
//  it through the freeze filter, the frozen enabled-capabilities manifest,
//  plus the context-window auto-disable verdict (kept here because the
//  size-class flag drives both `effectiveToolsOff` and the final
//  `ComposedContext.contextDisable`).
//
//  Replaces the previous "thread 8 named values down through helpers"
//  pattern. Once `resolveToolset` returns one of these, every downstream
//  gate consumes one struct instead of a fan-out parameter list.
//

import Foundation

struct ResolvedToolset: Sendable {

    /// Final tool schema delivered to the model, sorted into canonical
    /// order (loop tools → sandbox built-ins → capability discovery →
    /// alphabetical). Empty when `effectiveToolsOff` is true.
    let tools: [Tool]

    /// Rendered enabled-capabilities manifest section for this session, or
    /// `nil` when the section is gated off / empty. Frozen at session start
    /// and injected as a static prefix section, so it is query- and
    /// loaded-subset-independent (byte-stable across turns). Callers stash it
    /// on the per-session state and echo it back via `frozenManifest`.
    let enabledManifest: String?

    /// Always-loaded names this turn shipped, intersected against the
    /// frozen snapshot when one was supplied. Callers stash this on
    /// the per-session state so subsequent turns can freeze the schema.
    let alwaysLoadedNames: LoadedTools

    /// Auto-disable verdict for the resolved model's context window,
    /// or nil for normal-class models. Surfaces through
    /// `ComposedContext.contextDisable` so the budget popover can
    /// render its italic notice without re-deriving the decision.
    let contextDisable: ContextDisableInfo?

    /// Context-window size class for the resolved model. Session-constant
    /// (a session keeps one model), so prompt gates that key off it stay
    /// KV-cache safe across turns. Drives the small-context loop-guidance
    /// gate and the tiny-context section compaction. Distinct from the
    /// `effectiveToolsOff` flag, which only flips for `.tiny`.
    let sizeClass: ContextSizeClass

    /// OR of `snapshot.toolsDisabled` and the size-class auto-disable.
    /// Every gate that used to compute this from `(snapshot, sizeClass)`
    /// reads it from here instead.
    let effectiveToolsOff: Bool

    /// True when the prompt should include capability-discovery prose and
    /// dynamic backstops. Trivial salutations keep the callable bootstrap
    /// tools but skip this text so a "hi" turn does not pay the full agentic
    /// preamble cost before the model has any real task to solve.
    let capabilityPromptSectionsEnabled: Bool

    /// Mirror of `ContextWindowInfo.prefersCompactPrompt` for the resolved
    /// model. Drives the ids-only manifest, the small SOUL budget, compact
    /// model-family guidance, and dropping the plugin-creator recipe. Distinct
    /// from `sizeClass` so a roomy local model compacts without the
    /// memory/tool disabling `.small`/`.tiny` carry. Session-constant →
    /// KV-cache safe.
    let prefersCompactPrompt: Bool
}
