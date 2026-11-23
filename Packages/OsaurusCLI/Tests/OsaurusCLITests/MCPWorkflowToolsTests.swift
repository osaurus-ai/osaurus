import Foundation
import MCP
import XCTest

@testable import OsaurusCLICore

final class MCPWorkflowToolsTests: XCTestCase {
    private let briefID = "11111111-1111-1111-1111-111111111111"
    private let setupID = "22222222-2222-2222-2222-222222222222"
    private var store: CLITokenStore!

    override func setUp() {
        super.setUp()
        store = CLITokenStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-wf-\(UUID())/token"))
        try? store.save("osc_approved")
        StubURLProtocol.requests = []
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        store.clear()
        super.tearDown()
    }

    private var listing: [String: Any] {
        [
            "workflows": [
                [
                    "id": briefID, "name": "Daily Brief", "tool_name": "workflow_daily_brief",
                    "summary": "Morning summary",
                    "input_schema": ["type": "object", "properties": ["city": ["type": "string"]]],
                    "needs_setup": false,
                ],
                [
                    "id": setupID, "name": "Invoice Intake", "tool_name": "workflow_invoice_intake",
                    "input_schema": [:], "needs_setup": true, "setup_summary": "Pick a folder.",
                ],
            ]
        ]
    }

    private func tools(_ patterns: String = "") -> MCPWorkflowTools {
        let server = LocalServerClient(
            port: 1337, accessKey: nil, commandLabel: "mcp", tokenStore: store, interactive: false,
            session: StubURLProtocol.session())
        return MCPWorkflowTools(
            filter: MCPWorkflowFilter(patterns: patterns), client: WorkflowClient(server: server), budget: 5,
            poll: .milliseconds(1))
    }

    private func body(_ result: CallTool.Result?) throws -> [String: Any] {
        guard case .text(let text, _, _) = try XCTUnwrap(result?.content.first) else {
            throw XCTSkip("no text content")
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func reply(_ object: Any, status: Int = 200) -> (Int, Data) {
        (status, try! JSONSerialization.data(withJSONObject: object))
    }

    // MARK: Filter

    func testFilterParsing() {
        XCTAssertNil(MCPWorkflowFilter.parse(args: ["--tools", "x"]))
        XCTAssertEqual(MCPWorkflowFilter.parse(args: ["--workflows"])?.summary, "all")
        XCTAssertEqual(MCPWorkflowFilter.parse(args: ["--workflows", "--tools", "x"])?.summary, "all")
        XCTAssertEqual(MCPWorkflowFilter.parse(args: ["--workflows", "brief,inv*"])?.summary, "brief, inv*")
        XCTAssertEqual(MCPWorkflowFilter.parse(args: ["--workflows=*"])?.summary, "all")
    }

    func testFilterMatchesNamesToolNamesAndPrefixes() {
        let brief = WorkflowSummary(listing["workflows"].flatMap { ($0 as? [[String: Any]])?.first }!)!
        XCTAssertTrue(MCPWorkflowFilter(patterns: "Daily Brief").admits(brief))
        XCTAssertTrue(MCPWorkflowFilter(patterns: "workflow_daily_brief").admits(brief))
        XCTAssertTrue(MCPWorkflowFilter(patterns: briefID).admits(brief))
        XCTAssertTrue(MCPWorkflowFilter(patterns: "daily*").admits(brief))
        XCTAssertTrue(MCPWorkflowFilter(patterns: "workflow_dai*").admits(brief))
        XCTAssertFalse(MCPWorkflowFilter(patterns: "invoice*").admits(brief))
        XCTAssertFalse(MCPWorkflowFilter(patterns: "Weekly").admits(brief))
    }

    // MARK: Listing

    func testListsChosenWorkflowsAndTheStatusTool() async throws {
        StubURLProtocol.handler = { _ in self.reply(self.listing) }
        let all = try await tools().tools()
        XCTAssertEqual(all.map(\.name), ["workflow_daily_brief", "workflow_invoice_intake", "workflow_run_status"])
        XCTAssertTrue(all[0].description?.contains("Morning summary") == true)
        XCTAssertTrue(all[1].description?.contains("Needs setup") == true)
        guard case .object(let schema) = all[1].inputSchema else { return XCTFail("schema not an object") }
        XCTAssertEqual(schema["type"], .string("object"), "an empty schema still declares an object")

        let one = try await tools("daily_brief").tools()
        XCTAssertEqual(one.map(\.name), ["workflow_daily_brief", "workflow_run_status"])
        XCTAssertEqual(
            StubURLProtocol.requests.first?.value(forHTTPHeaderField: LocalServerClient.tokenHeaderName), "osc_approved")
    }

    // MARK: Calls

    func testCallRunsTheWorkflowAndReturnsItsOutput() async throws {
        let runID = "33333333-3333-3333-3333-333333333333"
        let polls = Counter()
        StubURLProtocol.handler = { request in
            switch (request.httpMethod ?? "GET", request.url!.path) {
            case ("GET", "/workflows"): return self.reply(self.listing)
            case ("POST", "/workflows/\(self.briefID)/run"): return self.reply(["run_id": runID], status: 202)
            case ("GET", "/workflows/runs/\(runID)"):
                polls.value += 1
                return self.reply(
                    polls.value < 3
                        ? ["status": "running", "run_id": runID]
                        : ["status": "completed", "run_id": runID, "output": ["summary": "Sunny"]])
            default: return (404, Data())
            }
        }
        let result = await tools().call("workflow_daily_brief", arguments: ["city": "Paris"])
        XCTAssertEqual(result?.isError, false)
        let report = try body(result)
        XCTAssertEqual(report["status"] as? String, "completed")
        XCTAssertEqual((report["output"] as? [String: Any])?["summary"] as? String, "Sunny")
        let start = try XCTUnwrap(StubURLProtocol.requests.first { $0.httpMethod == "POST" })
        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(start.httpBody ?? start.httpBodyStream.map(readAll)))
                as? [String: Any])
        XCTAssertEqual((sent["input"] as? [String: Any])?["city"] as? String, "Paris")
    }

