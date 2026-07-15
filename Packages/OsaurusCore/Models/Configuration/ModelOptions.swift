//
//  ModelOptions.swift
//  osaurus
//
//  Registry-based model options system. Each ModelProfile declares the options
//  a family of models supports; the UI renders them dynamically and the values
//  flow through to the request builder.
//

import Foundation
import os

// MARK: - Option Value

enum ModelOptionValue: Sendable, Equatable, Hashable, Codable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}

// MARK: - Option Definition

struct ModelOptionSegment: Identifiable, Sendable {
    let id: String
    let label: String
}

struct ModelOptionDefinition: Identifiable, Sendable {
    enum Kind: Sendable {
        case segmented([ModelOptionSegment])
        case toggle(default: Bool)
    }

    let id: String
    let label: String
    let icon: String?
    let kind: Kind

    init(id: String, label: String, icon: String? = nil, kind: Kind) {
        self.id = id
        self.label = label
        self.icon = icon
        self.kind = kind
    }
}

// MARK: - Remote Reasoning Capabilities (catalog-driven)

/// Ordered reasoning-effort capability set for a remote model, sourced from a
/// live provider catalog (the ChatGPT/Codex `/models` response) or a
/// documented API contract (official OpenAI GPT-5.6). Level ids are exact
/// wire values (`low`, `xhigh`, `ultra`, ...); only presentation labels are
/// mapped locally, so the original id always passes through unchanged.
struct ModelReasoningCapabilities: Sendable, Equatable, Hashable {
    struct Level: Sendable, Equatable, Hashable, Identifiable {
        /// Wire effort id, e.g. "xhigh".
        let id: String
        /// Catalog-provided copy for the level (secondary text in the picker).
        let description: String?

        init(id: String, description: String? = nil) {
            self.id = id
            self.description = description
        }
    }

    /// Supported levels in catalog order.
    let levels: [Level]
    /// Catalog default effort id. Display-only: shown when the user made no
    /// explicit choice, never synthesized into requests.
    let defaultLevelId: String?

    var isEmpty: Bool { levels.isEmpty }

    /// Human label for a wire effort id, matching ChatGPT's own naming.
    /// Unknown ids fall back to a capitalized form so a new catalog level
    /// still renders sensibly before Osaurus learns its label.
    static func displayLabel(forEffort effort: String) -> String {
        switch effort.lowercased() {
        case "none": return L("None")
        case "minimal": return L("Minimal")
        case "low": return L("Light")
        case "medium": return L("Medium")
        case "high": return L("High")
        case "xhigh": return L("Extra High")
        case "max": return L("Max")
        case "ultra": return L("Ultra")
        default: return effort.capitalized
        }
    }

    /// The dynamic `reasoningEffort` option definition for this capability
    /// set, used by both the option normalizer (segment validation) and the
    /// UI (segment rendering).
    var reasoningOptionDefinition: ModelOptionDefinition {
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Effort"),
            icon: "brain",
            kind: .segmented(
                levels.map { ModelOptionSegment(id: $0.id, label: Self.displayLabel(forEffort: $0.id)) }
            )
        )
    }

    /// Documented reasoning contract for GPT-5.6 (Sol/Terra/Luna) on the
    /// official `api.openai.com` API-key route: `none` through `max`,
    /// defaulting to `medium`. The public API does NOT expose Codex's
    /// `ultra`; this profile must never grow it, and it applies only to the
    /// official host — custom OpenAI-compatible providers keep the generic
    /// fallback behavior.
    static let officialOpenAIGPT56 = ModelReasoningCapabilities(
        levels: ["none", "low", "medium", "high", "xhigh", "max"].map { Level(id: $0) },
        defaultLevelId: "medium"
    )

    init(levels: [Level], defaultLevelId: String?) {
        self.levels = levels
        self.defaultLevelId = defaultLevelId
    }

    /// Build from live Codex catalog metadata; nil when the catalog exposes
    /// no reasoning levels for the model (older slugs keep the generic
    /// static profile).
    init?(codex metadata: CodexModelMetadata) {
        let levels = metadata.supportedReasoningLevels.map {
            Level(id: $0.effort, description: $0.description)
        }
        guard !levels.isEmpty else { return nil }
        self.init(levels: levels, defaultLevelId: metadata.defaultReasoningLevel)
    }
}

