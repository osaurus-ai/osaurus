//
//  PluginRouteReliabilityTests.swift
//  OsaurusCoreTests
//
//  Regression coverage for two route-dispatch reliability defects:
//
//  1. `ExternalPlugin.handleRoute` used `withThrowingTaskGroup` for its 30s
//     timeout. Task groups drain their children before returning, so a
//     blocking C route callback (which never observes Swift cancellation)
//     held the HTTP request for the FULL duration of the call — the timeout
//     never fired from the caller's point of view. The fix races an
//     unstructured body task against a GCD timer (same pattern as
//     `ToolRegistry.runToolBody`) and resumes the caller as soon as the
//     timer wins. The test below pins ELAPSED WALL TIME with a deliberately
//     blocking route callback.
//
//  2. Static web mount matching used a bare `subpath.hasPrefix(mountPrefix)`,
//     so mount `/ui` captured `/ui-other` — disagreeing with the load-time
//     web/route overlap validation. Both validation and dispatch now share
//     `PluginManifest.WebSpec.mountCaptures`, tested here for the exact
//     paths from the audit (`/ui`, `/ui/x`, `/ui-other`, `/`).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct PluginRouteReliabilityTests {

    // MARK: - Route handler timeout race

    /// Shared with the C route callback via the plugin's opaque `ctx`.
    final class RouteRecorder: @unchecked Sendable {
        /// Signaled once the blocking callback is inside plugin code.
        let callbackStarted = DispatchSemaphore(value: 0)
        /// The blocking callback waits on this before returning, so the test
        /// controls exactly how long the "hung" C call lasts.
        let releaseCallback = DispatchSemaphore(value: 0)
        /// Signaled when the blocking callback finally returns (cleanup sync).
        let callbackFinished = DispatchSemaphore(value: 0)
    }

    private func makeManifest(pluginId: String) -> PluginManifest {
        PluginManifest(
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
    }

    private func makePlugin(
        recorder: RouteRecorder,
        pluginId: String,
        handleRoute: @escaping osr_handle_route_t
    ) -> (plugin: ExternalPlugin, retain: Unmanaged<RouteRecorder>) {
        let retain = Unmanaged.passRetained(recorder)
        let ctx = retain.toOpaque()
        let api = osr_plugin_api(
            free_string: { ptr in
                guard let ptr else { return }
                free(UnsafeMutableRawPointer(mutating: ptr))
            },
            init: nil,
            destroy: { _ in },
            get_manifest: nil,
            invoke: { _, _, _, _ in nil },
            version: 6,
            handle_route: handleRoute,
            on_config_changed: nil,
            on_task_event: nil
        )
        let plugin = ExternalPlugin(
            handle: ctx,
            api: api,
            ctx: ctx,
            manifest: makeManifest(pluginId: pluginId),
            path: "/tmp/route-reliability-\(pluginId)",
            abiVersion: 6
        )
        return (plugin, retain)
    }

    /// Async-safe semaphore wait (Swift 6 forbids blocking a concurrency-pool
    /// thread), mirroring the helper in `PluginShutdownRaceTests`.
    private func signaled(_ sem: DispatchSemaphore, within timeout: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: sem.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    /// The core regression: a route callback that blocks inside C code
    /// (ignoring Swift cancellation entirely) must NOT hold the caller past
    /// the timeout. Before the fix, `handleRoute` returned only after the
    /// blocking callback itself returned — wall time equaled the callback's
    /// block duration, not the timeout.
    @Test
    func blockingRouteCallbackDoesNotDefeatTimeout() async throws {
        let recorder = RouteRecorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.route-timeout.\(UUID().uuidString)"
        ) { ctxPtr, _ in
            guard let ctxPtr else { return nil }
            let recorder = Unmanaged<RouteRecorder>.fromOpaque(ctxPtr).takeUnretainedValue()
            recorder.callbackStarted.signal()
            // Deliberately blocking, non-cooperative — models a plugin stuck
            // in a synchronous network call or a deadlocked mutex.
            recorder.releaseCallback.wait()
            recorder.callbackFinished.signal()
            return UnsafePointer(strdup(#"{"status":200,"body":"too late"}"#))
        }

        let timeoutSeconds: TimeInterval = 0.5
        let start = ContinuousClock.now
        var thrownError: NSError?
        do {
            _ = try await plugin.handleRoute(
                requestJSON: #"{"path":"/hook"}"#,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            thrownError = error as NSError
        }
        let elapsed = start.duration(to: .now)

        // The callback really was inside plugin code when the timeout fired.
        #expect(await signaled(recorder.callbackStarted))

        // Timeout error surfaced...
        let error = try #require(thrownError, "handleRoute must throw on timeout")
        #expect(error.domain == "ExternalPlugin")
        #expect(error.code == 5)
        #expect(error.localizedDescription.contains("timed out"))

        // ...and — the actual regression — the caller was resumed at
        // timeout-time, not when the blocked callback eventually returned.
        // Generous ceiling for loaded CI machines; before the fix the wall
        // time here was unbounded (the callback blocks until we signal).
        #expect(
            elapsed < .seconds(5),
            "caller must be released at the timeout, not when the blocking callback returns (elapsed: \(elapsed))"
        )

        // Cleanup: unblock the abandoned callback and wait for it to leave
        // plugin code before the recorder is released.
        recorder.releaseCallback.signal()
        #expect(await signaled(recorder.callbackFinished))
        // Give the abandoned dispatchPluginCall a beat to consume the result.
        try await Task.sleep(nanoseconds: 100_000_000)
        retain.release()
    }

    /// Happy-path control: a fast route handler returns its own response
    /// well before a generous timeout — the race must not fire spuriously.
    @Test
    func fastRouteCallbackReturnsItsResponse() async throws {
        let recorder = RouteRecorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.route-fast.\(UUID().uuidString)"
        ) { _, _ in
            UnsafePointer(strdup(#"{"status":200,"body":"ok"}"#))
        }
        defer { retain.release() }

        let result = try await plugin.handleRoute(
            requestJSON: #"{"path":"/hook"}"#,
            timeoutSeconds: 60
        )
        #expect(result == #"{"status":200,"body":"ok"}"#)
    }

    // MARK: - Mount segment-boundary matching

    @Test
    func mountUiCapturesItselfAndChildrenOnly() {
        typealias Web = PluginManifest.WebSpec
        // Exact mount and children are captured.
        #expect(Web.mountCaptures(subpath: "/ui", mount: "/ui"))
        #expect(Web.mountCaptures(subpath: "/ui/x", mount: "/ui"))
        #expect(Web.mountCaptures(subpath: "/ui/x/y", mount: "/ui"))
        // The regression: `/ui-other` shares the character prefix but is a
        // different path segment and must NOT be captured.
        #expect(!Web.mountCaptures(subpath: "/ui-other", mount: "/ui"))
        #expect(!Web.mountCaptures(subpath: "/ui-other/x", mount: "/ui"))
        // Unrelated paths.
        #expect(!Web.mountCaptures(subpath: "/", mount: "/ui"))
        #expect(!Web.mountCaptures(subpath: "/api", mount: "/ui"))
    }

    @Test
    func rootMountCapturesEverything() {
        typealias Web = PluginManifest.WebSpec
        #expect(Web.mountCaptures(subpath: "/", mount: "/"))
        #expect(Web.mountCaptures(subpath: "/ui", mount: "/"))
        #expect(Web.mountCaptures(subpath: "/ui-other/x", mount: "/"))
    }

    @Test
    func mountNormalizationHandlesMissingSlashAndTrailingSlash() {
        typealias Web = PluginManifest.WebSpec
        #expect(Web.normalizedMount("ui") == "/ui")
        #expect(Web.normalizedMount("/ui/") == "/ui")
        #expect(Web.normalizedMount("/") == "/")
        #expect(Web.normalizedMount("ui/") == "/ui")
        // Manifest authors who write `mount: "ui"` or `mount: "/ui/"` get
        // the same matching behavior as `/ui`.
        #expect(Web.mountCaptures(subpath: "/ui/x", mount: "ui"))
        #expect(Web.mountCaptures(subpath: "/ui/x", mount: "/ui/"))
        #expect(!Web.mountCaptures(subpath: "/ui-other", mount: "ui"))
    }

    @Test
    func relativeSubpathMatchesLegacyDispatchExpectations() {
        typealias Web = PluginManifest.WebSpec
        // Mount root serves the entry file (dispatch checks isEmpty/"/").
        #expect(Web.relativeSubpath(subpath: "/ui", mount: "/ui") == "")
        #expect(Web.relativeSubpath(subpath: "/ui/x", mount: "/ui") == "/x")
        #expect(Web.relativeSubpath(subpath: "/ui/x/y.js", mount: "/ui") == "/x/y.js")
        // Root mount: keep the full subpath (entry for bare "/").
        #expect(Web.relativeSubpath(subpath: "/", mount: "/") == "")
        #expect(Web.relativeSubpath(subpath: "/x", mount: "/") == "/x")
    }
}
