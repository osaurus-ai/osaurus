import Foundation
import Testing

@testable import OsaurusCore

/// The phase timings existed but were `#if DEBUG` only, so the build users run
/// recorded nothing — which is why a "prefill got slower" report could not be
/// confirmed or refuted from the reporter's machine. The load phase
/// (`load_container_start` → `load_container_done`) is the one they wait
/// through and the one the displayed TTFT excludes.
@Suite("TTFT trace enablement")
struct TTFTTraceEnablementTests {

    @Test("an explicit on wins in any configuration")
    func explicitOnEnables() {
        for value in ["1", "true", "yes", "on", "YES"] {
            #expect(TTFTTrace.isEnabled(environment: ["OSAURUS_TTFT_TRACE": value]),
                "\(value) should enable")
            #expect(TTFTTrace.makeIfEnabled(environment: ["OSAURUS_TTFT_TRACE": value]) != nil)
        }
    }

    @Test("an explicit off wins in any configuration")
    func explicitOffDisables() {
        for value in ["0", "false", "no", "off", "OFF", ""] {
            #expect(!TTFTTrace.isEnabled(environment: ["OSAURUS_TTFT_TRACE": value]),
                "\(value.debugDescription) should disable")
            #expect(TTFTTrace.makeIfEnabled(environment: ["OSAURUS_TTFT_TRACE": value]) == nil)
        }
    }

    /// Unset keeps the historical behaviour: on in debug, off in release.
    @Test("unset follows the build configuration")
    func unsetFollowsBuild() {
        #if DEBUG
            #expect(TTFTTrace.isEnabled(environment: [:]))
        #else
            #expect(!TTFTTrace.isEnabled(environment: [:]))
        #endif
    }

    @Test("surrounding whitespace does not defeat the switch")
    func whitespaceTolerated() {
        #expect(TTFTTrace.isEnabled(environment: ["OSAURUS_TTFT_TRACE": " 1 "]))
        #expect(!TTFTTrace.isEnabled(environment: ["OSAURUS_TTFT_TRACE": " off "]))
    }
}
