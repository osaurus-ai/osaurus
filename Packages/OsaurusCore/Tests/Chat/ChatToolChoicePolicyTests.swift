//
//  ChatToolChoicePolicyTests.swift
//

import Testing

@testable import OsaurusCore

struct ChatToolChoicePolicyTests {

    @Test
    func naturalLanguageDoesNotInventForcedToolChoice() {
        let prompts = [
            "Using the same starting balances from your example, suppose the debit succeeds but the credit fails and the transaction rolls back. What are A, B, and their total afterward? Also clarify whether your statement that every other session sees the old balances holds at every isolation level.",
            "Explain how to complete a transaction.",
            "What does file_read do?",
            "Redact all names and emails in note.txt",
        ]
        for prompt in prompts {
            let choice = ChatToolChoicePolicy.resolve(
                tools: [
                    Self.tool("clarify"), Self.tool("complete"),
                    Self.tool("file_read"), Self.tool("redact_file"),
                ],
                userText: prompt,
                attempt: 1
            )
            #expect(Self.isAuto(choice), "UI prose must not synthesize tool_choice: \(prompt)")
        }
    }

    @Test
    func explicitFileToolProseLeavesSelectionToModel() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "Using the available file tool, autonomously read mandelbrot.py lines 39 through 41.",
            attempt: 1
        )

        #expect(Self.isAuto(choice))
    }

    @Test
    func explicitNamedSandboxToolProseLeavesSelectionToModel() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("sandbox_read_file")],
            userText: "Call sandbox_read_file for mandelbrot.py lines 39 through 41.",
            attempt: 1
        )

        #expect(Self.isAuto(choice))
    }

    @Test
    func subsequentAttemptKeepsAuto() {
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
    func absolutePathWithFileActionKeepsAuto() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read")],
            userText: "Read /tmp/mandelbrot/source from disk.",
            attempt: 1
        )

        #expect(Self.isAuto(choice))
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

    @Test
    func redactionShapedRequestDoesNotForceFileMutation() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read"), Self.tool("redact_file")],
            userText: """
                Look in the selected folder for the file "note.txt". Edit the file using the following criteria:
                Replace names with "[REDACTED NAME]"
                Replace emails with "[REDACTED EMAIL]"
                """,
            attempt: 1
        )

        #expect(Self.isAuto(choice))
    }

    @Test
    func redactionIntent_secondAttempt_returnsAuto() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("redact_file")],
            userText: "Redact all names and emails in note.txt",
            attempt: 2
        )
        #expect(Self.isAuto(choice))
    }

    @Test
    func codingRequest_withBareSingularNoun_doesNotForceRedactFile() {
        // Coding vocabulary must not synthesize a file-mutating tool constraint.
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_edit"), Self.tool("redact_file")],
            userText: "Replace the function name in app.py with a shorter one",
            attempt: 1
        )
        if case .function = choice {
            Issue.record("bare singular noun must not force redact_file")
        }
    }

    @Test
    func ambiguousNoun_withWeakVerb_andNoRedactionSignal_doesNotForce() {
        // The live false positive: "names" is also data/code vocabulary,
        // and the forced tool WRITES — this prompt redacted a CSV's email
        // cells before the two-tier check.
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_edit"), Self.tool("redact_file")],
            userText: "Replace the column names in the CSV header of data.csv with lowercase versions",
            attempt: 1
        )
        if case .function = choice {
            Issue.record("ambiguous noun without redaction signal must not force redact_file")
        }
    }

    @Test
    func ambiguousNoun_withPlaceholderSignal_keepsAuto() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("redact_file")],
            userText: "Replace names with \"[REDACTED NAME]\" in note.txt",
            attempt: 1
        )
        #expect(Self.isAuto(choice))
    }

    @Test
    func genericReplace_withoutPIINoun_doesNotForceRedactFile() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_edit"), Self.tool("redact_file")],
            userText: "Replace every comma with a semicolon in note.txt",
            attempt: 1
        )
        if case .function = choice {
            Issue.record("generic replace must not force redact_file")
        }
    }

    @Test
    func redactionIntent_withoutRedactFileRegistered_fallsThrough() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_edit")],
            userText: "Redact all names and emails in note.txt",
            attempt: 1
        )
        if case .function = choice {
            Issue.record("must not force an unregistered tool")
        }
    }

    @Test
    func forcedToolGate_refusesMismatchedCall_untilMatchingCallDisarms() {
        let gate = ForcedToolChoiceGate()
        gate.arm(.function(.init(type: "function", function: .init(name: "redact_file"))))

        // Mismatch refused, gate stays armed for the rest of the wave.
        let first = gate.violationEnvelope(calledTool: "file_read")
        #expect(first?.contains("redact_file") == true)
        #expect(gate.violationEnvelope(calledTool: "shell_run") != nil)

        // Matching call executes and disarms.
        #expect(gate.violationEnvelope(calledTool: "redact_file") == nil)
        #expect(gate.violationEnvelope(calledTool: "file_read") == nil)
    }

    @Test
    func forcedToolGate_autoChoice_disarms() {
        let gate = ForcedToolChoiceGate()
        gate.arm(.function(.init(type: "function", function: .init(name: "redact_file"))))
        gate.arm(.auto)
        #expect(gate.violationEnvelope(calledTool: "file_read") == nil)
    }

    private static func tool(_ name: String) -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(name: name, description: nil, parameters: nil)
        )
    }

    private static func isAuto(_ choice: ToolChoiceOption?) -> Bool {
        guard case .auto = choice else { return false }
        return true
    }
}