/// Process-global dynamic reasoning capability catalog, keyed by the FULL
/// provider-prefixed model id (e.g. "openai-chatgpt/gpt-5.6-terra") so the
/// same slug offered by two routes (Codex OAuth vs official API key) never
/// receives the wrong provider's effort set.
///
/// Lock-backed because `ChatEngine` re-normalizes request options off the
/// SwiftUI layer; without a globally readable resolver, valid `xhigh`/`max`/
/// `ultra` selections would be dropped by the static four-tier profile.
/// `ModelPickerItemCache` atomically replaces the whole catalog on every
/// rebuild, which also clears entries for removed/disconnected providers.
enum RemoteReasoningCapabilityCatalog {
    private static let box = OSAllocatedUnfairLock<[String: ModelReasoningCapabilities]>(
        initialState: [:]
    )

    static func replaceAll(_ capabilities: [String: ModelReasoningCapabilities]) {
        box.withLock { $0 = capabilities }
    }

    static func capabilities(for modelId: String) -> ModelReasoningCapabilities? {
        box.withLock { $0[modelId] }
    }

    /// Current contents, for save/restore around tests.
    static func snapshot() -> [String: ModelReasoningCapabilities] {
        box.withLock { $0 }
    }
}

// MARK: - Model Profile Protocol

protocol ModelProfile: Sendable {
    static func matches(modelId: String) -> Bool
    static var displayName: String { get }
    static var options: [ModelOptionDefinition] { get }
    static var defaults: [String: ModelOptionValue] { get }

    /// Mapping for a dedicated "Thinking/Reasoning" toggle in the input area.
    /// Returns the option ID (like "disableThinking") and whether the stored
    /// boolean is inverted (`true` means disabled, so the UI shows OFF).
    static var thinkingOption: (id: String, inverted: Bool)? { get }
}

extension ModelProfile {
    static var thinkingOption: (id: String, inverted: Bool)? { nil }
}

// MARK: - Registry

enum ModelProfileRegistry {
    static let profiles: [any ModelProfile.Type] = [
        VeniceModelProfile.self,
        // Version-specific OpenAI profiles must precede the generic
        // `OpenAIReasoningProfile` fallback: first match wins.
        OpenAIOSeriesReasoningProfile.self,
        OpenAIGPT51ReasoningProfile.self,
        OpenAIGPT52PlusReasoningProfile.self,
        OpenAIReasoningProfile.self,
        MistralReasoningProfile.self,
        QwenThinkingProfile.self,
        NemotronThinkingProfile.self,
        LagunaThinkingProfile.self,
        DSV4ReasoningProfile.self,
        Hy3ReasoningProfile.self,
        LingRuntimeProfile.self,
        ZayaThinkingProfile.self,
        Gemma4RuntimeProfile.self,
        Gemini31FlashImageProfile.self,
        GeminiProImageProfile.self,
        GeminiFlashImageProfile.self,
        AutoThinkingProfile.self,
    ]

    static func profile(for modelId: String) -> (any ModelProfile.Type)? {
        profiles.first { $0.matches(modelId: modelId) }
    }

    static func defaults(for modelId: String) -> [String: ModelOptionValue] {
        profile(for: modelId)?.defaults ?? [:]
    }

    /// Catalog-driven reasoning capabilities for a (full, provider-prefixed)
    /// model id, when a connected provider published them.
    static func reasoningCapabilities(for modelId: String) -> ModelReasoningCapabilities? {
        RemoteReasoningCapabilityCatalog.capabilities(for: modelId)
    }

    /// The effort id the UI should display as active: the explicit persisted
    /// choice when present, otherwise the catalog default. Display-only —
    /// the default is never synthesized into `modelOptions`/requests, so the
    /// backend still applies it naturally.
    static func effectiveReasoningEffort(
        for modelId: String,
        values: [String: ModelOptionValue]
    ) -> String? {
        if let explicit = values["reasoningEffort"]?.stringValue { return explicit }
        return reasoningCapabilities(for: modelId)?.defaultLevelId
    }

