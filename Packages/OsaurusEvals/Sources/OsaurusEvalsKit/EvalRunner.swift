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
            for testCase in suite.cases {
                if let filter, !testCase.id.contains(filter) { continue }
                let row = await runOne(
                    testCase,
                    modelId: modelLabel,
                    thresholdOverride: thresholdOverride
                )
                rows.append(annotatedWithCaseNotes(row, from: testCase))
            }
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
            latencyMs: row.latencyMs
        )
    }

    // MARK: - Per-case

    private static func runOne(
        _ testCase: EvalCase,
        modelId: String,
        thresholdOverride: Float? = nil
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
        case "capability_search":
            return await runCapabilitySearchCase(
                testCase,
                modelId: modelId,
                cliThresholdOverride: thresholdOverride
            )
        case "capability_claims":
            return await runCapabilityClaimsCase(testCase, modelId: modelId)
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
        cliThresholdOverride: Float?
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
            threshold: threshold
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

        let resolvedAgentId = AgentManager.shared.activeAgent.id

        // Skip rather than mutate global state when a must-be-absent tool
        // is actually enabled.
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

        let judgeModel = ProcessInfo.processInfo.environment["JUDGE_MODEL"]
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
