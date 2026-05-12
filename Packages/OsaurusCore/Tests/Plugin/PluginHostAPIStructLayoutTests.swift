//
//  PluginHostAPIStructLayoutTests.swift
//  OsaurusCoreTests
//
//  Rejects Swift/C drift in `osr_host_api`. If these assertions fail, a plugin
//  dylib calling through `host->get_active_agent_id` may invoke the wrong
//  slot (misaligned vtable) and free garbage — the production
//  `pointer being freed was not allocated` class.
//

import Testing

@testable import OsaurusCore

struct PluginHostAPIStructLayoutTests {

    @Test func swiftMirrorMatchesClangFrozenLayout() {
        // From `clang -E` / offsetof against `osaurus_plugin.h` (arm64 Darwin,
        // standard LP64). The header promises a frozen layout — keep this
        // pin in lockstep when adding fields.
        #expect(MemoryLayout<osr_host_api>.size == 200)
        #expect(MemoryLayout<osr_host_api>.stride == 200)
        #expect(MemoryLayout<osr_host_api>.alignment == 8)

        #expect(MemoryLayout<osr_host_api>.offset(of: \.version) == 0)
        #expect(MemoryLayout<osr_host_api>.offset(of: \.config_get) == 8)
        #expect(MemoryLayout<osr_host_api>.offset(of: \.get_active_agent_id) == 176)
        #expect(MemoryLayout<osr_host_api>.offset(of: \.log_structured) == 184)
        #expect(MemoryLayout<osr_host_api>.offset(of: \.free_string) == 192)
    }
}
