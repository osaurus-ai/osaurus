import Testing
@testable import osaurus

struct BuildPromptTests {
    @Test func buildPromptIncludesSystemAndConversation() async throws {
        let messages = [
            Message(role: .system, content: "You are helpful."),
            Message(role: .user, content: "Hi"),
            Message(role: .assistant, content: "Hello")
        ]
        let prompt = buildPrompt(from: messages, tools: nil, toolChoice: nil)
        #expect(prompt.contains("You are helpful.") == true)
        #expect(prompt.contains("User: Hi") == true)
        #expect(prompt.contains("Assistant: Hello") == true)
    }

    @Test func buildPromptIncludesToolsBlock() async throws {
        let messages = [Message(role: .user, content: "Test")] 
        let tools = [Tool(type: "function", function: ToolFunction(name: "search", description: "", parameters: .object([:])))]
        let prompt = buildPrompt(from: messages, tools: tools, toolChoice: .auto)
        #expect(prompt.contains("Tools:") == true)
        #expect(prompt.contains("\"name\":\"search\"") == true)
        #expect(prompt.contains("tool_choice:") == true)
    }
}


