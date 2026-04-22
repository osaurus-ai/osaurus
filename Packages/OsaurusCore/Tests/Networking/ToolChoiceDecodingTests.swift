//
//  ToolChoiceDecodingTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolChoiceDecodingTests {

    private func decode(_ json: String) throws -> ToolChoiceOption {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(ToolChoiceOption.self, from: data)
    }

    @Test func decodesAuto() throws {
        let value = try decode("\"auto\"")
        if case .auto = value { return }
        Issue.record("expected .auto")
    }

    @Test func decodesNone() throws {
        let value = try decode("\"none\"")
        if case .none = value { return }
        Issue.record("expected .none")
    }

    @Test func decodesFunction() throws {
        let value = try decode("{\"type\":\"function\",\"function\":{\"name\":\"my_tool\"}}")
        guard case .function(let f) = value else {
            Issue.record("expected .function")
            return
        }
        #expect(f.function.name == "my_tool")
    }

    /// Unknown strings used to silently decode as `.auto`, masking client typos.
    /// Decoding now throws so the bad value surfaces immediately.
    @Test func rejectsUnknownStrings() throws {
        do {
            _ = try decode("\"required\"")
            Issue.record("expected DecodingError for unknown string")
        } catch {
            // Expected
        }

        do {
            _ = try decode("\"REJECT\"")
            Issue.record("expected DecodingError for unknown string")
        } catch {
            // Expected
        }
    }
}
