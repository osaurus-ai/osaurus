import Foundation

/// Saved custom-agent reasoning fields that still contribute after explicit
/// turn overrides. Host-only provenance: API requests never synthesize it.
struct AgentReasoningDefaults: Sendable, Equatable {
    let enableThinking: Bool?
    let reasoningEffort: String?

    init?(settings: AgentGenerationSettings?, overrides: ChatTurnOverrides = .init()) {
        enableThinking = overrides.enableThinking == nil ? settings?.enableThinking : nil
        reasoningEffort = overrides.reasoningEffort == nil ? settings?.reasoningEffort : nil
        if enableThinking == nil && reasoningEffort == nil { return nil }
    }

    var settings: AgentGenerationSettings {
        AgentGenerationSettings(enableThinking: enableThinking, reasoningEffort: reasoningEffort)
    }
}

/// App-owned execution context shared by inference request adapters.
///
/// This value has no wire encoding. Provider requests carry model input and
/// generation parameters; admission, residency, tracing and attribution remain
/// on the host. In particular, a Responses adapter must never re-derive an
/// explicit admission budget or turn a background load into an interactive one.
struct InferenceRequestContext: Sendable {
    var agentReasoningDefaults: AgentReasoningDefaults? = nil
    /// Local execution preference; never encoded into provider Responses/Chat payloads.
    var speculativeDecoding: Bool? = nil
    var modelOptions: [String: ModelOptionValue]? = nil
    var ttftTrace: TTFTTrace? = nil
    var turnId: UUID? = nil
    var samplingParametersAreImplicit: Bool = false
    var isAgentRequest: Bool = false
    var idempotencyKey: String? = nil
    var runAsRemoteAgent: Bool = false
    var remoteAgentLogModel: String? = nil
    var remoteAgentProviderId: UUID? = nil
    var suppressProgressUI: Bool = false
    var warmupPrefill: Bool = false
    var cacheStableSystemPrefix: String? = nil
    var admissionPositionLimit: Int? = nil
    var admissionOutputTokensAreImplicit: Bool = false
    var backgroundModelLoad: Bool = false
    var alignmentRepairModel: String? = nil
    var preserveExistingResidencyOwner: Bool = false
}
