//
//  PluginLogStructuredTests.swift
//  OsaurusCoreTests
//
//  Pins the v5 `log_structured` host surface added so plugins can
//  attach searchable JSON fields to log entries surfaced in Insights.
//  Backwards compatible with v4 plugins (NULL slot on older hosts).
//

import Foundation
import Testing

@testable import OsaurusCore

struct PluginLogStructuredTests {

    @Test func hostStructExposesLogStructured() throws {
        let ctx = try PluginHostContext(pluginId: "com.test.logstruct.\(UUID())")
        defer { ctx.teardown() }
        let api = ctx.buildHostAPI().pointee
        #expect(api.version >= 5, "log_structured wired only on v5+ hosts")
        #expect(api.log_structured != nil)
    }

    @Test func levelMetadataMatchesAbiContract() {
        // Both `trampolineLog` and `trampolineLogStructured` route
        // through `levelMetadata` so the synthetic HTTP status used
        // for Insights filtering stays consistent. Pin the mapping
        // against the ABI header's documented contract:
        // 0=trace, 1=debug, 2=info, 3=warn, 4=error.
        #expect(PluginHostContext.levelMetadata(for: 0).name == "TRACE")
        #expect(PluginHostContext.levelMetadata(for: 1).name == "DEBUG")
        #expect(PluginHostContext.levelMetadata(for: 2).name == "INFO")
        #expect(PluginHostContext.levelMetadata(for: 3).name == "WARN")
        #expect(PluginHostContext.levelMetadata(for: 4).name == "ERROR")
        #expect(PluginHostContext.levelMetadata(for: 99).name == "LOG")

        #expect(PluginHostContext.levelMetadata(for: 0).statusCode == 200)
        #expect(PluginHostContext.levelMetadata(for: 1).statusCode == 200)
        #expect(PluginHostContext.levelMetadata(for: 2).statusCode == 200)
        #expect(PluginHostContext.levelMetadata(for: 3).statusCode == 299)
        #expect(PluginHostContext.levelMetadata(for: 4).statusCode == 500)
    }

    @Test func nilPayloadDegradesToPlainLogShape() throws {
        // Callers that pass NULL payload should get the same console
        // / Insights output as the v1 `log` trampoline. The trampoline
        // is `@convention(c)`, but we can drive it directly because
        // it's a public static. Without a real plugin context bound
        // to TLS the trampoline early-returns; we just need to
        // confirm the call doesn't crash.
        let ctx = try PluginHostContext(pluginId: "com.test.logstruct.nilpayload.\(UUID())")
        defer { ctx.teardown() }
        PluginHostContext.setActivePlugin(ctx.pluginId)
        defer { PluginHostContext.clearActivePlugin() }

        "hello".withCString { msg in
            PluginHostContext.trampolineLogStructured(1, msg, nil)
        }
    }

    @Test func payloadIsForwardedToLog() throws {
        // Smoke that a payload-bearing call reaches `logPluginCall`
        // without throwing. Insights deduplication / search behavior
        // is exercised by the InsightsService tests; here we just
        // verify the trampoline survives a typical structured payload.
        let ctx = try PluginHostContext(pluginId: "com.test.logstruct.payload.\(UUID())")
        defer { ctx.teardown() }
        PluginHostContext.setActivePlugin(ctx.pluginId)
        defer { PluginHostContext.clearActivePlugin() }

        let payload = #"{"event":"webhook_registered","status":200}"#
        "registered".withCString { msg in
            payload.withCString { pl in
                PluginHostContext.trampolineLogStructured(1, msg, pl)
            }
        }
    }
}
