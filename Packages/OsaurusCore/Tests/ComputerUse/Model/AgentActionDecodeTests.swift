//
//  AgentActionDecodeTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Decode/coerce/validate coverage for the single model-facing envelope
//  (`AgentAction.decode`). This is the JSON-discipline boundary every small
//  local model hits first, so the regressions we've actually shipped get a
//  deterministic guard here:
//   • malformed JSON and the ChatEngine `_error`/`invalid_tool_arguments`
//     envelope (the misleading "Missing required property: verb" bug),
//   • string→int `mark` coercion from quantized models,
//   • nested `target:{mark}` decode (regression for the upstream Gemma parser
//     fix that used to stringify the nested object),
//   • invalid / missing verbs, and
//   • `semanticProblem()` per verb (the verb-specific required fields the JSON
//     schema can't express).
//
//  Pure, model-free: `decode` is a static function over a string.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class AgentActionDecodeTests: XCTestCase {

    // MARK: - Helpers

    private func decoded(_ json: String) -> AgentAction? {
        if case .action(let action) = AgentAction.decode(argumentsJSON: json) { return action }
        return nil
    }

    private func invalidReason(_ json: String) -> String? {
        if case .invalid(let reason) = AgentAction.decode(argumentsJSON: json) { return reason }
        return nil
    }

    // MARK: - Malformed JSON

    func testMalformedJSONIsInvalid() {
        let reason = invalidReason("{not valid json")
        XCTAssertNotNil(reason)
        XCTAssertTrue(
            reason?.localizedCaseInsensitiveContains("valid json") ?? false,
            "Expected a 'not valid JSON' reason; got: \(reason ?? "nil")"
        )
    }

    func testNonObjectJSONIsInvalid() {
        // A bare array is valid JSON but not an agent_action object.
        XCTAssertNotNil(invalidReason("[1, 2, 3]"))
    }

    // MARK: - ChatEngine `_error` envelope

    func testErrorEnvelopeSurfacesMessageAndField() {
        let json = """
            {"_error":"invalid_tool_arguments","_message":"Property 'mark' must be an integer","_field":"mark"}
            """
        let reason = invalidReason(json)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("Property 'mark' must be an integer") ?? false)
        XCTAssertTrue(
            reason?.contains("mark") ?? false,
            "The offending field should be surfaced; got: \(reason ?? "nil")"
        )
        // Crucially NOT the misleading generic "Missing required property: verb".
        XCTAssertFalse(reason?.localizedCaseInsensitiveContains("missing required") ?? true)
    }

    func testErrorEnvelopeMarkFieldCarriesConcreteShapeHint() {
        // A bare "must be an integer" doesn't help a model that keeps emitting
        // `"mark": true`; the re-ask should show the corrected shape + the
        // `describe` fallback. Model-agnostic feedback — it never changes which
        // values are accepted, only what the model is told to fix.
        let json = """
            {"_error":"invalid_tool_arguments","_message":"Property 'mark' must be an integer","_field":"mark"}
            """
        let reason = invalidReason(json)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("Property 'mark' must be an integer") ?? false)
        XCTAssertTrue(
            reason?.contains("{\"mark\": 1}") ?? false,
            "Should show a concrete corrected mark; got: \(reason ?? "nil")"
        )
        XCTAssertTrue(
            reason?.localizedCaseInsensitiveContains("true/false") ?? false,
            "Should call out the boolean mistake; got: \(reason ?? "nil")"
        )
        XCTAssertTrue(
            reason?.contains("describe") ?? false,
            "Should offer the describe fallback; got: \(reason ?? "nil")"
        )
    }

    func testErrorEnvelopeTargetFieldCarriesObjectHint() {
        let json = """
            {"_error":"invalid_tool_arguments","_message":"Property 'target' must be an object","_field":"target"}
            """
        let reason = invalidReason(json)
        XCTAssertTrue(reason?.contains("mark") ?? false, "got: \(reason ?? "nil")")
        XCTAssertTrue(reason?.contains("describe") ?? false, "got: \(reason ?? "nil")")
    }

    /// A native JSON boolean `mark` is REJECTED, not silently mapped to `1`.
    /// `ArgumentCoercion.int(true)` happens to return `1` (NSNumber.intValue),
    /// but the preflight `SchemaValidator` excludes booleans on purpose:
    /// mapping `true` → "element 1" is a synthetic repair that could click the
    /// wrong element in a multi-element view. We surface a clear re-ask instead.
    func testBooleanMarkIsRejectedNotCoercedToOne() {
        let reason = invalidReason(#"{"verb":"click","target":{"mark":true}}"#)
        XCTAssertNotNil(reason, "A boolean mark must not decode to a valid action")
        XCTAssertTrue(
            reason?.localizedCaseInsensitiveContains("integer") ?? false,
            "Reason should explain mark must be an integer; got: \(reason ?? "nil")"
        )
    }

    func testErrorEnvelopeWithoutFieldOmitsFieldSuffix() {
        let json = """
            {"_error":"invalid_tool_arguments","_message":"Bad shape.","_field":""}
            """
        let reason = invalidReason(json)
        XCTAssertEqual(reason, "Bad shape.")
    }

    func testErrorEnvelopeWithoutMessageFallsBack() {
        let json = #"{"_error":"invalid_tool_arguments"}"#
        let reason = invalidReason(json)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains("required shape") ?? false)
    }

    // MARK: - Coercion

    func testStringMarkIsCoercedToInt() {
        let action = decoded(#"{"verb":"click","target":{"mark":"3"},"note":"open it"}"#)
        XCTAssertEqual(action?.verb, .click)
        XCTAssertEqual(action?.target?.mark, 3, "A string mark from a quantized model should coerce to Int")
    }

    func testStringReplaceIsCoercedToBool() {
        let action = decoded(#"{"verb":"type","text":"hi","replace":"false"}"#)
        XCTAssertEqual(action?.verb, .type)
        XCTAssertEqual(action?.replace, false)
    }

    func testStringifiedModifiersArrayCoerced() {
        let action = decoded(#"{"verb":"press_key","key":"a","modifiers":"[\"cmd\"]"}"#)
        XCTAssertEqual(action?.key, "a")
        XCTAssertEqual(action?.modifiers, ["cmd"])
    }

    // MARK: - Nested target (Gemma parser regression)

    func testNestedTargetMarkDecodes() {
        // The upstream Gemma parser fix stopped stringifying `target:{mark:1}`;
        // at the decode level a proper nested object must decode to a real mark.
        let action = decoded(#"{"verb":"click","target":{"mark":1},"note":"x"}"#)
        XCTAssertEqual(action?.target?.mark, 1)
        XCTAssertNil(action?.target?.describe)
    }

    func testNestedTargetDescribeDecodes() {
        let action = decoded(#"{"verb":"click","target":{"describe":"the Send button"}}"#)
        XCTAssertNil(action?.target?.mark)
        XCTAssertEqual(action?.target?.describe, "the Send button")
    }

    func testNestedTargetWithBothMarkAndDescribe() {
        let action = decoded(#"{"verb":"click","target":{"mark":4,"describe":"Save"}}"#)
        XCTAssertEqual(action?.target?.mark, 4)
        XCTAssertEqual(action?.target?.describe, "Save")
    }

    // MARK: - Verb validity

    func testInvalidVerbIsRejected() {
        let reason = invalidReason(#"{"verb":"frobnicate"}"#)
        XCTAssertNotNil(reason)
        XCTAssertTrue(
            reason?.localizedCaseInsensitiveContains("verb") ?? false,
            "Reason should reference the verb constraint; got: \(reason ?? "nil")"
        )
    }

    func testMissingVerbIsRejected() {
        let reason = invalidReason(#"{"text":"hello"}"#)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains("verb") ?? false)
    }

    func testVerbCaseIsNormalized() {
        // Quantized models routinely capitalize; the enum match is lenient.
        XCTAssertEqual(decoded(#"{"verb":"OBSERVE"}"#)?.verb, .observe)
    }

    func testUnexpectedPropertyRejected() {
        let reason = invalidReason(#"{"verb":"observe","bogus":1}"#)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains("bogus") ?? false)
    }

    // MARK: - semanticProblem() per verb

    func testClickRequiresTarget() {
        XCTAssertTrue(invalidReason(#"{"verb":"click"}"#)?.contains("target") ?? false)
    }

    func testClearRequiresTarget() {
        XCTAssertTrue(invalidReason(#"{"verb":"clear"}"#)?.contains("target") ?? false)
    }

    func testTypeRequiresText() {
        XCTAssertTrue(invalidReason(#"{"verb":"type"}"#)?.contains("text") ?? false)
    }

    func testSetValueRequiresText() {
        XCTAssertTrue(invalidReason(#"{"verb":"set_value","target":{"mark":1}}"#)?.contains("text") ?? false)
    }

    func testSetValueRequiresTarget() {
        let reason = invalidReason(#"{"verb":"set_value","text":"x"}"#)
        XCTAssertTrue(reason?.contains("target") ?? false, "got: \(reason ?? "nil")")
    }

    func testPressKeyRequiresKey() {
        XCTAssertTrue(invalidReason(#"{"verb":"press_key"}"#)?.contains("key") ?? false)
    }

    func testScrollRequiresDirection() {
        XCTAssertTrue(invalidReason(#"{"verb":"scroll"}"#)?.contains("direction") ?? false)
    }

    func testOpenRequiresApp() {
        XCTAssertTrue(invalidReason(#"{"verb":"open"}"#)?.contains("app") ?? false)
    }

    func testFindRequiresQueryOrRoles() {
        XCTAssertNotNil(invalidReason(#"{"verb":"find"}"#))
        // A roles-only find is valid.
        XCTAssertEqual(decoded(#"{"verb":"find","roles":["button"]}"#)?.verb, .find)
    }

    func testDoneRequiresReason() {
        XCTAssertTrue(invalidReason(#"{"verb":"done"}"#)?.contains("reason") ?? false)
    }

    func testGiveUpRequiresReason() {
        XCTAssertTrue(invalidReason(#"{"verb":"give_up"}"#)?.contains("reason") ?? false)
    }

    // MARK: - New verbs (Phase 2)

    func testDoubleClickRequiresTarget() {
        XCTAssertTrue(invalidReason(#"{"verb":"double_click"}"#)?.contains("target") ?? false)
    }

    func testRightClickRequiresTarget() {
        XCTAssertTrue(invalidReason(#"{"verb":"right_click"}"#)?.contains("target") ?? false)
    }

    func testDoubleClickDecodes() {
        let action = decoded(#"{"verb":"double_click","target":{"mark":2}}"#)
        XCTAssertEqual(action?.verb, .doubleClick)
        XCTAssertEqual(action?.target?.mark, 2)
    }

    func testRightClickDecodes() {
        let action = decoded(#"{"verb":"right_click","target":{"describe":"the row"}}"#)
        XCTAssertEqual(action?.verb, .rightClick)
        XCTAssertEqual(action?.target?.describe, "the row")
    }

    func testDragRequiresStartTarget() {
        let reason = invalidReason(#"{"verb":"drag","to":{"mark":2}}"#)
        XCTAssertTrue(reason?.contains("target") ?? false, "got: \(reason ?? "nil")")
    }

    func testDragRequiresDestination() {
        let reason = invalidReason(#"{"verb":"drag","target":{"mark":1}}"#)
        XCTAssertTrue(reason?.contains("to") ?? false, "got: \(reason ?? "nil")")
    }

    func testDragDecodesBothEndpoints() {
        let action = decoded(#"{"verb":"drag","target":{"mark":1},"to":{"mark":7}}"#)
        XCTAssertEqual(action?.verb, .drag)
        XCTAssertEqual(action?.target?.mark, 1)
        XCTAssertEqual(action?.to?.mark, 7)
    }

    func testWaitDecodesAndNeedsNoFields() {
        XCTAssertEqual(decoded(#"{"verb":"wait"}"#)?.verb, .wait)
        let action = decoded(#"{"verb":"wait","seconds":3}"#)
        XCTAssertEqual(action?.seconds, 3)
    }

    func testWaitSecondsCoercedFromString() {
        XCTAssertEqual(decoded(#"{"verb":"wait","seconds":"2"}"#)?.seconds, 2)
    }

    // MARK: - Valid actions

    func testObserveDecodes() {
        XCTAssertEqual(decoded(#"{"verb":"observe"}"#)?.verb, .observe)
    }

    func testTypeWithoutTargetIsValid() {
        let action = decoded(#"{"verb":"type","text":"hello world"}"#)
        XCTAssertEqual(action?.verb, .type)
        XCTAssertEqual(action?.text, "hello world")
    }

    func testScrollDecodesDirectionAndAmount() {
        let action = decoded(#"{"verb":"scroll","direction":"down","amount":5}"#)
        XCTAssertEqual(action?.direction, .down)
        XCTAssertEqual(action?.amount, 5)
    }

    func testDoneDecodesReason() {
        let action = decoded(#"{"verb":"done","reason":"All set."}"#)
        XCTAssertEqual(action?.verb, .done)
        XCTAssertEqual(action?.reason, "All set.")
    }

    // MARK: - argumentsJSON() round-trip

    func testArgumentsJSONRoundTrips() {
        let cases: [AgentAction] = [
            AgentAction(verb: .observe),
            AgentAction(verb: .click, target: AgentTarget(mark: 3), note: "open it"),
            AgentAction(verb: .click, target: AgentTarget(describe: "the Send button")),
            AgentAction(verb: .type, text: "hello", replace: true, note: "fill the field"),
            AgentAction(verb: .setValue, target: AgentTarget(mark: 2), text: "v"),
            AgentAction(verb: .pressKey, key: "return", modifiers: ["cmd", "shift"]),
            AgentAction(verb: .scroll, direction: .down, amount: 4),
            AgentAction(verb: .open, app: "Safari"),
            AgentAction(verb: .find, query: "Send", roles: ["button"]),
            AgentAction(verb: .doubleClick, target: AgentTarget(mark: 5)),
            AgentAction(verb: .rightClick, target: AgentTarget(describe: "the row")),
            AgentAction(verb: .drag, target: AgentTarget(mark: 1), to: AgentTarget(mark: 9)),
            AgentAction(verb: .wait, seconds: 3),
            AgentAction(verb: .done, reason: "Completed."),
        ]
        for original in cases {
            let json = original.argumentsJSON()
            guard let round = decoded(json) else {
                return XCTFail("argumentsJSON for \(original.verb) did not decode: \(json)")
            }
            XCTAssertEqual(round, original, "Round-trip mismatch for \(original.verb): \(json)")
        }
    }
}
