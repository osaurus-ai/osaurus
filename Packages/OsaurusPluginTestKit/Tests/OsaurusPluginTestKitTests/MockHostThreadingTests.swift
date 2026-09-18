//
//  MockHostThreadingTests.swift
//  OsaurusPluginTestKitTests
//
//  The host ABI (osaurus_plugin.h) documents that a plugin may call host
//  callbacks from a plugin-spawned background thread, and the recorders are
//  NSLock-protected specifically to accept those writes. These tests pin two
//  threading properties of MockHost:
//    - host-global callbacks (log / config) made from a background thread
//      are recorded, while get_active_agent_id still returns NULL there
//      (per the ABI's "outside any per-agent frame" rule);
//    - installs nest: `withInstalled` can wrap another install, routing to
//      the inner host and restoring the outer one on exit.
//
//  Nested inside `MockHostTests` (which is `.serialized`) so these tests and
//  every other host-installing test run one at a time: the process-wide
//  single-host fallback (used to attribute a background-thread call when
//  exactly one host is installed) is only well-defined when installs don't
//  overlap.
//

import Foundation
import Testing

@testable import OsaurusPluginTestKit

extension MockHostTests {

    @Suite(.serialized)
    struct Threading {

        @Test func backgroundThreadLogIsRecorded() {
            let host = MockHost()
            host.withInstalled { ptr in
                let api = ptr.pointee
                let done = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    "bg log".withCString { api.log?(2, $0) }
                    done.signal()
                }
                done.wait()
            }
            #expect(host.logs.entries.count == 1)
            #expect(host.logs.contains("bg log"))
        }

        @Test func backgroundThreadConfigWriteIsRecorded() {
            let host = MockHost()
            host.withInstalled { ptr in
                let api = ptr.pointee
                let done = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    "k".withCString { k in "v".withCString { v in api.configSet?(k, v) } }
                    done.signal()
                }
                done.wait()
            }
            #expect(host.configWrites.lastValue(forKey: "k") == "v")
        }

        @Test func getActiveAgentIdIsNilOnBackgroundThread() {
            // Per the ABI, get_active_agent_id returns NULL outside a per-agent
            // frame — including a plugin-spawned background thread — even when an
            // id is configured for the install-thread frame.
            let host = MockHost()
            host.activeAgentId = "11111111-2222-3333-4444-555555555555"
            host.withInstalled { ptr in
                let api = ptr.pointee
                let done = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    let wasNil = (api.getActiveAgentId?() == nil)
                    (wasNil ? "agentid:nil" : "agentid:set").withCString { api.log?(2, $0) }
                    done.signal()
                }
                done.wait()
                // The install-thread frame still returns the configured id.
                if let cstr = api.getActiveAgentId?() {
                    let s = String(cString: cstr)
                    free(UnsafeMutableRawPointer(mutating: cstr))
                    #expect(s == "11111111-2222-3333-4444-555555555555")
                } else {
                    Issue.record("expected the configured agent id on the install thread")
                }
            }
            #expect(host.logs.messages.last == "agentid:nil")
        }

        @Test func backgroundCallIsDroppedWhenMultipleHostsInstalled() {
            // Two hosts installed on different threads: a background-thread call
            // can't be unambiguously attributed, so it is dropped (not misrouted
            // to the wrong recorder).
            let hostA = MockHost()
            let hostB = MockHost()
            let bInstalled = DispatchSemaphore(value: 0)
            let releaseB = DispatchSemaphore(value: 0)
            let bWorkerDone = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                hostB.withInstalled { _ in
                    bInstalled.signal()
                    releaseB.wait()
                }
                // hostB is now fully uninstalled (out of the registry).
                bWorkerDone.signal()
            }
            bInstalled.wait()
            hostA.withInstalled { ptr in
                let api = ptr.pointee
                let done = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    "ambiguous".withCString { api.log?(2, $0) }
                    done.signal()
                }
                done.wait()
            }
            releaseB.signal()
            // Join the hostB worker so it can't leave hostB in the registry past
            // this test and perturb the next test's single-host fallback.
            bWorkerDone.wait()
            #expect(hostA.logs.entries.isEmpty)
            #expect(hostB.logs.entries.isEmpty)
        }

        @Test func nestedInstallRoutesToInnerThenRestoresOuter() {
            let outer = MockHost()
            let inner = MockHost()
            outer.withInstalled { outerPtr in
                let outerApi = outerPtr.pointee
                "outer-before".withCString { outerApi.log?(2, $0) }
                inner.withInstalled { innerPtr in
                    let innerApi = innerPtr.pointee
                    "inner".withCString { innerApi.log?(2, $0) }
                }
                // Inner uninstalled: the outer host is restored as current.
                "outer-after".withCString { outerApi.log?(2, $0) }
            }
            #expect(inner.logs.messages == ["inner"])
            #expect(outer.logs.messages == ["outer-before", "outer-after"])
        }

        @Test func nestedLifoUninstallDoesNotLeakOrPoisonSlot() {
            // The install stack is `Unmanaged`-retained, so a regression here
            // could (a) leak a host whose slot retain is never released, or
            // (b) leave the thread slot pointing at a logically-uninstalled
            // host. Pin both: after a nested LIFO unwind every host must
            // deallocate and the slot must be clean.
            weak var weakOuter: MockHost?
            weak var weakInner: MockHost?
            do {
                let outer = MockHost()
                let inner = MockHost()
                weakOuter = outer
                weakInner = inner
                outer.withInstalled { _ in
                    inner.withInstalled { _ in }
                }
                // Both uninstalled LIFO via `defer`; only the locals retain them.
            }
            #expect(weakOuter == nil, "outer must deallocate after LIFO uninstall (no leaked slot retain)")
            #expect(weakInner == nil, "inner must deallocate after LIFO uninstall")
            // Slot is clean: a fresh sole host records a background-thread call,
            // which it could not if the slot still pointed at a dead host.
            let fresh = MockHost()
            fresh.withInstalled { ptr in
                let api = ptr.pointee
                let done = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    "after-nest".withCString { api.log?(2, $0) }
                    done.signal()
                }
                done.wait()
            }
            #expect(fresh.logs.messages == ["after-nest"])
        }

        @Test func nonLifoUninstallTraps() async {
            // A manual out-of-LIFO uninstall (outer before inner) would
            // otherwise orphan the outer's retain and leave the slot pointing
            // at it; instead it must trap. Run in a child process so the
            // precondition abort is observed rather than crashing this suite.
            await #expect(processExitsWith: .failure) {
                let outer = MockHost()
                let inner = MockHost()
                _ = outer.hostAPIPointer()
                _ = inner.hostAPIPointer()
                outer.uninstall()  // not the slot top → precondition failure
            }
        }
    }
}
