//
//  EvalRunner.swift
//  OsaurusEvalsKit
//
//  Orchestrates one suite run: applies the model selection, walks each
//  case sequentially (avoids tripping the CoreModelService circuit
//  breaker), and assembles an `EvalReport`.
//
//  Cases run on the main actor — `PreflightEvaluator.evaluate` is
//  main-actor-isolated because the underlying registry / agent /
//  plugin manager state is. Sequencing keeps the state guarantees
//  simple and matches how preflight runs in the actual chat path.
//

import Foundation
import OsaurusCore

@MainActor
public enum EvalRunner {

    /// Run every case in `suite`, one at a time, and produce a report.
    /// `filter` is a substring that must appear in `case.id` for the
    /// case to run — the CLI exposes it via `--filter` so a contributor
    /// debugging a single case doesn't burn tokens on the whole suite.
    public static func run(
        suite: EvalSuite,
        model: ModelSelection,
        filter: String? = nil
    ) async -> EvalReport {
        // The CLI is its own process — it has to scan + dlopen every
        // installed plugin manually before preflight can see plugin
        // tools (the host app does this in AppDelegate). Without it
        // every `requirePlugins` case skips with "missing plugins" no
        // matter what's actually installed on disk.
        await PreflightEvaluator.loadInstalledPlugins()

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
                let row = await runOne(testCase, modelId: modelLabel)
                rows.append(row)
            }
        }

        return EvalReport(modelId: modelLabel, startedAt: startedAt, cases: rows)
    }

    // MARK: - Per-case

    private static func runOne(_ testCase: EvalCase, modelId: String) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        switch testCase.domain {
        case "preflight":
            break  // fall through to the existing preflight body below
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
        case "request_validation":
            return runRequestValidationCase(testCase, modelId: modelId)
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

        // Skip cases whose required plugins aren't installed locally.
        // We check before calling preflight so the LLM doesn't burn
        // a generation just to reveal a fixture mismatch.
        if let required = testCase.fixtures.requirePlugins, !required.isEmpty {
            let installed = PreflightEvaluator.installedPluginIds()
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

        // `EvalCase.PreflightMode` mirrors `PreflightSearchMode` raw
        // values 1:1 (off / narrow / balanced / wide); the rawValue
        // bridge keeps the enums decoupled without a hand-rolled
        // mapping function.
        let mode =
            PreflightSearchMode(
                rawValue: (testCase.fixtures.preflightMode ?? .balanced).rawValue
            ) ?? .balanced
        let observed = await PreflightEvaluator.evaluate(query: testCase.query, mode: mode)

        let toolResult = Scorers.scoreTools(observed: observed, expectation: testCase.expect.tools)
        let companionResult = Scorers.scoreCompanions(
            observed: observed,
            expectation: testCase.expect.companions
        )
        let aggregate = Scorers.aggregate(
            tools: toolResult?.score,
            companions: companionResult?.score
        )
        let score = EvalCaseScore(
            aggregate: aggregate,
            tools: toolResult?.score,
            companions: companionResult?.score
        )
        let notes = (toolResult?.notes ?? []) + (companionResult?.notes ?? [])
        let outcome: EvalCaseOutcome = aggregate >= 1.0 ? .passed : .failed

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: outcome,
            score: score,
            observed: observed,
            notes: notes,
            modelId: modelId,
            latencyMs: observed.latencyMs
        )
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

    // MARK: - Helpers

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
