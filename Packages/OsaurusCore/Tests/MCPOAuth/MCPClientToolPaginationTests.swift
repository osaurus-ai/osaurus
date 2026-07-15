//
//  MCPClientToolPaginationTests.swift
//  osaurusTests
//
//  Regression coverage for cursor-following tools/list discovery
//  (osaurus-ai/osaurus#1999 — servers that paginate tools/list were
//  truncated to their first page).
//

import Foundation
import Logging
import MCP
import Testing

@testable import OsaurusCore

@Suite("MCP tools/list pagination")
struct MCPClientToolPaginationTests {
    @Test func listAllToolsFollowsNextCursorAcrossPages() async throws {
        let transport = PaginatedFakeMCPTransport(pages: [
            (tools: ["alpha", "beta"], nextCursor: "cursor-2"),
            (tools: ["gamma"], nextCursor: "cursor-3"),
            (tools: ["delta"], nextCursor: nil),
        ])
        let client = MCP.Client(name: "Osaurus", version: "1.0.0")
        _ = try await client.connect(transport: transport)
        defer { Task { await client.disconnect() } }

        let tools = try await client.listAllTools()

        #expect(tools.map(\.name) == ["alpha", "beta", "gamma", "delta"])
        #expect(await transport.receivedCursors == [nil, "cursor-2", "cursor-3"])
    }

    @Test func listAllToolsStopsOnRepeatedCursorInsteadOfLooping() async throws {
        let transport = PaginatedFakeMCPTransport(
            pages: [(tools: ["alpha"], nextCursor: "stuck")],
            stuckCursor: "stuck"
        )
        let client = MCP.Client(name: "Osaurus", version: "1.0.0")
        _ = try await client.connect(transport: transport)
        defer { Task { await client.disconnect() } }

        let tools = try await client.listAllTools()

        // The stuck page's tools are collected once; the repeated cursor
        // terminates the loop rather than re-fetching forever.
        #expect(tools.map(\.name) == ["alpha", "stuck-tool"])
    }

    @Test func probeDiscoversToolsFromPaginatedServer() async throws {
        let provider = MCPProvider(
            id: UUID(),
            name: "Paginated MCP",
            url: "",
            discoveryTimeout: 5,
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "fake-mcp"
        )

        let result = await MCPProviderProbeService.probeForTesting(
            provider: provider,
            transport: PaginatedFakeMCPTransport(pages: [
                (tools: ["list_tables"], nextCursor: "cursor-2"),
                (tools: ["list_table_rows"], nextCursor: nil),
            ])
        )

        #expect(result.succeeded)
        #expect(result.toolCount == 2)
        #expect(result.toolNames == ["list_tables", "list_table_rows"])
    }
}

/// Fake transport whose tools/list handler serves a fixed sequence of pages
/// keyed by the request's `cursor` param. An optional `stuckCursor` always
/// responds with the same `nextCursor` it was asked for, to exercise the
/// cycle guard.
private actor PaginatedFakeMCPTransport: MCP.Transport {
    nonisolated let logger = Logger(
        label: "osaurus.tests.paginated-fake-mcp-transport",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let pages: [(tools: [String], nextCursor: String?)]
    private let stuckCursor: String?
    private(set) var receivedCursors: [String?] = []

    init(pages: [(tools: [String], nextCursor: String?)], stuckCursor: String? = nil) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
        self.pages = pages
        self.stuckCursor = stuckCursor
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object, let method = object["method"] as? String else { return }
        let id = object["id"] ?? 0

        switch method {
        case "initialize":
            continuation.yield(
                responseData(
                    id: id,
                    result: [
                        "protocolVersion": "2025-11-25",
                        "capabilities": ["tools": [:]],
                        "serverInfo": ["name": "fake", "version": "1.0.0"],
                    ]
                )
            )
        case "tools/list":
            let params = object["params"] as? [String: Any]
            let cursor = params?["cursor"] as? String
            receivedCursors.append(cursor)
            continuation.yield(responseData(id: id, result: toolsPage(for: cursor)))
        default:
            break
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    private func toolsPage(for cursor: String?) -> [String: Any] {
        if let stuckCursor, cursor == stuckCursor {
            var page = toolsResult(names: ["stuck-tool"])
            page["nextCursor"] = stuckCursor
            return page
        }
        // Resolve the page: nil cursor is page 0; otherwise the page after
        // the one that emitted this cursor.
        let pageIndex: Int
        if let cursor {
            pageIndex = (pages.firstIndex(where: { $0.nextCursor == cursor }) ?? -1) + 1
        } else {
            pageIndex = 0
        }
        guard pageIndex < pages.count else { return toolsResult(names: []) }
        let page = pages[pageIndex]
        var result = toolsResult(names: page.tools)
        if let next = page.nextCursor {
            result["nextCursor"] = next
        }
        return result
    }

    private func toolsResult(names: [String]) -> [String: Any] {
        [
            "tools": names.map {
                [
                    "name": $0,
                    "description": "Fixture tool \($0)",
                    "inputSchema": ["type": "object", "properties": [:]],
                ]
            }
        ]
    }

    private func responseData(id: Any, result: [String: Any]) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        return try! JSONSerialization.data(withJSONObject: response)
    }
}
