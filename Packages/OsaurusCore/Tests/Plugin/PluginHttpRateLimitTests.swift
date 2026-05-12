//
//  PluginHttpRateLimitTests.swift
//  OsaurusCoreTests
//
//  Pins the per-(plugin, agent) HTTP rate limiter added to the
//  `http_request` trampoline. A chatty plugin that loops on
//  `host->http_request` could otherwise saturate the shared
//  `httpSession` connection pool, trip third-party rate limits
//  silently, or DoS the host's userInitiated cooperative pool. The
//  cap is host-side defense; well-behaved plugins still need to
//  implement their own backoff against upstream APIs.
//

import Foundation
import Testing

@testable import OsaurusCore

struct PluginHttpRateLimitTests {

    private let agentId = UUID()

    private func makeContext() throws -> PluginHostContext {
        try PluginHostContext(pluginId: "com.test.httprl.\(UUID().uuidString)")
    }

    @Test func defaultsAreDocumented() {
        // The published defaults are part of the contract authors will
        // see in the `rate_limit_exceeded` envelope. Pin them so a
        // casual tweak doesn't silently change the documented numbers.
        #expect(PluginHostContext.httpRateLimit == 60)
        #expect(PluginHostContext.httpRateWindow == 60)
    }

    @Test func allowsFirstRequest() throws {
        let ctx = try makeContext()
        defer { ctx.teardown() }
        #expect(ctx.checkHttpRateLimit(agentId: agentId) == true)
    }

    @Test func allowsUpToLimit() throws {
        let ctx = try makeContext()
        defer { ctx.teardown() }
        for i in 0 ..< PluginHostContext.httpRateLimit {
            #expect(
                ctx.checkHttpRateLimit(agentId: agentId) == true,
                "request \(i) within budget should be allowed"
            )
        }
    }

    @Test func deniesAtLimitPlusOne() throws {
        let ctx = try makeContext()
        defer { ctx.teardown() }
        for _ in 0 ..< PluginHostContext.httpRateLimit {
            _ = ctx.checkHttpRateLimit(agentId: agentId)
        }
        #expect(ctx.checkHttpRateLimit(agentId: agentId) == false)
    }

    @Test func differentAgentsHaveIndependentBuckets() throws {
        // Same plugin context, two different agents. Saturating one
        // must not affect the other — matches the dispatch limiter's
        // per-(plugin, agent) shape.
        let ctx = try makeContext()
        defer { ctx.teardown() }
        let agentA = UUID()
        let agentB = UUID()

        for _ in 0 ..< PluginHostContext.httpRateLimit {
            _ = ctx.checkHttpRateLimit(agentId: agentA)
        }
        #expect(ctx.checkHttpRateLimit(agentId: agentA) == false)
        #expect(ctx.checkHttpRateLimit(agentId: agentB) == true)
    }

    @Test func differentPluginsHaveIndependentBuckets() throws {
        // Each plugin keeps its own `PluginHostContext`, so a hot
        // plugin can't starve a quiet one against the same agent.
        let ctxA = try makeContext()
        let ctxB = try makeContext()
        defer {
            ctxA.teardown()
            ctxB.teardown()
        }

        for _ in 0 ..< PluginHostContext.httpRateLimit {
            _ = ctxA.checkHttpRateLimit(agentId: agentId)
        }
        #expect(ctxA.checkHttpRateLimit(agentId: agentId) == false)
        #expect(ctxB.checkHttpRateLimit(agentId: agentId) == true)
    }

    @Test func httpAndDispatchLimitsAreIndependent() throws {
        // Both limiters share `rateLimitLock` for thread-safety but
        // track their own timestamp arrays — exhausting one must not
        // exhaust the other.
        let ctx = try makeContext()
        defer { ctx.teardown() }

        for _ in 0 ..< PluginHostContext.httpRateLimit {
            _ = ctx.checkHttpRateLimit(agentId: agentId)
        }
        #expect(ctx.checkHttpRateLimit(agentId: agentId) == false)
        // Dispatch limit (10/min) is still untouched.
        #expect(ctx.checkDispatchRateLimit(agentId: agentId) == true)
    }
}
