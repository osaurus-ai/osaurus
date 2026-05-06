//
//  ResolvedToolset.swift
//  osaurus
//
//  Bundle of every tool-axis decision the composer makes for a single
//  request: which tools landed in the schema, what the preflight returned,
//  which always-loaded names made it through the freeze filter, which
//  standalone-skill teasers were derived, plus the context-window auto-
//  disable verdict (kept here because the size-class flag drives both
//  `effectiveToolsOff` and the final `ComposedContext.contextDisable`).
//
//  Replaces the previous "thread 8 named values down through helpers"
//  pattern. Once `resolveToolset` returns one of these, every downstream
//  gate consumes one struct instead of a fan-out parameter list.
//

import Foundation

struct ResolvedToolset: Sendable {

    /// Preflight result this turn used (fresh, cached, or `.empty`).
    let preflight: PreflightResult

    /// Final tool schema delivered to the model, sorted into canonical
    /// order (loop tools → sandbox built-ins → capability discovery →
    /// alphabetical). Empty when `effectiveToolsOff` is true.
    let tools: [Tool]

    /// Standalone (non-plugin) skill teasers derived from the user
    /// query. Already filtered to skip skills surfaced via plugin
    /// companions or already loaded mid-session.
    let skillSuggestions: [SkillTeaser]

    /// Always-loaded names this turn shipped, intersected against the
    /// frozen snapshot when one was supplied. Callers stash this on
    /// the per-session state so subsequent turns can freeze the schema.
    let alwaysLoadedNames: LoadedTools

    /// Auto-disable verdict for the resolved model's context window,
    /// or nil for normal-class models. Surfaces through
    /// `ComposedContext.contextDisable` so the budget popover can
    /// render its italic notice without re-deriving the decision.
    let contextDisable: ContextDisableInfo?

    /// OR of `snapshot.toolsDisabled` and the size-class auto-disable.
    /// Every gate that used to compute this from `(snapshot, sizeClass)`
    /// reads it from here instead.
    let effectiveToolsOff: Bool
}
