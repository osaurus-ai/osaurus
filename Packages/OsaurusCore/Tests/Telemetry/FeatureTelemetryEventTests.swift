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

    @Test func sandboxProvisionFailure_emitsOnlyClosedDimensions() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        FeatureTelemetry.sandboxProvisionFailure(
            category: "runtime_start_failed",
            backend: "vm",
            phase: "runtime_start",
            errorClass: "posix_eexist",
            trigger: "launch_autostart",
            coldStart: false,
            service: service
        )

        #expect(rec.events.count == 1)
        #expect(rec.events[0].name == "sandbox_provision_failure")
        let props = business(rec.events[0].props)
        #expect(props.count == 6)
        #expect(props["category"] as? String == "runtime_start_failed")
        #expect(props["backend"] as? String == "vm")
        #expect(props["phase"] as? String == "runtime_start")
        #expect(props["error_class"] as? String == "posix_eexist")
        #expect(props["trigger"] as? String == "launch_autostart")
        #expect(props["cold_start"] as? Bool == false)
        // Every value is a token from a closed set — no message, path, or
        // agent identity can be smuggled through these dimensions.
        #expect(
            SandboxToolRegistrar.failureErrorClasses.contains(props["error_class"] as! String)
        )
        #expect(
            SandboxToolRegistrar.RegistrationTrigger(rawValue: props["trigger"] as! String) != nil
        )
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
        FeatureTelemetry.agentCreated(numberOfAgents: 3, service: service)
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

    @Test func agentCreated_carries_only_agent_count() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        FeatureTelemetry.agentCreated(numberOfAgents: 4, service: service)

        let event = rec.events[0]
        #expect(event.name == "agent_created")
        #expect(event.props["number_of_agents"] as? Int == 4)
        #expect(business(event.props).count == 1)
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

    // MARK: - Computer Use funnel

    /// The funnel denominator: one property-less event per invocation.
    @Test func computerUseAttempt_hasNoProperties() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        FeatureTelemetry.computerUseAttempt(service: service)

        #expect(rec.events.count == 1)
        #expect(rec.events[0].name == "computer_use_attempt")
        #expect(business(rec.events[0].props).isEmpty)
    }

    /// Pre-loop refusals carry exactly one closed `stage` token — never an
    /// agent id, goal, or message text — and every stage is snake_case.
    @Test func computerUseRefused_carriesClosedStageToken() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        for stage in ComputerUseRefusalStage.allCases {
            FeatureTelemetry.computerUseRefused(stage: stage, service: service)
        }

        #expect(rec.events.count == ComputerUseRefusalStage.allCases.count)
        for (event, stage) in zip(rec.events, ComputerUseRefusalStage.allCases) {
            #expect(event.name == "computer_use_refused")
            let props = business(event.props)
            #expect(props.keys.sorted() == ["stage"])
            #expect(props["stage"] as? String == stage.rawValue)
        }
        #expect(
            ComputerUseRefusalStage.allCases.allSatisfy { stage in
                stage.rawValue.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
            }
        )
        // Pin the tokens the dashboard segments on.
        #expect(ComputerUseRefusalStage.permissionAccessibility.rawValue == "permission_accessibility")
        #expect(ComputerUseRefusalStage.agentAuth.rawValue == "agent_auth")
        #expect(ComputerUseRefusalStage.modelUnavailable.rawValue == "model_unavailable")
        #expect(ComputerUseRefusalStage.handoffDenied.rawValue == "handoff_denied")
        #expect(ComputerUseRefusalStage.admissionTimeout.rawValue == "admission_timeout")
        #expect(ComputerUseRefusalStage.ramSafety.rawValue == "ram_safety")
        #expect(ComputerUseRefusalStage.recursion.rawValue == "recursion")
    }

    /// `computer_use_run` keeps its original coarse shape and adds the
    /// reliability dimensions: the dominant input route and the "declared
    /// done, nothing observably changed" flag.
    @Test func computerUseRun_shape_includesRouteAndDoneWithoutChange() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        var metrics = ComputerUseRunMetrics()
        metrics.steps = 5
        metrics.actsAttempted = 3
        metrics.verifyChanged = 0
        metrics.unverifiedActs = 3
        metrics.recordRoute(.perPid)
        metrics.recordRoute(.perPid)
        metrics.recordRoute(nil)  // AX action: not a synthesized-input route

        FeatureTelemetry.computerUseRun(metrics, outcome: "done", service: service)

        #expect(rec.events.count == 1)
        #expect(rec.events[0].name == "computer_use_run")
        let props = business(rec.events[0].props)
        #expect(
            props.keys.sorted() == [
                "ax_resolvable", "cloud_vision_used", "confirms_bucket", "done_without_change",
                "had_block", "had_dead_end", "max_tier", "outcome", "route_used", "steps_bucket",
                "unverified_acts_bucket", "verify_pass",
            ]
        )
        #expect(props["route_used"] as? String == "per_pid")
        #expect(props["done_without_change"] as? Bool == true)
        #expect(props["unverified_acts_bucket"] as? String == "1-3")
        #expect(props["verify_pass"] as? String == "low")
    }

    /// `done_without_change` is only the "acted but nothing changed"
    /// signature: a verified run and a pure read run both report `false`.
    @Test func computerUseRun_doneWithoutChange_requiresAnUnverifiedAct() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        var verified = ComputerUseRunMetrics()
        verified.actsAttempted = 2
        verified.verifyChanged = 1
        verified.recordRoute(.skyLight)
        verified.recordRoute(.hidFallback)
        FeatureTelemetry.computerUseRun(verified, outcome: "done", service: service)

        let readOnly = ComputerUseRunMetrics()
        FeatureTelemetry.computerUseRun(readOnly, outcome: "done", service: service)

        var gaveUp = ComputerUseRunMetrics()
        gaveUp.actsAttempted = 1
        FeatureTelemetry.computerUseRun(gaveUp, outcome: "gave_up", service: service)

        #expect(rec.events.count == 3)
        #expect(rec.events[0].props["done_without_change"] as? Bool == false)
        #expect(rec.events[0].props["route_used"] as? String == "mixed")
        #expect(rec.events[1].props["done_without_change"] as? Bool == false)
        #expect(rec.events[1].props["route_used"] as? String == "none")
        #expect(rec.events[2].props["done_without_change"] as? Bool == false)
    }

    // MARK: - Install cohort / age (retention)

    /// Fixed UTC ISO calendar so cohort/age math is deterministic regardless
    /// of the machine's time zone.
    private var utcISO: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        utcISO.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// The vocabulary is a dashboard contract; a silent token rename would
    /// fork the dimension.
    @Test func installCohortSource_tokens_match_the_documented_contract() {
        #expect(FeatureTelemetry.installCohortSourceInstall == "install")
        #expect(FeatureTelemetry.installCohortSourceInferred == "inferred")
        #expect(FeatureTelemetry.installCohortSourceUnknown == "unknown")
        #expect(FeatureTelemetry.installAgeCapLabel == "365+")
    }

    /// A fresh install (onboarding never completed) records the launch
    /// moment as its install date, and the stamp is one-shot.
    @Test func stampFirstLaunch_fresh_install_records_now_once() {
        let (defaults, cleanup) = makeFlagDefaults()
        defer { cleanup() }
        let first = utc(2026, 9, 19)

        // A stale data root must not override a genuinely fresh install.
        FeatureTelemetry.stampFirstLaunchIfNeeded(
            now: first,
            birthDates: { [utc(2026, 2, 25)] },
            defaults: defaults
        )
        #expect(FeatureTelemetry.persistedFirstLaunchDate(defaults: defaults) == first)
        #expect(defaults.string(forKey: FeatureTelemetry.installCohortSourceKey) == "install")

        // Never re-stamps — a later launch (even after re-running
        // onboarding) keeps the original cohort.
        defaults.set(false, forKey: "hasCompletedOnboarding")
        FeatureTelemetry.stampFirstLaunchIfNeeded(
            now: utc(2026, 10, 1),
            birthDates: { [utc(2026, 1, 1)] },
            defaults: defaults
        )
        #expect(FeatureTelemetry.persistedFirstLaunchDate(defaults: defaults) == first)
        #expect(defaults.string(forKey: FeatureTelemetry.installCohortSourceKey) == "install")
    }

    /// Existing installs are back-dated from the earliest data-root birth
    /// time — the legacy Application Support root when it is older than the
    /// copied `~/.osaurus`, whichever single root exists otherwise.
    @Test func stampFirstLaunch_existing_install_infers_earliest_birth_date() {
        let now = utc(2026, 9, 19)

        // Legacy root older than the copied active root → legacy wins.
        let (both, cleanupBoth) = makeFlagDefaults()
        defer { cleanupBoth() }
        both.set(true, forKey: "hasCompletedOnboarding")
        FeatureTelemetry.stampFirstLaunchIfNeeded(
            now: now,
            birthDates: { [utc(2026, 2, 25), utc(2025, 11, 3)] },
            defaults: both
        )
        #expect(FeatureTelemetry.persistedFirstLaunchDate(defaults: both) == utc(2025, 11, 3))
        #expect(both.string(forKey: FeatureTelemetry.installCohortSourceKey) == "inferred")

        // Only one root present → that root.
        let (one, cleanupOne) = makeFlagDefaults()
        defer { cleanupOne() }
        one.set(true, forKey: "hasCompletedOnboarding")
        FeatureTelemetry.stampFirstLaunchIfNeeded(
            now: now,
            birthDates: { [utc(2026, 2, 25)] },
            defaults: one
        )
        #expect(FeatureTelemetry.persistedFirstLaunchDate(defaults: one) == utc(2026, 2, 25))
        #expect(one.string(forKey: FeatureTelemetry.installCohortSourceKey) == "inferred")

        // A birth time in the future (clock skew) is ignored, never used.
        let (skew, cleanupSkew) = makeFlagDefaults()
        defer { cleanupSkew() }
        skew.set(true, forKey: "hasCompletedOnboarding")
        FeatureTelemetry.stampFirstLaunchIfNeeded(
            now: now,
            birthDates: { [utc(2027, 1, 1), utc(2026, 6, 3)] },
            defaults: skew
        )
        #expect(FeatureTelemetry.persistedFirstLaunchDate(defaults: skew) == utc(2026, 6, 3))
    }

    /// Existing install with no readable data root: stamp `now`, but label
    /// it `unknown` so dashboards can exclude it instead of treating the
    /// upgrade launch as a real install date.
    @Test func stampFirstLaunch_existing_install_without_roots_is_unknown() {
        let (defaults, cleanup) = makeFlagDefaults()
        defer { cleanup() }
        defaults.set(true, forKey: "hasCompletedOnboarding")
        let now = utc(2026, 9, 19)

        FeatureTelemetry.stampFirstLaunchIfNeeded(now: now, birthDates: { [] }, defaults: defaults)

        #expect(FeatureTelemetry.persistedFirstLaunchDate(defaults: defaults) == now)
        #expect(defaults.string(forKey: FeatureTelemetry.installCohortSourceKey) == "unknown")
    }

    /// The real resolver only ever returns readable birth times and never
    /// throws or invents a date for a missing path.
    @Test func defaultInstallBirthDates_returns_only_readable_roots() {
        let dates = FeatureTelemetry.defaultInstallBirthDates()
        #expect(dates.count <= 2)
        #expect(dates.allSatisfy { $0 <= Date() })
    }

    @Test func installCohort_formats_iso_week_across_year_boundary() {
        // 2026-09-19 is a Saturday in ISO week 38.
        #expect(FeatureTelemetry.installCohort(firstLaunch: utc(2026, 9, 19), calendar: utcISO) == "2026-W38")
        // ISO weeks straddle the calendar year: Jan 1 2027 (Friday) is
        // still 2026-W53, and Dec 29 2025 (Monday) is already 2026-W01.
        #expect(FeatureTelemetry.installCohort(firstLaunch: utc(2027, 1, 1), calendar: utcISO) == "2026-W53")
        #expect(FeatureTelemetry.installCohort(firstLaunch: utc(2025, 12, 29), calendar: utcISO) == "2026-W01")
    }

    /// Age counts calendar-day boundaries, not 24-hour spans, clamps at
    /// zero, and caps at the `365+` bucket.
    @Test func installAgeDays_uses_day_boundaries_clamps_and_caps() {
        let first = utc(2026, 9, 19, 23)
        func age(_ now: Date) -> String {
            FeatureTelemetry.installAgeDays(firstLaunch: first, now: now, calendar: utcISO)
        }

        // Same day → 0; one hour later across midnight → 1.
        #expect(age(utc(2026, 9, 19, 23)) == "0")
        #expect(age(utc(2026, 9, 20, 0)) == "1")
        #expect(age(utc(2026, 10, 19, 8)) == "30")
        // Clock went backwards → never negative.
        #expect(age(utc(2026, 9, 18)) == "0")
        // Cap.
        #expect(age(utc(2027, 9, 18)) == "364")
        #expect(age(utc(2027, 9, 19)) == "365+")
        #expect(age(utc(2030, 1, 1)) == "365+")
    }

    /// `daily_active` fires once per local calendar day with exactly the
    /// three retention dimensions, and is silent until the install is stamped.
    @Test func dailyActive_fires_once_per_day_with_install_dimensions() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }
        let (flags, flagCleanup) = makeFlagDefaults()
        defer { flagCleanup() }

        // Not stamped yet → silent (emitting bare would reopen a coverage gap).
        FeatureTelemetry.dailyActive(now: utc(2026, 9, 19), calendar: utcISO, service: service, defaults: flags)
        #expect(rec.events.isEmpty)

        flags.set(true, forKey: "hasCompletedOnboarding")
        FeatureTelemetry.stampFirstLaunchIfNeeded(
            now: utc(2026, 9, 19),
            birthDates: { [utc(2026, 2, 25)] },
            defaults: flags
        )

        // Three launches on the same day → one event.
        FeatureTelemetry.dailyActive(now: utc(2026, 9, 19, 9), calendar: utcISO, service: service, defaults: flags)
        FeatureTelemetry.dailyActive(now: utc(2026, 9, 19, 13), calendar: utcISO, service: service, defaults: flags)
        FeatureTelemetry.dailyActive(now: utc(2026, 9, 19, 23), calendar: utcISO, service: service, defaults: flags)
        #expect(rec.events.count == 1)
        #expect(rec.events[0].name == "daily_active")
        let props = business(rec.events[0].props)
        #expect(props.keys.sorted() == ["install_age_days", "install_cohort", "install_cohort_source"])
        #expect(props["install_cohort"] as? String == "2026-W09")
        #expect(props["install_age_days"] as? String == "206")
        #expect(props["install_cohort_source"] as? String == "inferred")

        // Next calendar day → fires again with the age advanced.
        FeatureTelemetry.dailyActive(now: utc(2026, 9, 20, 0), calendar: utcISO, service: service, defaults: flags)
        #expect(rec.events.count == 2)
        #expect(rec.events[1].props["install_age_days"] as? String == "207")
        #expect(rec.events[1].props["install_cohort"] as? String == "2026-W09")
    }

    /// `installProps` is what rides on `app_launched`: nil before the stamp,
    /// the same three dimensions afterwards.
    @Test func installProps_nil_before_stamp_then_carries_dimensions() {
        let (flags, flagCleanup) = makeFlagDefaults()
        defer { flagCleanup() }

        #expect(FeatureTelemetry.installProps(now: utc(2026, 9, 19), calendar: utcISO, defaults: flags) == nil)

        FeatureTelemetry.stampFirstLaunchIfNeeded(now: utc(2026, 9, 19), birthDates: { [] }, defaults: flags)
        let props = FeatureTelemetry.installProps(now: utc(2026, 9, 21), calendar: utcISO, defaults: flags)!
            .mapValues { $0 as Any }
        #expect(props.keys.sorted() == ["install_age_days", "install_cohort", "install_cohort_source"])
        #expect(props["install_cohort"] as? String == "2026-W38")
        #expect(props["install_age_days"] as? String == "2")
        #expect(props["install_cohort_source"] as? String == "install")
    }

    /// `app_launched` carries whatever launch props the caller resolved,
    /// plus the global RAM bucket — and nothing else.
    @Test func appLaunched_carries_install_dimensions() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }
        let (flags, flagCleanup) = makeFlagDefaults()
        defer { flagCleanup() }

        FeatureTelemetry.stampFirstLaunchIfNeeded(now: utc(2026, 9, 19), birthDates: { [] }, defaults: flags)
        let props = FeatureTelemetry.installProps(now: utc(2026, 9, 19), calendar: utcISO, defaults: flags)!
        // `configure()` needs a real key; `track` is the path it takes.
        service.track("app_launched", props)

        #expect(rec.events.count == 1)
        #expect(rec.events[0].name == "app_launched")
        let sent = business(rec.events[0].props)
        #expect(sent.keys.sorted() == ["install_age_days", "install_cohort", "install_cohort_source"])
        #expect(sent["install_cohort"] as? String == "2026-W38")
        #expect(sent["install_age_days"] as? String == "0")
        #expect(sent["install_cohort_source"] as? String == "install")
    }

    /// Retention events obey the same consent gate as everything else.
    @Test func dailyActive_drops_when_consent_declined() {
        let suiteName = "feature-telemetry-daily-declined-\(UUID().uuidString)"
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

        FeatureTelemetry.stampFirstLaunchIfNeeded(now: utc(2026, 9, 19), birthDates: { [] }, defaults: defaults)
        FeatureTelemetry.dailyActive(now: utc(2026, 9, 19), calendar: utcISO, service: service, defaults: defaults)

        #expect(recorder.events.isEmpty)
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
