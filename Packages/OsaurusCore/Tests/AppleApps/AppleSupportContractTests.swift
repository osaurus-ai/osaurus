//
//  AppleSupportContractTests.swift
//  OsaurusCoreTests — AppleApps
//
//  Shared-support contracts for the Apple app tools: AppleScript literal
//  escaping and record parsing on Unicode scalars, JSON bridging of
//  non-finite numbers, and the typed registry permission-gate envelope.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Apple tools: shared support contracts")
struct AppleSupportContractTests {

    @Test("literal() escapes a quote or backslash even when a combining mark fuses it into one grapheme")
    func literalEscapesPerScalar() {
        // U+0301 (combining acute) fused onto `"` makes a single Character;
        // a Character-based loop would leave the quote unescaped.
        let fusedQuote = "\"\u{0301}"
        let fusedBackslash = "\\\u{0301}"
        let quoted = AppleScriptBridge.literal("a" + fusedQuote + "b" + fusedBackslash + "c")
        #expect(quoted.hasPrefix("\""))
        #expect(quoted.hasSuffix("\""))
        let inner = String(quoted.dropFirst().dropLast())
        // Every raw `"` inside the body must be preceded by a backslash.
        var previous: Unicode.Scalar? = nil
        for scalar in inner.unicodeScalars {
            if scalar == "\"" { #expect(previous == "\\") }
            previous = scalar
        }
        // Scalar-level checks (String.contains is grapheme-based and would
        // not see `\"` when the combining mark fuses onto the quote).
        let scalars = Array(inner.unicodeScalars)
        #expect(scalars.filter { $0 == "\\" }.count == 3)  // one before `"`, two for the backslash
        #expect(scalars.filter { $0 == "\"" }.count == 1)
        // Plain characters and the combining marks are preserved verbatim.
        #expect(inner.unicodeScalars.filter { $0 == "\u{0301}" }.count == 2)
        #expect(AppleScriptBridge.literal("line\nbreak\ttab") == "\"line\\nbreak\\ttab\"")
    }

    @Test("parseRecords splits on separator scalars even when a combining mark follows them")
    func parseRecordsPerScalar() {
        let fs = String(AppleScriptBridge.fieldSeparator)
        let rs = String(AppleScriptBridge.recordSeparator)
        let output = "a" + fs + "\u{0301}b" + rs + "c" + fs + "d" + rs
        let rows = AppleScriptBridge.parseRecords(output)
        #expect(rows.count == 2)
        #expect(rows[0].count == 2)
        #expect(rows[0][0] == "a")
        #expect(rows[0][1] == "\u{0301}b")
        #expect(rows[1] == ["c", "d"])
        #expect(AppleScriptBridge.parseRecords("").isEmpty)
        // Empty fields are kept so column positions stay stable.
        #expect(AppleScriptBridge.parseRecords("x" + fs + fs + "z") == [["x", "", "z"]])
    }

    @Test("AppleJSON.serializable maps non-finite numbers to null and keeps finite ones")
    func nonFiniteNumbers() throws {
        let payload: [String: Any?] = [
            "nan": Double.nan, "inf": Double.infinity, "neg": -Double.infinity,
            "ok": 1.5, "int": 3, "boxed": NSNumber(value: Double.nan), "flag": true,
        ]
        let out = try #require(AppleJSON.serializable(payload) as? [String: Any])
        #expect(out["nan"] is NSNull)
        #expect(out["inf"] is NSNull)
        #expect(out["neg"] is NSNull)
        #expect(out["boxed"] is NSNull)
        #expect(out["ok"] as? Double == 1.5)
        #expect(out["int"] as? Int == 3)
        #expect(out["flag"] as? Bool == true)
        // The whole envelope must remain serialisable.
        #expect(JSONSerialization.isValidJSONObject(out))
    }

    @Test("the registry's missing-permission (code 7) error renders a typed permission_denied envelope with the settings pane")
    @MainActor
    func codeSevenEnvelope() throws {
        let error = NSError(
            domain: "ToolRegistry", code: 7,
            userInfo: [
                NSLocalizedDescriptionKey: "Missing system permissions for tool: calendar_events. Required: Calendar.",
                ToolRegistry.missingPermissionUserInfoKey: SystemPermission.calendar.rawValue,
                ToolRegistry.missingPermissionSettingsURLUserInfoKey: SystemPermission.calendar.systemSettingsURL?.absoluteString ?? "",
            ]
        )
        let json = ToolEnvelope.fromError(error, tool: "calendar_events")
        let dict = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == ToolEnvelope.Kind.permissionDenied.rawValue)
        #expect(dict["retryable"] as? Bool == false)
        #expect(dict["permission"] as? String == SystemPermission.calendar.rawValue)
        let url = try #require(dict["system_settings_url"] as? String)
        #expect(url.hasPrefix("x-apple.systempreferences:"))

        // Without the typed keys the envelope is still permission_denied.
        let bare = NSError(domain: "ToolRegistry", code: 7, userInfo: [NSLocalizedDescriptionKey: "missing"])
        let bareJSON = ToolEnvelope.fromError(bare, tool: "calendar_events")
        let bareDict = try #require(JSONSerialization.jsonObject(with: Data(bareJSON.utf8)) as? [String: Any])
        #expect(bareDict["kind"] as? String == ToolEnvelope.Kind.permissionDenied.rawValue)
        #expect(bareDict["permission"] == nil)
    }

    @Test("a write script whose caller was cancelled while queued is skipped, not run")
    func cancelledWriteIsSkipped() async {
        // The executor's skipIf seam is what the bridge feeds with the
        // cancellation flag; prove the seam abandons the run unexecuted.
        let result = await AppleScriptExecutor.run(
            source: "return \"ran\"", timeout: 5, skipIf: { true }
        )
        #expect(result.status == .timedOut)
        #expect(result.output == nil)
        #expect(result.errorMessage == AppleScriptExecutor.skippedBeforeStartMessage)
    }
}
