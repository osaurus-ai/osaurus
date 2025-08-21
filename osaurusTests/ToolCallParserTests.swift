import Testing
import Foundation
@testable import osaurus

struct ToolCallParserTests {
    @Test func parseSimpleArguments() async throws {
        let text = """
        {"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"SF\"}"}}]}
        """
        let calls = ToolCallParser.parse(from: text)
        #expect(calls != nil)
        #expect(calls?.count == 1)
        #expect(calls?.first?.function.name == "get_weather")
        #expect(calls?.first?.type == "function")
        if let argsStr = calls?.first?.function.arguments,
           let data = argsStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            #expect(obj["city"] as? String == "SF")
        }
    }

    @Test func parseParametersFallback() async throws {
        let text = """
        ```json
        {"tool_calls":[{"function":{"name":"search","parameters":{"q":"hello","page":2}}}]}
        ```
        """
        let calls = ToolCallParser.parse(from: text)
        #expect(calls != nil)
        #expect(calls?.first?.function.name == "search")
        if let argsStr = calls?.first?.function.arguments,
           let data = argsStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            #expect(obj["q"] as? String == "hello")
            #expect(obj["page"] as? Int == 2)
        } else {
            #expect(Bool(false))
        }
    }

    @Test func parseWithAssistantPrefix() async throws {
        let text = "assistant: {\n  \"tool_calls\": [ { \"function\": { \"name\": \"ping\", \"arguments\": \"{\\\"host\\\":\\\"a.com\\\"}\" } } ]\n}"
        let calls = ToolCallParser.parse(from: text)
        #expect(calls != nil)
        #expect(calls?.first?.function.name == "ping")
    }

    @Test func noToolCallsReturnsNil() async throws {
        let text = "Hello world"
        #expect(ToolCallParser.parse(from: text) == nil)
    }
}


