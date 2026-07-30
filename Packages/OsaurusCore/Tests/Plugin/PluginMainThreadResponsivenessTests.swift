//
//  PluginMainThreadResponsivenessTests.swift
//  OsaurusCoreTests
//
//  Pins the zero-blocking MainActor contract for plugin invocation:
//  accessibility/automation plugin calls run on the shared off-main AX
//  serial queue (`InvocationIsolation.accessibilityQueue`), never
//  synchronously on the main actor. A plugin legitimately driving another
//  app for seconds — or wedged outright — must never beachball the UI.
//
//  Deterministic setup: the fake plugin's C callback blocks on a semaphore
//  ("stalled AX source"), and the test proves the main actor completes
//  work while that callback is still inside plugin code.
//

import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite(.serialized)
struct PluginMainThreadResponsivenessTests {

    final class Recorder: @unchecked Sendable {
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)

        private let lock = NSLock()
        private var _ranOnMainThread: Bool?

        /// Whether the plugin C callback executed on the main thread.
        var ranOnMainThread: Bool? {
            get { lock.withLock { _ranOnMainThread } }
            set { lock.withLock { _ranOnMainThread = newValue } }
        }
    }

    private func signaled(_ sem: DispatchSemaphore, within timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: sem.wait(timeout: .now() + timeout) == .success)
            }
        }
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
            destroy: nil,
            get_manifest: nil,
            invoke: { ctxPtr, _, _, _ in
                guard let ctxPtr else { return nil }
                let recorder = Unmanaged<Recorder>.fromOpaque(ctxPtr).takeUnretainedValue()
                recorder.ranOnMainThread = Thread.isMainThread
                recorder.callbackStarted.signal()
                recorder.releaseCallback.wait()
                return UnsafePointer(strdup(#"{"ok":true}"#))
            },
            version: 6,
            handle_route: nil,
            on_config_changed: nil,
            on_task_event: nil
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
            path: "/tmp/main-responsiveness-\(pluginId)",
            abiVersion: 6
        )
        return (plugin, retain)
    }

    /// While an accessibility-isolation plugin call is blocked inside
    /// plugin C code, the main actor must stay fully responsive, and the
    /// callback itself must NOT be executing on the main thread.
    @Test
    func mainActorRespondsWhileAccessibilityPluginCallIsStalled() async throws {
        let recorder = Recorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.responsiveness.\(UUID().uuidString)"
        )

        let invokeTask = Task {
            try await plugin.invoke(
                type: "tool", id: "t", payload: "{}", isolation: .accessibilityQueue
            )
        }
        #expect(await signaled(recorder.callbackStarted))
        #expect(recorder.ranOnMainThread == false, "plugin C code must not run on the main thread")

        // The "UI heartbeat": schedule work on the main actor while the
        // plugin callback is still blocked. With the old synchronous
        // main-actor dispatch this hop could not complete until the plugin
        // returned; now it must land promptly.
        let heartbeat = Task { @MainActor () -> Bool in
            true
        }
        let start = Date()
        let beat = await heartbeat.value
        let elapsed = Date().timeIntervalSince(start)
        #expect(beat)
        #expect(elapsed < 1.0, "main actor stalled for \(elapsed)s behind a blocked plugin call")

        recorder.releaseCallback.signal()
        let result = try await invokeTask.value
        #expect(result == #"{"ok":true}"#)

        await plugin.shutdown()
        retain.release()
    }
}