    /// Display label for the model chip's inline reasoning suffix
    /// ("Terra · Extra High", "deepseek-v4 · Instruct"): the effective
    /// effort's presentation label from the model's segmented reasoning
    /// option — dynamic catalog first (ChatGPT-style labels), then the
    /// static profile's own segment labels. Nil when the model has no
    /// segmented `reasoningEffort` option or no effective value to show.
    static func inlineReasoningSuffixLabel(
        for modelId: String,
        values: [String: ModelOptionValue]
    ) -> String? {
        if let capabilities = reasoningCapabilities(for: modelId), !capabilities.isEmpty {
            let effective =
                values["reasoningEffort"]?.stringValue ?? capabilities.defaultLevelId
            return effective.map { ModelReasoningCapabilities.displayLabel(forEffort: $0) }
        }
        guard
            let option = profile(for: modelId)?.options
                .first(where: { $0.id == "reasoningEffort" }),
            case .segmented(let segments) = option.kind
        else { return nil }
        let effective =
            values["reasoningEffort"]?.stringValue
            ?? defaults(for: modelId)["reasoningEffort"]?.stringValue
        guard let effective else { return nil }
        return segments.first(where: { $0.id == effective })?.label
            ?? ModelReasoningCapabilities.displayLabel(forEffort: effective)
    }

    static func options(for modelId: String) -> [ModelOptionDefinition] {
        // Provider-scoped live capabilities win over the static profiles:
        // the catalog is authoritative for which efforts a model accepts
        // (Terra offers `ultra`, Luna stops at `max`). Static profiles remain
        // the fallback for older models and pre-catalog states.
        if let capabilities = reasoningCapabilities(for: modelId), !capabilities.isEmpty {
            return [capabilities.reasoningOptionDefinition]
        }
        return profile(for: modelId)?.options ?? []
    }

    static func normalizedOptions(
        for modelId: String,
        persisted: [String: ModelOptionValue]?
    ) -> [String: ModelOptionValue] {
        let definitions = options(for: modelId)
        guard !definitions.isEmpty else { return [:] }

        // Do not synthesize profile defaults into requests. Missing values mean
        // "let the model bundle/runtime decide"; only explicit UI/API choices
        // are allowed to reach modelOptions.
        guard let persisted else { return [:] }

        let allowedIds = Set(definitions.map(\.id))
        // Segment ids allowed per option. A persisted segment value that is no
        // longer offered (e.g. an old Mistral `reasoningEffort: "medium"` after
        // the option set was narrowed to none/high) must be dropped, not sent to
        // the wire, where it would be rejected.
        let allowedSegmentValues: [String: Set<String>] = definitions.reduce(into: [:]) { acc, def in
            if case .segmented(let segments) = def.kind {
                acc[def.id] = Set(segments.map(\.id))
            }
        }
        return persisted.filter { key, value in
            guard allowedIds.contains(key) else { return false }
            guard let segments = allowedSegmentValues[key] else { return true }
            guard let stringValue = value.stringValue else { return true }
            return segments.contains(stringValue)
        }
    }

    static func boolOptionValue(
        for modelId: String,
        optionId: String,
        values: [String: ModelOptionValue]
    ) -> Bool? {
        values[optionId]?.boolValue
    }

    static func thinkingEnabled(
        for modelId: String,
        values: [String: ModelOptionValue]
    ) -> Bool? {
        guard let option = profile(for: modelId)?.thinkingOption,
            let value = boolOptionValue(for: modelId, optionId: option.id, values: values)
        else {
            return nil
        }
        return option.inverted ? !value : value
    }

    /// The reasoning state the chip should show when the user has made no
    /// explicit choice. Requests intentionally send nothing in that case (see
    /// `normalizedOptions`), so the engine runs the model's chat-template
    /// default — ornith / qwen3.5 default thinking-ON, gemma-4 defaults OFF.
    /// Reporting that here keeps the chip honest instead of the old hardcoded
    /// "off" that lied for default-on models. Reads the local bundle's template
    /// via `LocalReasoningCapability`, so it is a view-layer helper (potential
    /// disk touch) rather than part of the pure registry lookups above.
    static func thinkingDefaultOn(for modelId: String) -> Bool {
        LocalReasoningCapability.capability(forModelId: modelId).defaultThinkingOn
    }
}

// MARK: - DSV4 Reasoning Profile

