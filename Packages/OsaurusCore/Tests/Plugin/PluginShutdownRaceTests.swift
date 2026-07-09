//
//  PluginShutdownRaceTests.swift
//  OsaurusCoreTests
//
//  Regresses the production crash class behind Sentry APPLE-MACOS-9T
//  (EXC_BAD_ACCESS during `ExternalPlugin.shutdown` → `destroy(ctx)`).
//
//  `shutdown()` drains the per-task event queues (snapshot), the config
//  event queue, and the invoke queue (barrier) before calling `destroy`.
//  Two callback paths escaped that drain:
//
//  1. Main-actor invocations (`dispatchPluginCallOnMainActor`) never touch
//     `invokeQueue`, so the barrier could not see them — `destroy(ctx)`
//     could free the context while the main thread was inside plugin code.
//  2. Task events delivered on a per-task queue created AFTER the snapshot
//     (or whose body read `isShutDown == false` just before the mid-drain
//     flip) ran concurrently with `destroy`.
//
//  Both are now covered by `inFlightCallbacks` (enter-before-latch-check,
//  `shutdown()` waits on the group before `destroy`). These tests block a
//  callback inside plugin code, run a full `shutdown()` concurrently, and
//  pin that `destroy` fired exactly once and never while the callback was
//  still executing.
//
//  Also pins that `destroy` runs inside a plugin TLS scope: plugin teardown
//  code routinely calls host trampolines (e.g. `config_get("api_key")`),
//  and without TLS those resolve through the racy global fallback —
//  potentially another plugin's context, or none at all.
//

import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite(.serialized)
struct PluginShutdownRaceTests {

    /// Shared with the C callbacks via the plugin's opaque `ctx` pointer.
    final class Recorder: @unchecked Sendable {
        // Signaled by the blocked callback once it is inside plugin code.
        let callbackStarted = DispatchSemaphore(value: 0)
        // The blocked callback waits on this before returning.
        let releaseCallback = DispatchSemaphore(value: 0)
        // Signaled by the blocked on_config_changed delivery (test 2 only).
        let configStarted = DispatchSemaphore(value: 0)
        // The blocked on_config_changed waits on this (test 2 only).
        let releaseConfig = DispatchSemaphore(value: 0)

        private let lock = NSLock()
        private var _insidePluginCode = false
        private var _destroyCount = 0
        private var _destroyedWhileInsidePluginCode = false
        private var _tlsPluginIdAtDestroy: String?

        var insidePluginCode: Bool {
            get { lock.withLock { _insidePluginCode } }
            set { lock.withLock { _insidePluginCode = newValue } }
        }
        var destroyCount: Int { lock.withLock { _destroyCount } }
        var destroyedWhileInsidePluginCode: Bool {
            lock.withLock { _destroyedWhileInsidePluginCode }
        }
        var tlsPluginIdAtDestroy: String? { lock.withLock { _tlsPluginIdAtDestroy } }

        func recordDestroy(tlsPluginId: String?) {
            lock.withLock {
                _destroyCount += 1
                if _insidePluginCode { _destroyedWhileInsidePluginCode = true }
                _tlsPluginIdAtDestroy = tlsPluginId
            }
        }
    }

