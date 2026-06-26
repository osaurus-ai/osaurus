//
//  FeatureTelemetry.swift
//  osaurus
//
//  Maps product KPI moments (the primary `message_sent` metric plus a small
//  set of engagement / feature-adoption signals) onto `TelemetryService`
//  events. Kept separate from the generic service — exactly like
//  `OnboardingTelemetry` — so the event names and property shapes the
//  dashboards query live in one auditable place and stay unit-testable.
//
//  Privacy posture (see docs/TELEMETRY.md): every event here is a count or a
//  low-cardinality enum. No prompts, completions, message text, tool
//  arguments, agent names, file paths, keys, or token counts are ever
//  attached. Built-in catalog identifiers (Foundation + local MLX model ids,
//  the `RemoteProviderType` enum) are safe to send verbatim; user-typed
//  remote model ids are reduced to `provider_type` + a salted hash and are
//  never sent in plaintext. All sends still flow through the opt-in,
//  consent-gated `TelemetryService.track`.
//

import Aptabase
import Foundation

/// Stable, privacy-reviewed dimensions for a single `message_sent` event.
///
/// Derived synchronously inside `ChatEngine` (a nonisolated step, no main-actor
/// hop) and `Sendable`, so it can be handed to the `@MainActor` emitter via a
/// fire-and-forget `Task` without blocking dispatch.
struct MessageTelemetryInfo: Sendable {
    /// Originating surface: `chat_ui` | `http_api` | `plugin`.
    let source: String
    /// Inference backend category: `foundation` | `local` | `remote`.
    let modelSource: String
    /// Exact model id — ONLY populated for built-in `foundation`/`local`
    /// routes (curated catalog, non-identifying). `nil` for remote.
    let model: String?
    /// `foundation` | `mlx` | the `RemoteProviderType` raw value
    /// (`openai`/`anthropic`/`gemini`/...).
    let providerType: String
    /// Salted, truncated hash of the remote model id — remote routes only,
    /// `nil` otherwise. Lets distinct custom models be counted without the
    /// raw string.
    let modelHash: String?
    /// Whether this turn came from an autonomous agent run (the
    /// `/agents/{id}/run` endpoint). Plain completions and interactive Chat
    /// are `false`; agent runs are also counted in full by `agent_run`.
    let isAgent: Bool
    /// Whether the caller requested a streaming response.
    let stream: Bool
    /// The brain source the user picked during onboarding (`local` | `hosted`
    /// | `provider_key`), attached only to chat-UI sends so the funnel can
    /// join the path choice to the first message. `nil` for non-chat sources
    /// and for installs that predate the choice. Low-cardinality enum.
    let brainSource: String?

    init(
        source: String,
        modelSource: String,
        model: String?,
        providerType: String,
        modelHash: String?,
        isAgent: Bool,
        stream: Bool,
        brainSource: String? = nil
    ) {
        self.source = source
        self.modelSource = modelSource
        self.model = model
        self.providerType = providerType
        self.modelHash = modelHash
        self.isAgent = isAgent
        self.stream = stream
        self.brainSource = brainSource
    }
}

@MainActor
enum FeatureTelemetry {
    // The `service` parameter defaults to the shared instance for app use;
    // tests inject a recording service to assert the exact event name and
    // properties each KPI moment produces.

    // MARK: - Engagement (primary)

    /// The headline metric: one top-level user/client-initiated chat request.
    /// Tool-loop continuations are intentionally excluded by the caller (see
    /// `ChatEngine`) so an agent's internal turns don't inflate the count.
    static func messageSent(_ info: MessageTelemetryInfo, service: TelemetryService = .shared) {
        var props: [String: Value] = [
            "source": info.source,
            "model_source": info.modelSource,
            "provider_type": info.providerType,
            "is_agent": info.isAgent,
            "stream": info.stream,
        ]
        if let model = info.model { props["model"] = model }
        if let modelHash = info.modelHash { props["model_hash"] = modelHash }
        if let brainSource = info.brainSource { props["brain_source"] = brainSource }
        service.track("message_sent", props)
    }

    /// A new chat conversation was started from the UI. Engagement breadth
    /// signal; carries no titles or ids.
    static func chatSessionStarted(service: TelemetryService = .shared) {
        service.track("chat_session_started")
    }

    // MARK: - Brain source (onboarding → first message join)

    /// Persisted key holding the onboarding brain choice (`local` | `hosted` |
    /// `provider_key`). Read nonisolated by `messageInfo`; written on
    /// onboarding finish. `nonisolated` so the `ChatEngine` actor can read it
    /// without a main-actor hop.
    nonisolated static let brainSourceDefaultsKey = "ai.osaurus.onboarding.brain_source"

