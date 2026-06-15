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

        // Default init leaves `brainSource` nil (e.g. non-chat sources, or an
        // install that predates the onboarding choice).
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

    @Test func recordOnboardingBrainSource_persists_and_does_not_clobber() {
        let suiteName = "feature-telemetry-brain-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == nil)

        FeatureTelemetry.recordOnboardingBrainSource("hosted", defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == "hosted")

        // A nil or empty write must not wipe a prior choice.
        FeatureTelemetry.recordOnboardingBrainSource(nil, defaults: defaults)
        FeatureTelemetry.recordOnboardingBrainSource("", defaults: defaults)
        #expect(FeatureTelemetry.persistedBrainSource(defaults: defaults) == "hosted")
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
