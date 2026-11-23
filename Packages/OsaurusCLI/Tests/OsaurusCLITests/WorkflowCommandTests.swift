import Foundation
import XCTest

@testable import OsaurusCLICore

final class WorkflowCommandTests: XCTestCase {
    private func summary(_ id: String, _ name: String, tool: String? = nil, schema: [String: Any] = [:]) -> WorkflowSummary {
        WorkflowSummary([
            "id": id, "name": name, "tool_name": tool ?? "workflow_" + WorkflowClient.slug(name),
            "input_schema": schema, "needs_setup": false,
        ])!
    }

    // MARK: Parsing

    func testParsesRunOptions() throws {
        let invocation = try WorkflowCommand.parse([
            "run", "Daily Brief", "--input", "city=Paris", "-i", "days=3", "--no-wait", "--json",
        ])
        var expected = WorkflowCommand.RunOptions(workflow: "Daily Brief", inputs: ["city=Paris", "days=3"])
        expected.wait = false
        expected.json = true
        XCTAssertEqual(invocation, .run(expected))
        XCTAssertEqual(try WorkflowCommand.parse(["runs", "brief", "--limit", "5"]), .runs(workflow: "brief", limit: 5, json: false))
        XCTAssertEqual(try WorkflowCommand.parse(["status", "abc", "--json"]), .status(runID: "abc", json: true))
        XCTAssertEqual(try WorkflowCommand.parse(["run", "x", "--help"]), .help)
    }

    func testRejectsBadArguments() {
        XCTAssertThrowsError(try WorkflowCommand.parse([]))
        XCTAssertThrowsError(try WorkflowCommand.parse(["run"]))
        XCTAssertThrowsError(try WorkflowCommand.parse(["run", "x", "--text", "hi", "--input", "a=b"]))
        XCTAssertThrowsError(try WorkflowCommand.parse(["list", "--no-wait"]), "run-only flags stay on run")
        XCTAssertThrowsError(try WorkflowCommand.parse(["runs", "--limit", "0"]))
        XCTAssertThrowsError(try WorkflowCommand.parse(["frobnicate"]))
    }

