//
//  OsrHostAPILayoutTests.swift
//  OsaurusPluginTestKitTests
//
//  Plugins that hand-define a Swift copy of `osr_host_api` must preserve
//  the exact field order from `osaurus_plugin.h`. Appending `free_string`
//  immediately after `get_active_agent_id` while omitting `log_structured`
//  shifts every trailing offset and leads to calling the wrong function
//  pointers (production symptom: `free` of a non-heap pointer).
//

import Foundation
import Testing

@testable import OsaurusPluginTestKit

struct OsrHostAPILayoutTests {

    @Test func layoutMatchesFrozenCABI() {
        #expect(MemoryLayout<OsrHostAPI>.size == 200)
        #expect(MemoryLayout<OsrHostAPI>.stride == 200)
        #expect(MemoryLayout<OsrHostAPI>.alignment == 8)
        #expect(MemoryLayout<OsrHostAPI>.offset(of: \.version) == 0)
        #expect(MemoryLayout<OsrHostAPI>.offset(of: \.configGet) == 8)
        #expect(MemoryLayout<OsrHostAPI>.offset(of: \.getActiveAgentId) == 176)
        #expect(MemoryLayout<OsrHostAPI>.offset(of: \.logStructured) == 184)
        #expect(MemoryLayout<OsrHostAPI>.offset(of: \.freeString) == 192)
    }
}
