//
//  SubagentKind.swift
//  OsaurusCore — Subagent framework
//
//  The pluggable contract every nested subagent KIND conforms to. Adding a
//  future kind (privacy loop, code exec, browser) means writing ONE
//  conformer — the host (`SubagentSession`), the live feed, the recursion
//  guard, the compact-result normalization, and the optional model handoff
//  are all shared and need no edits.
//
//  The tool entry point parses its arguments, constructs a concrete kind
//  capturing them, and hands it to `SubagentSession.run(_:tool:)`. Keeping
//  arg-parsing in the tool/kind init means the protocol methods stay uniform
//  so the host can drive `any SubagentKind`.
//

import Foundation

/// One nested subagent implementation. A value/reference type that has
/// already captured its parsed request, so the host can run it uniformly.
public protocol SubagentKind: Sendable {
    /// The kind's registry descriptor: gate + tool name(s) + guidance + display
    /// + `modelSource`. Each kind returns its `SubagentCapabilityRegistry`
    /// entry, so the kind and the registry are one value (no parallel struct).
    var capability: SubagentCapability { get }

    /// One-line human label for the live feed row header (goal / task /
    /// prompt). Defaults to the capability id.
    var feedTitle: String { get }

    /// Resolve + validate the target model BEFORE any residency eviction
    /// (reject-before-evict). Throw `SubagentError` to fail cleanly.
    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel

    /// Permission decision (policy gate / interactive prompt / rich gate).
    /// Each kind owns its consent UX; the host only needs the verdict.
    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision

    /// Re-read any mutable execution authority after an interactive permission
    /// boundary and before a prepared run is returned. Most subagent kinds have
    /// no request-local mutable authority and use the default passthrough.
    ///
    /// Spawn overrides this narrowly: an Ask panel can stay open while its
    /// allow-list, budgets, target agent, tool grant, or model changes. Those
    /// values must be re-resolved without admitting/loading a model, and the
    /// approved target must remain identical.
    func revalidateAfterPermission(
        _ scope: SubagentScope,
        approved resolved: ResolvedModel
    ) async throws -> ResolvedModel

    /// Final execution-authority check immediately before process-wide
    /// admission/residency work. This closes the small prepare→execute race for
    /// kinds whose authorization comes from mutable settings. The default is a
    /// no-op; only the owning kind should opt in.
    func validateExecutionAuthority(
        _ scope: SubagentScope,
        resolved: ResolvedModel
    ) async throws

    /// Run the inner loop, emitting progress to `feed` and honoring
    /// `interrupt`. Returns the compact result or throws `SubagentError`.
    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult

    /// The optional model-residency handoff this kind wraps its run with.
    /// Same-model kinds (computer_use) use the default
    /// passthrough; model-swapping kinds (spawn, image) override this to vend a
    /// `ResidencyHandoff` configured with their per-run plan (the kind owns the
    /// policy + size source, so the middleware stays generic).
    func makeHandoff() -> SubagentHandoff

    /// The run's residency class for process-wide admission
    /// (`SubagentAdmission`): remote runs fan out concurrently, local
    /// handoffs are exclusive. Called after `resolveModel`, so kinds derive it
    /// from their live residency plan.
    func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass
}

/// A local-model kind whose residency decision can become stale while it waits
/// for process-wide admission.
///
/// `TextSubagentKind` is the production conformer. Keeping this separate from
/// `SubagentKind` avoids imposing model-residency policy on browser, media, and
/// other kinds that already own a different execution contract.
protocol SubagentPostAdmissionResidencyPlanning: SubagentKind {
    /// Re-read live residency and RAM-safety inputs after admission is held and
    /// update the kind's handoff state to match the returned plan.
    func refreshedResidencyPlanAfterAdmission(
        for resolved: ResolvedModel
    ) async throws -> ResidencyPlan
}

extension SubagentKind {
    public var feedTitle: String { capability.id }

    /// Default: no residency change. Model-swapping kinds override.
    public func makeHandoff() -> SubagentHandoff { PassthroughHandoff() }

    public func revalidateAfterPermission(
        _ scope: SubagentScope,
        approved resolved: ResolvedModel
    ) async throws -> ResolvedModel {
        resolved
    }

    public func validateExecutionAuthority(
        _ scope: SubagentScope,
        resolved: ResolvedModel
    ) async throws {}

    /// Default: a local model runs in place; a remote model doesn't touch the
    /// GPU. Kinds whose plan unloads resident models override to
    /// `.localExclusive`.
    public func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
        resolved.isLocal ? .localInPlace : .remote
    }
}

// MARK: - Optional handoff middleware

/// Wraps a run with optional residency management. Only kinds that resolve a
/// different model use a real implementation; same-model kinds use
/// `PassthroughHandoff`. Implemented as an "around" combinator so restore is
/// guaranteed even when the run throws.
public protocol SubagentHandoff: Sendable {
    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult
}

/// No-op handoff: same-model kinds (computer_use) run the
/// body directly with no preflight / unload / restore.
public struct PassthroughHandoff: SubagentHandoff {
    public init() {}
    public func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        try await body()
    }
}
