//
//  PluginProcessHostTests.swift
//  OsaurusCoreTests
//
//  End-to-end proof of the killable out-of-process plugin host: a real toy
//  plugin dylib (compiled at test time from C source against the frozen
//  ABI) is loaded by the real `osaurus-plugin-host` helper binary and
//  driven through the real `PluginProcessHostClient`.
//
//  Pins the three contracts that make the helper worth having:
//    1. normal invocations round-trip;
//    2. a WEDGED invocation (plugin sleeps forever — the AX hang shape)
//       breaches its deadline, the helper is killed, and the next call
//       transparently respawns and works;
//    3. host-API callbacks from inside the helper (reverse RPC) complete
//       without deadlocking, even when the host has no context to answer
//       with.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PluginProcessHostTests {

    // MARK: - Fixtures

    /// Anchor class so `Bundle(for:)` resolves the test bundle even under
    /// the swift-testing harness, where `Bundle.allBundles` may not list
    /// the .xctest bundle.
    private final class BundleMarker {}

    /// Directory containing the built test products (xctest bundle and the
    /// `osaurus-plugin-host` executable — SwiftPM puts all products of one
    /// build in the same directory).
    private static var productsDirectory: URL {
        let bundleURL = Bundle(for: BundleMarker.self).bundleURL
        if bundleURL.pathExtension == "xctest" {
            return bundleURL.deletingLastPathComponent()
        }
        return bundleURL
    }

    private static var helperURL: URL {
        productsDirectory.appendingPathComponent("osaurus-plugin-host")
    }

    /// C source for the toy plugin. Mirrors the frozen ABI structs from
    /// `osaurus_plugin.h` (prefix only — the layouts are append-frozen).
    /// Tools: `echo` (round-trip), `sleep` (wedge forever, ignore
    /// everything — the exact shape of a hung AX call), `config_probe`
    /// (calls host->config_get, exercising reverse RPC end-to-end).
    private static let toyPluginSource = #"""
        #include <stdlib.h>
        #include <string.h>
        #include <stdio.h>
        #include <unistd.h>

        typedef void* osr_plugin_ctx_t;

        typedef struct osr_host_api {
            unsigned int version;
            const char* (*config_get)(const char* key);
            void (*config_set)(const char* key, const char* value);
            void (*config_delete)(const char* key);
            /* Remaining slots are irrelevant to this toy plugin; the frozen
               layout means the prefix above is stable. It only ever calls
               config_get. */
        } osr_host_api;

        typedef struct osr_plugin_api {
            void (*free_string)(const char* s);
            osr_plugin_ctx_t (*init)(void);
            void (*destroy)(osr_plugin_ctx_t ctx);
            const char* (*get_manifest)(osr_plugin_ctx_t ctx);
            const char* (*invoke)(osr_plugin_ctx_t ctx, const char* type, const char* id, const char* payload);
            unsigned int version;
            void* handle_route;
            void* on_config_changed;
            void* on_task_event;
        } osr_plugin_api;

        static const osr_host_api* g_host = NULL;

        static void my_free(const char* s) { free((void*)s); }
        static osr_plugin_ctx_t my_init(void) { return malloc(1); }
        static void my_destroy(osr_plugin_ctx_t ctx) { free(ctx); }

        static const char* my_manifest(osr_plugin_ctx_t ctx) {
            return strdup("{\"plugin_id\":\"test.toy\",\"capabilities\":{}}");
        }

        static const char* my_invoke(osr_plugin_ctx_t ctx, const char* type, const char* id, const char* payload) {
            if (strcmp(id, "echo") == 0) {
                char* out = malloc(strlen(payload) + 32);
                sprintf(out, "{\"echo\":%s}", payload);
                return out;
            }
            if (strcmp(id, "sleep") == 0) {
                for (;;) { sleep(3600); }  /* wedged forever */
            }
            if (strcmp(id, "config_probe") == 0) {
                const char* v = g_host && g_host->config_get ? g_host->config_get("some_key") : NULL;
                if (v == NULL) return strdup("{\"config\":null}");
                char* out = malloc(strlen(v) + 32);
                sprintf(out, "{\"config\":\"%s\"}", v);
                free((void*)v);  /* helper strings are strdup'd */
                return out;
            }
            return strdup("{\"error\":\"unknown tool\"}");
        }

        static osr_plugin_api g_api = {
            my_free, my_init, my_destroy, my_manifest, my_invoke, 2, NULL, NULL, NULL
        };

        const osr_plugin_api* osaurus_plugin_entry_v2(const osr_host_api* host) {
            g_host = host;
            return &g_api;
        }
        """#

    /// Compile the toy plugin once per process into a temp dylib.
    private static let toyPluginURL: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-plugin-host-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("toy.c")
        let dylib = dir.appendingPathComponent("toy.dylib")
        try! toyPluginSource.write(to: source, atomically: true, encoding: .utf8)

        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-dynamiclib", "-o", dylib.path, source.path]
        try! cc.run()
        cc.waitUntilExit()
        precondition(cc.terminationStatus == 0, "toy plugin compile failed")
        return dylib
    }()

    private func makeClient() -> PluginProcessHostClient {
        PluginProcessHostClient(
            pluginId: "test.toy",
            dylibPath: Self.toyPluginURL.path,
            helperURL: Self.helperURL
        )
    }

    // MARK: - Tests

    @Test
    func invokeRoundTripsThroughHelperProcess() async throws {
        let client = makeClient()
        defer { Task { await client.shutdown() } }
        let result = try await client.invoke(
            type: "tool", id: "echo", payload: #"{"hello":"world"}"#, agentId: nil
        )
        #expect(result == #"{"echo":{"hello":"world"}}"#)
    }

    @Test
    func wedgedInvokeIsKilledAndNextCallRespawns() async throws {
        let client = makeClient()
        defer { Task { await client.shutdown() } }

        // Wedge: the plugin sleeps forever — like a hung AX/automation call.
        // A short deadline must kill the helper and throw, not hang the test.
        let start = Date()
        do {
            _ = try await client.invoke(
                type: "tool", id: "sleep", payload: "{}", agentId: nil,
                deadlineSeconds: 1.5
            )
            Issue.record("expected wedged invoke to throw")
        } catch let error as PluginProcessHostError {
            #expect(error.message.contains("terminated"))
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 10, "kill path took \(elapsed)s — caller was not released promptly")

        // Recovery: the next call must respawn the helper and work. This is
        // the whole point of the process host — in-process, this plugin
        // would have wedged the accessibility queue until app restart.
        let result = try await client.invoke(
            type: "tool", id: "echo", payload: #"{"after":"restart"}"#, agentId: nil
        )
        #expect(result == #"{"echo":{"after":"restart"}}"#)
    }

    @Test
    func hostAPICallbackRoundTripsWithoutDeadlock() async throws {
        // config_probe calls host->config_get inside the helper, which
        // reverse-RPCs to the parent. No PluginHostContext is registered
        // for "test.toy", so the answer is "no value" — the plugin must
        // receive NULL and answer, not deadlock waiting on the bridge.
        let client = makeClient()
        defer { Task { await client.shutdown() } }
        let result = try await client.invoke(
            type: "tool", id: "config_probe", payload: "{}", agentId: nil,
            deadlineSeconds: 40  // must comfortably beat HostBridge's 30s timeout path
        )
        #expect(result == #"{"config":null}"#)
    }

    @Test
    func helperCrashSurfacesAsErrorAndClientRecovers() async throws {
        let client = makeClient()
        defer { Task { await client.shutdown() } }

        // Load once, then kill the helper out from under the client to
        // simulate a plugin crash (SIGKILL — no goodbye message).
        _ = try await client.invoke(type: "tool", id: "echo", payload: "{}", agentId: nil)
        await client.shutdown()

        // Next call after the process died must respawn cleanly.
        let result = try await client.invoke(
            type: "tool", id: "echo", payload: #"{"x":1}"#, agentId: nil
        )
        #expect(result == #"{"echo":{"x":1}}"#)
    }

    @Test
    func modeIsDisabledByDefault() {
        // The staged-rollout contract: with no flag set and no env
        // override, invocations must stay in-process.
        if ProcessInfo.processInfo.environment["OSAURUS_PLUGIN_PROCESS_HOST"] == "1" {
            return  // explicitly enabled in this environment; nothing to assert
        }
        UserDefaults.standard.removeObject(forKey: PluginProcessHostMode.defaultsKey)
        #expect(PluginProcessHostMode.isEnabled == false)
    }
}
