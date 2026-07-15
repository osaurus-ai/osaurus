//
//  CurrentTimeToolTests.swift
//  osaurusTests
//
//  Exercises `get_current_time`: the no-argument default path, an explicit
//  IANA timezone, and the typed failure for an unknown timezone. The instant
//  itself is read from the system clock, so the assertions pin the envelope
//  shape and timezone plumbing rather than a specific wall-clock value.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct CurrentTimeToolTests {

    private func decode(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func returnsLocalTimeWithNoArguments() async throws {
        let tool = CurrentTimeTool()
        let dict = try decode(try await tool.execute(argumentsJSON: "{}"))

        #expect(dict["ok"] as? Bool == true)
        #expect(dict["tool"] as? String == "get_current_time")

        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["timezone"] as? String == TimeZone.current.identifier)
        #expect((result["iso8601"] as? String)?.isEmpty == false)
        #expect((result["readable"] as? String)?.isEmpty == false)
        #expect((result["unix_seconds"] as? Int) != nil)
    }

    @Test
    func honorsExplicitTimezone() async throws {
        let tool = CurrentTimeTool()
        let dict = try decode(
            try await tool.execute(argumentsJSON: #"{"timezone": "America/New_York"}"#)
        )

        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["timezone"] as? String == "America/New_York")
        // Eastern time is a negative UTC offset, so the ISO string ends in
        // `-04:00` (DST) or `-05:00` (standard) — never `Z`.
        let iso = try #require(result["iso8601"] as? String)
        #expect(iso.contains("-04:00") || iso.contains("-05:00"))
    }

    @Test
    func rejectsUnknownTimezone() async throws {
        let tool = CurrentTimeTool()
        let dict = try decode(
            try await tool.execute(argumentsJSON: #"{"timezone": "Mars/Olympus_Mons"}"#)
        )

        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
        #expect(dict["field"] as? String == "timezone")
        #expect(dict["tool"] as? String == "get_current_time")
    }

    @Test
    func rejectsNonStringTimezone() async throws {
        let tool = CurrentTimeTool()
        let dict = try decode(
            try await tool.execute(argumentsJSON: #"{"timezone": 42}"#)
        )

        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
        #expect(dict["field"] as? String == "timezone")
    }
}
