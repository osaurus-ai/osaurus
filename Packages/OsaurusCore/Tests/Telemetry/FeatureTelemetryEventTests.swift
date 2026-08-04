//
//  FeatureTelemetryEventTests.swift
//  osaurusTests
//
//  Locks the exact event names and property shapes the KPI dashboards query
//  for the product-engagement events defined in `FeatureTelemetry` — most
//  importantly the primary `message_sent` metric. Mirrors the approach in
//  `OnboardingTelemetryEventTests`: a recording `TelemetryService` (granted +
//  started) captures sends synchronously, with no SDK, real key, or
//  `.standard` involvement.
//
//  Also covers the privacy-critical pieces: the remote-id hashing helper, the
//  built-in-vs-remote dimension derivation, the tool-loop de-dup rule, and
//  that feature events stay consent-gated.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct FeatureTelemetryEventTests {

    /// One emitted event, props boxed to `Any` so assertions can cast to
    /// concrete types without naming the Aptabase `Value` protocol.
    private struct Event {
        let name: String
        let props: [String: Any]
    }

    private final class Recorder {
        var events: [Event] = []
    }

    /// Drops the global `total_memory_gb` bucket (attached to every event by
    /// `TelemetryService.track`) so per-event shape assertions stay focused on
    /// the event-specific props.
    private func business(_ props: [String: Any]) -> [String: Any] {
        props.filter { $0.key != "total_memory_gb" }
    }

    /// A granted + started service whose sends are captured.
    private func makeRecordingService() -> (TelemetryService, Recorder, () -> Void) {
        let suiteName = "feature-telemetry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let recorder = Recorder()
        let service = TelemetryService(
            defaults: defaults,
            emit: { name, props in
                recorder.events.append(Event(name: name, props: props.mapValues { $0 as Any }))
            }
        )
        service.markStartedForTesting()
        service.setEnabled(true)  // granted → emit immediately
        return (service, recorder, { defaults.removePersistentDomain(forName: suiteName) })
    }

    /// Minimal `ModelService` stub — only `id` matters for dimension
    /// derivation; the generation methods are never invoked here.
    private struct StubService: ModelService {
        let id: String
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { true }
        func generateOneShot(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?
        ) async throws -> String { "" }
        func streamDeltas(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?,
            stopSequences: [String]
        ) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    // MARK: - message_sent shapes

    @Test func messageSent_local_includes_model_and_omits_hash() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        let info = FeatureTelemetry.messageInfo(
            service: StubService(id: "mlx"),
            effectiveModel: "mlx-community/Qwen2.5-7B-4bit",
            source: .chatUI,
            isAgent: false,
            stream: true
        )
        FeatureTelemetry.messageSent(info, service: service)

        #expect(rec.events.count == 1)
        let event = rec.events[0]
        #expect(event.name == "message_sent")
        #expect(event.props["source"] as? String == "chat_ui")
        #expect(event.props["model_source"] as? String == "local")
        #expect(event.props["provider_type"] as? String == "mlx")
        #expect(event.props["model"] as? String == "mlx-community/Qwen2.5-7B-4bit")
        #expect(event.props["is_agent"] as? Bool == false)
        #expect(event.props["stream"] as? Bool == true)
        // A generative local model (not an installed embedding bundle) is
        // chat-capability traffic.
        #expect(event.props["capability"] as? String == "chat")
        // Built-in models never carry a hash.
        #expect(event.props["model_hash"] == nil)
    }

    @Test func messageSent_foundation_uses_foundation_dimensions() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        let info = FeatureTelemetry.messageInfo(
            service: StubService(id: FoundationModelService.serviceId),
            effectiveModel: FoundationModelService.serviceId,
            source: .httpAPI,
            isAgent: false,
            stream: false
        )
        FeatureTelemetry.messageSent(info, service: service)

        let event = rec.events[0]
        #expect(event.props["source"] as? String == "http_api")
        #expect(event.props["model_source"] as? String == "foundation")
        #expect(event.props["provider_type"] as? String == "foundation")
        #expect(event.props["model"] as? String == "foundation")
        #expect(event.props["model_hash"] == nil)
        #expect(event.props["stream"] as? Bool == false)
        #expect(event.props["capability"] as? String == "chat")
    }

    /// Remote routes must NOT carry the raw model id in plaintext; they carry
    /// the closed-enum provider type plus a hash for distinct-counting.
    @Test func messageSent_remote_omits_model_and_carries_hash() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        let remoteModel = "acme-internal/legal-bot"
        let info = MessageTelemetryInfo(
            source: FeatureTelemetry.sourceToken(.plugin),
            modelSource: "remote",
            model: nil,
            providerType: "openai",
            modelHash: TelemetryService.anonymizedRemoteId(remoteModel),
            isAgent: true,
            stream: true
        )
        FeatureTelemetry.messageSent(info, service: service)

        let event = rec.events[0]
        #expect(event.props["source"] as? String == "plugin")
        #expect(event.props["model_source"] as? String == "remote")
        #expect(event.props["provider_type"] as? String == "openai")
        #expect(event.props["is_agent"] as? Bool == true)
        // The raw remote model id must never be present.
        #expect(event.props["model"] == nil)
        let hash = event.props["model_hash"] as? String
        #expect(hash != nil)
        #expect(hash != remoteModel)
        // Remote routes are always chat-capability traffic (the default).
        #expect(event.props["capability"] as? String == "chat")
    }

    // MARK: - capability dimension (model-TYPE check, not a name denylist)

    /// Builds an on-disk bundle directory with the given config.json so the
    /// classifier resolves it exactly like a real HF-cache/LM Studio import.
    private func makeBundle(config: [String: Any]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-telemetry-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config)
            .write(to: dir.appendingPathComponent("config.json"))
        return dir
    }

    /// Encoder-only bundles are classified `embedding` from config.json
    /// (`model_type` / `architectures`) — never from the model NAME, so a
    /// new potion size or a lowercase id variant can't reopen the hole a
    /// name denylist would leave.
    @Test func localModelCapability_classifies_embedding_bundle_by_model_type() throws {
        // minishlab/potion-* style model2vec static embedding bundle.
        let embeddingDir = try makeBundle(config: [
            "model_type": "model2vec",
            "architectures": ["StaticModel"],
        ])
        defer { try? FileManager.default.removeItem(at: embeddingDir) }

        #expect(
            FeatureTelemetry.localModelCapability(
                "minishlab/potion-base-32m",
                resolveBundleDirectory: { _ in embeddingDir }
            ) == "embedding"
        )
    }

    @Test func localModelCapability_keeps_generative_bundles_chat() throws {
        let chatDir = try makeBundle(config: [
            "model_type": "qwen2",
            "architectures": ["Qwen2ForCausalLM"],
        ])
        defer { try? FileManager.default.removeItem(at: chatDir) }

        #expect(
            FeatureTelemetry.localModelCapability(
                "mlx-community/Qwen2.5-7B-4bit",
                resolveBundleDirectory: { _ in chatDir }
            ) == "chat"
        )
    }

    /// An id that can't be resolved to an installed bundle stays `chat` —
    /// the classifier must never hide generative traffic behind a lookup
    /// miss.
    @Test func localModelCapability_defaults_to_chat_when_bundle_unresolvable() {
        #expect(
            FeatureTelemetry.localModelCapability(
                "not-installed/model",
                resolveBundleDirectory: { _ in nil }
            ) == "chat"
        )
    }

    // MARK: - brain_source dimension + persistence

    @Test func messageSent_includes_brain_source_when_present() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        let info = MessageTelemetryInfo(
            source: "chat_ui",
            modelSource: "remote",
            model: nil,
            providerType: "osaurusRouter",
            modelHash: nil,
            isAgent: false,
            stream: true,
            brainSource: "hosted"
        )
        FeatureTelemetry.messageSent(info, service: service)

        #expect(rec.events[0].props["brain_source"] as? String == "hosted")
    }

    @Test func messageSent_omits_brain_source_when_absent() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        // Default init leaves `brainSource` nil (non-chat sources only —
        // chat-UI sends always derive a value via `messageInfo`).
        let info = MessageTelemetryInfo(
            source: "http_api",
            modelSource: "local",
            model: "mlx-community/Qwen2.5-7B-4bit",
            providerType: "mlx",
            modelHash: nil,
            isAgent: false,
            stream: false
        )
        FeatureTelemetry.messageSent(info, service: service)

        #expect(rec.events[0].props["brain_source"] == nil)
    }

    /// Isolated defaults suite for brain-source persistence tests.
    private func makeBrainDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "feature-telemetry-brain-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func recordOnboardingBrainSource_persists_and_does_not_clobber() {
        let (defaults, cleanup) = makeBrainDefaults()
        defer { cleanup() }

        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == nil)

        FeatureTelemetry.recordOnboardingBrainSource("hosted", defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == "hosted")

        // A nil or empty write must not wipe a prior choice.
        FeatureTelemetry.recordOnboardingBrainSource(nil, defaults: defaults)
        FeatureTelemetry.recordOnboardingBrainSource("", defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == "hosted")
    }

    /// The vocabulary is a dashboard contract; a silent token rename would
    /// fork the dimension.
    @Test func brainSource_fallback_tokens_match_the_documented_contract() {
        #expect(FeatureTelemetry.brainSourceNone == "none")
        #expect(FeatureTelemetry.brainSourcePreChoice == "pre_choice")
        #expect(FeatureTelemetry.brainSourceUnknown == "unknown")
    }

    /// An onboarding run that ends without a commit records `none`, but only
    /// when nothing was persisted yet — a later early-closed re-run can't
    /// clobber a real choice (or a legacy `pre_choice` stamp).
    @Test func recordOnboardingBrainSourceAbsent_writes_none_only_when_unset() {
        let (defaults, cleanup) = makeBrainDefaults()
        defer { cleanup() }

        FeatureTelemetry.recordOnboardingBrainSourceAbsent(defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == "none")

        // A real commit on a later run overwrites the `none` placeholder…
        FeatureTelemetry.recordOnboardingBrainSource("local", defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == "local")

        // …but another early-closed run never clobbers the real choice.
        FeatureTelemetry.recordOnboardingBrainSourceAbsent(defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == "local")
    }

    /// Launch migration: only installs that completed onboarding before the
    /// brain choice existed get the `pre_choice` stamp — fresh installs and
    /// installs with a recorded choice are untouched. Idempotent.
    @Test func stampLegacyBrainSource_stamps_only_completed_installs_without_choice() {
        let (defaults, cleanup) = makeBrainDefaults()
        defer { cleanup() }

        // Fresh install (onboarding never completed) → nothing stamped;
        // onboarding's own writers handle it.
        FeatureTelemetry.stampLegacyBrainSourceIfNeeded(defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == nil)

        // Legacy install: onboarding completed, no choice recorded.
        defaults.set(true, forKey: "hasCompletedOnboarding")
        FeatureTelemetry.stampLegacyBrainSourceIfNeeded(defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == "pre_choice")

        // Idempotent across launches.
        FeatureTelemetry.stampLegacyBrainSourceIfNeeded(defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == "pre_choice")

        // A real re-run commit still wins, and the stamp never reverts it.
        FeatureTelemetry.recordOnboardingBrainSource("provider_key", defaults: defaults)
        FeatureTelemetry.stampLegacyBrainSourceIfNeeded(defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == "provider_key")
    }

    /// Chat-UI sends must always carry a `brain_source` value: the persisted
    /// choice when one exists, the explicit `unknown` fallback otherwise —
    /// omission would silently reopen the coverage gap. Non-chat sources
    /// stay bare.
    @Test func messageInfo_brain_source_is_total_for_chat_ui_sends() {
        let (defaults, cleanup) = makeBrainDefaults()
        defer { cleanup() }

        let unknownInfo = FeatureTelemetry.messageInfo(
            service: StubService(id: "mlx"),
            effectiveModel: "mlx-community/Qwen2.5-7B-4bit",
            source: .chatUI,
            isAgent: false,
            stream: true,
            defaults: defaults
        )
        #expect(unknownInfo.brainSource == "unknown")

        FeatureTelemetry.recordOnboardingBrainSource("hosted", defaults: defaults)
        let hostedInfo = FeatureTelemetry.messageInfo(
            service: StubService(id: "mlx"),
            effectiveModel: "mlx-community/Qwen2.5-7B-4bit",
            source: .chatUI,
            isAgent: false,
            stream: true,
            defaults: defaults
        )
        #expect(hostedInfo.brainSource == "hosted")

        // The dimension would be misleading on HTTP-API/plugin traffic.
        let apiInfo = FeatureTelemetry.messageInfo(
            service: StubService(id: "mlx"),
            effectiveModel: "mlx-community/Qwen2.5-7B-4bit",
            source: .httpAPI,
            isAgent: false,
            stream: true,
            defaults: defaults
        )
        #expect(apiInfo.brainSource == nil)
    }

    // MARK: - Prepaid balance / top-up

    @Test func balanceTopUp_events_emit_with_no_props() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        FeatureTelemetry.balanceTopUpInitiated(service: service)
        FeatureTelemetry.balanceTopUpSucceeded(service: service)

        #expect(rec.events.map(\.name) == ["balance_topup_initiated", "balance_topup_succeeded"])
        #expect(business(rec.events[0].props).isEmpty)
        #expect(business(rec.events[1].props).isEmpty)
    }

    // MARK: - Remote-id hashing

    @Test func anonymizedRemoteId_is_deterministic_truncated_and_not_raw() {
        let raw = "acme-internal/legal-bot"
        let a = TelemetryService.anonymizedRemoteId(raw)
        let b = TelemetryService.anonymizedRemoteId(raw)

        // Deterministic so the same custom model groups across users.
        #expect(a == b)
        // Truncated to 12 hex chars and never the raw string.
        #expect(a.count == 12)
        #expect(a != raw)
        #expect(a.allSatisfy { $0.isHexDigit })
        // Whitespace is normalized before hashing.
        #expect(TelemetryService.anonymizedRemoteId("  \(raw)  ") == a)
        // Distinct inputs hash differently.
        #expect(TelemetryService.anonymizedRemoteId("other/model") != a)
    }

    // MARK: - Tool-loop de-dup rule

    @Test func isPrimaryUserTurn_true_only_for_trailing_user_message() {
        // Fresh user turn → counts.
        #expect(
            FeatureTelemetry.isPrimaryUserTurn([
                ChatMessage(role: "system", content: "sys"),
                ChatMessage(role: "user", content: "hello"),
            ]) == true
        )
        // Tool-loop continuation (ends in a tool result) → excluded.
        #expect(
            FeatureTelemetry.isPrimaryUserTurn([
                ChatMessage(role: "user", content: "hello"),
                ChatMessage(role: "assistant", content: nil, tool_calls: nil, tool_call_id: nil),
                ChatMessage(role: "tool", content: "result"),
            ]) == false
        )
        // Assistant-trailing (prefill continuation) → excluded.
        #expect(
            FeatureTelemetry.isPrimaryUserTurn([
                ChatMessage(role: "user", content: "hello"),
                ChatMessage(role: "assistant", content: "partial"),
            ]) == false
        )
        // Empty → excluded.
        #expect(FeatureTelemetry.isPrimaryUserTurn([]) == false)
    }

    // MARK: - First-run activation one-shots

    /// Isolated defaults suite for the persisted one-shot flags.
    private func makeFlagDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "feature-telemetry-flags-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func firstTimeChatShown_is_silent_until_armed_then_fires_once() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }
        let (flags, flagCleanup) = makeFlagDefaults()
        defer { flagCleanup() }

        // Not armed (no onboarding completion) → nothing.
        FeatureTelemetry.firstTimeChatShown(service: service, defaults: flags)
        #expect(rec.events.isEmpty)

        // Armed by onboarding completion → exactly one emit, then silent.
        FeatureTelemetry.armFirstTimeChatShown(defaults: flags)
        FeatureTelemetry.firstTimeChatShown(service: service, defaults: flags)
        FeatureTelemetry.firstTimeChatShown(service: service, defaults: flags)

        #expect(rec.events.count == 1)
        #expect(rec.events[0].name == "first_time_chat_shown")
        #expect(business(rec.events[0].props).isEmpty)
    }

    /// Re-running onboarding (help button, version bump) must NOT fire the
    /// event again — it is strictly once per install.
    @Test func firstTimeChatShown_does_not_rearm_after_firing() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }
        let (flags, flagCleanup) = makeFlagDefaults()
        defer { flagCleanup() }

        FeatureTelemetry.armFirstTimeChatShown(defaults: flags)
        FeatureTelemetry.firstTimeChatShown(service: service, defaults: flags)
        FeatureTelemetry.armFirstTimeChatShown(defaults: flags)
        FeatureTelemetry.firstTimeChatShown(service: service, defaults: flags)

        #expect(rec.events.count == 1)
    }

    @Test func firstTimeChatUsed_fires_exactly_once_ever() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }
        let (flags, flagCleanup) = makeFlagDefaults()
        defer { flagCleanup() }

        FeatureTelemetry.firstTimeChatUsed(service: service, defaults: flags)
        FeatureTelemetry.firstTimeChatUsed(service: service, defaults: flags)

        #expect(rec.events.count == 1)
        #expect(rec.events[0].name == "first_time_chat_used")
        #expect(business(rec.events[0].props).isEmpty)
    }

    // MARK: - Consent gating

    @Test func feature_events_drop_when_consent_declined() {
        let suiteName = "feature-telemetry-declined-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = Recorder()
        let service = TelemetryService(
            defaults: defaults,
            emit: { name, props in
                recorder.events.append(Event(name: name, props: props.mapValues { $0 as Any }))
            }
        )
        service.markStartedForTesting()
        service.setEnabled(false)  // declined → drop

        FeatureTelemetry.serverStarted(service: service)
        FeatureTelemetry.agentCreated(service: service)
        FeatureTelemetry.modelDownloaded(
            model: "mlx-community/Qwen2.5-7B-4bit",
            parameterCount: "7B",
            quantization: "4-bit",
            isVLM: false,
            service: service
        )

        #expect(recorder.events.isEmpty)
    }

    // MARK: - Feature-adoption shapes

    @Test func modelDownloaded_emits_catalog_descriptors() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        FeatureTelemetry.modelDownloaded(
            model: "mlx-community/Qwen2.5-7B-4bit",
            parameterCount: "7B",
            quantization: "4-bit",
            isVLM: true,
            service: service
        )

        let event = rec.events[0]
        #expect(event.name == "model_downloaded")
        #expect(event.props["model"] as? String == "mlx-community/Qwen2.5-7B-4bit")
        #expect(event.props["param_count"] as? String == "7B")
        #expect(event.props["quantization"] as? String == "4-bit")
        #expect(event.props["is_vlm"] as? Bool == true)
    }

    @Test func providerAdded_events_carry_only_type_and_transport() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        FeatureTelemetry.remoteProviderAdded(providerType: "anthropic", service: service)
        FeatureTelemetry.mcpProviderAdded(transport: "stdio", service: service)
        FeatureTelemetry.agentRun(source: "dispatch", service: service)

        #expect(rec.events[0].name == "remote_provider_added")
        #expect(rec.events[0].props["provider_type"] as? String == "anthropic")
        #expect(business(rec.events[0].props).count == 1)

        #expect(rec.events[1].name == "mcp_provider_added")
        #expect(rec.events[1].props["transport"] as? String == "stdio")
        #expect(business(rec.events[1].props).count == 1)

        #expect(rec.events[2].name == "agent_run")
        #expect(rec.events[2].props["source"] as? String == "dispatch")
    }

    // MARK: - Product Hunt launch dialog

    @Test func productHuntLaunchDialog_shown_and_clicked_shapes() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        FeatureTelemetry.productHuntLaunchDialogShown(service: service)
        FeatureTelemetry.productHuntLaunchDialogClicked(action: "launch", service: service)
        FeatureTelemetry.productHuntLaunchDialogClicked(action: "later", service: service)

        #expect(
            rec.events.map(\.name) == [
                "product_hunt_launch_dialog_shown",
                "product_hunt_launch_dialog_clicked",
                "product_hunt_launch_dialog_clicked",
            ]
        )
        // Shown carries no event-specific props; clicked carries only the
        // closed two-value action token.
        #expect(business(rec.events[0].props).isEmpty)
        #expect(rec.events[1].props["action"] as? String == "launch")
        #expect(business(rec.events[1].props).count == 1)
        #expect(rec.events[2].props["action"] as? String == "later")
    }

    @Test func productHuntLaunchDialog_events_drop_when_consent_declined() {
        let suiteName = "feature-telemetry-ph-declined-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = Recorder()
        let service = TelemetryService(
            defaults: defaults,
            emit: { name, props in
                recorder.events.append(Event(name: name, props: props.mapValues { $0 as Any }))
            }
        )
        service.markStartedForTesting()
        service.setEnabled(false)  // declined → drop

        FeatureTelemetry.productHuntLaunchDialogShown(service: service)
        FeatureTelemetry.productHuntLaunchDialogClicked(action: "later", service: service)

        #expect(recorder.events.isEmpty)
    }

    // MARK: - Import history prompt

    @Test func importHistoryPrompt_shown_and_clicked_shapes() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        FeatureTelemetry.importHistoryPromptShown(service: service)
        FeatureTelemetry.importHistoryPromptClicked(action: "import", service: service)
        FeatureTelemetry.importHistoryPromptClicked(action: "skip", service: service)

        #expect(
            rec.events.map(\.name) == [
                "import_history_prompt_shown",
                "import_history_prompt_clicked",
                "import_history_prompt_clicked",
            ]
        )
        // Shown carries no event-specific props; clicked carries only the
        // closed two-value action token.
        #expect(business(rec.events[0].props).isEmpty)
        #expect(rec.events[1].props["action"] as? String == "import")
        #expect(business(rec.events[1].props).count == 1)
        #expect(rec.events[2].props["action"] as? String == "skip")
    }

    /// A completed import carries the closed entry-point token and the four
    /// summary counts — never file names, provider formats, or content.
    @Test func chatHistoryImported_carries_source_and_counts_only() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        FeatureTelemetry.chatHistoryImported(
            source: "onboarding_prompt",
            imported: 12,
            duplicates: 3,
            unreadable: 1,
            failedFiles: 0,
            service: service
        )

        #expect(rec.events.map(\.name) == ["chat_history_imported"])
        let props = rec.events[0].props
        #expect(props["source"] as? String == "onboarding_prompt")
        #expect(props["imported"] as? Int == 12)
        #expect(props["duplicates"] as? Int == 3)
        #expect(props["unreadable"] as? Int == 1)
        #expect(props["failed_files"] as? Int == 0)
        #expect(business(props).count == 5)
    }

    // MARK: - Settings engagement

    /// `settings_opened` carries exactly the stable tab token and the
    /// activation-join flag — never setting names or values.
    @Test func settingsOpened_carries_tab_token_and_activation_flag() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }
        let (flags, flagCleanup) = makeFlagDefaults()
        defer { flagCleanup() }

        // Before any chat message this install ever sent.
        FeatureTelemetry.settingsOpened(tab: .computerUse, service: service, defaults: flags)

        #expect(rec.events.count == 1)
        #expect(rec.events[0].name == "settings_opened")
        #expect(rec.events[0].props["tab"] as? String == "computer_use")
        #expect(rec.events[0].props["before_first_message"] as? Bool == true)
        #expect(business(rec.events[0].props).count == 2)

        // After the first chat message, the flag flips.
        FeatureTelemetry.firstTimeChatUsed(service: service, defaults: flags)
        FeatureTelemetry.settingsOpened(tab: .models, service: service, defaults: flags)

        let after = rec.events[2]
        #expect(after.name == "settings_opened")
        #expect(after.props["tab"] as? String == "models")
        #expect(after.props["before_first_message"] as? Bool == false)
    }

    /// Every settings tab must map to a non-empty, unique, snake_case token
    /// so the dashboard vocabulary stays closed and stable across sidebar
    /// renames or tab-id migrations.
    @Test func settingsTabToken_covers_every_tab_with_stable_snake_case_tokens() {
        let tokens = ManagementTab.allCases.map(FeatureTelemetry.settingsTabToken)

        #expect(tokens.allSatisfy { !$0.isEmpty })
        #expect(Set(tokens).count == ManagementTab.allCases.count)
        #expect(
            tokens.allSatisfy { token in
                token.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
            }
        )

        // Pin the tokens most likely to drift: the display-renamed General
        // tab and the camelCase raw values.
        #expect(FeatureTelemetry.settingsTabToken(.settings) == "general")
        #expect(FeatureTelemetry.settingsTabToken(.computerUse) == "computer_use")
        #expect(FeatureTelemetry.settingsTabToken(.imageGeneration) == "image_generation")
        #expect(FeatureTelemetry.settingsTabToken(.agentChannels) == "agent_channels")
    }

    // MARK: - Hardware RAM bucket (attached to every event)

    /// Every emitted event must carry the coarse `total_memory_gb` bucket so
    /// dashboards can segment any metric (bounce, funnel, adoption) by machine
    /// class. The value is a known whole-GB tier label or the `"128+"` cap.
    @Test func everyEvent_carries_total_memory_gb_bucket() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        FeatureTelemetry.serverStarted(service: service)

        #expect(rec.events.count == 1)
        let bucket = rec.events[0].props["total_memory_gb"] as? String
        #expect(bucket != nil)
        let allowed: Set<String> = ["8", "16", "18", "24", "32", "36", "48", "64", "96", "128", "128+"]
        #expect(allowed.contains(bucket ?? ""))
    }
}
