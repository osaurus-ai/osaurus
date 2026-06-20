//
//  EvalRunner.swift
//  OsaurusEvalsKit
//
//  Orchestrates one suite run: applies the model selection, walks each
//  case sequentially (avoids tripping the CoreModelService circuit
//  breaker), and assembles an `EvalReport`.
//
//  Cases run on the main actor — the capability-search / claims
//  evaluators are main-actor-isolated because the underlying registry /
//  agent / plugin manager state is. Sequencing keeps the state guarantees
//  simple and matches how the chat path resolves capabilities.
//

import Foundation
import OsaurusCore

@MainActor
public enum EvalRunner {

    public enum BootstrapMode: Sendable, Equatable {
        case loadInstalledPlugins
        case alreadyLoaded
    }

    /// Run every case in `suite`, one at a time, and produce a report.
    /// `filter` is a substring that must appear in `case.id` for the
    /// case to run — the CLI exposes it via `--filter` so a contributor
    /// debugging a single case doesn't burn tokens on the whole suite.
    /// `thresholdOverride` (when non-nil) is forwarded to
    /// `capability_search` cases and supersedes any per-case
    /// `expect.capabilitySearch.thresholdOverride`. No-op for other
    /// domains. Lets the CLI sweep candidate thresholds without
    /// editing fixtures (`--threshold 0.25`).
    public static func run(
        suite: EvalSuite,
        model: ModelSelection,
        filter: String? = nil,
        thresholdOverride: Float? = nil,
        embedCosineFloorOverride: Float? = nil,
        bootstrapMode: BootstrapMode = .loadInstalledPlugins
    ) async -> EvalReport {
        if bootstrapMode == .loadInstalledPlugins {
            // The CLI is its own process — it has to scan + dlopen every
            // installed plugin manually before capability search can see
            // plugin tools (the host app does this in AppDelegate). Without
            // it every `requirePlugins` case skips with "missing plugins" no
            // matter what's actually installed on disk.
            await EvalHostBootstrap.loadInstalledPlugins()
        }

        let modelLabel = ModelOverride.describe(model)
        let startedAt = isoNow()
        var rows: [EvalCaseReport] = []

        // Surface decode failures up-front as `errored` rows so a
        // contributor with a typo sees the file name in the report
        // instead of silently losing one case.
        for failure in suite.decodeFailures {
            rows.append(
                EvalCaseReport.terminal(
                    id: failure.filename,
                    label: failure.filename,
                    domain: "(unknown)",
                    outcome: .errored,
                    notes: ["decode failure: \(failure.error)"],
                    modelId: modelLabel
                )
            )
        }

        await ModelOverride.withSelection(model) {
            // Warm the model's JIT'd Metal kernels once, BEFORE any scored
            // case, exactly as a production server warms a bundle when it
            // becomes resident. The first decode on a fresh process pays a
            // one-time, multi-second kernel-compilation cost (the cold-start
            // TTFT outlier); without this the cost lands on whichever case
            // happens to run first and pollutes that case's TTFT with a
            // startup artifact. Warming here makes every scored case measure
            // the warm steady-state per-request TTFT a running server actually
            // delivers. Idempotent per (process, model) and best-effort:
            // remote/unknown ids and load failures are no-ops, so a model that
            // can't warm just pays its cold cost on the first case as before.
            // Latency-only — warm-up output is discarded and never changes
            // what the model emits on the scored cases.
            //
            // `OSAURUS_EVALS_DISABLE_WARMUP=1` skips this so the optimization
            // loop can run a clean same-binary A/B (warm-up OFF reproduces the
            // pre-warm-up cold-start: the one-time JIT lands on the first
            // scored case; warm-up ON moves it off the request path).
            if ProcessInfo.processInfo.environment["OSAURUS_EVALS_DISABLE_WARMUP"] != "1" {
                await ModelWarmup.warmUp(modelId: modelLabel)
            } else {
                FileHandle.standardError.write(
                    Data("[evals] warm-up DISABLED (OSAURUS_EVALS_DISABLE_WARMUP=1)\n".utf8)
                )
            }
            for testCase in suite.cases {
                if let filter, !testCase.id.contains(filter) { continue }
                let row = await runOne(
                    testCase,
                    modelId: modelLabel,
                    thresholdOverride: thresholdOverride,
                    embedCosineFloorOverride: embedCosineFloorOverride
                )
                rows.append(annotatedWithCaseNotes(row, from: testCase))
            }
        }

        // Sandbox cases keep the container alive across cases (boot is
        // expensive; provisioning a per-case agent user is cheap). Stop it
        // gracefully before the process exits — a hard kill at exit leaves
        // a dirty rootfs.ext4 behind, and the next run's warm restart can
        // boot a corrupted guest (observed as /etc/group damage that breaks
        // agent provisioning with "chown: invalid group").
        if await SandboxManager.shared.status() == .running {
            try? await SandboxManager.shared.stopContainer()
        }

        return EvalReport(modelId: modelLabel, startedAt: startedAt, cases: rows)
    }

    /// Prepends `testCase.notes` (if any) to the report row's `notes`
    /// array as `note: <text>`. Centralised here so each per-domain
    /// runner branch (schema, capability_search, capability_claims, …) doesn't
    /// have to remember to forward the case-level field. Used today
    /// for tracking-only cases like `capability_search.shell-execution`
    /// where the case file documents WHY it stays red.
    private static func annotatedWithCaseNotes(
        _ row: EvalCaseReport,
        from testCase: EvalCase
    ) -> EvalCaseReport {
        guard let extra = testCase.notes, !extra.isEmpty else { return row }
        return EvalCaseReport(
            id: row.id,
            label: row.label,
            domain: row.domain,
            query: row.query,
            outcome: row.outcome,
            capabilitySearch: row.capabilitySearch,
            notes: ["note: \(extra)"] + row.notes,
            modelId: row.modelId,
            latencyMs: row.latencyMs,
            toolUsage: row.toolUsage,
            telemetry: row.telemetry
        )
    }

    // MARK: - Per-case

    /// Domains that load MLX (local model or embedder) or call a model,
    /// so peak-RAM + KV-cache telemetry is meaningful. Deterministic
    /// pure-data domains (schema, coercion, …) are excluded so their rows
    /// stay telemetry-free instead of carrying a noisy process footprint.
    private static let resourceSampledDomains: Set<String> = [
        "agent_loop", "capability_claims", "computer_use_loop", "capability_search",
        "default_agent",
    ]

    private static func runOne(
        _ testCase: EvalCase,
        modelId: String,
        thresholdOverride: Float? = nil,
        embedCosineFloorOverride: Float? = nil
    ) async -> EvalCaseReport {
        guard resourceSampledDomains.contains(testCase.domain) else {
            return await dispatchCase(
                testCase,
                modelId: modelId,
                thresholdOverride: thresholdOverride,
                embedCosineFloorOverride: embedCosineFloorOverride
            )
        }
        // Wrap model/embedder-driven cases with a peak-RAM + CPU sampler and
        // a before/after KV-cache snapshot. The sampler keeps observing the
        // physical footprint and CPU time while the main actor is blocked
        // inside MLX decode; the KV delta proves prefix reuse across loop
        // iterations.
        let sampler = ResourceSampler.start()
        let kvBefore = await ModelRuntime.batchDiagnosticsSnapshot()
        let row = await dispatchCase(
            testCase,
            modelId: modelId,
            thresholdOverride: thresholdOverride,
            embedCosineFloorOverride: embedCosineFloorOverride
        )
        let kvAfter = await ModelRuntime.batchDiagnosticsSnapshot()
        let sample = sampler.stop()
        return mergeResourceTelemetry(into: row, sample: sample, kvBefore: kvBefore, kvAfter: kvAfter)
    }