    /// The brain source recorded at onboarding finish, or `nil` for installs
    /// that completed onboarding before this choice existed.
    nonisolated static func persistedBrainSource(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: brainSourceDefaultsKey)
    }

    /// Persist the onboarding brain choice so the next `message_sent` from the
    /// chat UI can carry the `brain_source` dimension. No-op for an empty/`nil`
    /// value so a half-finished run can't clobber a prior choice with "".
    static func recordOnboardingBrainSource(_ value: String?, defaults: UserDefaults = .standard) {
        guard let value, !value.isEmpty else { return }
        defaults.set(value, forKey: brainSourceDefaultsKey)
    }

    // MARK: - Prepaid balance / top-up

    /// The user kicked off a credits top-up (a Checkout session was created and
    /// is about to open). Count only — no amount or identifiers.
    static func balanceTopUpInitiated(service: TelemetryService = .shared) {
        service.track("balance_topup_initiated")
    }

    /// A previously initiated top-up was confirmed by an observed balance
    /// increase after returning from Checkout (best-effort; not fired on mere
    /// sheet dismissal). Count only.
    static func balanceTopUpSucceeded(service: TelemetryService = .shared) {
        service.track("balance_topup_succeeded")
    }

    // MARK: - First-run activation

    // Bridges the gap the onboarding funnel can't see: `onboarding_completed`
    // fires, then nothing — did the user ever reach chat, and did they ever
    // send a message? Two one-shot events answer that. Both are persisted
    // flags (not in-memory) because the first message often happens in a
    // later session than the one that finished onboarding.

    /// Armed when onboarding completes; cleared when `first_time_chat_shown`
    /// fires. Scoping the event to an explicit arm (rather than "first chat
    /// window ever") keeps users who consented via the post-launch upgrade
    /// prompt — without a fresh onboarding run — out of the activation funnel.
    private static let firstChatShownPendingKey = "firstTimeChatShownPending"

    /// Set once `first_time_chat_shown` has fired, ever. Blocks re-arming so
    /// re-running onboarding (help button, version bump) can't fire it again.
    private static let firstChatShownTrackedKey = "firstTimeChatShownTracked"

    /// Set once `first_time_chat_used` has fired, ever.
    private static let firstChatUsedTrackedKey = "firstTimeChatUsedTracked"

    /// Arm the `first_time_chat_shown` one-shot. Called when onboarding
    /// completes (any path — the chat window opens right after both the
    /// finish CTA and an early close). No-op once the event has ever fired,
    /// keeping it strictly once per install.
    static func armFirstTimeChatShown(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: firstChatShownTrackedKey) else { return }
        defaults.set(true, forKey: firstChatShownPendingKey)
    }

    /// The first chat window became visible after completing onboarding.
    /// Call on every window show — the persisted arm + tracked flags make it
    /// emit at most once per install. No properties.
    static func firstTimeChatShown(
        service: TelemetryService = .shared,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.bool(forKey: firstChatShownPendingKey) else { return }
        defaults.set(false, forKey: firstChatShownPendingKey)
        defaults.set(true, forKey: firstChatShownTrackedKey)
        service.track("first_time_chat_shown")
    }

    /// The first message this install ever sent from the chat UI. Call on
    /// every chat-UI send — the persisted flag makes it emit exactly once.
    /// No properties; the regular `message_sent` carries the dimensions.
    static func firstTimeChatUsed(
        service: TelemetryService = .shared,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: firstChatUsedTrackedKey) else { return }
        defaults.set(true, forKey: firstChatUsedTrackedKey)
        service.track("first_time_chat_used")
    }

    /// An agent run was initiated. `source` is `http_api` (the
    /// `/agents/{id}/run` endpoint) or `dispatch` (background / scheduled /
    /// plugin dispatch). No agent id or name is attached.
    static func agentRun(source: String, service: TelemetryService = .shared) {
        service.track("agent_run", ["source": source])
    }

    /// A Computer Use run finished. Every dimension is a coarse, non-identifying
    /// bucket or enum — never the goal text, app name, on-screen content, or
    /// raw counts. Full-fidelity per-app/per-tier analysis happens locally in
    /// the OsaurusEvals suite, not here. `outcome` is the `RunOutcome` token
    /// (`done` | `gave_up` | `dead_end` | `step_cap` | `interrupted` |
    /// `failed`).
    static func computerUseRun(
        _ metrics: ComputerUseRunMetrics,
        outcome: String,
        service: TelemetryService = .shared
    ) {
        let props: [String: Value] = [
            "outcome": outcome,
            "max_tier": metrics.maxTier.rawValue,
            "steps_bucket": ComputerUseRunMetrics.countBucket(metrics.steps),
            "confirms_bucket": ComputerUseRunMetrics.countBucket(metrics.confirmsRequested),
            "ax_resolvable": ComputerUseRunMetrics.rateBucket(metrics.axResolvableRate),
            "verify_pass": ComputerUseRunMetrics.rateBucket(metrics.verifyPassRate),
            "had_dead_end": metrics.deadEnds > 0,
            "had_block": metrics.blocked > 0,
            "cloud_vision_used": metrics.cloudVisionUsed,
        ]
        service.track("computer_use_run", props)
    }

    // MARK: - Lifecycle / retention

    /// The local server transitioned to running — an activation/retention
    /// signal. No port or address is attached.
    static func serverStarted(service: TelemetryService = .shared) {
        service.track("server_started")
    }

    // MARK: - Feature adoption / scope

    /// A model finished downloading. The model id comes from the curated
    /// catalog so it is safe to send; the rest are coarse, non-identifying
    /// descriptors.
    static func modelDownloaded(
        model: String,
        parameterCount: String?,
        quantization: String?,
        isVLM: Bool,
        service: TelemetryService = .shared
    ) {
        var props: [String: Value] = [
            "model": model,
            "is_vlm": isVLM,
        ]
        if let parameterCount { props["param_count"] = parameterCount }
        if let quantization { props["quantization"] = quantization }
        service.track("model_downloaded", props)
    }

    /// A remote inference provider was configured. Only the provider TYPE (a
    /// closed enum) is sent — never the user-chosen provider name, URL, or
    /// key.
    static func remoteProviderAdded(providerType: String, service: TelemetryService = .shared) {
        service.track("remote_provider_added", ["provider_type": providerType])
    }

    /// An MCP (tool) provider was configured. Only the transport kind
    /// (`http` | `stdio`) is sent — never the command, URL, or args.
    static func mcpProviderAdded(transport: String, service: TelemetryService = .shared) {
        service.track("mcp_provider_added", ["transport": transport])
    }

    /// A user-created agent was added. Count only — no name, prompt, or
    /// configuration.
    static func agentCreated(service: TelemetryService = .shared) {
        service.track("agent_created")
    }

    // MARK: - Derivation helpers

    /// Whether a chat request counts as a new top-level message for the
    /// `message_sent` KPI. True only when the request's last message is a
    /// `user` turn. Tool-loop continuations (agent-run server loop, Chat UI
    /// tool loop, plugin loops) re-enter with a trailing `tool`/`assistant`
    /// message and so return `false`, which is what keeps a multi-step answer
    /// from counting as multiple messages. Inspects only the role enum —
    /// never message content.
    nonisolated static func isPrimaryUserTurn(_ messages: [ChatMessage]) -> Bool {
        messages.last?.role == "user"
    }

    /// Stable, snake_case token for the inference surface. Decoupled from
    /// `RequestSource.rawValue` (which is display copy like `"Chat UI"`) so
    /// the analytics value never shifts if that display string is localized
    /// or reworded.
    nonisolated static func sourceToken(_ source: InferenceSource) -> String {
        switch source {
        case .chatUI: return "chat_ui"
        case .httpAPI: return "http_api"
        case .plugin: return "plugin"
        case .p2p: return "p2p"
        }
    }

    /// Derive the privacy-reviewed `message_sent` dimensions from a resolved
    /// route. `nonisolated` so the `ChatEngine` actor can call it directly;
    /// it only reads `Sendable`, nonisolated state (`RemoteProviderService`'s
    /// immutable `provider`).
    nonisolated static func messageInfo(
        service: ModelService,
        effectiveModel: String,
        source: InferenceSource,
        isAgent: Bool,
        stream: Bool
    ) -> MessageTelemetryInfo {
        let modelSource: String
        let model: String?
        let providerType: String
        let modelHash: String?

        if let remote = service as? RemoteProviderService {
            // User-configured remote: omit the (possibly identifying) model
            // id, keep the closed-enum provider type, and hash the id so
            // distinct custom models stay countable.
            modelSource = "remote"
            model = nil
            providerType = remote.provider.providerType.rawValue
            modelHash = TelemetryService.anonymizedRemoteId(effectiveModel)
        } else if service.id == FoundationModelService.serviceId {
            modelSource = "foundation"
            model = effectiveModel
            providerType = "foundation"
            modelHash = nil
        } else {
            // Local MLX catalog model — id is curated and safe to send.
            modelSource = "local"
            model = effectiveModel
            providerType = "mlx"
            modelHash = nil
        }

        // Attach the onboarding brain choice only to chat-UI sends — it's a
        // funnel join for "did the user who picked path X send a message", and
        // it would be misleading on HTTP-API / plugin traffic.
        let isChatUI: Bool = {
            if case .chatUI = source { return true }
            return false
        }()
        let brainSource = isChatUI ? persistedBrainSource() : nil

        return MessageTelemetryInfo(
            source: sourceToken(source),
            modelSource: modelSource,
            model: model,
            providerType: providerType,
            modelHash: modelHash,
            isAgent: isAgent,
            stream: stream,
            brainSource: brainSource
        )
    }
}