    /// Async-safe semaphore wait: Swift 6 forbids `DispatchSemaphore.wait`
    /// on a concurrency-pool thread, so hop to a GCD global queue for the
    /// blocking wait and resume with whether it was signaled in time.
    private func signaled(_ sem: DispatchSemaphore, within timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: sem.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    /// Mirrors the private TLS key in `PluginHostContext` — the destroy
    /// callback reads it to prove `destroy` ran inside a plugin TLS scope.
    /// If the key is ever renamed in the host, this test fails loudly
    /// instead of the contract silently regressing.
    private static let pluginTLSKey = "ai.osaurus.plugin.active"

    private static let blockingDestroy: osr_destroy_t = { ctxPtr in
        guard let ctxPtr else { return }
        let recorder = Unmanaged<Recorder>.fromOpaque(ctxPtr).takeUnretainedValue()
        recorder.recordDestroy(
            tlsPluginId: Thread.current.threadDictionary[PluginShutdownRaceTests.pluginTLSKey] as? String
        )
    }

    private func makePlugin(
        recorder: Recorder,
        pluginId: String
    ) -> (plugin: ExternalPlugin, retain: Unmanaged<Recorder>) {
        let retain = Unmanaged.passRetained(recorder)
        let ctx = retain.toOpaque()
        let api = osr_plugin_api(
            free_string: { ptr in
                guard let ptr else { return }
                free(UnsafeMutableRawPointer(mutating: ptr))
            },
            init: nil,
            destroy: Self.blockingDestroy,
            get_manifest: nil,
            invoke: { ctxPtr, _, _, _ in
                guard let ctxPtr else { return nil }
                let recorder = Unmanaged<Recorder>.fromOpaque(ctxPtr).takeUnretainedValue()
                recorder.insidePluginCode = true
                recorder.callbackStarted.signal()
                recorder.releaseCallback.wait()
                recorder.insidePluginCode = false
                return UnsafePointer(strdup(#"{"ok":true}"#))
            },
            version: 6,
            handle_route: nil,
            on_config_changed: { ctxPtr, _, _ in
                guard let ctxPtr else { return }
                let recorder = Unmanaged<Recorder>.fromOpaque(ctxPtr).takeUnretainedValue()
                recorder.configStarted.signal()
                recorder.releaseConfig.wait()
            },
            on_task_event: { ctxPtr, _, _, _ in
                guard let ctxPtr else { return }
                let recorder = Unmanaged<Recorder>.fromOpaque(ctxPtr).takeUnretainedValue()
                recorder.insidePluginCode = true
                recorder.callbackStarted.signal()
                recorder.releaseCallback.wait()
                recorder.insidePluginCode = false
            }
        )
        let manifest = PluginManifest(
            plugin_id: pluginId,
            description: nil,
            capabilities: .init(tools: nil, routes: nil, config: nil, web: nil, artifact_handler: nil),
            instructions: nil,
            name: nil,
            version: nil,
            license: nil,
            authors: nil,
            min_macos: nil,
            min_osaurus: nil,
            secrets: nil,
            docs: nil
        )
        let plugin = ExternalPlugin(
            handle: ctx,
            api: api,
            ctx: ctx,
            manifest: manifest,
            path: "/tmp/shutdown-race-\(pluginId)",
            abiVersion: 6
        )
        return (plugin, retain)
    }

    /// A main-actor invocation (accessibility-style plugin call) blocked
    /// inside plugin code must delay `destroy(ctx)` until it returns —
    /// `invokeQueue`'s barrier drain cannot see main-actor calls, so only
    /// `inFlightCallbacks` prevents the use-after-free.
    @Test
    func shutdownWaitsForInFlightMainActorInvocation() async throws {
        let recorder = Recorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.shutdown-race.mainactor.\(UUID().uuidString)"
        )
        defer { retain.release() }

        let invokeTask = Task {
            try await plugin.invoke(type: "tool", id: "t", payload: "{}", isolation: .mainActor)
        }
        #expect(await signaled(recorder.callbackStarted))

        let shutdownTask = Task.detached { await plugin.shutdown() }
        // Give shutdown time to finish every drain it CAN see. Before the
        // fix, destroy fired inside this window while the main thread was
        // still executing plugin code.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.destroyCount == 0, "destroy must wait for the in-flight main-actor call")

        recorder.releaseCallback.signal()
        let result = try await invokeTask.value
        #expect(result == #"{"ok":true}"#)
        await shutdownTask.value

        #expect(recorder.destroyCount == 1)
        #expect(!recorder.destroyedWhileInsidePluginCode)
        #expect(recorder.tlsPluginIdAtDestroy == plugin.id, "destroy must run inside this plugin's TLS scope")
    }

    /// A task event delivered on a per-task queue created AFTER `shutdown()`
    /// took its drain snapshot must still delay `destroy(ctx)`. The config
    /// event queue is deliberately kept busy so the `isShutDown` latch flips
    /// late — reproducing the exact interleaving where the drain group
    /// completed while the event callback was still inside plugin code.
    @Test
    func shutdownWaitsForTaskEventOnQueueCreatedAfterSnapshot() async throws {
        let recorder = Recorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.shutdown-race.taskevent.\(UUID().uuidString)"
        )
        defer { retain.release() }

        // Occupy the config event queue so shutdown's drain marker (which
        // flips `isShutDown`) queues behind it.
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: UUID())
        #expect(await signaled(recorder.configStarted))

        let shutdownTask = Task.detached { await plugin.shutdown() }
        // Wait until the drain snapshot exists — the event queue created
        // below is then provably invisible to the drain group.
        let deadline = Date().addingTimeInterval(5)
        while !plugin.shutdownSnapshotTakenForTesting.withLock({ $0 }) {
            try #require(Date() < deadline, "shutdown never took its drain snapshot")
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // Fresh task id → fresh queue, post-snapshot. The latch is still
        // false (config marker blocked), so delivery proceeds into plugin
        // code and blocks there.
        plugin.notifyTaskEvent(taskId: "post-snapshot-task", eventType: .started, eventJSON: "{}")
        #expect(await signaled(recorder.callbackStarted))

        // Unblock the config queue: the latch flips, the drain group
        // completes, and shutdown reaches the destroy step — which must
        // now wait for the blocked event delivery.
        recorder.releaseConfig.signal()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.destroyCount == 0, "destroy must wait for the in-flight task event")

        recorder.releaseCallback.signal()
        await shutdownTask.value

        #expect(recorder.destroyCount == 1)
        #expect(!recorder.destroyedWhileInsidePluginCode)
        #expect(recorder.tlsPluginIdAtDestroy == plugin.id, "destroy must run inside this plugin's TLS scope")
    }
}