    /// Fold runner-level resource telemetry (peak RAM, CPU%, KV-prefix delta)
    /// into a case row, preserving any generation telemetry the domain
    /// runner already attached (decode tok/s, TTFT, prefill from the
    /// agent-loop transcript). KV deltas are only recorded when both
    /// snapshots exist (a remote-only run has neither).
    private static func mergeResourceTelemetry(
        into row: EvalCaseReport,
        sample: ResourceSample,
        kvBefore: BatchDiagnosticsSnapshot?,
        kvAfter: BatchDiagnosticsSnapshot?
    ) -> EvalCaseReport {
        var hitsDelta: Int?
        var missesDelta: Int?
        var ssmHitsDelta: Int?
        var ssmReDerivesDelta: Int?
        var diskL2HitsDelta: Int?
        var diskL2MissesDelta: Int?
        var diskL2StoresDelta: Int?
        if let before = kvBefore, let after = kvAfter {
            hitsDelta = after.prefixHits - before.prefixHits
            missesDelta = after.prefixMisses - before.prefixMisses
            ssmHitsDelta = after.ssmCompanionHits - before.ssmCompanionHits
            ssmReDerivesDelta = after.ssmCompanionReDerives - before.ssmCompanionReDerives
            diskL2HitsDelta = after.diskL2Hits - before.diskL2Hits
            diskL2MissesDelta = after.diskL2Misses - before.diskL2Misses
            diskL2StoresDelta = after.diskL2Stores - before.diskL2Stores
        }
        let existing = row.telemetry
        let merged = EvalCaseTelemetry(
            decodeTokensPerSecond: existing?.decodeTokensPerSecond,
            prefillTokensPerSecond: existing?.prefillTokensPerSecond,
            ttftMs: existing?.ttftMs,
            completionTokens: existing?.completionTokens,
            peakPhysFootprintMb: sample.peakPhysFootprintMb,
            meanCpuPercent: sample.meanCpuPercent,
            peakCpuPercent: sample.peakCpuPercent,
            kvPrefixHitsDelta: hitsDelta,
            kvPrefixMissesDelta: missesDelta,
            ssmCompanionHitsDelta: ssmHitsDelta,
            ssmCompanionReDerivesDelta: ssmReDerivesDelta,
            diskL2HitsDelta: diskL2HitsDelta,
            diskL2MissesDelta: diskL2MissesDelta,
            diskL2StoresDelta: diskL2StoresDelta
        )
        guard !merged.isEmpty else { return row }
        return EvalCaseReport(
            id: row.id,
            label: row.label,
            domain: row.domain,
            query: row.query,
            outcome: row.outcome,
            capabilitySearch: row.capabilitySearch,
            notes: row.notes,
            modelId: row.modelId,
            latencyMs: row.latencyMs,
            toolUsage: row.toolUsage,
            telemetry: merged
        )
    }

