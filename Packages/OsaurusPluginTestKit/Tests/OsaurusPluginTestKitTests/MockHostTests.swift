//
//  MockHostTests.swift
//  OsaurusPluginTestKitTests
//
//  Smoke tests for the mock host's recording surface. Plugins under
//  test will exercise these paths via their dlopen'd entry point —
//  the trampolines in `MockHost` are the seam, so we drive them
//  directly here to confirm the recording works.
//

import Foundation
import Testing

@testable import OsaurusPluginTestKit

struct MockHostTests {

    @Test func hostAPIPointerAdvertisesV6() throws {
        let host = MockHost()
        let api = host.hostAPIPointer().pointee
        defer { host.uninstall() }
        #expect(api.version == 6)
        #expect(api.configGet != nil)
        #expect(api.configSet != nil)
        #expect(api.dispatch != nil)
        #expect(api.getActiveAgentId != nil)
        #expect(api.logStructured != nil)
        #expect(api.freeString != nil)
    }

    @Test func configGetCallsOverrideClosure() {
        let host = MockHost()
        host.onConfigGet = { key in key == "api_key" ? "secret" : nil }

        host.withInstalled { ptr in
            let api = ptr.pointee
            // Mirror what a plugin would do: call config_get, copy out
            // the C string, free it via the host's free_string (here
            // we just `free` since the kit uses `strdup`).
            let value = "api_key".withCString { keyPtr -> String? in
                guard let cstr = api.configGet?(keyPtr) else { return nil }
                let s = String(cString: cstr)
                free(UnsafeMutableRawPointer(mutating: cstr))
                return s
            }
            #expect(value == "secret")
        }
    }

    @Test func configGetReturnsNilForUnknownKey() {
        let host = MockHost()
        host.withInstalled { ptr in
            let api = ptr.pointee
            let value = "nope".withCString { keyPtr -> UnsafePointer<CChar>? in
                api.configGet?(keyPtr)
            }
            #expect(value == nil)
        }
    }

    @Test func configWritesAreRecorded() {
        let host = MockHost()
        host.withInstalled { ptr in
            let api = ptr.pointee
            "k1".withCString { k in
                "v1".withCString { v in
                    api.configSet?(k, v)
                }
            }
            "k2".withCString { k in
                "v2".withCString { v in
                    api.configSet?(k, v)
                }
            }
            "k1".withCString { k in
                api.configDelete?(k)
            }
        }
        #expect(host.configWrites.setCount == 2)
        #expect(host.configWrites.deleteCount == 1)
        #expect(host.configWrites.lastValue(forKey: "k1") == "v1")
        #expect(host.configWrites.lastValue(forKey: "k2") == "v2")
    }

    @Test func logsAreRecorded() {
        let host = MockHost()
        host.withInstalled { ptr in
            let api = ptr.pointee
            "first message".withCString { msg in api.log?(1, msg) }
            "second message".withCString { msg in api.log?(3, msg) }
        }
        #expect(host.logs.entries.count == 2)
        #expect(host.logs.entries[0].level == 1)
        #expect(host.logs.entries[1].level == 3)
        #expect(host.logs.contains("second"))
    }

    @Test func getActiveAgentIdReturnsConfiguredValue() {
        let host = MockHost()
        let agentId = "11111111-2222-3333-4444-555555555555"
        host.activeAgentId = agentId

        host.withInstalled { ptr in
            let api = ptr.pointee
            guard let cstr = api.getActiveAgentId?() else {
                Issue.record("expected non-nil agent id")
                return
            }
            let returned = String(cString: cstr)
            free(UnsafeMutableRawPointer(mutating: cstr))
            #expect(returned == agentId)
        }
    }

    @Test func getActiveAgentIdNilByDefault() {
        let host = MockHost()
        host.withInstalled { ptr in
            let api = ptr.pointee
            #expect(api.getActiveAgentId?() == nil)
        }
    }

    @Test func dispatchHasSensibleDefault() {
        // Default dispatch returns a `running` envelope with a fresh
        // UUID so plugins that don't set up a custom handler still see
        // a parseable response.
        let host = MockHost()
        host.withInstalled { ptr in
            let api = ptr.pointee
            let response = #"{"prompt":"hi"}"#.withCString { json -> String in
                guard let cstr = api.dispatch?(json) else { return "" }
                let s = String(cString: cstr)
                free(UnsafeMutableRawPointer(mutating: cstr))
                return s
            }
            #expect(response.contains("\"status\":\"running\""))
            #expect(response.contains("\"id\""))
        }
    }

    @Test func uninstallIsIdempotent() {
        let host = MockHost()
        _ = host.hostAPIPointer()
        host.uninstall()
        host.uninstall()  // second call must not crash
    }
}
