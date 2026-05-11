//
//  PluginGetActiveAgentIdTests.swift
//  OsaurusCoreTests
//
//  Pins the v4 `osr_get_active_agent_id` host surface added so plugins
//  can resolve the active agent on every callback frame instead of
//  caching it in their `osr_plugin_ctx_t` (which is shared across all
//  agents). The old behavior — silently falling back to the default
//  agent when no TLS agent was bound — was the source of the
//  "several agents share the same configuration" symptom.
//

import Foundation
import Testing

@testable import OsaurusCore

struct PluginGetActiveAgentIdTests {

    // MARK: - ABI presence

    @Test func hostStructExposesGetActiveAgentIdSlot() throws {
        let ctx = try PluginHostContext(pluginId: "com.test.activeagent.slot.\(UUID())")
        defer { ctx.teardown() }
        let api = ctx.buildHostAPI().pointee
        #expect(api.version >= 4, "v4+ ABI must advertise get_active_agent_id")
        #expect(api.get_active_agent_id != nil)
    }

    // MARK: - Trampoline behavior

    /// Default thread state has no TLS agent bound. The trampoline must
    /// surface that as a NULL return rather than silently returning the
    /// default agent's UUID — that would defeat the whole point of the
    /// API (plugin can't distinguish "no agent" from "default agent").
    @Test func returnsNullOutsideAnyAgentFrame() {
        // Tests run on test-runner threads which never had `setActiveAgent`
        // called. The trampoline reads TLS directly so we can call it
        // without spinning up an `ExternalPlugin`.
        let ptr = PluginHostContext.trampolineGetActiveAgentId()
        #expect(ptr == nil, "no TLS agent → must return NULL, not the default agent's UUID")
    }

    /// Inside a `withTLSScope` frame (mirrors what
    /// `ExternalPlugin.handleRoute` / `notifyConfigBatch` /
    /// `notifyTaskEvent` do), the trampoline must return the bound
    /// agent's UUID string verbatim AND the returned pointer must be
    /// `libc free`-able (paired with the host's `strdup` allocation).
    /// The earlier version of this test leaked the pointer — which is
    /// exactly what hid the production crash. This version frees the
    /// pointer the same way every plugin does.
    @Test func returnsBoundAgentInsideTLSScope() throws {
        let agentId = UUID()
        var captured: String?
        PluginHostContext.withTLSScope(pluginId: "com.test.activeagent.scope", agentId: agentId) {
            guard let cstr = PluginHostContext.trampolineGetActiveAgentId() else { return }
            captured = String(cString: cstr)
            // Plugin's flow: read the C string into a Swift String
            // (which copies), then free the host pointer with libc
            // `free()`. This MUST not abort — if it does, the
            // host/plugin malloc pairing is broken.
            free(UnsafeMutableRawPointer(mutating: cstr))
        }
        let str = try #require(captured)
        #expect(UUID(uuidString: str) == agentId)
    }

    /// Hammer the trampoline to surface any racy / heap-corruption
    /// issues that a single call would miss. Each iteration mirrors
    /// the production sequence: scope → trampoline → read → free.
    @Test func roundtripStrdupFreeUnderRepeatedCalls() {
        for _ in 0 ..< 256 {
            let agentId = UUID()
            PluginHostContext.withTLSScope(
                pluginId: "com.test.activeagent.hammer",
                agentId: agentId
            ) {
                guard let cstr = PluginHostContext.trampolineGetActiveAgentId() else { return }
                _ = String(cString: cstr)
                free(UnsafeMutableRawPointer(mutating: cstr))
            }
        }
    }

    /// Production-shape repro: invoke the trampoline through the
    /// actual `osr_host_api.get_active_agent_id` C function pointer
    /// (the plugin's view), then free with `host->free_string`.
    /// Calling through the function-pointer slot exercises the
    /// `@convention(c)` boundary the plugin's dylib hits, where the
    /// implicit `String → UnsafePointer<CChar>!` bridge in the old
    /// `makeCString` had a bug that produced
    /// `pointer being freed was not allocated`. Hammering 256
    /// iterations from a serial dispatch queue (mirrors
    /// `ExternalPlugin.configEventQueue`) and wrapping the call in
    /// the same nested `withCString` frames `notifyConfigBatch`
    /// establishes around `on_config_changed` is the tightest
    /// reproduction shape we can drive without loading a real plugin.
    @Test func roundtripFromSerialQueueMimicsConfigEventPath() async throws {
        let ctx = try PluginHostContext(pluginId: "com.test.activeagent.queue.\(UUID())")
        defer { ctx.teardown() }
        let api = ctx.buildHostAPI().pointee
        let getActiveAgentId = try #require(api.get_active_agent_id)
        let freeString = try #require(api.free_string)
        let queue = DispatchQueue(label: "com.test.activeagent.queue.serial")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                for _ in 0 ..< 256 {
                    let agentId = UUID()
                    PluginHostContext.withTLSScope(
                        pluginId: ctx.pluginId,
                        agentId: agentId
                    ) {
                        "some_key".withCString { _ in
                            "some_value".withCString { _ in
                                guard let cstr = getActiveAgentId() else { return }
                                let s = String(cString: cstr)
                                #expect(UUID(uuidString: s) == agentId)
                                freeString(cstr)
                            }
                        }
                    }
                }
                cont.resume()
            }
        }
    }

    /// TLS must be cleared after the scope exits, so back-to-back
    /// callbacks against the same thread (concurrent invokeQueue thread
    /// reuse) don't leak agent state from the prior call.
    @Test func tlsIsClearedAfterScopeExits() {
        let agentId = UUID()
        PluginHostContext.withTLSScope(pluginId: "com.test.activeagent.clear", agentId: agentId) {
            _ = PluginHostContext.trampolineGetActiveAgentId()  // populated inside
        }
        // After exit, the trampoline must see no agent again.
        let ptr = PluginHostContext.trampolineGetActiveAgentId()
        #expect(ptr == nil, "TLS must reset on scope exit so the next call sees no agent")
    }

    /// Two different agents back-to-back on the same thread must each
    /// see their own UUID — pinning that the trampoline reads TLS fresh
    /// per call rather than caching.
    @Test func eachScopeReportsItsOwnAgent() throws {
        let agentA = UUID()
        let agentB = UUID()
        var capturedA: String?
        var capturedB: String?

        PluginHostContext.withTLSScope(pluginId: "com.test.activeagent.swap", agentId: agentA) {
            if let cstr = PluginHostContext.trampolineGetActiveAgentId() {
                capturedA = String(cString: cstr)
            }
        }
        PluginHostContext.withTLSScope(pluginId: "com.test.activeagent.swap", agentId: agentB) {
            if let cstr = PluginHostContext.trampolineGetActiveAgentId() {
                capturedB = String(cString: cstr)
            }
        }

        let strA = try #require(capturedA)
        let strB = try #require(capturedB)
        #expect(UUID(uuidString: strA) == agentA)
        #expect(UUID(uuidString: strB) == agentB)
        #expect(strA != strB)
    }
}
