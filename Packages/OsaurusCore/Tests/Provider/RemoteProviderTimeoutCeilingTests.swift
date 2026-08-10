//
//  RemoteProviderTimeoutCeilingTests.swift
//  osaurusTests
//
//  Pins the `disableTimeout` hard-ceiling contract: "no timeout" lifts the
//  user-facing limits but stays finite (24h) so a dead peer holding an open
//  socket can never pin a request task indefinitely, and the value remains
//  safe for the streaming path's nanosecond conversion and JSON encoding.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct RemoteProviderTimeoutCeilingTests {

    @Test func ceilingIsTwentyFourHours() {
        #expect(RemoteProvider.unboundedTimeout == 60 * 60 * 24)
    }

    @Test func ceilingSurvivesNanosecondConversion() {
        // The stream watchdog converts seconds to nanoseconds through
        // UInt64; the ceiling must stay far away from overflow.
        let nanos = RemoteProvider.unboundedTimeout * 1_000_000_000
        #expect(nanos.isFinite)
        #expect(nanos < Double(UInt64.max))
        #expect(UInt64(nanos) > 0)
    }

    @Test func ceilingIsJSONEncodable() throws {
        // `.infinity` would throw here — the sentinel must round-trip
        // through provider config persistence.
        let data = try JSONEncoder().encode([RemoteProvider.unboundedTimeout])
        let decoded = try JSONDecoder().decode([TimeInterval].self, from: data)
        #expect(decoded.first == RemoteProvider.unboundedTimeout)
    }
}
