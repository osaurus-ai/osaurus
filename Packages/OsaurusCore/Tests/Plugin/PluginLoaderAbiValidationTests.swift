//
//  PluginLoaderAbiValidationTests.swift
//  OsaurusCoreTests
//
//  Pins the loader's load-time validation:
//  - a plugin ABI table missing any required function pointer is rejected
//    BEFORE `init` is called (previously only `init`/`get_manifest` were
//    checked, so nil `free_string`/`destroy`/`invoke` leaked or broke tools);
//  - the legacy v1 entry path decodes through the explicit
//    `osr_plugin_api_v1` prefix instead of the full struct (out-of-bounds
//    read on historical v1 plugins otherwise);
//  - manifest plugin_id must equal the install-directory-derived ID;
//  - tool and route IDs must be non-empty and unique.
//

import Foundation
import Testing

@testable import OsaurusCore

struct PluginLoaderAbiValidationTests {

    // MARK: - Fixtures

    private static let dummyFree: osr_free_string_t = { _ in }
    private static let dummyInit: osr_init_t = { nil }
    private static let dummyDestroy: osr_destroy_t = { _ in }
    private static let dummyManifest: osr_get_manifest_t = { _ in nil }
    private static let dummyInvoke: osr_invoke_t = { _, _, _, _ in nil }

    private func completeAPI() -> osr_plugin_api {
        osr_plugin_api(
            free_string: Self.dummyFree,
            init: Self.dummyInit,
            destroy: Self.dummyDestroy,
            get_manifest: Self.dummyManifest,
            invoke: Self.dummyInvoke,
            version: 2,
            handle_route: nil,
            on_config_changed: nil,
            on_task_event: nil
        )
    }

    private func makeManifest(
        pluginId: String = "com.test.loader",
        tools: [PluginManifest.ToolSpec]? = nil,
        routes: [PluginManifest.RouteSpec]? = nil
    ) -> PluginManifest {
        PluginManifest(
            plugin_id: pluginId,
            description: nil,
            capabilities: .init(tools: tools, routes: routes, config: nil, web: nil, artifact_handler: nil),
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

    private func tool(_ id: String) -> PluginManifest.ToolSpec {
        PluginManifest.ToolSpec(
            id: id,
            description: "test tool",
            parameters: nil,
            requirements: nil,
            permission_policy: nil
        )
    }

    private func route(_ id: String, path: String = "/x") -> PluginManifest.RouteSpec {
        PluginManifest.RouteSpec(id: id, path: path, methods: ["GET"])
    }

    // MARK: - ABI table validation

    @Test func completeTablePassesValidation() {
        #expect(PluginManager.abiTableValidationFailure(completeAPI()) == nil)
    }

    @Test func missingFreeStringIsRejected() throws {
        var api = completeAPI()
        api.free_string = nil
        let msg = try #require(PluginManager.abiTableValidationFailure(api))
        #expect(msg.contains("free_string"))
    }

    @Test func missingDestroyIsRejected() throws {
        var api = completeAPI()
        api.destroy = nil
        let msg = try #require(PluginManager.abiTableValidationFailure(api))
        #expect(msg.contains("destroy"))
    }

    @Test func missingInvokeIsRejected() throws {
        var api = completeAPI()
        api.invoke = nil
        let msg = try #require(PluginManager.abiTableValidationFailure(api))
        #expect(msg.contains("invoke"))
    }

    @Test func missingInitIsRejected() throws {
        var api = completeAPI()
        api.`init` = nil
        let msg = try #require(PluginManager.abiTableValidationFailure(api))
        #expect(msg.contains("init"))
    }

    @Test func missingGetManifestIsRejected() throws {
        var api = completeAPI()
        api.get_manifest = nil
        let msg = try #require(PluginManager.abiTableValidationFailure(api))
        #expect(msg.contains("get_manifest"))
    }

    @Test func allMissingFunctionsAreListed() throws {
        let api = osr_plugin_api(
            free_string: nil,
            init: nil,
            destroy: nil,
            get_manifest: nil,
            invoke: nil,
            version: 0,
            handle_route: nil,
            on_config_changed: nil,
            on_task_event: nil
        )
        let msg = try #require(PluginManager.abiTableValidationFailure(api))
        for name in ["free_string", "init", "destroy", "get_manifest", "invoke"] {
            #expect(msg.contains(name))
        }
    }

    @Test func nilOptionalV2CallbacksAreStillAccepted() {
        // Optional v2+ callbacks (handle_route / on_config_changed /
        // on_task_event) remain optional; only the required prefix is gated.
        var api = completeAPI()
        api.handle_route = nil
        api.on_config_changed = nil
        api.on_task_event = nil
        #expect(PluginManager.abiTableValidationFailure(api) == nil)
    }

    // MARK: - v1 prefix decode

    @Test func v1PrefixLayoutIsExactlyTheFiveRequiredPointers() {
        // The v1 entry path reads plugin memory through this struct — its
        // size must be exactly five function pointers so the loader never
        // reads past the end of a historical v1 plugin's static table.
        #expect(MemoryLayout<osr_plugin_api_v1>.size == 5 * MemoryLayout<UnsafeRawPointer?>.size)
        #expect(MemoryLayout<osr_plugin_api_v1>.size < MemoryLayout<osr_plugin_api>.size)
    }

    @Test func v1PrefixWidensWithOptionalFieldsZeroed() {
        let prefix = osr_plugin_api_v1(
            free_string: Self.dummyFree,
            init: Self.dummyInit,
            destroy: Self.dummyDestroy,
            get_manifest: Self.dummyManifest,
            invoke: Self.dummyInvoke
        )

        let widened = osr_plugin_api(v1: prefix)

        #expect(widened.free_string != nil)
        #expect(widened.`init` != nil)
        #expect(widened.destroy != nil)
        #expect(widened.get_manifest != nil)
        #expect(widened.invoke != nil)
        #expect(widened.version == 0)
        #expect(widened.handle_route == nil)
        #expect(widened.on_config_changed == nil)
        #expect(widened.on_task_event == nil)
    }

    @Test func v1PrefixWideningPassesAbiValidationWhenComplete() {
        let prefix = osr_plugin_api_v1(
            free_string: Self.dummyFree,
            init: Self.dummyInit,
            destroy: Self.dummyDestroy,
            get_manifest: Self.dummyManifest,
            invoke: Self.dummyInvoke
        )
        #expect(PluginManager.abiTableValidationFailure(osr_plugin_api(v1: prefix)) == nil)
    }

    @Test func v1PrefixWideningStillRejectsIncompleteTable() throws {
        let prefix = osr_plugin_api_v1(
            free_string: nil,
            init: Self.dummyInit,
            destroy: nil,
            get_manifest: Self.dummyManifest,
            invoke: nil
        )
        let msg = try #require(
            PluginManager.abiTableValidationFailure(osr_plugin_api(v1: prefix))
        )
        #expect(msg.contains("free_string"))
        #expect(msg.contains("destroy"))
        #expect(msg.contains("invoke"))
    }

    // MARK: - Manifest identity validation

    @Test func matchingManifestAndDirectoryIdPasses() {
        let manifest = makeManifest(pluginId: "com.test.match")
        #expect(
            PluginManager.manifestIdentityValidationFailure(
                manifest: manifest,
                directoryId: "com.test.match"
            ) == nil
        )
    }

