//
//  PluginHostFreeStringTests.swift
//  OsaurusCoreTests
//
//  Pins the v6 host-side `free_string` callback added because the
//  previous contract ("free with the plugin's own free_string") was
//  ambiguous: the plugin's `free_string` is for the reverse direction
//  (host → plugin strings) and a plugin that implemented it as
//  anything other than plain `libc free()` would corrupt the heap on
//  every host-returned pointer it touched. The v6 callback gives
//  plugins a host-controlled, allocator-stable way to free strings.
//

import Foundation
import Testing

@testable import OsaurusCore

struct PluginHostFreeStringTests {

    @Test func hostStructAdvertisesV6() throws {
        let ctx = try PluginHostContext(pluginId: "com.test.hostfree.\(UUID())")
        defer { ctx.teardown() }
        let api = ctx.buildHostAPI().pointee
        #expect(api.version == 6, "v6 ABI must be advertised when host->free_string is wired")
        #expect(api.free_string != nil, "free_string slot must be populated on v6 host")
    }

    @Test func nilPointerIsNoOp() {
        // Defensive: plugins routinely wrap the call in a defer that
        // fires regardless of whether the host returned NULL. Plain
        // `libc free(NULL)` is documented as a no-op, so the
        // trampoline must inherit that behavior.
        PluginHostContext.trampolineHostFreeString(nil)
    }

    @Test func freesStringReturnedByHostTrampoline() throws {
        // End-to-end: take a strdup'd pointer the host produces (same
        // path every host trampoline takes) and free it through the
        // v6 callback. If the malloc pairing is correct this should
        // not abort. Run it 64 times so a corrupted free is more
        // likely to surface as a malloc-zone crash.
        let ctx = try PluginHostContext(pluginId: "com.test.hostfree.roundtrip.\(UUID())")
        defer { ctx.teardown() }
        let api = ctx.buildHostAPI().pointee
        guard let freeFn = api.free_string else {
            Issue.record("free_string slot missing")
            return
        }

        for _ in 0 ..< 64 {
            // Mimic what `makeCString` does inside any host trampoline:
            // strdup an arbitrary string and hand the pointer to the
            // plugin. Using a UUID string mirrors the
            // `get_active_agent_id` payload shape so the test exercises
            // the same allocation size class the production crash
            // landed on.
            let str = UUID().uuidString
            guard let cstr = strdup(str) else {
                Issue.record("strdup failed")
                return
            }
            freeFn(UnsafePointer(cstr))
        }
    }

    @Test func freeAfterReadStillWorks() throws {
        // Common plugin pattern: read the C string into a Swift String
        // (which copies), then free the host pointer. Pin that the
        // read doesn't leave the underlying buffer in a state that
        // makes free() unhappy.
        let ctx = try PluginHostContext(pluginId: "com.test.hostfree.read.\(UUID())")
        defer { ctx.teardown() }
        let freeFn = try #require(ctx.buildHostAPI().pointee.free_string)

        let original = UUID().uuidString
        let cstr = try #require(strdup(original))
        let copied = String(cString: cstr)
        #expect(copied == original)
        freeFn(UnsafePointer(cstr))
    }
}
