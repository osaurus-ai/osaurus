//
//  PromptComposerExperiment.swift
//  osaurus
//
//  Eval-scoped prompt/tool ablation overrides for the context
//  optimization harness. Production never sets these: the scope is
//  populated only by the OsaurusEvals CLI (via a validated experiment
//  profile) so an A/B run can measure "what does dropping section X /
//  deferring tool Y / forcing the compact prompt actually cost" through
//  the REAL composer, with zero behavior change when unset.
//
//  Safety contract (mirrors the AGENTS.md non-negotiables):
//    - `current == nil` (the production default) is byte-for-byte the
//      existing compose pipeline. Every hook below is a no-op then.
//    - Quality-critical contracts cannot be ablated: the protected
//      section ids / tool names below are enforced BOTH at profile
//      validation time (OsaurusEvalsKit) and again at the apply site,
//      so a hand-rolled experiment can never silently remove the
//      capability-discovery gateway, the agent-loop tool contract, or
//      grounding.
//

import Foundation

/// One experiment's composer overrides. All fields optional/empty ⇒
/// identical to production composition.
public struct PromptComposerExperiment: Sendable, Equatable {
    /// Force the compact/full prompt selection regardless of the model's
    /// resolved `prefersCompactPrompt`. nil keeps the production resolver.
    public var forceCompactPrompt: Bool?
    /// Prompt section ids removed AFTER gated composition (never the
    /// protected ids). The manifest, rendered prompt, static prefix and
    /// cache hint all reflect the removal — exactly what a real shipped
    /// change would produce.
    public var dropSectionIds: Set<String>
    /// Tool names stripped from the resolved request schema (never the
    /// protected names). The tools stay registered and loadable via
    /// `capabilities_load`, so this measures the "defer to discovery"
    /// architecture rather than deleting a capability.
    public var deferToolNames: Set<String>
    /// Compact the results `capabilities_load` writes into history: a
    /// smaller skill-reference budget and skeleton (compact) schemas for
    /// dynamically loaded tools. This is the "loaded result compaction"
    /// architecture axis — it saves CUMULATIVE/history tokens rather than
    /// first-step surface, so only model runs can price it. nil/false
    /// keeps production behavior.
    public var compactLoadedResults: Bool?

    public init(
        forceCompactPrompt: Bool? = nil,
        dropSectionIds: Set<String> = [],
        deferToolNames: Set<String> = [],
        compactLoadedResults: Bool? = nil
    ) {
        self.forceCompactPrompt = forceCompactPrompt
        self.dropSectionIds = dropSectionIds
        self.deferToolNames = deferToolNames
        self.compactLoadedResults = compactLoadedResults
    }

    public var isNoOp: Bool {
        forceCompactPrompt == nil && dropSectionIds.isEmpty && deferToolNames.isEmpty
            && compactLoadedResults != true
    }

    // MARK: - Contract guards

    /// Section ids that can never be ablated. Platform/persona are the
    /// identity contract; grounding is a quality non-negotiable.
    ///
    /// `enabledManifest` is deliberately NOT protected anymore: the exact
    /// paginated listing replacement the plan requires now exists
    /// (`capabilities_discover` with `{"list": "enabled"}`), so a
    /// manifest-replacement experiment is a VALID candidate — but it is
    /// promotable only when it survives the capability-claim and tool-use
    /// eval gates. Keep the manifest in production until then.
    public static let protectedSectionIds: Set<String> = [
        "platform", "persona", "grounding",
    ]

    /// Every section id the composer can emit — the validation census.
    /// Kept in the composer's own module so a new section can't be added
    /// without the harness seeing it (ProfileValidation rejects unknown
    /// ids, which turns a drift into a loud eval-time error).
    public static let knownSectionIds: Set<String> = [
        "platform", "persona", "soul", "selfImprovement", "agentDB",
        "modelFamilyGuidance", "grounding", "codeStyle", "riskAware",
        "secretHandling", "spawn", "knowledge", "agentLoopGuidance",
        "sandbox", "combinedHostRead", "folderContext", "capabilityNudge",
        "enabledManifest", "skillsGovern", "pluginCreator", "agentDBSchema",
        "sandboxState", "sandboxUnavailable", "memory",
    ]

