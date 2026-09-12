//
//  ChatToolChoicePolicyTests.swift
//

import Testing

@testable import OsaurusCore

struct ChatToolChoicePolicyTests {

    @Test
    func delegatedDeliveryInstructionsDoNotBecomeTaskToolIntent() {
        let input = "What are two practical benefits of reusable water bottles? Answer in two short bullet points."
        let tools = [Self.tool("share_artifact"), Self.tool("search_and_extract")]
        #expect(Self.isAuto(ChatToolChoicePolicy.resolve(tools: tools, userText: input, attempt: 1)))
        let dispatched = AgentDelegationDispatcher.delegatedPrompt(input: input)
        let request = DispatchRequest(prompt: dispatched, source: .delegation, toolIntentText: input)
        #expect(request.prompt == dispatched)
        #expect(Self.isAuto(ChatToolChoicePolicy.resolve(tools: tools, userText: request.toolIntentText, attempt: 1)))
    }

    @Test
    func delegatedExplicitToolIntentIsPreserved() {
        let input = "Call share_artifact with the finished report."
        let request = DispatchRequest(
            prompt: AgentDelegationDispatcher.delegatedPrompt(input: input),
            source: .delegation,
            toolIntentText: input
        )
        #expect(
            Self.isRequired(
                ChatToolChoicePolicy.resolve(
                    tools: [Self.tool("share_artifact")],
                    userText: request.toolIntentText,
                    attempt: 1
                )
            )
        )
    }

    @Test
    func ordinaryDispatchKeepsOriginalToolIntent() {
        let request = DispatchRequest(prompt: "Call file_read for report.md", source: .schedule)
        #expect(request.toolIntentText == request.prompt)
    }

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

    @Test
    func redactionShapedRequestForcesRedactFileOnFirstAttempt() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("file_read"), Self.tool("redact_file")],
            userText: """
                Look in the selected folder for the file "note.txt". Edit the file using the following criteria:
                Replace names with "[REDACTED NAME]"
                Replace emails with "[REDACTED EMAIL]"
                """,
            attempt: 1
        )

        guard case .function(let fn) = choice else {
            Issue.record("expected forced redact_file, got \(String(describing: choice))")
            return
        }
        #expect(fn.function.name == "redact_file")
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
        // "name"/"email" singulars are everyday coding vocabulary; only
        // plural/phrase PII forms may trigger the forced route.
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
    func ambiguousNoun_withPlaceholderSignal_stillForces() {
        let choice = ChatToolChoicePolicy.resolve(
            tools: [Self.tool("redact_file")],
            userText: "Replace names with \"[REDACTED NAME]\" in note.txt",
            attempt: 1
        )
        guard case .function(let fn) = choice else {
            Issue.record("placeholder signal must keep the forced route")
            return
        }
        #expect(fn.function.name == "redact_file")
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

    private static func isRequired(_ choice: ToolChoiceOption?) -> Bool {
        guard case .required = choice else { return false }
        return true
    }

    private static func isAuto(_ choice: ToolChoiceOption?) -> Bool {
        guard case .auto = choice else { return false }
        return true
    }
}
