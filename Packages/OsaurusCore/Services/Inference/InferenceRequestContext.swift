import Foundation

/// App-owned execution context shared by inference request adapters.
///
/// This value has no wire encoding. Provider requests carry model input and
/// generation parameters; admission, residency, tracing and attribution remain
/// on the host. In particular, a Responses adapter must never re-derive an
/// explicit admission budget or turn a background load into an interactive one.
struct InferenceRequestContext: Sendable {
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
