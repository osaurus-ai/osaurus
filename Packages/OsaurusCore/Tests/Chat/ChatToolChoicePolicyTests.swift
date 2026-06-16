//
//  ChatToolChoicePolicyTests.swift
//

import Testing

@testable import OsaurusCore

struct ChatToolChoicePolicyTests {

    @Test
    func explicitFileToolIntentRequiresToolOnFirstAttempt() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "Using the available file tool, autonomously read mandelbrot.py lines 39 through 41.",
            attempt: 1
        )

        #expect(Self.isRequired(choice))
    }

    @Test
    func explicitNamedSandboxToolIntentRequiresToolOnFirstAttempt() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("sandbox_read_file")],
            userText: "Call sandbox_read_file for mandelbrot.py lines 39 through 41.",
            attempt: 1
        )

        #expect(Self.isRequired(choice))
    }

    @Test
    func subsequentAttemptFallsBackToAutoToAvoidToolLoops() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "Use the file_read tool for mandelbrot.py.",
            attempt: 2
        )

        #expect(Self.isAuto(choice))
    }

    @Test
    func ordinaryPromptKeepsAutoToolChoice() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "Reply with exactly: UI_OK",
            attempt: 1
        )

        #expect(Self.isAuto(choice))
    }

    @Test
    func explanatoryMentionsDoNotForceToolChoice() {
        let toolQuestion = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "What is a file tool?",
            attempt: 1
        )
        let workingDirectoryQuestion = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "What is a working directory?",
            attempt: 1
        )

        #expect(Self.isAuto(toolQuestion))
        #expect(Self.isAuto(workingDirectoryQuestion))
    }

    @Test
    func conversationalSlashLineAndSearchTextDoNotForceToolChoice() {
        let slashMention = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "Search Google for rock/roll history.",
            attempt: 1
        )
        let lineQuestion = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "How many lines are in Hamlet?",
            attempt: 1
        )

        #expect(Self.isAuto(slashMention))
        #expect(Self.isAuto(lineQuestion))
    }

    @Test
    func absolutePathWithFileActionRequiresToolChoice() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "Read /tmp/mandelbrot/source from disk.",
            attempt: 1
        )

        #expect(Self.isRequired(choice))
    }

    @Test
    func negatedToolIntentKeepsAutoToolChoice() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "Do not use tools; just explain what a Mandelbrot set is.",
            attempt: 1
        )

        #expect(Self.isAuto(choice))
    }

    @Test
    func emptyToolListOmitsToolChoice() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [],
            userText: "Use the file_read tool for mandelbrot.py.",
            attempt: 1
        )

        #expect(choice == nil)
    }

    private static func tool(_ name: String) -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(name: name, description: nil, parameters: nil)
        )
    }

    private static func isRequired(_ choice: ToolChoiceOption?) -> Bool {
        guard case .required = choice else { return false }
        return true
    }

    private static func isAuto(_ choice: ToolChoiceOption?) -> Bool {
        guard case .auto = choice else { return false }
        return true
    }
}