    func testAFormHandsBackTheRunID() async throws {
        let runID = "44444444-4444-4444-4444-444444444444"
        StubURLProtocol.handler = { request in
            switch (request.httpMethod ?? "GET", request.url!.path) {
            case ("GET", "/workflows"): return self.reply(self.listing)
            case ("POST", _): return self.reply(["run_id": runID], status: 202)
            default:
                return self.reply([
                    "status": "awaiting_user", "run_id": runID,
                    "pending_dialog": [
                        "id": "d", "node_id": "n", "title": "Confirm", "fields": [["key": "ok", "label": "Looks right?"]],
                    ],
                ])
            }
        }
        let result = await tools().call("workflow_daily_brief", arguments: [:])
        XCTAssertEqual(result?.isError, false)
        let report = try body(result)
        XCTAssertEqual(report["status"] as? String, "awaiting_user")
        XCTAssertEqual(report["run_id"] as? String, runID)
        XCTAssertEqual((report["form"] as? [String: Any])?["fields"] as? [String], ["Looks right?"])
        XCTAssertTrue((report["next"] as? String)?.contains("workflow_run_status") == true)
    }

    func testSetupAndUnknownToolsAndRefusal() async throws {
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return self.reply(["error": "app_only", "message": "no"], status: 403)
            }
            return self.reply(self.listing)
        }
        let setup = await tools().call("workflow_invoice_intake", arguments: [:])
        XCTAssertEqual(setup?.isError, true)
        XCTAssertTrue((try body(setup)["message"] as? String)?.contains("Pick a folder.") == true)

        let other = await tools().call("osaurus_help", arguments: [:])
        XCTAssertNil(other, "not a workflow tool: the proxy handles it")
        let hidden = await tools("invoice*").call("workflow_daily_brief", arguments: [:])
        XCTAssertNil(hidden, "a workflow outside --workflows is not served here")

        let refused = await tools().call("workflow_daily_brief", arguments: [:])
        XCTAssertEqual(refused?.isError, true)
        XCTAssertTrue((try body(refused)["message"] as? String)?.contains("osaurus workflow run") == true)
    }

    func testStatusToolNeedsARunID() async throws {
        let missing = await tools().call(MCPWorkflowTools.statusToolName, arguments: [:])
        XCTAssertEqual(missing?.isError, true)
        StubURLProtocol.handler = { _ in self.reply(["status": "failed", "run_id": "r", "error": "boom"]) }
        let failed = await tools().call(MCPWorkflowTools.statusToolName, arguments: ["run_id": "r"])
        XCTAssertEqual(failed?.isError, true)
        XCTAssertEqual(try body(failed)["error"] as? String, "boom")
    }

    func testStatusWaitKeepsWaitingWhileTheOwnerFillsTheForm() async throws {
        let polls = Counter()
        StubURLProtocol.handler = { _ in
            polls.value += 1
            return self.reply(
                polls.value < 4
                    ? ["status": "awaiting_user", "run_id": "r", "pending_dialog": ["id": "d", "node_id": "n"]]
                    : ["status": "completed", "run_id": "r", "output": ["plan": "Pro"]])
        }
        let waited = await tools().call(MCPWorkflowTools.statusToolName, arguments: ["run_id": "r", "wait": true])
        XCTAssertEqual(try body(waited)["status"] as? String, "completed")
        XCTAssertEqual(polls.value, 4)
        XCTAssertFalse(
            StubURLProtocol.requests.contains { $0.httpMethod == "POST" }, "the MCP client never answers the form")

        polls.value = 0
        let peeked = await tools().call(MCPWorkflowTools.statusToolName, arguments: ["run_id": "r"])
        XCTAssertEqual(try body(peeked)["status"] as? String, "awaiting_user", "without wait it reports at once")
    }
}

final class Counter: @unchecked Sendable {
    var value = 0
}

func readAll(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