    /// Tool names that can never be deferred: the discovery gateway
    /// (`capabilities_discover` / `capabilities_load`) is what makes
    /// deferral safe at all, and the constrained agent-loop schema is a
    /// scored contract.
    public static let protectedToolNames: Set<String> = [
        "capabilities_discover", "capabilities_load",
        "todo", "complete", "clarify", "share_artifact",
    ]

    /// The immutable hot set for the hot-set architecture experiment
    /// (plan §5): the protected loop/discovery contract plus the
    /// primitives an agent reaches for on turn one — file/exec/web —
    /// where a discovery round-trip before the first action would cost
    /// more than the schema saves. Everything outside this set defers to
    /// `capabilities_load` under the `arch-hot-set` candidate.
    public static let hotSetToolNames: Set<String> = protectedToolNames.union([
        "sandbox_exec", "sandbox_read_file", "sandbox_write_file",
        "sandbox_search_files", "web_search", "get_current_time",
    ])

    /// Human-readable validation problems, empty when the experiment is
    /// applicable. Enforced again (silently, defensively) at apply time.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        let protectedSections = dropSectionIds.intersection(Self.protectedSectionIds)
        if !protectedSections.isEmpty {
            errors.append(
                "cannot drop protected section(s): \(protectedSections.sorted().joined(separator: ", "))"
            )
        }
        let unknownSections = dropSectionIds.subtracting(Self.knownSectionIds)
        if !unknownSections.isEmpty {
            errors.append(
                "unknown section id(s): \(unknownSections.sorted().joined(separator: ", "))"
            )
        }
        let protectedTools = deferToolNames.intersection(Self.protectedToolNames)
        if !protectedTools.isEmpty {
            errors.append(
                "cannot defer protected tool(s): \(protectedTools.sorted().joined(separator: ", "))"
            )
        }
        return errors
    }

    // MARK: - Apply helpers (no-ops when the experiment doesn't touch the axis)

    /// Sections surviving the ablation. Protected ids are kept even if
    /// listed (validation should have refused; this is the second lock).
    func filterSections(_ sections: [PromptSection]) -> [PromptSection] {
        guard !dropSectionIds.isEmpty else { return sections }
        let effective = dropSectionIds.subtracting(Self.protectedSectionIds)
        guard !effective.isEmpty else { return sections }
        return sections.filter { !effective.contains($0.id) }
    }

    /// Tools surviving the deferral. Protected names always survive.
    func filterTools(_ tools: [Tool]) -> [Tool] {
        guard !deferToolNames.isEmpty else { return tools }
        let effective = deferToolNames.subtracting(Self.protectedToolNames)
        guard !effective.isEmpty else { return tools }
        return tools.filter { !effective.contains($0.function.name) }
    }
}

/// Process-wide holder for the active experiment. Lock-guarded (not
/// MainActor) because `ContextSizeResolver.resolve` is a pure sync
/// function called off the main actor too. Set once by the eval CLI
/// before any compose; production code never writes it.
public enum PromptComposerExperimentScope {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: PromptComposerExperiment?

    public static var current: PromptComposerExperiment? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _current
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _current = newValue
        }
    }

    /// Apply the compact-prompt override to a resolved window, keeping
    /// every other field. Called from `ContextSizeResolver.resolve` so
    /// every read site (toolset, manifest, SOUL cap, templates) sees one
    /// consistent answer.
    static func applyCompactOverride(to info: ContextWindowInfo) -> ContextWindowInfo {
        guard let force = current?.forceCompactPrompt,
            force != info.prefersCompactPrompt
        else { return info }
        return ContextWindowInfo(
            sizeClass: info.sizeClass,
            contextLength: info.contextLength,
            prefersCompactPrompt: force
        )
    }
}
