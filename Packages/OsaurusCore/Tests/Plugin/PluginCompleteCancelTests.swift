//
//  PluginCompleteCancelTests.swift
//  osaurusTests
//
//  Tests for the v3 streaming-cancellation surface:
//
//  - `osr_host_api.complete_cancel` is wired and present in the host struct.
//  - `PluginHostContext.completeCancel(streamId:)` flips the per-context
//    cancellation flag for a registered stream id.
//  - Whitespace / empty stream ids are ignored.
//
//  Tests do NOT exercise an end-to-end streaming run (which would require a
//  real chat engine); the registry is the unit under test here. The
//  `completeStream` integration with the registry is verified by the
//  request-parse path in PluginHostAPI.swift and an `MockChatEngine`-backed
//  smoke test would be a future addition.
//

import Foundation
import Testing

@testable import OsaurusCore

struct PluginCompleteCancelTests {

    // MARK: - ABI presence

    @Test func hostAPIExposesCompleteCancel() {
        let dummyCancel: osr_complete_cancel_t = { _ in }
        var api = osr_host_api(version: 3)
        api.complete_cancel = dummyCancel
        #expect(api.complete_cancel != nil)
    }

    @Test func completeCancelTrampolineIsWiredOnHostAPI() throws {
        let ctx = try PluginHostContext(pluginId: "com.test.cancel.trampoline")
        defer { ctx.teardown() }
        // `buildHostAPI()` stores the pointer on the context; the context's
        // own deinit owns the lifetime, so we read the struct without
        // deallocating it ourselves.
        let ptr = ctx.buildHostAPI()
        let api = ptr.pointee
        // Host struct version reflects the current surface (v6 since
        // the host-side `free_string` callback was added on top of the
        // v5 `log_structured`).
        #expect(api.version == 6)
        // The cancel trampoline is wired (non-nil) so plugins can call it.
        #expect(api.complete_cancel != nil)
    }

    // MARK: - Registry semantics

    @Test func completeCancelMarksStreamId() throws {
        let ctx = try PluginHostContext(pluginId: "com.test.cancel.registry")
        defer { ctx.teardown() }
        let id = "stream-1"
        // Initially not cancelled.
        #expect(ctx.isStreamCancelled(id) == false)
        ctx.completeCancel(streamId: id)
        // Cancellation flag is now set so completeStream's next delta-loop
        // iteration would observe it and unwind.
        #expect(ctx.isStreamCancelled(id) == true)
    }

    @Test func completeCancelIgnoresEmptyStreamId() throws {
        let ctx = try PluginHostContext(pluginId: "com.test.cancel.empty")
        defer { ctx.teardown() }
        ctx.completeCancel(streamId: "")
        #expect(ctx.isStreamCancelled("") == false)
    }

    @Test func completeCancelIgnoresWhitespaceStreamId() throws {
        let ctx = try PluginHostContext(pluginId: "com.test.cancel.whitespace")
        defer { ctx.teardown() }
        ctx.completeCancel(streamId: "   \t  ")
        #expect(ctx.isStreamCancelled("   \t  ") == false)
    }

    @Test func completeCancelTrimsStreamId() throws {
        let ctx = try PluginHostContext(pluginId: "com.test.cancel.trim")
        defer { ctx.teardown() }
        ctx.completeCancel(streamId: "  stream-X  ")
        // The trimmed form is what gets registered.
        #expect(ctx.isStreamCancelled("stream-X") == true)
    }

    @Test func cancellationIsScopedPerContext() throws {
        let ctxA = try PluginHostContext(pluginId: "com.test.cancel.scopeA")
        let ctxB = try PluginHostContext(pluginId: "com.test.cancel.scopeB")
        defer {
            ctxA.teardown()
            ctxB.teardown()
        }
        let id = "shared-id"
        ctxA.completeCancel(streamId: id)
        // Cancelling on plugin A's context must not flip plugin B's flag —
        // plugins can't interfere with each other's streams.
        #expect(ctxA.isStreamCancelled(id) == true)
        #expect(ctxB.isStreamCancelled(id) == false)
    }
}