/// DeepSeek-V4 / DSV4 Flash JANG bundles use vmlx's dedicated DSV4 encoder
/// rather than a generic `enable_thinking`-only Jinja path. The runtime has
/// three intentional modes:
/// - instruct: closed `</think>` assistant tail, answer on content rail
/// - reasoning: open `<think>` assistant tail, normal reasoning split
/// - max: raw DSV4 max reasoning effort; Osaurus passes it through to vmlx
///   unchanged so runtime issues are fixed at the engine layer, not hidden here
struct DSV4ReasoningProfile: ModelProfile {
    static let displayName = "DSV4 Reasoning"

    static func matches(modelId: String) -> Bool {
        ModelFamilyNames.isDSV4Family(modelId)
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Reasoning Mode"),
            icon: "brain.head.profile",
            kind: .segmented([
                ModelOptionSegment(id: "instruct", label: L("Instruct")),
                ModelOptionSegment(id: "high", label: L("Reasoning")),
                ModelOptionSegment(id: "max", label: L("Max")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("instruct")
    ]

    static func normalizedEffort(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "instruct", "chat", "none", "no_think", "off", "disabled", "false":
            return "instruct"
        case "max", "maximum":
            return "max"
        case "reasoning", "think", "thinking", "high", "medium", "low", "true":
            return "high"
        default:
            return "instruct"
        }
    }
}

// MARK: - OpenAI Reasoning Profiles

/// Shared helpers for the OpenAI static profiles. The documented
/// `reasoning_effort` contract is version-specific (audited against the
/// OpenAI reasoning guide + Azure compatibility matrix, 2026-07):
/// - o1/o3/o4: `low`/`medium`/`high` only — `minimal` and `none` are
///   rejected.
/// - Original gpt-5 family (gpt-5, -mini, -nano, -codex): `minimal` through
///   `high`; no `none`. (`gpt-5-pro` accepts only `high`; not modeled
///   separately — the picker still offers the shared set for it.)
/// - gpt-5.1: replaces `minimal` with `none`; no `xhigh`.
/// - gpt-5.2 through gpt-5.5: `none` through `xhigh`.
/// - gpt-5.6: `none` through `max` — carried by the documented public
///   capability profile on the official route (`ModelReasoningCapabilities
///   .officialOpenAIGPT56`) and the live Codex catalog; on custom
///   OpenAI-compatible hosts it falls through to the 5.2+ static set, which
///   is never assumed to include `max`.
private enum OpenAIModelVersion {
    static func bare(_ modelId: String) -> String {
        modelId.lowercased().split(separator: "/").last.map(String.init)
            ?? modelId.lowercased()
    }

    /// The minor version N for a "gpt-5.N…" id; nil for the original gpt-5
    /// family and non-gpt-5 ids.
    static func gpt5Minor(_ modelId: String) -> Int? {
        let bare = Self.bare(modelId)
        guard bare.hasPrefix("gpt-5.") else { return nil }
        let digits = bare.dropFirst("gpt-5.".count).prefix(while: \.isNumber)
        return Int(digits)
    }
}

/// OpenAI o-series reasoning models (o1/o3/o4, including -mini/-pro
/// variants) — `low`/`medium`/`high` only. `minimal` is rejected by the
/// API for these ids.
struct OpenAIOSeriesReasoningProfile: ModelProfile {
    static let displayName = "Reasoning"

    static func matches(modelId: String) -> Bool {
        let bare = OpenAIModelVersion.bare(modelId)
        return ["o1", "o3", "o4"].contains { bare.hasPrefix($0) }
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Reasoning Effort"),
            icon: "brain",
            kind: .segmented([
                ModelOptionSegment(id: "low", label: L("Low")),
                ModelOptionSegment(id: "medium", label: L("Medium")),
                ModelOptionSegment(id: "high", label: L("High")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("medium")
    ]
}

/// GPT-5.1 — `none`/`low`/`medium`/`high`. 5.1 dropped `minimal` in favor
/// of `none` and does not accept `xhigh` (only the codex-max slug did).
/// The API default is `none`.
struct OpenAIGPT51ReasoningProfile: ModelProfile {
    static let displayName = "Reasoning"

    static func matches(modelId: String) -> Bool {
        OpenAIModelVersion.gpt5Minor(modelId) == 1
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Reasoning Effort"),
            icon: "brain",
            kind: .segmented([
                ModelOptionSegment(id: "none", label: L("None")),
                ModelOptionSegment(id: "low", label: L("Low")),
                ModelOptionSegment(id: "medium", label: L("Medium")),
                ModelOptionSegment(id: "high", label: L("High")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("none")
    ]
}

/// GPT-5.2 and later minors (5.2–5.5, and 5.6+ on custom hosts where the
/// documented public capability profile doesn't apply) — `none` through
/// `xhigh`, defaulting to `medium`. `max` is never offered statically; it
/// requires the documented 5.6 public profile or live Codex catalog.
struct OpenAIGPT52PlusReasoningProfile: ModelProfile {
    static let displayName = "Reasoning"

    static func matches(modelId: String) -> Bool {
        guard let minor = OpenAIModelVersion.gpt5Minor(modelId) else { return false }
        return minor >= 2
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Reasoning Effort"),
            icon: "brain",
            kind: .segmented([
                ModelOptionSegment(id: "none", label: L("None")),
                ModelOptionSegment(id: "low", label: L("Low")),
                ModelOptionSegment(id: "medium", label: L("Medium")),
                ModelOptionSegment(id: "high", label: L("High")),
                ModelOptionSegment(id: "xhigh", label: L("Extra High")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("medium")
    ]
}

/// Generic OpenAI reasoning fallback. Registered after the version-specific
/// profiles above, so in practice it resolves only for the original gpt-5
/// family (gpt-5, -mini, -nano, -codex), which accepts `minimal` through
/// `high`. Its broad `matches` (any o1/o3/o4/gpt-5* id) is intentionally
/// kept: `RemoteProviderService` uses it as the "OpenAI reasoning model"
/// wire predicate (max_completion_tokens, temperature/top_p stripping).
struct OpenAIReasoningProfile: ModelProfile {
    static let displayName = "Reasoning"

    private static let reasoningModelPrefixes = ["o1", "o3", "o4", "gpt-5"]

    static func matches(modelId: String) -> Bool {
        let bare = OpenAIModelVersion.bare(modelId)
        return reasoningModelPrefixes.contains { bare.hasPrefix($0) }
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Reasoning Effort"),
            icon: "brain",
            kind: .segmented([
                ModelOptionSegment(id: "minimal", label: L("Minimal")),
                ModelOptionSegment(id: "low", label: L("Low")),
                ModelOptionSegment(id: "medium", label: L("Medium")),
                ModelOptionSegment(id: "high", label: L("High")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("medium")
    ]
}

// MARK: - Mistral Reasoning Profile

/// Mistral's adjustable-reasoning models — supports reasoning effort control
/// via the `reasoning_effort` request field. Per Mistral's reasoning docs
/// (audited 2026-07), adjustable reasoning exists ONLY on `mistral-small-*`
/// and `mistral-medium-3-5`/`3.5`; plain `mistral-medium-latest`,
/// `mistral-large-*`, and the always-reasoning `magistral-*` family all
/// reject the parameter with HTTP 400, so the match must not widen to the
/// whole `mistral-medium` prefix.
struct MistralReasoningProfile: ModelProfile {
    static let displayName = "Reasoning Effort"

    static func matches(modelId: String) -> Bool {
        let bare =
            modelId.lowercased().split(separator: "/").last.map(String.init)
            ?? modelId.lowercased()
        return bare.hasPrefix("mistral-small") || bare.hasPrefix("mistral-medium-3")
    }

    // Mistral's chat-completions `reasoning_effort` accepts only `none` and
    // `high` on mistral-small-latest / mistral-medium-3.5; `low` and `medium`
    // are rejected with HTTP 400 (`invalid_request_invalid_args`).
    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Reasoning Effort"),
            icon: "brain",
            kind: .segmented([
                ModelOptionSegment(id: "none", label: L("None")),
                ModelOptionSegment(id: "high", label: L("High")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("high")
    ]
}

// MARK: - Qwen Thinking Profile

/// Qwen3 / Qwen3.5 local models — supports disabling thinking via `enable_thinking` chat template kwarg.
/// Excludes Qwen3-Coder variants which are non-thinking only.
struct QwenThinkingProfile: ModelProfile {
    static let displayName = "Qwen Thinking"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("qwen3") && !lower.contains("coder")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Nemotron-3 Thinking Profile

/// Nemotron-3 reasoning models — `model_type=nemotron_h` hybrid
/// Mamba+Attn+MoE bundles whose chat template reads an `enable_thinking`
/// kwarg. Osaurus exposes the toggle but does not synthesize a reasoning mode:
/// absent values must let the model bundle/runtime decide.
///
/// Match excludes `coder` variants (none ship today, but mirroring
/// `QwenThinkingProfile`'s shape for consistency if NVIDIA publishes one).
struct NemotronThinkingProfile: ModelProfile {
    static let displayName = "Nemotron Thinking"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return ModelFamilyNames.isNemotronThinkingFamily(modelId) && !lower.contains("coder")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Laguna Thinking Profile

/// Poolside Laguna (`model_type=laguna`) — agentic-coding 33B/3B-active MoE
/// whose chat template (`laguna_glm_thinking_v5/chat_template.jinja`)
/// reads an `enable_thinking` Jinja kwarg. Osaurus exposes the native switch
/// while leaving absent values absent so the shipped template/runtime defaults
/// remain authoritative.
///
/// Match is `laguna` substring lower-cased; covers any future Laguna
/// variant (e.g. Laguna-S, Laguna-M) without a registry edit. There is
/// no `coder` exclusion because Laguna IS the coder family — exclusion
/// would be a no-op.
struct LagunaThinkingProfile: ModelProfile {
    static let displayName = "Laguna Thinking"

    static func matches(modelId: String) -> Bool {
        return modelId.lowercased().contains("laguna")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Hy3 Reasoning Profile

/// Tencent Hunyuan v3 / Hy3 (`model_type=hy_v3`) uses a `reasoning_effort`
/// chat-template kwarg instead of the boolean `enable_thinking` convention.
/// The shipped template defaults to `no_think` and opens `<think>` only for
/// `low` / `high`, so expose the native effort values rather than mapping it
/// through the generic Disable Thinking toggle.
struct Hy3ReasoningProfile: ModelProfile {
    static let displayName = "Hy3 Reasoning"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("hy3")
            || lower.contains("hy-v3")
            || lower.contains("hy_v3")
            || lower.contains("hunyuan-v3")
            || lower.contains("hunyuan_v3")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Reasoning Effort"),
            icon: "brain.head.profile",
            kind: .segmented([
                ModelOptionSegment(id: "no_think", label: L("Off")),
                ModelOptionSegment(id: "low", label: L("Low")),
                ModelOptionSegment(id: "high", label: L("High")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("no_think")
    ]

    static func normalizedEffort(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "no_think", "none", "off", "disabled", "false":
            return "no_think"
        case "low":
            return "low"
        case "high", "medium", "max", "maximum":
            return "high"
        default:
            return "no_think"
        }
    }
}

// MARK: - Ling Runtime Profile

/// Ling-2.6 Flash (`model_type=bailing_hybrid`) uses an `enable_thinking`
/// chat-template kwarg to choose the upstream "detailed thinking on/off"
/// directive. Osaurus only forwards explicit user/API choices; this is a
/// template mode, not an output-shaping guard.
struct LingRuntimeProfile: ModelProfile {
    static let displayName = "Ling"

    static func matches(modelId: String) -> Bool {
        ModelFamilyNames.isLingFamily(modelId)
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Zaya Thinking Profile

/// ZAYA1 (Zyphra; `model_type=zaya`) — hybrid CCA-attention bundles
/// (BF16 base + JANGTQ2 / JANGTQ4 / MXFP4 routed-expert variants). ZAYA is
/// reasoning-capable, but its template default is a closed/no-thinking
/// assistant prefix (`think_in_template=false`): callers may opt in with
/// `enable_thinking=true` to open a reasoning block. The profile exposes the
/// standard Disable Thinking toggle without injecting a default into requests.
struct ZayaThinkingProfile: ModelProfile {
    static let displayName = "Zaya Thinking"

    static func matches(modelId: String) -> Bool {
        ModelFamilyNames.isZayaFamily(modelId)
            && !ModelFamilyNames.isZayaVLFamily(modelId)
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Gemma 4 Runtime Profile

/// Gemma-4 chat templates expose an `enable_thinking` kwarg and pipe-wrapped
/// `<|think|>` markers. Expose the same chat-input Thinking chip as other
/// local reasoning models, but do not synthesize a hidden request default:
/// omitted options still let the model bundle/runtime decide.
struct Gemma4RuntimeProfile: ModelProfile {
    static let displayName = "Gemma 4"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("gemma-4") || lower.contains("gemma4")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Auto Thinking Profile (chat-template driven)

/// Fallback profile that activates for locally-installed models whose chat
/// template exposes an `enable_thinking` kwarg and uses thinking markers the
/// runtime can process. Registered last so that explicit family profiles
/// (Qwen, Venice, etc.) still win when they match.
struct AutoThinkingProfile: ModelProfile {
    static let displayName = "Thinking"

    static func matches(modelId: String) -> Bool {
        LocalReasoningCapability.capability(forModelId: modelId).isToggleableThinking
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: false)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(false)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Shared Segments

private let geminiAspectRatioSegments: [ModelOptionSegment] = [
    ModelOptionSegment(id: "auto", label: L("Auto")),
    ModelOptionSegment(id: "1:1", label: "1:1"),
    ModelOptionSegment(id: "2:3", label: "2:3"),
    ModelOptionSegment(id: "3:2", label: "3:2"),
    ModelOptionSegment(id: "3:4", label: "3:4"),
    ModelOptionSegment(id: "4:3", label: "4:3"),
    ModelOptionSegment(id: "4:5", label: "4:5"),
    ModelOptionSegment(id: "5:4", label: "5:4"),
    ModelOptionSegment(id: "9:16", label: "9:16"),
    ModelOptionSegment(id: "16:9", label: "16:9"),
    ModelOptionSegment(id: "21:9", label: "21:9"),
]

private let geminiExtendedAspectRatioSegments: [ModelOptionSegment] = [
    ModelOptionSegment(id: "auto", label: L("Auto")),
    ModelOptionSegment(id: "1:1", label: "1:1"),
    ModelOptionSegment(id: "1:4", label: "1:4"),
    ModelOptionSegment(id: "1:8", label: "1:8"),
    ModelOptionSegment(id: "2:3", label: "2:3"),
    ModelOptionSegment(id: "3:2", label: "3:2"),
    ModelOptionSegment(id: "3:4", label: "3:4"),
    ModelOptionSegment(id: "4:1", label: "4:1"),
    ModelOptionSegment(id: "4:3", label: "4:3"),
    ModelOptionSegment(id: "4:5", label: "4:5"),
    ModelOptionSegment(id: "5:4", label: "5:4"),
    ModelOptionSegment(id: "8:1", label: "8:1"),
    ModelOptionSegment(id: "9:16", label: "9:16"),
    ModelOptionSegment(id: "16:9", label: "16:9"),
    ModelOptionSegment(id: "21:9", label: "21:9"),
]

private let geminiOutputTypeSegments: [ModelOptionSegment] = [
    ModelOptionSegment(id: "textAndImage", label: L("Text & Image")),
    ModelOptionSegment(id: "imageOnly", label: L("Image Only")),
]

// MARK: - Gemini 3.1 Flash Image Profile (Nano Banana 2)

/// Gemini 3.1 Flash Image Preview — supports extended aspect ratios
/// (including 1:4/4:1/1:8/8:1), resolution (512px/1K/2K/4K), and output
/// type. Excludes the Lite variant: per the Gemini image docs (audited
/// 2026-07) `gemini-3.1-flash-lite-image` supports only 1K output, so
/// offering it this resolution set would send values the API rejects; Lite
/// intentionally matches no profile and runs on API defaults.
struct Gemini31FlashImageProfile: ModelProfile {
    static let displayName = "Image Generation (3.1 Flash)"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("gemini-3.1") && lower.contains("flash") && lower.contains("image")
            && !lower.contains("lite")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "aspectRatio",
            label: L("Aspect Ratio"),
            icon: "aspectratio",
            kind: .segmented(geminiExtendedAspectRatioSegments)
        ),
        ModelOptionDefinition(
            id: "imageSize",
            label: L("Resolution"),
            icon: "arrow.up.right.and.arrow.down.left",
            kind: .segmented([
                ModelOptionSegment(id: "auto", label: L("Auto")),
                ModelOptionSegment(id: "512px", label: "0.5K"),
                ModelOptionSegment(id: "1K", label: "1K"),
                ModelOptionSegment(id: "2K", label: "2K"),
                ModelOptionSegment(id: "4K", label: "4K"),
            ])
        ),
        ModelOptionDefinition(
            id: "outputType",
            label: L("Output"),
            icon: "photo.on.rectangle",
            kind: .segmented(geminiOutputTypeSegments)
        ),
    ]

    static let defaults: [String: ModelOptionValue] = [
        "aspectRatio": .string("auto"),
        "imageSize": .string("auto"),
        "outputType": .string("textAndImage"),
    ]
}

// MARK: - Gemini 3 Pro Image Profile (Nano Banana Pro)

/// Gemini 3 Pro Image Preview — supports aspect ratio, resolution (1K/2K/4K), and output type.
struct GeminiProImageProfile: ModelProfile {
    static let displayName = "Image Generation (Pro)"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("nano-banana")
            || (lower.contains("gemini-3") && lower.contains("pro") && lower.contains("image"))
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "aspectRatio",
            label: L("Aspect Ratio"),
            icon: "aspectratio",
            kind: .segmented(geminiAspectRatioSegments)
        ),
        ModelOptionDefinition(
            id: "imageSize",
            label: L("Resolution"),
            icon: "arrow.up.right.and.arrow.down.left",
            kind: .segmented([
                ModelOptionSegment(id: "auto", label: L("Auto")),
                ModelOptionSegment(id: "1K", label: "1K"),
                ModelOptionSegment(id: "2K", label: "2K"),
                ModelOptionSegment(id: "4K", label: "4K"),
            ])
        ),
        ModelOptionDefinition(
            id: "outputType",
            label: L("Output"),
            icon: "photo.on.rectangle",
            kind: .segmented(geminiOutputTypeSegments)
        ),
    ]

    static let defaults: [String: ModelOptionValue] = [
        "aspectRatio": .string("auto"),
        "imageSize": .string("auto"),
        "outputType": .string("textAndImage"),
    ]
}

// MARK: - Gemini Flash Image Profile (Nano Banana)

/// Gemini 2.5 Flash Image — supports aspect ratio and output type (no resolution control).
struct GeminiFlashImageProfile: ModelProfile {
    static let displayName = "Image Generation"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("flash") && lower.contains("image") && !lower.contains("gemini-3")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "aspectRatio",
            label: L("Aspect Ratio"),
            icon: "aspectratio",
            kind: .segmented(geminiAspectRatioSegments)
        ),
        ModelOptionDefinition(
            id: "outputType",
            label: L("Output"),
            icon: "photo.on.rectangle",
            kind: .segmented(geminiOutputTypeSegments)
        ),
    ]

    static let defaults: [String: ModelOptionValue] = [
        "aspectRatio": .string("auto"),
        "outputType": .string("textAndImage"),
    ]
}

// MARK: - Venice AI Model Profile

/// Venice AI models — supports web search, thinking control, and Venice system prompt toggle.
/// See https://docs.venice.ai/api-reference/api-spec for venice_parameters details.
///
/// Match caveat: picker model ids are prefixed with a slug of the
/// user-visible provider NAME (`RemoteProviderManager.cachedAvailableModels`),
/// so `venice-ai/` relies on the provider keeping its preset name
/// "Venice AI". A renamed Venice provider loses these options in the UI;
/// the wire side is unaffected because `buildVeniceParameters` gates on the
/// venice.ai host, not this prefix.
struct VeniceModelProfile: ModelProfile {
    static let displayName = "Venice AI"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.hasPrefix("venice-ai/")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "enableWebSearch",
            label: L("Web Search"),
            icon: "magnifyingglass",
            kind: .segmented([
                ModelOptionSegment(id: "off", label: L("Off")),
                ModelOptionSegment(id: "on", label: L("On")),
                ModelOptionSegment(id: "auto", label: L("Auto")),
            ])
        ),
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        ),
        ModelOptionDefinition(
            id: "includeVeniceSystemPrompt",
            label: L("Venice System Prompt"),
            icon: "text.bubble",
            kind: .toggle(default: true)
        ),
    ]

    static let defaults: [String: ModelOptionValue] = [
        "enableWebSearch": .string("off"),
        "disableThinking": .bool(true),
        "includeVeniceSystemPrompt": .bool(true),
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}
