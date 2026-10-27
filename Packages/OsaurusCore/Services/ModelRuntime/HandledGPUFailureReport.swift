import CryptoKit
import Foundation
import MLXLMCommon

/// What was known about the failing request when the failure arrived.
/// Identifiers and counts only: no prompt text, no paths (a volume is a
/// coarse kind), no raw error text. Every field is optional; a field that
/// was not observed is left out of the report rather than invented.
///
/// Minimal handled-failure reports cannot identify the request's draft path,
/// restore amount or preparation operation. These observed facts narrow
/// diagnosis; they do not identify the originating Metal command or establish
/// a causal fix.
struct HandledGPUFailureContext: Sendable, Equatable {
    /// The request's resolved draft strategy as `ModelRuntime` names it:
    /// `none`, `native_mtp:dN`, `dflash2`, ... (`describeDraftStrategy`).
    var decodePath: String? = nil
    /// The depth the request asked for (Adaptive starts there and governs
    /// from then on; this is the configured figure, not the active one).
    var configuredDepth: Int? = nil
    /// The last `PrefillProgress` stage the mapper saw before the failure:
    /// `cacheLookup`, `cacheRestore`, `prefill`, `complete`.
    var lastPrefillStage: String? = nil
    /// A whitelisted runtime operation identifier, never arbitrary detail text.
    var lastPrefillOperation: String? = nil
    var prefillCompletedUnits: Int? = nil
    var prefillTotalUnits: Int? = nil
    /// Tokens the runtime's `.cacheRestore` event reported restored; 0 is
    /// a cold request that found nothing to restore.
    var restoredTokens: Int? = nil
    /// The tier the restore came from, as the runtime labels it (`disk`,
    /// `paged`, `native-mtp`): an identifier, never content.
    var restoreDetail: String? = nil
    /// Wall milliseconds from the `.cacheLookup` event to the `.cacheRestore`
    /// report: lookup plus the disk read plus the restore's eval.
    var cacheRestoreMs: Int? = nil
    /// Request-correlated payload bytes and read time, when available.
    /// A process-wide latest fetch is not evidence for this request.
    var diskRestoreBytes: Int64? = nil
    var diskRestoreMs: Int? = nil
    /// `internal` / `external` / `removable` / `unknown`: the volume the
    /// model bundle is on. Never the path.
    var modelVolumeKind: String? = nil
    /// Prompt tokens as counted before the iterator was built. The runtime
    /// may report -1 on preparation failure. A scrubbed Sentry export does
    /// not establish whether the original field was numeric or unavailable.
    var promptTokens: Int? = nil

    init(
        decodePath: String? = nil, configuredDepth: Int? = nil,
        lastPrefillStage: String? = nil, lastPrefillOperation: String? = nil,
        prefillCompletedUnits: Int? = nil,
        prefillTotalUnits: Int? = nil, restoredTokens: Int? = nil,
        restoreDetail: String? = nil, cacheRestoreMs: Int? = nil,
        diskRestoreBytes: Int64? = nil, diskRestoreMs: Int? = nil,
        modelVolumeKind: String? = nil, promptTokens: Int? = nil
    ) {
        self.decodePath = decodePath
        self.configuredDepth = configuredDepth
        self.lastPrefillStage = lastPrefillStage
        self.lastPrefillOperation = lastPrefillOperation
        self.prefillCompletedUnits = prefillCompletedUnits
        self.prefillTotalUnits = prefillTotalUnits
        self.restoredTokens = restoredTokens
        self.restoreDetail = restoreDetail
        self.cacheRestoreMs = cacheRestoreMs
        self.diskRestoreBytes = diskRestoreBytes
        self.diskRestoreMs = diskRestoreMs
        self.modelVolumeKind = modelVolumeKind
        self.promptTokens = promptTokens
    }
}

/// Only whitelisted native diagnostics become telemetry. The originating
/// error still belongs to the caller; never copy its text into a report.
struct HandledGPUFailureReport: Sendable, Equatable {
    let modelReference: String
    let stage: String
    let promptTokens: Int?
    let generatedTokens: Int?
    let requestContext: HandledGPUFailureContext

