import Foundation
import XCTest

@testable import OsaurusCLICore

final class AgentCommandTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-cli-\(UUID())")
        StubURLProtocol.requests = []
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func server(token: String? = nil) -> LocalServerClient {
        let store = CLITokenStore(fileURL: directory.appendingPathComponent("token"))
        if let token { try? store.save(token) }
        return LocalServerClient(
            port: 1337, accessKey: nil, commandLabel: "agent", tokenStore: store, interactive: false,
            session: StubURLProtocol.session())
    }

    private func sse(_ chunks: [Any]) -> Data {
        var text = ": ping\n\n"
        for chunk in chunks {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
            text += "data: \(json)\n\n"
        }
        return Data((text + "data: [DONE]\n\n").utf8)
    }

    nonisolated(unsafe) private static let agents: [String: Any] = [
        "agents": [
            ["id": "00000000-0000-0000-0000-000000000001", "name": "Osaurus", "is_built_in": true],
            [
                "id": "AAAAAAAA-0000-0000-0000-000000000002", "name": "Code Reviewer",
                "effective_model": "qwen3", "description": "Reviews diffs",
            ],
        ]
    ]

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map(readAll))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Parsing

    func testParsesRun() throws {
        XCTAssertEqual(
            try AgentCommand.parse(["run", "Code Reviewer", "-p", "hi", "--session", "work-1", "--json"]),
            .run(.init(agent: "Code Reviewer", prompt: "hi", session: "work-1", json: true)))
        XCTAssertEqual(try AgentCommand.parse(["list", "--json"]), .list(json: true))
        XCTAssertEqual(try AgentCommand.parse(["--help"]), .help)
        XCTAssertThrowsError(try AgentCommand.parse(["run"]))
        XCTAssertThrowsError(try AgentCommand.parse(["run", "x", "unquoted", "prompt"]))
        XCTAssertThrowsError(try AgentCommand.parse(["run", "x", "--session", "../etc"]))
        XCTAssertThrowsError(try AgentCommand.parse(["list", "-p", "x"]))
    }

    func testPipedInputFollowsThePrompt() {
        XCTAssertEqual(AgentCommand.combinedPrompt("Review this", piped: "diff\n"), "Review this\n\ndiff")
        XCTAssertEqual(AgentCommand.combinedPrompt(nil, piped: "only stdin"), "only stdin")
        XCTAssertEqual(AgentCommand.combinedPrompt("just -p", piped: "  \n"), "just -p")
    }

    func testResolvesAgents() {
        let agents = (Self.agents["agents"] as! [[String: Any]]).compactMap(AgentSummary.init)
        for query in ["default", "osaurus", "code reviewer", "code-reviewer", "aaaaaaaa-0000-0000-0000-000000000002"] {
            guard case .found = AgentSummary.resolve(query, in: agents) else { return XCTFail(query) }
        }
        XCTAssertEqual(AgentSummary.resolve("nobody", in: agents), .notFound)
        XCTAssertEqual(agents[1].model, "qwen3")
    }

    func testListingMarksOnlyTheAgentThatDefaultPicks() {
        let osaurus = AgentSummary(["id": "1", "name": "Osaurus", "is_built_in": true])!
        let architect = AgentSummary(["id": "2", "name": "Architect", "is_built_in": true, "effective_model": "foundation"])!
        XCTAssertEqual(AgentCommand.describe(osaurus, isDefault: true), "Osaurus  (default)")
        XCTAssertEqual(AgentCommand.describe(architect, isDefault: false), "Architect  (built-in)  [foundation]")
    }

    // MARK: Stream

    func testStreamParserReadsTextToolsErrorsAndDone() {
        XCTAssertEqual(AgentStreamParser.parse(line: ": ping"), [])
        XCTAssertEqual(AgentStreamParser.parse(line: "data: [DONE]"), [.done])
        XCTAssertEqual(
            AgentStreamParser.parse(line: #"data: {"choices":[{"index":0,"delta":{"content":"Hi"}}]}"#), [.text("Hi")])
        XCTAssertEqual(
            AgentStreamParser.parse(line: #"data: {"choices":[{"index":0,"delta":{"reasoning_content":"hmm"}}]}"#), [])
        XCTAssertEqual(
            AgentStreamParser.parse(
                line: #"data: {"choices":[],"osaurus_agent_tool":{"phase":"started","name":"web_fetch","call_id":"1","label":"Fetch page"}}"#),
            [.toolStarted(name: "web_fetch", label: "Fetch page")])
        XCTAssertEqual(
            AgentStreamParser.parse(line: #"data: {"error":{"message":"Model unavailable","type":"x"}}"#),
            [.error("Model unavailable")])
        XCTAssertTrue(
            AgentStreamParser.isApprovalRefusal(
                "Tool 'web_fetch' requires interactive approval in the Osaurus app. Enable auto-approve…"))
        XCTAssertEqual(
            AgentStreamParser.errorMessage(#"{"ok":false,"message":"Not found"}"#), "Not found")
    }

    func testRunStreamsTheAnswerAndKeepsTheSession() async throws {
        let reviewerID = "AAAAAAAA-0000-0000-0000-000000000002"
        StubURLProtocol.handler = { request in
            if request.url!.path == "/agents" {
                return (200, try! JSONSerialization.data(withJSONObject: Self.agents))
            }
            return (
                200,
                self.sse([
                    ["choices": [["index": 0, "delta": ["role": "assistant", "content": ""]]]],
                    ["choices": [], "osaurus_agent_tool": ["phase": "started", "name": "web_fetch", "call_id": "1"]],
                    [
                        "choices": [],
                        "osaurus_agent_tool": [
                            "phase": "completed", "name": "web_fetch", "call_id": "1", "is_error": true,
                            "result": "Tool 'web_fetch' requires interactive approval in the Osaurus app.",
                        ],
                    ],
                    ["choices": [["index": 0, "delta": ["content": "Looks "]]]],
                    ["choices": [["index": 0, "delta": ["content": "good."]]]],
                ])
            )
        }
        let sessions = AgentSessionStore(directory: directory.appendingPathComponent("sessions"))
        let options = AgentCommand.RunOptions(agent: "code reviewer", prompt: "Review", session: "pr-9", json: true)
        let status = try await AgentCommand.run(options, server: server(), sessions: sessions)
        XCTAssertEqual(status, EXIT_SUCCESS)

        let run = try XCTUnwrap(StubURLProtocol.requests.first { $0.url!.path == "/agents/\(reviewerID)/run" })
        let sent = try body(of: run)
        XCTAssertEqual(sent["session_id"] as? String, "cli-pr-9")
        XCTAssertEqual((sent["messages"] as? [[String: Any]])?.last?["content"] as? String, "Review")
        XCTAssertNil(run.value(forHTTPHeaderField: AgentCommand.approvalSessionHeader), "no approvals without a token")

        let saved = try XCTUnwrap(sessions.load("pr-9"))
        XCTAssertEqual(saved.agent, reviewerID)
        XCTAssertEqual(saved.messages.map(\.content), ["Review", "Looks good."])

        StubURLProtocol.requests = []
        let followUp = AgentCommand.RunOptions(agent: reviewerID, prompt: "And now?", session: "pr-9", json: true)
        _ = try await AgentCommand.run(followUp, server: server(), sessions: sessions)
        let second = try body(
            of: try XCTUnwrap(StubURLProtocol.requests.first { $0.url!.path.hasSuffix("/run") }))
        XCTAssertEqual(
            (second["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? String },
            ["Review", "Looks good.", "And now?"])

        let other = AgentCommand.RunOptions(agent: "default", prompt: "x", session: "pr-9", json: true)
        do {
            _ = try await AgentCommand.run(other, server: server(), sessions: sessions)
            XCTFail("a session stays with its agent")
        } catch {}
    }

    func testAFailedRunExitsOneAndSavesNothing() async throws {
        StubURLProtocol.handler = { request in
            if request.url!.path == "/agents" {
                return (200, try! JSONSerialization.data(withJSONObject: Self.agents))
            }
            return (200, self.sse([["error": ["message": "No model is loaded.", "type": "x"]]]))
        }
        let sessions = AgentSessionStore(directory: directory.appendingPathComponent("sessions"))
        let options = AgentCommand.RunOptions(agent: "default", prompt: "hi", session: "s1", json: true)
        let status = try await AgentCommand.run(options, server: server(), sessions: sessions)
        XCTAssertEqual(status, EXIT_FAILURE)
        XCTAssertNil(sessions.load("s1"))
    }

    func testDeclinedNoteNamesTheToolsAndTheSetting() {
        let note = AgentCommand.declinedNote(["web_fetch", "web_fetch", "mail_send"])
        XCTAssertTrue(note.contains("mail_send, web_fetch"))
        XCTAssertTrue(note.contains("Tools & MCP → All Tools"))
    }

    // MARK: Approvals

    func testApprovalDecisions() {
        XCTAssertEqual(ApprovalDecision.parse("y", offersRunLease: false), .allowOnce)
        XCTAssertEqual(ApprovalDecision.parse("R", offersRunLease: true), .allowForRun)
        XCTAssertNil(ApprovalDecision.parse("r", offersRunLease: false))
        XCTAssertEqual(ApprovalDecision.parse("always", offersRunLease: false), .alwaysAllow)
        XCTAssertEqual(ApprovalDecision.parse(" n ", offersRunLease: false), .deny)
        XCTAssertNil(ApprovalDecision.parse("", offersRunLease: true))
    }

    func testWatchAnswersEachCardOnceWithTheSession() async throws {
        let answered = Flag()
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                answered.value = true
                return (200, Data(#"{"ok":true}"#.utf8))
            }
            let cards: [[String: Any]] =
                answered.value
                ? []
                : [["id": "card-1", "tool": "web_fetch", "arguments": "{}", "offers_run_lease": true]]
            return (200, try! JSONSerialization.data(withJSONObject: ["approvals": cards]))
        }
        let approvals = TerminalApprovals(server: server(token: "osc_ok"), session: "cli-abc12345", poll: .milliseconds(5))
        let asked = Counter()
        let watch = Task {
            await approvals.watch(
                ask: { card, _ in
                    asked.value += 1
                    return card.offersRunLease ? .allowForRun : .allowOnce
                }, note: { _ in })
        }
        for _ in 0..<200 where !answered.value { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        watch.cancel()
        XCTAssertEqual(asked.value, 1)
        let list = try XCTUnwrap(StubURLProtocol.requests.first { $0.httpMethod != "POST" })
        XCTAssertEqual(list.url?.query, "session=cli-abc12345")
        let post = try XCTUnwrap(StubURLProtocol.requests.first { $0.httpMethod == "POST" })
        XCTAssertEqual(post.url?.path, "/approvals/card-1")
        let sent = try body(of: post)
        XCTAssertEqual(sent["decision"] as? String, "allow_for_run")
        XCTAssertEqual(sent["session"] as? String, "cli-abc12345")
        XCTAssertEqual(post.value(forHTTPHeaderField: LocalServerClient.tokenHeaderName), "osc_ok")
    }

    func testACardAnsweredOnTheMacStopsTheQuestion() async throws {
        let listed = Counter()
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return (500, Data()) }
            listed.value += 1
            let cards: [[String: Any]] = listed.value <= 1 ? [["id": "card-2", "tool": "mail_send"]] : []
            return (200, try! JSONSerialization.data(withJSONObject: ["approvals": cards]))
        }
        let approvals = TerminalApprovals(server: server(token: "osc_ok"), session: "cli-abc12345", poll: .milliseconds(5))
        let notes = OutputLog()
        let gaveUp = Flag()
        let watch = Task {
            await approvals.watch(
                ask: { _, stillPending in
                    while stillPending() { try? await Task.sleep(for: .milliseconds(2)) }
                    gaveUp.value = true
                    return nil
                }, note: { notes.append($0) })
        }
        for _ in 0..<200 where !gaveUp.value { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(20))
        watch.cancel()
        XCTAssertTrue(gaveUp.value)
        XCTAssertTrue(notes.text.contains("Answered in Osaurus."))
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }

    func testTheTerminalQuestionStopsWhenTheCardGoesAway() throws {
        var controller: Int32 = -1
        var terminal: Int32 = -1
        XCTAssertEqual(openpty(&controller, &terminal, nil, nil, nil), 0)
        defer {
            close(controller)
            close(terminal)
        }
        let start = Date()
        let line = TerminalApprovals.readLine(tty: terminal) { Date().timeIntervalSince(start) > 0.3 }
        XCTAssertNil(line)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "a terminal with no input must not block the read")

        var answer = Array("y\n".utf8)
        _ = write(controller, &answer, answer.count)
        XCTAssertEqual(TerminalApprovals.readLine(tty: terminal) { false }, "y")
    }

    func testSessionIDs() {
        XCTAssertTrue(AgentSessionStore.isValidID("work-1.2_b"))
        XCTAssertFalse(AgentSessionStore.isValidID(".hidden"))
        XCTAssertFalse(AgentSessionStore.isValidID("a/b"))
        XCTAssertFalse(AgentSessionStore.isValidID(""))
    }
}