    func testInputsTakeTheSchemaType() throws {
        let schema: [String: Any] = [
            "properties": [
                "count": ["type": "integer"], "ratio": ["type": "number"], "loud": ["type": "boolean"],
                "tags": ["type": "array"], "note": ["type": ["string", "null"]],
            ]
        ]
        let values = try WorkflowCommand.inputValues(
            ["count=3", "ratio=0.5", "loud=yes", #"tags=["a","b"]"#, "note=a=b", "unknown=7"], schema: schema)
        XCTAssertEqual(values["count"] as? Int, 3)
        XCTAssertEqual(values["ratio"] as? Double, 0.5)
        XCTAssertEqual(values["loud"] as? Bool, true)
        XCTAssertEqual(values["tags"] as? [String], ["a", "b"])
        XCTAssertEqual(values["note"] as? String, "a=b", "only the first = splits")
        XCTAssertEqual(values["unknown"] as? String, "7")
        XCTAssertThrowsError(try WorkflowCommand.inputValues(["count=many"], schema: schema))
        XCTAssertThrowsError(try WorkflowCommand.inputValues(["=x"], schema: schema))
    }

    // MARK: Resolution

    func testResolvesByIdToolNameAndName() {
        let brief = summary("11111111-1111-1111-1111-111111111111", "Daily Brief")
        let other = summary("22222222-2222-2222-2222-222222222222", "Invoice Intake")
        let all = [brief, other]
        for query in [brief.id.lowercased(), "workflow_daily_brief", "daily_brief", "daily brief", "Daily-Brief"] {
            guard case .found(let match) = WorkflowClient.resolve(query, in: all) else {
                return XCTFail("no match for \(query)")
            }
            XCTAssertEqual(match.id, brief.id, query)
        }
        guard case .notFound = WorkflowClient.resolve("nope", in: all) else { return XCTFail("expected not found") }
        let twin = summary("33333333-3333-3333-3333-333333333333", "daily brief", tool: "workflow_daily_brief_2")
        guard case .ambiguous(let both) = WorkflowClient.resolve("Daily Brief", in: [brief, twin]) else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(both.count, 2)
    }

    // MARK: Forms

    func testFormAnswersEachFieldWithDefaults() {
        let dialog: [String: Any] = [
            "title": "Details", "message": "Tell me more",
            "fields": [
                ["key": "city", "label": "City", "type": "text", "required": true],
                ["key": "days", "label": "Days", "type": "number", "required": true, "default": 2],
                ["key": "mode", "label": "Mode", "type": "choice", "options": ["fast", "slow"]],
                ["key": "ok", "label": "OK", "type": "bool"],
                ["key": "note", "label": "Note", "type": "text", "required": false],
                ["key": "pin", "label": "PIN", "type": "secret"],
            ],
            "prefill": ["city": "Paris"],
        ]
        let lines = LineFeed(["", "", "nope", "2", "maybe", "y", ""])
        let output = OutputLog()
        let io = WorkflowFormPrompt.IO(
            write: { output.append($0) }, readLine: { lines.next() }, readSecret: { _ in "1234" })
        let values = WorkflowFormPrompt.ask(dialog, io: io)
        XCTAssertEqual(values["city"] as? String, "Paris")
        XCTAssertEqual(values["days"] as? Int, 2)
        XCTAssertEqual(values["mode"] as? String, "slow")
        XCTAssertEqual(values["ok"] as? Bool, true)
        XCTAssertNil(values["note"])
        XCTAssertEqual(values["pin"] as? String, "1234")
        XCTAssertTrue(output.text.contains("Pick one of the numbers above."))
        XCTAssertTrue(output.text.contains("Enter y or n."))
        XCTAssertFalse(output.text.contains("1234"), "a secret is never echoed")
    }

    // MARK: Waiting

    func testWaitAnswersTheFormThenReturnsTheResult() async throws {
        let runID = "44444444-4444-4444-4444-444444444444"
        let answered = Flag()
        StubURLProtocol.requests = []
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            if path == "/workflows/runs/\(runID)" {
                let body: [String: Any] =
                    answered.value
                    ? ["status": "completed", "run_id": runID, "output": ["summary": "done"]]
                    : [
                        "status": "awaiting_user", "run_id": runID,
                        "pending_dialog": [
                            "id": "d1", "node_id": "ask", "current": true, "title": "Need",
                            "fields": [["key": "name", "type": "text"]],
                        ],
                    ]
                return (200, try! JSONSerialization.data(withJSONObject: body))
            }
            if path == "/workflows/runs/\(runID)/dialogs/ask" {
                answered.value = true
                return (200, Data(#"{"ok":true}"#.utf8))
            }
            return (404, Data())
        }
        defer { StubURLProtocol.handler = nil }
        let server = LocalServerClient(
            port: 1337, accessKey: nil, commandLabel: "workflow",
            tokenStore: CLITokenStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID())")),
            interactive: false, session: StubURLProtocol.session())

        let parked = try await WorkflowCommand.wait(
            for: runID, client: WorkflowClient(server: server), answerForms: false, poll: .milliseconds(1))
        XCTAssertEqual(WorkflowCommand.exitCode(for: parked), WorkflowCommand.exitAwaitingInput)
        XCTAssertFalse(answered.value)

        let lines = LineFeed(["Ada"])
        let io = WorkflowFormPrompt.IO(write: { _ in }, readLine: { lines.next() }, readSecret: { _ in nil })
        let finished = try await WorkflowCommand.wait(
            for: runID, client: WorkflowClient(server: server), answerForms: true, io: io, poll: .milliseconds(1))
        XCTAssertTrue(answered.value)
        XCTAssertEqual(WorkflowCommand.exitCode(for: finished), 0)
        let answer = try XCTUnwrap(StubURLProtocol.requests.first { $0.url!.path.hasSuffix("/dialogs/ask") })
        let body = try XCTUnwrap(answer.httpBody ?? answer.httpBodyStream.map(readAll))
        let values = try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["values"] as? [String: Any])
        XCTAssertEqual(values["name"] as? String, "Ada")
    }

    func testExitCodes() {
        XCTAssertEqual(WorkflowCommand.exitCode(for: ["status": "completed"]), 0)
        XCTAssertEqual(WorkflowCommand.exitCode(for: ["status": "failed"]), 1)
        XCTAssertEqual(WorkflowCommand.exitCode(for: ["status": "cancelled"]), 1)
        XCTAssertEqual(WorkflowCommand.exitCode(for: ["status": "needs_setup"]), 1)
        XCTAssertEqual(WorkflowCommand.exitCode(for: ["status": "awaiting_user"]), 3)
    }

    func testRenderPrintsTextOutputsPlainly() {
        XCTAssertEqual(WorkflowCommand.render("hello"), "hello")
        XCTAssertEqual(WorkflowCommand.render(["summary": "hi"]), "hi")
        XCTAssertTrue(WorkflowCommand.render(["a": 1, "b": 2]).contains("\"a\" : 1"))
    }
}

final class LineFeed: @unchecked Sendable {
    private var lines: [String]
    init(_ lines: [String]) { self.lines = lines }
    func next() -> String? { lines.isEmpty ? nil : lines.removeFirst() }
}

final class OutputLog: @unchecked Sendable {
    private(set) var text = ""
    func append(_ s: String) { text += s }
}

final class Flag: @unchecked Sendable {
    var value = false
}