    @Test func mismatchedManifestIdIsRejected() throws {
        let manifest = makeManifest(pluginId: "com.test.impostor")
        let msg = try #require(
            PluginManager.manifestIdentityValidationFailure(
                manifest: manifest,
                directoryId: "com.test.victim"
            )
        )
        #expect(msg.contains("com.test.impostor"))
        #expect(msg.contains("com.test.victim"))
    }

    // MARK: - Tool / route ID validation

    @Test func absentCapabilitiesPass() {
        #expect(PluginManager.manifestCapabilityValidationFailure(makeManifest()) == nil)
    }

    @Test func uniqueToolAndRouteIdsPass() {
        let manifest = makeManifest(
            tools: [tool("a"), tool("b")],
            routes: [route("r1"), route("r2", path: "/y")]
        )
        #expect(PluginManager.manifestCapabilityValidationFailure(manifest) == nil)
    }

    @Test func emptyToolIdIsRejected() throws {
        let manifest = makeManifest(tools: [tool("")])
        let msg = try #require(PluginManager.manifestCapabilityValidationFailure(manifest))
        #expect(msg.contains("empty"))
        #expect(msg.contains("tool"))
    }

    @Test func whitespaceOnlyToolIdIsRejected() throws {
        let manifest = makeManifest(tools: [tool("   ")])
        let msg = try #require(PluginManager.manifestCapabilityValidationFailure(manifest))
        #expect(msg.contains("empty"))
    }

    @Test func duplicateToolIdIsRejected() throws {
        let manifest = makeManifest(tools: [tool("dup"), tool("dup")])
        let msg = try #require(PluginManager.manifestCapabilityValidationFailure(manifest))
        #expect(msg.contains("duplicate"))
        #expect(msg.contains("dup"))
    }

    @Test func emptyRouteIdIsRejected() throws {
        let manifest = makeManifest(routes: [route("")])
        let msg = try #require(PluginManager.manifestCapabilityValidationFailure(manifest))
        #expect(msg.contains("empty"))
        #expect(msg.contains("route"))
    }

    @Test func duplicateRouteIdIsRejected() throws {
        let manifest = makeManifest(routes: [route("dup"), route("dup", path: "/other")])
        let msg = try #require(PluginManager.manifestCapabilityValidationFailure(manifest))
        #expect(msg.contains("duplicate"))
        #expect(msg.contains("dup"))
    }
}
