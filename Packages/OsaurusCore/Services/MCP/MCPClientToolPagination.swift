//
//  MCPClientToolPagination.swift
//  OsaurusCore
//
//  Cursor-following wrapper around `MCP.Client.listTools`. The MCP spec
//  allows servers to paginate `tools/list`; a single call only returns the
//  first page, so callers that treat it as the full tool set silently drop
//  every tool past page one (osaurus-ai/osaurus#1999 — Baserow returns a
//  paginated list and Osaurus discovered zero tools).
//

import Foundation
import MCP

extension MCP.Client {
    /// Fetch every page of `tools/list`, following `nextCursor` until the
    /// server stops returning one.
    ///
    /// `maxPages` is a guard against a misbehaving server that returns a
    /// cursor forever (or cycles cursors); on hitting the cap the tools
    /// collected so far are returned rather than throwing, since a partial
    /// list is strictly more useful than none.
    public func listAllTools(maxPages: Int = 100) async throws -> [MCP.Tool] {
        var allTools: [MCP.Tool] = []
        var cursor: String? = nil
        var seenCursors = Set<String>()
        for _ in 0..<maxPages {
            let (tools, nextCursor) = try await listTools(cursor: cursor)
            allTools.append(contentsOf: tools)
            guard let next = nextCursor, !next.isEmpty else {
                return allTools
            }
            // A repeated cursor would loop forever without the page cap;
            // bail out early instead of burning the remaining pages.
            guard seenCursors.insert(next).inserted else {
                return allTools
            }
            cursor = next
        }
        return allTools
    }
}
