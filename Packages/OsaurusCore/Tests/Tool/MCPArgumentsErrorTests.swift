//
//  MCPArgumentsErrorTests.swift
//  osaurusTests
//
//  Validates MCP argument JSON parsing: empty/whitespace inputs are accepted
//  as legitimate "no arguments" calls, while malformed JSON / non-object
//  payloads / upstream-error envelopes throw so the model receives a
//  structured error instead of silently running with empty args.
//

import Foundation
import Testing

@testable import OsaurusCore

struct MCPArgumentsErrorTests {

    @Test func emptyStringIsTreatedAsNoArguments() throws {
        let result = try MCPProviderTool.convertArgumentsToMCPValues("")
        #expect(result.isEmpty)
    }

    @Test func emptyJSONObjectIsTreatedAsNoArguments() throws {
        let result = try MCPProviderTool.convertArgumentsToMCPValues("{}")
        #expect(result.isEmpty)
    }

    @Test func validJSONObjectIsParsed() throws {
        let result = try MCPProviderTool.convertArgumentsToMCPValues(
            "{\"city\":\"Tokyo\",\"limit\":5}"
        )
        #expect(result.count == 2)
    }

    @Test func malformedJSONThrows() throws {
        do {
            _ = try MCPProviderTool.convertArgumentsToMCPValues("{not valid json")
            Issue.record("expected throw for malformed JSON")
        } catch {
            // Expected: structured error rather than silent empty dict
        }
    }

    @Test func nonObjectJSONThrows() throws {
        do {
            _ = try MCPProviderTool.convertArgumentsToMCPValues("[1, 2, 3]")
            Issue.record("expected throw for non-object JSON")
        } catch {
            // Expected
        }
    }

    /// When the upstream argument-serialization fails,
    /// `GenerationEventMapper.serializeArguments` emits an error envelope.
    /// MCP must surface that as a tool error rather than calling the tool
    /// with the `_error` field as an argument.
    @Test func upstreamSerializationFailureIsSurfacedAsError() throws {
        let envelope = "{\"_error\":\"argument_serialization_failed\",\"_tool\":\"foo\"}"
        do {
            _ = try MCPProviderTool.convertArgumentsToMCPValues(envelope)
            Issue.record("expected throw for upstream error envelope")
        } catch {
            // Expected
        }
    }
}