    private static func dispatchCase(
        _ testCase: EvalCase,
        modelId: String,
        thresholdOverride: Float? = nil,
        embedCosineFloorOverride: Float? = nil
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        switch testCase.domain {
        case "schema":
            return runSchemaCase(testCase, modelId: modelId)
        case "tool_envelope":
            return runToolEnvelopeCase(testCase, modelId: modelId)
        case "streaming_hint":
            return runStreamingHintCase(testCase, modelId: modelId)
        case "prefix_hash":
            return runPrefixHashCase(testCase, modelId: modelId)
        case "argument_coercion":
            return runArgumentCoercionCase(testCase, modelId: modelId)
        case "sandbox_diagnostics":
            return runSandboxDiagnosticsCase(testCase, modelId: modelId)
        case "request_validation":
            return runRequestValidationCase(testCase, modelId: modelId)
        case "computer_use":
            return runComputerUseCase(testCase, modelId: modelId)
        case "computer_use_loop":
            return await runComputerUseLoopCase(testCase, modelId: modelId)
        case "capability_search":
            return await runCapabilitySearchCase(
                testCase,
                modelId: modelId,
                cliThresholdOverride: thresholdOverride,
                cliEmbedCosineFloorOverride: embedCosineFloorOverride
            )
        case "capability_claims":
            return await runCapabilityClaimsCase(testCase, modelId: modelId)
        case "default_agent":
            return await runDefaultAgentCase(testCase, modelId: modelId)
        case "agent_loop":
            return await runAgentLoopCase(testCase, modelId: modelId)
        case "tools", "streaming", "contract":
            // Scaffolded domains — runner implementation lives in a
            // follow-up so cases can be authored against the format
            // without forcing a heavyweight ChatEngine entry point
            // into the public OsaurusCore surface yet.
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .skipped,
                notes: [
                    "domain '\(testCase.domain)' runner not yet implemented in this build."
                ],
                modelId: modelId
            )
        default:
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["unknown domain: \(testCase.domain)"],
                modelId: modelId
            )
        }
    }

    // MARK: - Schema domain

    /// Pure-data evaluator for the `schema` domain. Mirrors what
    /// `ToolRegistry.execute` does in production: coerce → validate.
    /// Coercion is the rescue layer that unwraps stringified arrays /
    /// objects / scalars before validation sees them, so cases that
    /// pin its behaviour against quantized-model output (e.g. the
    /// browser_do `actions` regression) verify the full path the
    /// chat tool dispatch takes — not just the validator in isolation.
    private static func runSchemaCase(_ testCase: EvalCase, modelId: String) -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let expectation = testCase.expect.schema else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["schema case missing `expect.schema` block"],
                modelId: modelId
            )
        }
        let rawArgs = jsonValueToAny(expectation.arguments)
        let argsAny = SchemaValidator.coerceArguments(rawArgs, against: expectation.schema)
        let result = SchemaValidator.validate(
            arguments: argsAny,
            against: expectation.schema
        )
        var notes: [String] = []
        var passed = (result.isValid == expectation.expectValid)
        if !result.isValid, let msg = result.errorMessage {
            notes.append("validator: \(msg)")
        }
        if let expectField = expectation.expectField {
            if result.field != expectField {
                passed = false
                notes.append(
                    "field mismatch: expected '\(expectField)', got '\(result.field ?? "nil")'"
                )
            }
        }
        return .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId
        )
    }

    /// Build an `.errored` terminal row for cases that fail their
    /// own preconditions (missing required expectation field,
    /// malformed enum value, etc.). Pulls the `id`/`domain`/`label`
    /// from `testCase` so the call site stays a one-liner.
    private static func errored(
        _ testCase: EvalCase,
        label: String,
        modelId: String,
        note: String
    ) -> EvalCaseReport {
        .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: .errored,
            notes: [note],
            modelId: modelId
        )
    }

    /// Convert a `JSONValue` (decoded from the case JSON) into the
    /// `Any` shape `SchemaValidator.validate` consumes. Mirrors the
    /// private `JSONValue.foundationValue` extension in SchemaValidator.
    private static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let obj): return obj.mapValues { jsonValueToAny($0) }
        }
    }

    // MARK: - Tool envelope domain

    /// Pure-data evaluator for `domain == "tool_envelope"`. Drives one
    /// of the `ToolEnvelope.{success,failure}` builders and asserts the
    /// resulting JSON parses back into a dict whose top-level keys
    /// match the expectations.
    private static func runToolEnvelopeCase(_ testCase: EvalCase, modelId: String) -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.toolEnvelope else {
            return Self.errored(testCase, label: label, modelId: modelId, note: "missing `expect.toolEnvelope`")
        }
        let result: String
        switch exp.builder {
        case .failure:
            guard let kindRaw = exp.kind, let kind = ToolEnvelope.Kind(rawValue: kindRaw) else {
                return Self.errored(
                    testCase,
                    label: label,
                    modelId: modelId,
                    note: "failure builder needs `kind` matching ToolEnvelope.Kind raw values"
                )
            }
            result = ToolEnvelope.failure(
                kind: kind,
                message: exp.message ?? "",
                tool: exp.tool
            )
        case .successText:
            result = ToolEnvelope.success(tool: exp.tool, text: exp.text ?? "")
        }
        let mismatches = compareTopLevelKeys(result, expectKeys: exp.expectKeys)
        return .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: mismatches.isEmpty ? .passed : .failed,
            notes: mismatches.isEmpty ? ["envelope: \(result)"] : mismatches,
            modelId: modelId
        )
    }

    /// Compare every entry in `expectKeys` against the parsed top-level
    /// dict from `envelopeJSON`. Returns one mismatch line per key that
    /// disagrees; an empty array means full pass.
    private static func compareTopLevelKeys(
        _ envelopeJSON: String,
        expectKeys: [String: JSONValue]
    ) -> [String] {
        guard let data = envelopeJSON.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ["envelope did not parse as a JSON object: \(envelopeJSON)"]
        }
        var mismatches: [String] = []
        for (key, expected) in expectKeys {
            let actual = dict[key]
            if !equalsJSONValue(actual, expected) {
                mismatches.append("key '\(key)': expected \(expected), got \(actual ?? "<missing>")")
            }
        }
        return mismatches
    }

    /// Equality between a Foundation-decoded `Any?` and a `JSONValue`
    /// literal from the case file. Bool/Number/String/Null are compared
    /// directly; arrays and objects are not used by the Tier 1 suites
    /// (would need recursion if a future case needs them).
    private static func equalsJSONValue(_ actual: Any?, _ expected: JSONValue) -> Bool {
        switch expected {
        case .null:
            return actual == nil || actual is NSNull
        case .bool(let b):
            if let n = actual as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue == b
            }
            return false
        case .number(let n):
            if let actualN = actual as? NSNumber, CFGetTypeID(actualN) != CFBooleanGetTypeID() {
                return actualN.doubleValue == n
            }
            return false
        case .string(let s):
            return (actual as? String) == s
        case .array, .object:
            return false
        }
    }

    // MARK: - Streaming hint domain

    /// Pure-data evaluator for `domain == "streaming_hint"`. Verifies
    /// the encode → isSentinel → decode round-trip for every supported
    /// `StreamingToolHint` operation.
    private static func runStreamingHintCase(_ testCase: EvalCase, modelId: String) -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.streamingHint else {
            return Self.errored(testCase, label: label, modelId: modelId, note: "missing `expect.streamingHint`")
        }

        var notes: [String] = []
        var passed = true
        switch exp.op {
        case .encode:
            guard let payload = exp.payload else {
                return Self.errored(testCase, label: label, modelId: modelId, note: "encode op needs `payload`")
            }
            let encoded = StreamingToolHint.encode(payload)
            if !StreamingToolHint.isSentinel(encoded) {
                passed = false
                notes.append("isSentinel returned false on encoded payload")
            }
            if StreamingToolHint.decode(encoded) != payload {
                passed = false
                notes.append("decode did not round-trip payload")
            }
        case .encodeArgs:
            guard let payload = exp.payload else {
                return Self.errored(testCase, label: label, modelId: modelId, note: "encodeArgs op needs `payload`")
            }
            let encoded = StreamingToolHint.encodeArgs(payload)
            if !StreamingToolHint.isSentinel(encoded) {
                passed = false
                notes.append("isSentinel returned false on encoded args")
            }
            if StreamingToolHint.decodeArgs(encoded) != payload {
                passed = false
                notes.append("decodeArgs did not round-trip payload")
            }
        case .encodeDone:
            guard let callId = exp.callId, let name = exp.name,
                let arguments = exp.arguments, let result = exp.result
            else {
                return Self.errored(
                    testCase,
                    label: label,
                    modelId: modelId,
                    note: "encodeDone needs callId/name/arguments/result"
                )
            }
            let encoded = StreamingToolHint.encodeDone(
                callId: callId,
                name: name,
                arguments: arguments,
                result: result
            )
            if !StreamingToolHint.isSentinel(encoded) {
                passed = false
                notes.append("isSentinel returned false on encoded done")
            }
            guard let decoded = StreamingToolHint.decodeDone(encoded) else {
                passed = false
                notes.append("decodeDone returned nil")
                break
            }
            if decoded.callId != callId { passed = false; notes.append("callId drift: \(decoded.callId)") }
            if decoded.name != name { passed = false; notes.append("name drift: \(decoded.name)") }
            if decoded.arguments != arguments { passed = false; notes.append("arguments drift") }
            if decoded.result != result { passed = false; notes.append("result drift") }
        }
        return .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId
        )
    }

    // MARK: - Prefix hash domain

    /// Pure-data evaluator for `domain == "prefix_hash"`. Pins both
    /// hash stability against literal hex strings and structural
    /// invariants between two input pairs.
    private static func runPrefixHashCase(_ testCase: EvalCase, modelId: String) -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.prefixHash else {
            return Self.errored(testCase, label: label, modelId: modelId, note: "missing `expect.prefixHash`")
        }
        let h1 = ModelRuntime.computePrefixHash(
            systemContent: exp.systemContent,
            toolNames: exp.toolNames
        )
        var notes: [String] = []
        var passed = true

        if let expectedHash = exp.expectHash, h1 != expectedHash {
            passed = false
            notes.append("hash drift: expected \(expectedHash), got \(h1)")
        }
        if let other = exp.compareTo {
            let h2 = ModelRuntime.computePrefixHash(
                systemContent: other.systemContent,
                toolNames: other.toolNames
            )
            let shouldBeEqual = exp.expectEqual ?? false
            let actuallyEqual = (h1 == h2)
            if shouldBeEqual != actuallyEqual {
                passed = false
                notes.append(
                    "comparison: expected equal=\(shouldBeEqual), got \(h1) vs \(h2) (equal=\(actuallyEqual))"
                )
            }
        }
        if exp.expectHash == nil && exp.compareTo == nil {
            // Smoke-test: just record the hash. Useful for bootstrapping
            // a new case before pinning a literal value.
            notes.append("hash: \(h1)")
        }
        return .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId
        )
    }

    // MARK: - Argument coercion domain

    /// Pure-data evaluator for `domain == "argument_coercion"`. Drives
    /// one of `ArgumentCoercion.{stringArray,int,bool}` and pins the
    /// result against the case's `expect` value (or `nil` for the
    /// rejection branch).
    private static func runArgumentCoercionCase(_ testCase: EvalCase, modelId: String) -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.argumentCoercion else {
            return Self.errored(testCase, label: label, modelId: modelId, note: "missing `expect.argumentCoercion`")
        }
        let valueAny = jsonValueToAny(exp.value)
        let outcome: (passed: Bool, note: String)
        switch exp.helper {
        case .stringArray:
            let got = ArgumentCoercion.stringArray(valueAny)
            outcome = compareCoerced(
                got: got.map { JSONValue.array($0.map { .string($0) }) },
                expect: exp.expect
            )
        case .int:
            let got = ArgumentCoercion.int(valueAny)
            outcome = compareCoerced(got: got.map { JSONValue.number(Double($0)) }, expect: exp.expect)
        case .bool:
            let got = ArgumentCoercion.bool(valueAny)
            outcome = compareCoerced(got: got.map { JSONValue.bool($0) }, expect: exp.expect)
        }
        return .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: outcome.passed ? .passed : .failed,
            notes: [outcome.note],
            modelId: modelId
        )
    }

    /// Pure-data evaluator for `domain == "sandbox_diagnostics"`. Feeds
    /// the canned `(command, exitCode, stderr)` tuple through
    /// `shellCommandFailureHint` and pins both the fire/no-fire decision
    /// and (for positive cases) an optional substring of the recovery hint.
    private static func runSandboxDiagnosticsCase(_ testCase: EvalCase, modelId: String) -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.sandboxDiagnostics else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "missing `expect.sandboxDiagnostics`"
            )
        }
        let hint = shellCommandFailureHint(
            command: exp.command,
            exitCode: Int32(exp.exitCode),
            stderr: exp.stderr
        )
        let fired = hint != nil
        var passed = fired == exp.expectHint
        var note: String
        if !passed {
            note = "hint fired: \(fired), expected: \(exp.expectHint)"
        } else if exp.expectHint, let needle = exp.hintContains {
            passed = hint?.contains(needle) ?? false
            note =
                passed
                ? "hint fired and contains `\(needle)`"
                : "hint fired but missing `\(needle)`: \(hint ?? "<nil>")"
        } else {
            note = fired ? "hint fired as expected" : "hint correctly silent"
        }
        return .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: passed ? .passed : .failed,
            notes: [note],
            modelId: modelId
        )
    }

    private static func compareCoerced(
        got: JSONValue?,
        expect: JSONValue?
    ) -> (passed: Bool, note: String) {
        switch (got, expect) {
        case (nil, nil), (nil, .null?), (.null?, nil):
            return (true, "coerced: nil (matches expectation)")
        case (let g?, let e?) where jsonValuesEqual(g, e):
            return (true, "coerced: \(g)")
        default:
            return (false, "coerced: \(String(describing: got)), expected: \(String(describing: expect))")
        }
    }

    /// Structural equality on `JSONValue`. Handles the
    /// number/string/bool leaves the coercion suite produces.
    private static func jsonValuesEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)):
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy { jsonValuesEqual($0.0, $0.1) }
        case (.object(let x), .object(let y)):
            guard x.keys.sorted() == y.keys.sorted() else { return false }
            return x.allSatisfy { key, value in
                guard let other = y[key] else { return false }
                return jsonValuesEqual(value, other)
            }
        default: return false
        }
    }

    // MARK: - Request validation domain

    /// Pure-data evaluator for `domain == "request_validation"`. Pins
    /// the accept/reject decision of `RequestValidator.unsupportedSamplerReason`
    /// for the (`n`, `response_format.type`) tuple.
    private static func runRequestValidationCase(_ testCase: EvalCase, modelId: String) -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.requestValidation else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "missing `expect.requestValidation`"
            )
        }
        let reason = RequestValidator.unsupportedSamplerReason(
            n: exp.n,
            responseFormatType: exp.responseFormatType
        )
        var passed = true
        var notes: [String] = []
        if exp.expectAccept {
            if let reason {
                passed = false
                notes.append("expected accept, got reject: \(reason)")
            } else {
                notes.append("accepted (as expected)")
            }
        } else {
            guard let reason else {
                passed = false
                notes.append("expected reject, got accept")
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .failed,
                    notes: notes,
                    modelId: modelId
                )
            }
            notes.append("rejected: \(reason)")
            if let needle = exp.expectReasonContains, !reason.contains(needle) {
                passed = false
                notes.append("expected reason to contain '\(needle)'")
            }
        }
        return .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId
        )
    }

    // MARK: - Computer Use domain

    /// Pure-data evaluator for `domain == "computer_use"`. Reconstructs a
    /// scripted `AgentAction` + resolution context, runs it through the
    /// harness's `EffectClassifier` and `AutonomyPolicy`, and pins the
    /// resulting effect class, gate disposition, and allowlist decision.
    /// No driver, no permissions, no model — the gate's safe-by-default
    /// behaviour locked against regression on every PR.
    private static func runComputerUseCase(_ testCase: EvalCase, modelId: String) -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.computerUse else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "missing `expect.computerUse`"
            )
        }
        guard let verb = AgentVerb(rawValue: exp.verb) else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "unknown verb '\(exp.verb)' (expected an AgentVerb raw value)"
            )
        }

        // 1) Rebuild the action exactly as the loop would hand it to the gate.
        let target: AgentTarget? = {
            if exp.mark == nil && (exp.describe?.isEmpty ?? true) { return nil }
            return AgentTarget(mark: exp.mark, describe: exp.describe)
        }()
        let action = AgentAction(
            verb: verb,
            target: target,
            text: exp.text,
            key: exp.key,
            modifiers: exp.modifiers ?? [],
            note: exp.note
        )

        // 2) Classify the effect, optionally with per-app recipe signals.
        let recipeSignals =
            (exp.useRecipes ?? false) ? AppRecipes.signals(for: exp.appName) : RecipeSignals.empty
        let effect = EffectClassifier.classify(
            action: action,
            resolvedRole: exp.resolvedRole,
            resolvedLabel: exp.resolvedLabel,
            appName: exp.appName,
            recipeSignals: recipeSignals
        )

        // 3) Build the policy and resolve disposition + allowlist gate.
        let preset = exp.preset.flatMap { AutonomyPreset(rawValue: $0) } ?? .default
        var perApp: [String: AutonomyPreset] = [:]
        for (app, raw) in exp.perApp ?? [:] {
            guard let p = AutonomyPreset(rawValue: raw) else {
                return Self.errored(
                    testCase,
                    label: label,
                    modelId: modelId,
                    note: "unknown perApp preset '\(raw)' for app '\(app)'"
                )
            }
            perApp[AutonomyPolicy.normalize(app)] = p
        }
        let policy = AutonomyPolicy(
            globalPreset: preset,
            perApp: perApp,
            allowlist: exp.allowlist
        )
        let ceiling = exp.ceiling.flatMap { AutonomyPreset(rawValue: $0) }.map {
            AutonomyCeiling.cappedAt($0)
        }
        let allowed = policy.isAppAllowed(exp.appName)
        let disposition = policy.disposition(for: effect, app: exp.appName, ceiling: ceiling)

        // 4) Score every present expectation; an empty set just records.
        var notes: [String] = []
        var passed = true

        if let want = exp.expectEffect {
            if effect.rawValue == want {
                notes.append("effect ok: \(effect.rawValue)")
            } else {
                passed = false
                notes.append("effect mismatch: expected \(want), got \(effect.rawValue)")
            }
        }
        if let want = exp.expectDisposition {
            if disposition.rawValue == want {
                notes.append("disposition ok: \(disposition.rawValue)")
            } else {
                passed = false
                notes.append("disposition mismatch: expected \(want), got \(disposition.rawValue)")
            }
        }
        if let want = exp.expectAllowed {
            if allowed == want {
                notes.append("allowlist ok: allowed=\(allowed)")
            } else {
                passed = false
                notes.append("allowlist mismatch: expected allowed=\(want), got \(allowed)")
            }
        }
        if exp.expectEffect == nil, exp.expectDisposition == nil, exp.expectAllowed == nil {
            notes.append(
                "recorded: effect=\(effect.rawValue) disposition=\(disposition.rawValue) "
                    + "allowed=\(allowed)"
            )
        }

        return .terminal(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId
        )
    }

    // MARK: - Capability search domain

    /// Pure-data evaluator for `domain == "capability_search"`. Drives
    /// `CapabilitySearchEvaluator.evaluate` and pins recall + abstain
    /// behaviour against the `expect.capabilitySearch` matchers. No
    /// LLM call, no agent state — fast enough to run in CI on every
    /// PR once the threshold floor is set (see `recall_floors.json`).
    ///
    /// Tools-lane threshold precedence: CLI `--threshold` > per-case
    /// `thresholdOverride` > `CapabilitySearch.minimumFusedScore`.
    /// Methods + skills lanes always use their own per-lane cosine
    /// constants — see `CapabilitySearchEvaluator.evaluate` doc.
    /// Honours the existing `requirePlugins` skip behaviour so a host
    /// without the relevant plugin gets `skipped + missing plugins`
    /// instead of a misleading `failed`.
    private static func runCapabilitySearchCase(
        _ testCase: EvalCase,
        modelId: String,
        cliThresholdOverride: Float?,
        cliEmbedCosineFloorOverride: Float? = nil
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        guard let exp = testCase.expect.capabilitySearch else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "missing `expect.capabilitySearch`"
            )
        }

        if let required = testCase.fixtures.requirePlugins, !required.isEmpty {
            let installed = EvalHostBootstrap.installedPluginIds()
            let missing = required.filter { !installed.contains($0) }
            if !missing.isEmpty {
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .skipped,
                    notes: ["missing plugins: \(missing.joined(separator: ", "))"],
                    modelId: modelId
                )
            }
        }

        // Per-case fixture setup. Both `seedMethods` and `enableSkills`
        // mutate persistent state (SQLite + on-disk skill files) — the
        // wrap snapshots prior state and restores it after the case
        // body runs. Crashes mid-case can leak `eval-` prefixed methods
        // and toggled-on skills into the developer's local state; we
        // accept this as a cost of running fixtures against the live
        // DB rather than building an isolated test harness.
        let seededMethods = await applySeedMethods(testCase.fixtures.seedMethods)
        let priorSkillState = await applyEnableSkills(testCase.fixtures.enableSkills)

        let threshold = cliThresholdOverride ?? exp.thresholdOverride
        let topK = exp.topK ?? 10
        let observed = await CapabilitySearchEvaluator.evaluate(
            query: testCase.query,
            topK: topK,
            threshold: threshold,
            embedCosineFloor: cliEmbedCosineFloorOverride
        )

        await restoreSkillEnabledState(priorSkillState)
        await cleanupSeededMethods(seededMethods)

        var notes: [String] = []
        var passed = true

        let acceptedToolNames = Set(observed.toolHits.filter(\.acceptedByThreshold).map(\.name))
        let acceptedMethodNames = Set(observed.methodHits.filter(\.acceptedByThreshold).map(\.name))
        let acceptedSkillNames = Set(observed.skillHits.filter(\.acceptedByThreshold).map(\.name))
        let acceptedTotal = acceptedToolNames.count + acceptedMethodNames.count + acceptedSkillNames.count

        if let m = exp.expectedTools {
            let result = scoreAnyOf(matcher: m, accepted: acceptedToolNames, kind: "tools")
            passed = passed && result.passed
            notes.append(result.note)
        }
        if let m = exp.expectedMethods {
            let result = scoreAnyOf(matcher: m, accepted: acceptedMethodNames, kind: "methods")
            passed = passed && result.passed
            notes.append(result.note)
        }
        if let m = exp.expectedSkills {
            let result = scoreAnyOf(matcher: m, accepted: acceptedSkillNames, kind: "skills")
            passed = passed && result.passed
            notes.append(result.note)
        }
        if let cap = exp.maxAccepted {
            if acceptedTotal > cap {
                passed = false
                notes.append("maxAccepted breached: got \(acceptedTotal) accepted, expected ≤ \(cap)")
            } else {
                notes.append("maxAccepted ok: \(acceptedTotal) ≤ \(cap)")
            }
        }

        // Always include a one-line forensic summary so a failing case
        // in `--verbose` (or `--report-forensics`) reads at a glance.
        // Tools use the hybrid `appliedMinFusedScore` (RRF cutoff);
        // methods + skills carry independent embed-cosine cutoffs
        // post-PR-A (split out of the legacy single `appliedThreshold`,
        // which now mirrors `appliedMethodsThreshold` for back-compat).
        notes.append(
            "summary: tools raw=\(observed.toolHits.count) accepted=\(acceptedToolNames.count) | "
                + "methods raw=\(observed.methodHits.count) accepted=\(acceptedMethodNames.count) | "
                + "skills raw=\(observed.skillHits.count) accepted=\(acceptedSkillNames.count) | "
                + "registry=\(observed.registrySize) index=\(observed.indexSize) "
                + "minFusedScore=\(String(format: "%.3f", observed.appliedMinFusedScore)) "
                + "methodsThreshold=\(String(format: "%.3f", observed.appliedMethodsThreshold)) "
                + "skillsThreshold=\(String(format: "%.3f", observed.appliedSkillsThreshold))"
        )

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            capabilitySearch: observed,
            notes: notes,
            modelId: modelId,
            latencyMs: observed.latencyMs
        )
    }

    /// Score one `AnyOfMatcher` against the accepted-name set for its
    /// kind. Returns `(passed, note)` so the caller can fold the note
    /// into the case report regardless of pass/fail.
    private static func scoreAnyOf(
        matcher: EvalCase.CapabilitySearchExpectations.AnyOfMatcher,
        accepted: Set<String>,
        kind: String
    ) -> (passed: Bool, note: String) {
        let hits = matcher.anyOf.filter { accepted.contains($0) }
        let passed = hits.count >= matcher.minMatches
        if matcher.minMatches == 0 && matcher.anyOf.isEmpty {
            // Abstain-style matcher: minMatches=0, anyOf=[]. Pass is
            // signalled separately by `maxAccepted`; here we just
            // emit a note so the report makes sense.
            return (true, "\(kind) abstain matcher (no expected names)")
        }
        if passed {
            return (
                true,
                "\(kind) matched \(hits.count)/\(matcher.minMatches): [\(hits.joined(separator: ","))]"
            )
        }
        return (
            false,
            "\(kind) under floor: matched \(hits.count)/\(matcher.minMatches) of [\(matcher.anyOf.joined(separator: ","))]"
        )
    }

    // MARK: - Capability claims domain

    /// Agent-loop evaluator for `domain == "capability_claims"`. Runs
    /// the real multi-turn chat loop via `CapabilityClaimsEvaluator`,
    /// then scores deterministic transcript assertions plus an LLM-judge
    /// rubric. Off-CI (token cost).
    ///
    /// Fixture setup mirrors `capability_search`: `requirePlugins` skips,
    /// `enableSkills` / `enableTools` grant capabilities for the run
    /// window and restore afterwards. `ensureToolsDisabled` skips the
    /// case when a tool that must be absent is actually enabled, since
    /// the runner can't safely disable globally-enabled tools.
    private static func runCapabilityClaimsCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        guard let exp = testCase.expect.capabilityClaims else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "missing `expect.capabilityClaims`"
            )
        }

        if let required = testCase.fixtures.requirePlugins, !required.isEmpty {
            let installed = EvalHostBootstrap.installedPluginIds()
            let missing = required.filter { !installed.contains($0) }
            if !missing.isEmpty {
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .skipped,
                    notes: ["missing plugins: \(missing.joined(separator: ", "))"],
                    modelId: modelId
                )
            }
        }

        // Capability skip (mirrors the `agent_loop` tiny-context skip and the
        // `ensureToolsDisabled` skip below): a model whose context size class
        // auto-disables tool calling — Apple Foundation and any other
        // ≤4K-token-window model (`ContextSizeClass.tiny`) — cannot satisfy a
        // case that REQUIRES a tool call, because Osaurus strips the tool
        // schema at compose time for such models. A `mustCallTools` /
        // `loadSkillFirst` case would then score a capability-mismatch FAIL
        // rather than an honest-claims result, so surface it as SKIP. The
        // abstention cases (no tool requirement — they assert the model does
        // NOT over-claim a capability it lacks) still run: a tool-less model
        // is exactly their premise, so they stay meaningful here.
        let claimsRequiresTools =
            !(exp.mustCallTools?.isEmpty ?? true) || exp.loadSkillFirst != nil
        let claimsWindow = ContextSizeResolver.resolve(modelId: modelId)
        if claimsRequiresTools && claimsWindow.sizeClass.disablesTools {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .skipped,
                notes: [
                    "tools auto-disabled for '\(modelId)': context size class "
                        + "\(claimsWindow.sizeClass) (≤\(ContextSizeResolver.tinyCeiling)-token "
                        + "window) strips the tool schema; this case requires a tool call"
                ],
                modelId: modelId
            )
        }

        // Cases that assert a tool MUST be absent (`ensureToolsDisabled`)
        // can't be proven against the Default agent's legacy global tool
        // mode, where `effectiveEnabledToolNames == nil` means "everything
        // is reachable" — so the gate below would always skip. Stand up an
        // isolated, fully-enabled auto-mode eval agent whose allowlist is the
        // live dynamic-tool registry minus the forbidden names; that makes
        // the absence authoritative (and naturally excludes fictional tools
        // like send_fax / place_trade) so the case actually runs. The agent
        // is torn down on every exit path via `defer`. Cases with no
        // `ensureToolsDisabled` keep using the active agent unchanged.
        let claimsAbsenceNames = testCase.fixtures.ensureToolsDisabled ?? []
        let isolatedClaimsAgentId: UUID? =
            claimsAbsenceNames.isEmpty
            ? nil
            : installCapabilityClaimsAgent(excluding: claimsAbsenceNames)
        defer {
            if let isolatedClaimsAgentId {
                removeEvalAgent(isolatedClaimsAgentId)
            }
        }
        let resolvedAgentId = isolatedClaimsAgentId ?? AgentManager.shared.activeAgent.id

        // Skip only when a must-be-absent tool is GENUINELY reachable on the
        // resolved agent (e.g. a host that really ships a `send_fax` tool) —
        // that would change what the abstention case proves. With the
        // isolated agent above the allowlist is non-nil and excludes the
        // forbidden names, so the well-behaved case proceeds.
        if let mustBeAbsent = testCase.fixtures.ensureToolsDisabled, !mustBeAbsent.isEmpty {
            let enabled = AgentManager.shared.effectiveEnabledToolNames(for: resolvedAgentId)
            // nil = legacy global-enabled mode: everything is reachable,
            // so a "must be absent" tool cannot be guaranteed absent.
            let present: [String]
            if let enabled {
                present = mustBeAbsent.filter { enabled.contains($0) }
            } else {
                present = mustBeAbsent
            }
            if !present.isEmpty {
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .skipped,
                    notes: [
                        "ensureToolsDisabled not satisfiable — enabled: "
                            + present.joined(separator: ", ")
                    ],
                    modelId: modelId
                )
            }
        }

        let priorSkillState = await applyEnableSkills(testCase.fixtures.enableSkills)
        let priorToolGrant = await applyEnableTools(
            testCase.fixtures.enableTools,
            agentId: resolvedAgentId
        )

        let judgeModel = EvalJudgeModel.resolveAndWarnOnce(runModelId: modelId)
        let started = Date()
        let transcript = await CapabilityClaimsEvaluator.run(
            query: testCase.query,
            agentId: resolvedAgentId,
            maxIterations: exp.maxIterations ?? 6
        )

        var verdicts: [CapabilityClaimsJudgement] = []
        if transcript.error == nil, !exp.rubric.isEmpty {
            verdicts = await CapabilityClaimsEvaluator.judge(
                finalText: transcript.finalText,
                conditions: exp.rubric,
                model: judgeModel
            )
        }
        let elapsed = Date().timeIntervalSince(started) * 1000

        await restoreToolGrant(priorToolGrant, agentId: resolvedAgentId)
        await restoreSkillEnabledState(priorSkillState)

        // Score.
        var notes: [String] = []
        var passed = true

        if let err = transcript.error {
            return EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: testCase.query,
                outcome: .errored,
                notes: ["agent loop error: \(err)"],
                modelId: modelId,
                latencyMs: elapsed
            )
        }

        let calledNames = transcript.toolCalls.map(\.name)
        let calledSet = Set(calledNames)

        if let must = exp.mustCallTools {
            let missing = must.filter { !calledSet.contains($0) }
            if missing.isEmpty {
                notes.append("mustCallTools ok: [\(must.joined(separator: ","))]")
            } else {
                passed = false
                notes.append("mustCallTools missing: [\(missing.joined(separator: ","))]")
            }
        }
        if let mustNot = exp.mustNotCallTools {
            let offenders = mustNot.filter { calledSet.contains($0) }
            if offenders.isEmpty {
                notes.append("mustNotCallTools ok")
            } else {
                passed = false
                notes.append("mustNotCallTools called: [\(offenders.joined(separator: ","))]")
            }
        }
        if let matcher = exp.loadSkillFirst {
            let result = scoreSkillFirst(matcher: matcher, transcript: transcript)
            passed = passed && result.passed
            notes.append(result.note)
        }

        // LLM-judge rubric — every condition must pass.
        for (index, verdict) in verdicts.enumerated() {
            let condition = index < exp.rubric.count ? exp.rubric[index] : "(condition \(index))"
            if verdict.pass {
                notes.append("judge ok: \(condition)")
            } else {
                passed = false
                notes.append("judge FAIL: \(condition) — \(verdict.reason)")
            }
        }
        if !exp.rubric.isEmpty && verdicts.count != exp.rubric.count {
            passed = false
            notes.append(
                "judge produced \(verdicts.count) verdicts for \(exp.rubric.count) conditions"
            )
        }

        if transcript.hitIterationCap {
            notes.append("warning: hit iteration cap (\(transcript.iterations)) — possible loop")
        }
        notes.append(
            "summary: toolCalls=[\(calledNames.joined(separator: ","))] "
                + "loaded=[\(transcript.loadedToolNames.joined(separator: ","))] "
                + "iters=\(transcript.iterations)"
        )
        notes.append("final: \(transcript.finalText.replacingOccurrences(of: "\n", with: " "))")

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: elapsed
        )
    }

    /// Agent-loop evaluator for `domain == "default_agent"`. Drives the
    /// multi-turn chat loop PINNED to the built-in Default (configuration)
    /// agent via `DefaultAgentConfigurationEvaluator`, then scores
    /// deterministic transcript assertions (`mustCallTools` /
    /// `mustNotCallTools` / `argsMustContain`) plus an optional LLM-judge
    /// rubric. Off-CI (token cost).
    ///
    /// Tool-requiring cases SKIP on tiny-window models (Apple Foundation on
    /// macOS 26.x and any ≤4K-token model) because Osaurus auto-disables the
    /// tool schema there — the documented 4096 go/no-go. Out-of-scope routing
    /// and honesty cases carry no tool requirement, so they still run on tiny
    /// models (a tool-less Default agent is exactly their premise).
    private static func runDefaultAgentCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        guard let exp = testCase.expect.defaultAgent else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "missing `expect.defaultAgent`"
            )
        }

        // A case that pins a tool call or its arguments can only run where the
        // tool schema survives composition. Tiny-window models strip it.
        let requiresTools =
            !(exp.mustCallTools?.isEmpty ?? true)
            || !(exp.argsMustContain?.isEmpty ?? true)
        let window = ContextSizeResolver.resolve(modelId: modelId)
        if requiresTools && window.sizeClass.disablesTools {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .skipped,
                notes: [
                    "tools auto-disabled for '\(modelId)': context size class "
                        + "\(window.sizeClass) (≤\(ContextSizeResolver.tinyCeiling)-token window) "
                        + "strips the tool schema; this case requires a configure tool call "
                        + "(BLOCKED-by-window)"
                ],
                modelId: modelId
            )
        }

        let rubric = exp.rubric ?? []
        let judgeModel = EvalJudgeModel.resolveAndWarnOnce(runModelId: modelId)
        let started = Date()
        // Seed any fixture agents so create cases can target a real agent
        // (and not loop on a not-found id), then tear them down once the run
        // is done — the seeded agent is only needed during the model loop.
        let seededAgentIds = await seedDefaultAgentFixtures(testCase.fixtures.seedAgents)
        let transcript = await DefaultAgentConfigurationEvaluator.run(
            query: testCase.query,
            maxIterations: exp.maxIterations ?? 6
        )
        await cleanupDefaultAgentFixtures(seededAgentIds)

        var verdicts: [CapabilityClaimsJudgement] = []
        if transcript.error == nil, !rubric.isEmpty {
            verdicts = await DefaultAgentConfigurationEvaluator.judge(
                finalText: transcript.finalText,
                conditions: rubric,
                model: judgeModel
            )
        }
        let elapsed = Date().timeIntervalSince(started) * 1000

        if let err = transcript.error {
            return EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: testCase.query,
                outcome: .errored,
                notes: ["agent loop error: \(err)"],
                modelId: modelId,
                latencyMs: elapsed
            )
        }

        var notes: [String] = []
        var passed = true

        let calledNames = transcript.toolCalls.map(\.name)
        let calledSet = Set(calledNames)

        if let must = exp.mustCallTools {
            let missing = must.filter { !calledSet.contains($0) }
            if missing.isEmpty {
                notes.append("mustCallTools ok: [\(must.joined(separator: ","))]")
            } else {
                passed = false
                notes.append("mustCallTools missing: [\(missing.joined(separator: ","))]")
            }
        }
        if let mustNot = exp.mustNotCallTools {
            let offenders = mustNot.filter { calledSet.contains($0) }
            if offenders.isEmpty {
                notes.append("mustNotCallTools ok")
            } else {
                passed = false
                notes.append("mustNotCallTools called: [\(offenders.joined(separator: ","))]")
            }
        }
        if let matchers = exp.argsMustContain {
            for matcher in matchers {
                let result = scoreArgsMustContain(matcher: matcher, transcript: transcript)
                passed = passed && result.passed
                notes.append(result.note)
            }
        }

        // LLM-judge rubric — every condition must pass.
        for (index, verdict) in verdicts.enumerated() {
            let condition = index < rubric.count ? rubric[index] : "(condition \(index))"
            if verdict.pass {
                notes.append("judge ok: \(condition)")
            } else {
                passed = false
                notes.append("judge FAIL: \(condition) — \(verdict.reason)")
            }
        }
        if !rubric.isEmpty && verdicts.count != rubric.count {
            passed = false
            notes.append(
                "judge produced \(verdicts.count) verdicts for \(rubric.count) conditions"
            )
        }

        if transcript.hitIterationCap {
            notes.append("warning: hit iteration cap (\(transcript.iterations)) — possible loop")
        }
        notes.append(
            "summary: toolCalls=[\(calledNames.joined(separator: ","))] "
                + "iters=\(transcript.iterations)"
        )
        notes.append("final: \(transcript.finalText.replacingOccurrences(of: "\n", with: " "))")

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: elapsed,
            telemetry: EvalCaseTelemetry(
                decodeTokensPerSecond: transcript.decodeTokensPerSecond,
                completionTokens: transcript.completionTokens
            )
        )
    }

    /// Pre-register the case's fixture agents in the isolated store so a
    /// `default_agent` create case can target a real custom agent. Returns the
    /// seeded ids (skipping malformed UUIDs) for teardown. Runs on the main
    /// actor because `AgentStore`/`AgentManager` are main-actor state.
    @MainActor
    private static func seedDefaultAgentFixtures(_ seeds: [EvalCase.SeedAgent]?) -> [UUID] {
        guard let seeds, !seeds.isEmpty else { return [] }
        var ids: [UUID] = []
        for seed in seeds {
            guard let id = UUID(uuidString: seed.id) else { continue }
            let agent = Agent(
                id: id,
                name: seed.name,
                description: "Seeded by OsaurusEvals; safe to delete."
            )
            AgentStore.save(agent)
            ids.append(id)
        }
        if !ids.isEmpty { AgentManager.shared.refresh() }
        return ids
    }

    /// Remove fixture agents seeded by `seedDefaultAgentFixtures` (and, via
    /// `AgentStore.delete`, any schedules they own) so a created schedule
    /// doesn't leak across cases in the shared isolated root.
    @MainActor
    private static func cleanupDefaultAgentFixtures(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { AgentStore.delete(id: id) }
        AgentManager.shared.refresh()
    }

    /// Score one `argsMustContain` matcher: at least one transcript call to
    /// `matcher.tool` whose parsed arguments satisfy every key→substring pair.
    /// Parsing the arguments JSON (rather than substring-matching the raw
    /// string) makes the assertion robust to whitespace and key order; the
    /// value comparison is a case-insensitive substring so enum/value casing
    /// from the model doesn't flake the check.
    private static func scoreArgsMustContain(
        matcher: EvalCase.DefaultAgentExpectations.ToolArgsMatcher,
        transcript: CapabilityClaimsTranscript
    ) -> (passed: Bool, note: String) {
        let pairs = matcher.args.map { "\($0)=\($1)" }.sorted().joined(separator: ",")
        let calls = transcript.toolCalls.filter { $0.name == matcher.tool }
        guard !calls.isEmpty else {
            return (false, "argsMustContain FAIL: \(matcher.tool) was never called")
        }
        for call in calls {
            guard
                let data = call.arguments.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let satisfiesAll = matcher.args.allSatisfy { key, expected in
                guard let actual = obj[key] else { return false }
                return argValueString(actual).lowercased().contains(expected.lowercased())
            }
            if satisfiesAll {
                return (true, "argsMustContain ok: \(matcher.tool){\(pairs)}")
            }
        }
        return (false, "argsMustContain FAIL: no \(matcher.tool) call matched {\(pairs)}")
    }

    /// Flatten one parsed JSON argument value to a string for substring
    /// matching. Strings pass through; JSON booleans (which decode as
    /// `NSNumber` backed by `CFBoolean`) render as `true`/`false`; other
    /// numbers use their canonical string; arrays/objects re-encode to JSON
    /// so a matcher can probe inside (e.g. a comma-joined id list).
    private static func argValueString(_ value: Any) -> String {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value),
                let s = String(data: data, encoding: .utf8)
            {
                return s
            }
            return String(describing: value)
        }
    }

    /// Score the skill-first ordering: the first `capabilities_load`
    /// call carrying `skill/<skill>` must occur before the first call to
    /// any tool in `beforeTools`. If no gated tool ran, the ordering is
    /// vacuously satisfied (nothing to gate).
    private static func scoreSkillFirst(
        matcher: EvalCase.CapabilityClaimsExpectations.SkillFirstMatcher,
        transcript: CapabilityClaimsTranscript
    ) -> (passed: Bool, note: String) {
        let gated = Set(matcher.beforeTools)
        let firstGatedIndex = transcript.toolCalls.firstIndex { gated.contains($0.name) }
        guard let gatedIndex = firstGatedIndex else {
            return (true, "skill-first vacuous: no gated tool called")
        }
        let skillLoadIndex = transcript.toolCalls.firstIndex { call in
            call.name == "capabilities_load"
                && (call.arguments.contains("skill/\(matcher.skill)")
                    || call.arguments.contains(matcher.skill))
        }
        guard let loadIndex = skillLoadIndex, loadIndex < gatedIndex else {
            return (
                false,
                "skill-first FAIL: gated tool ran before loading skill '\(matcher.skill)'"
            )
        }
        return (true, "skill-first ok: loaded '\(matcher.skill)' before gated tool")
    }

    /// Grant `names` to the agent for a case run. Returns the prior
    /// allowlist to restore, or nil when no mutation was needed (legacy
    /// global mode, or every name already enabled). Snapshot/restore
    /// mirrors `applyEnableSkills`.
    private static func applyEnableTools(
        _ names: [String]?,
        agentId: UUID
    ) async -> [String]? {
        guard let names, !names.isEmpty else { return nil }
        // nil = legacy global-enabled mode: the names are already
        // reachable, so there's nothing to grant or restore.
        guard let prior = AgentManager.shared.effectiveEnabledToolNames(for: agentId) else {
            return nil
        }
        let priorSet = Set(prior)
        let missing = names.filter { !priorSet.contains($0) }
        if missing.isEmpty { return nil }
        AgentManager.shared.updateEnabledToolNames(Array(priorSet.union(names)), for: agentId)
        return prior
    }

    /// Restore the allowlist snapshot taken by `applyEnableTools`.
    private static func restoreToolGrant(_ prior: [String]?, agentId: UUID) async {
        guard let prior else { return }
        AgentManager.shared.updateEnabledToolNames(prior, for: agentId)
    }

    // MARK: - Capability search fixture seeding

    /// Insert each `SeedMethod` into the live `MethodDatabase` and
    /// the `MethodSearchService` index. Returns the ids of methods
    /// that were actually inserted (skipping any that pre-existed) so
    /// `cleanupSeededMethods` only deletes what this case created —
    /// a developer who happens to have a real `eval-pdf-summary`
    /// method on disk doesn't lose it because their fixture name
    /// collided.
    ///
    /// Index errors are logged via `notes` but do not fail the case
    /// here; a missing index hit becomes a real recall miss in the
    /// observed `methodHits` count, which is exactly the signal the
    /// case is designed to surface.
    private static func applySeedMethods(_ seeds: [EvalCase.SeedMethod]?) async -> [String] {
        guard let seeds, !seeds.isEmpty else { return [] }
        var insertedIds: [String] = []
        for seed in seeds {
            // Skip when the id already exists so we never clobber a
            // real user method that happens to share the test slug.
            // `loadMethod` returns `Method?` and throws — flatten the
            // double-optional from `try?` into a single existence check.
            let existing = (try? MethodDatabase.shared.loadMethod(id: seed.id)) ?? nil
            if existing != nil { continue }
            let method = Method(
                id: seed.id,
                name: seed.name,
                description: seed.description,
                triggerText: seed.triggerText,
                body: seed.body ?? "",
                source: .user
            )
            do {
                try MethodDatabase.shared.insertMethod(method)
                await MethodSearchService.shared.indexMethod(method)
                insertedIds.append(seed.id)
            } catch {
                // Best-effort: continue. The case will read back fewer
                // candidates and the recall assertion will surface it.
                continue
            }
        }
        return insertedIds
    }

    /// Reverse of `applySeedMethods`. Tolerates missing rows (a crash
    /// mid-cleanup on a previous run could have already removed some)
    /// so re-running a case after a crash converges back to a clean
    /// state.
    private static func cleanupSeededMethods(_ ids: [String]) async {
        for id in ids {
            try? MethodDatabase.shared.deleteMethod(id: id)
            await MethodSearchService.shared.removeMethod(id: id)
        }
    }

    /// Snapshot the prior `enabled` flag of every named skill, then
    /// flip them all on. Returns `[(skillId, priorEnabled)]` for
    /// `restoreSkillEnabledState` to walk in reverse.
    ///
    /// Skill lookup is by name (case-insensitive, mirrors
    /// `SkillManager.skill(named:)`). Names that don't resolve are
    /// silently ignored — the `expectedSkills` matcher will surface
    /// the miss as a real recall failure rather than a config error.
    private static func applyEnableSkills(_ names: [String]?) async -> [(UUID, Bool)] {
        guard let names, !names.isEmpty else { return [] }
        var prior: [(UUID, Bool)] = []
        for name in names {
            guard let skill = SkillManager.shared.skill(named: name) else { continue }
            prior.append((skill.id, skill.enabled))
            if !skill.enabled {
                await SkillManager.shared.setEnabled(true, for: skill.id)
            }
        }
        return prior
    }

    /// Restore the snapshot taken by `applyEnableSkills`. Skips
    /// entries whose current state already matches the prior state
    /// to avoid an unnecessary disk write.
    private static func restoreSkillEnabledState(_ prior: [(UUID, Bool)]) async {
        for (id, wasEnabled) in prior {
            guard let current = SkillManager.shared.skill(for: id) else { continue }
            if current.enabled != wasEnabled {
                await SkillManager.shared.setEnabled(wasEnabled, for: id)
            }
        }
    }

    // MARK: - Helpers

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