    init?(
        failure: GenerationFailure, modelName: String, promptTokens: Int, generatedTokens: Int,
        context: HandledGPUFailureContext = HandledGPUFailureContext()
    ) {
        guard failure.cause.contains("[METAL] Command buffer execution failed:"),
            failure.cause.contains("kIOGPUCommandBufferCallbackErrorImpactingInteractivity")
        else { return nil }
        // Canonical catalog ids use publisher--repository. Paths and arbitrary
        // local names remain correlatable without publishing their contents.
        let catalogPattern = #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,95}--[A-Za-z0-9][A-Za-z0-9_.-]{0,159}\z"#
        if modelName.range(of: catalogPattern, options: .regularExpression) != nil {
            modelReference = modelName
        } else {
            let digest = SHA256.hash(data: Data(modelName.utf8))
                .prefix(12).map { String(format: "%02x", $0) }.joined()
            modelReference = "local-sha256:\(digest)"
        }
        stage = failure.stage.rawValue
        // The runtime's count wins when it has one; a preparation failure
        // may report -1 there, and the request's own count fills in.
        if promptTokens >= 0 {
            self.promptTokens = promptTokens
        } else if let known = context.promptTokens, known >= 0 {
            self.promptTokens = known
        } else {
            self.promptTokens = nil
        }
        self.generatedTokens = generatedTokens >= 0 ? generatedTokens : nil
        requestContext = context
    }

    var context: [String: Any] {
        var context: [String: Any] = [
            "kind": "impacting_interactivity", "stage": stage,
            "model_reference": modelReference,
            "snapshot_stage": "app_terminal_info_handler",
        ]
        // Keep compatibility fields. The observed server-side privacy rule
        // removed numeric count fields with "token" in their names; these
        // numeric aliases avoid that spelling without bypassing consent or
        // changing the server's filter. Export survival remains unverified.
        if let promptTokens {
            context["prompt_tokens"] = promptTokens
            context["input_units"] = promptTokens
        }
        if let generatedTokens {
            context["generated_tokens"] = generatedTokens
            context["output_units"] = generatedTokens
        }
        let request = requestContext
        if let value = request.decodePath { context["decode_path"] = value }
        if let value = request.configuredDepth { context["configured_depth"] = value }
        if let value = request.lastPrefillStage { context["last_prefill_stage"] = value }
        if let value = Self.whitelistedPrefillOperation(request.lastPrefillOperation) {
            context["last_prefill_operation"] = value
        }
        if let value = request.prefillCompletedUnits { context["prefill_completed_units"] = value }
        if let value = request.prefillTotalUnits { context["prefill_total_units"] = value }
        if let value = request.restoredTokens {
            context["restored_tokens"] = value
            context["restored_units"] = value
        }
        if let value = Self.whitelistedPrefillOperation(request.restoreDetail) { context["restore_detail"] = value }
        if let value = request.cacheRestoreMs { context["cache_restore_ms"] = value }
        if let value = request.diskRestoreBytes { context["disk_restore_bytes"] = value }
        if let value = request.diskRestoreMs { context["disk_restore_ms"] = value }
        if let value = request.modelVolumeKind { context["model_volume_kind"] = value }
        return context
    }

    static func whitelistedPrefillOperation(_ detail: String?) -> String? {
        switch detail {
        case "native-mtp", "native-mtp-boundary", "native-mtp-complete",
             "native-mtp-head-prime", "native-mtp-seed", "native-mtp-bridge", "native-mtp-initial-drafts",
             "paged", "disk", "miss", "disabled", "checking", "running", "chunk", "decode_ready", "solo", "admitted":
            return detail
        default:
            return nil
        }
    }

    /// The coarse kind of volume a model bundle sits on. A path never leaves
    /// this function; the answer is one of four words. `nil` when there is
    /// no directory to ask about, `unknown` when the volume will not say.
    static func volumeKind(of directory: URL?) -> String? {
        guard let directory else { return nil }
        guard
            let values = try? directory.resourceValues(forKeys: [
                .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            ])
        else { return "unknown" }
        if values.volumeIsRemovable == true || values.volumeIsEjectable == true {
            return "removable"
        }
        switch values.volumeIsInternal {
        case .some(true): return "internal"
        case .some(false): return "external"
        case .none: return "unknown"
        }
    }

    static func savedProfileContext(_ saved: VMLXMemorySafetySettings) -> [String: Any] {
        var context: [String: Any] = [
            "mode": saved.mode.rawValue, "slider": saved.slider,
            "keep_model_in_memory": saved.keepModelInMemory,
            "fail_closed_when_estimate_unknown": saved.failClosedWhenEstimateUnknown,
        ]
        if let value = saved.customPhysicalMemoryFraction { context["custom_physical_memory_fraction"] = value }
        if let value = saved.customAllocatorCacheBytes { context["custom_allocator_max_bytes"] = value }
        if let value = saved.customDefaultMaxKVSize { context["custom_default_max_kv_tokens"] = value }
        if let value = saved.customMaxConcurrentSequences { context["custom_max_concurrent_sequences"] = value }
        return context
    }
}
