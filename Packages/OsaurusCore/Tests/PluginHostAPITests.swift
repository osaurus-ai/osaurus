//
//  PluginHostAPITests.swift
//  OsaurusCoreTests
//
//  Tests for the Host API v2 implementation: SSRF protection, JSON helpers,
//  rate limiting, ABI struct layout, dispatch models, and agent resolution.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - SSRF Protection

struct SSRFProtectionTests {

    private func check(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return "bad url" }
        return PluginHostContext.checkSSRF(url: url)
    }

    // Blocked addresses

    @Test func blocksLocalhost() {
        #expect(check("http://localhost/path") != nil)
    }

    @Test func blocksLocalhostWithPort() {
        #expect(check("http://localhost:8080/api") != nil)
    }

    @Test func blocksIPv6Loopback() {
        #expect(check("http://[::1]/path") != nil)
    }

    @Test func blocks127Range() {
        #expect(check("http://127.0.0.1/") != nil)
        #expect(check("http://127.0.0.2/") != nil)
        #expect(check("http://127.255.255.255/") != nil)
    }

    @Test func blocks10Range() {
        #expect(check("http://10.0.0.1/") != nil)
        #expect(check("http://10.255.255.255/") != nil)
    }

    @Test func blocks172_16Range() {
        #expect(check("http://172.16.0.1/") != nil)
        #expect(check("http://172.31.255.255/") != nil)
    }

    @Test func allows172_outside_range() {
        #expect(check("http://172.15.0.1/") == nil)
        #expect(check("http://172.32.0.1/") == nil)
    }

    @Test func blocks192_168Range() {
        #expect(check("http://192.168.0.1/") != nil)
        #expect(check("http://192.168.255.255/") != nil)
    }

    @Test func blocks0Range() {
        #expect(check("http://0.0.0.0/") != nil)
        #expect(check("http://0.255.255.255/") != nil)
    }

    @Test func blocksLinkLocal169_254() {
        #expect(check("http://169.254.0.1/") != nil)
        #expect(check("http://169.254.169.254/latest/meta-data/") != nil)
    }

    @Test func blocksLinkLocalIPv6() {
        #expect(check("http://[fe80::1]/") != nil)
    }

    // Allowed addresses

    @Test func allowsPublicIPv4() {
        #expect(check("https://8.8.8.8/dns-query") == nil)
        #expect(check("https://1.1.1.1/") == nil)
        #expect(check("https://203.0.113.1/") == nil)
    }

    @Test func allowsPublicDomain() {
        #expect(check("https://api.example.com/v1/data") == nil)
        #expect(check("https://github.com") == nil)
    }

    @Test func allowsNonIPv4Hostnames() {
        #expect(check("https://my-service.internal.example.com/api") == nil)
    }

    @Test func missingHostReturnsError() {
        let url = URL(string: "data:text/plain;base64,SGVsbG8=")!
        #expect(PluginHostContext.checkSSRF(url: url) != nil)
    }
}

// MARK: - JSON String Helper

struct PluginHostJSONTests {

    @Test func simpleDict() {
        let json = PluginHostContext.jsonString(["key": "value"])
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        #expect(parsed?["key"] == "value")
    }

    @Test func nestedDict() {
        let json = PluginHostContext.jsonString(["error": "test", "message": "Something failed"])
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        #expect(parsed?["error"] == "test")
        #expect(parsed?["message"] == "Something failed")
    }

    @Test func numericValues() {
        let json = PluginHostContext.jsonString(["count": 42, "pi": 3.14])
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["count"] as? Int == 42)
    }

    @Test func emptyDict() {
        let json = PluginHostContext.jsonString([:])
        #expect(json == "{}")
    }

    @Test func boolValues() {
        let json = PluginHostContext.jsonString(["success": true, "failed": false])
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["success"] as? Bool == true)
        #expect(parsed?["failed"] as? Bool == false)
    }

    @Test func arrayValues() {
        let json = PluginHostContext.jsonString(["items": ["a", "b", "c"]])
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect((parsed?["items"] as? [String])?.count == 3)
    }
}

// MARK: - DispatchRequest Model

struct DispatchRequestTests {

    @Test func defaultsAreCorrect() {
        let request = DispatchRequest(mode: .work, prompt: "Do something")
        #expect(request.sourcePluginId == nil)
        #expect(request.showToast == true)
        #expect(request.agentId == nil)
        #expect(request.title == nil)
        #expect(request.parameters.isEmpty)
        #expect(request.folderPath == nil)
        #expect(request.folderBookmark == nil)
    }

    @Test func sourcePluginIdIsPreserved() {
        let request = DispatchRequest(
            mode: .work,
            prompt: "Build feature",
            sourcePluginId: "com.test.plugin"
        )
        #expect(request.sourcePluginId == "com.test.plugin")
    }

    @Test func allFieldsRoundtrip() {
        let id = UUID()
        let agentId = UUID()
        let bookmark = Data([0x01, 0x02, 0x03])

        let request = DispatchRequest(
            id: id,
            mode: .chat,
            prompt: "Hello",
            agentId: agentId,
            title: "My Task",
            parameters: ["key": "val"],
            folderPath: "/tmp/test",
            folderBookmark: bookmark,
            showToast: false,
            sourcePluginId: "com.example.plugin"
        )

        #expect(request.id == id)
        #expect(request.mode == .chat)
        #expect(request.prompt == "Hello")
        #expect(request.agentId == agentId)
        #expect(request.title == "My Task")
        #expect(request.parameters == ["key": "val"])
        #expect(request.folderPath == "/tmp/test")
        #expect(request.folderBookmark == bookmark)
        #expect(request.showToast == false)
        #expect(request.sourcePluginId == "com.example.plugin")
    }
}

// MARK: - BackgroundTaskStatus

struct BackgroundTaskStatusTests {

    @Test func runningIsActive() {
        let status = BackgroundTaskStatus.running
        #expect(status.isActive == true)
        #expect(status.displayName == "Running")
    }

    @Test func awaitingClarificationIsActive() {
        let status = BackgroundTaskStatus.awaitingClarification
        #expect(status.isActive == true)
        #expect(status.displayName == "Waiting")
    }

    @Test func completedSuccessIsNotActive() {
        let status = BackgroundTaskStatus.completed(success: true, summary: "Done")
        #expect(status.isActive == false)
        #expect(status.displayName == "Completed")
    }

    @Test func completedFailureIsNotActive() {
        let status = BackgroundTaskStatus.completed(success: false, summary: "Error")
        #expect(status.isActive == false)
        #expect(status.displayName == "Failed")
    }

    @Test func cancelledIsNotActive() {
        let status = BackgroundTaskStatus.cancelled
        #expect(status.isActive == false)
        #expect(status.displayName == "Cancelled")
    }

    @Test func iconNames() {
        #expect(BackgroundTaskStatus.running.iconName == "arrow.triangle.2.circlepath")
        #expect(BackgroundTaskStatus.awaitingClarification.iconName == "questionmark.circle.fill")
        #expect(BackgroundTaskStatus.completed(success: true, summary: "").iconName == "checkmark.circle.fill")
        #expect(BackgroundTaskStatus.completed(success: false, summary: "").iconName == "xmark.circle.fill")
        #expect(BackgroundTaskStatus.cancelled.iconName == "stop.circle.fill")
    }

    @Test func equality() {
        #expect(BackgroundTaskStatus.running == BackgroundTaskStatus.running)
        #expect(BackgroundTaskStatus.cancelled == BackgroundTaskStatus.cancelled)
        #expect(
            BackgroundTaskStatus.completed(success: true, summary: "ok")
                == BackgroundTaskStatus.completed(success: true, summary: "ok")
        )
        #expect(
            BackgroundTaskStatus.completed(success: true, summary: "ok")
                != BackgroundTaskStatus.completed(success: false, summary: "ok")
        )
    }
}

// MARK: - BackgroundTaskActivityItem

struct BackgroundTaskActivityItemTests {

    @Test func initDefaults() {
        let item = BackgroundTaskActivityItem(kind: .info, title: "Test")
        #expect(item.kind == .info)
        #expect(item.title == "Test")
        #expect(item.detail == nil)
    }

    @Test func initWithDetail() {
        let item = BackgroundTaskActivityItem(kind: .error, title: "Failed", detail: "Timeout after 30s")
        #expect(item.kind == .error)
        #expect(item.detail == "Timeout after 30s")
    }

    @Test func allKinds() {
        let kinds: [BackgroundTaskActivityItem.Kind] = [.info, .progress, .tool, .warning, .success, .error]
        for kind in kinds {
            let item = BackgroundTaskActivityItem(kind: kind, title: "t")
            #expect(item.kind == kind)
        }
    }

    @Test func equality() {
        let date = Date()
        let id = UUID()
        let a = BackgroundTaskActivityItem(id: id, date: date, kind: .tool, title: "Run")
        let b = BackgroundTaskActivityItem(id: id, date: date, kind: .tool, title: "Run")
        #expect(a == b)
    }
}

// MARK: - Host API Struct Layout

struct HostAPIStructTests {

    @Test func defaultInitAllNil() {
        let api = osr_host_api(
            version: 2,
            config_get: nil,
            config_set: nil,
            config_delete: nil,
            db_exec: nil,
            db_query: nil,
            log: nil,
            dispatch: nil,
            task_status: nil,
            dispatch_cancel: nil,
            dispatch_clarify: nil,
            complete: nil,
            complete_stream: nil,
            embed: nil,
            list_models: nil,
            http_request: nil
        )
        #expect(api.version == 2)
        #expect(api.config_get == nil)
        #expect(api.dispatch == nil)
        #expect(api.complete == nil)
        #expect(api.list_models == nil)
        #expect(api.http_request == nil)
    }

    @Test func versionFieldCarriesThrough() {
        var api = osr_host_api(
            version: 1,
            config_get: nil,
            config_set: nil,
            config_delete: nil,
            db_exec: nil,
            db_query: nil,
            log: nil,
            dispatch: nil,
            task_status: nil,
            dispatch_cancel: nil,
            dispatch_clarify: nil,
            complete: nil,
            complete_stream: nil,
            embed: nil,
            list_models: nil,
            http_request: nil
        )
        #expect(api.version == 1)
        api.version = 2
        #expect(api.version == 2)
    }

    @Test func allFieldsAssignable() {
        let dummyGet: osr_config_get_t = { _ in nil }
        let dummySet: osr_config_set_t = { _, _ in }
        let dummyDel: osr_config_delete_t = { _ in }
        let dummyExec: osr_db_exec_t = { _, _ in nil }
        let dummyQuery: osr_db_query_t = { _, _ in nil }
        let dummyLog: osr_log_t = { _, _ in }
        let dummyDispatch: osr_dispatch_t = { _ in nil }
        let dummyStatus: osr_task_status_t = { _ in nil }
        let dummyCancel: osr_dispatch_cancel_t = { _ in }
        let dummyClarify: osr_dispatch_clarify_t = { _, _ in }
        let dummyComplete: osr_complete_t = { _ in nil }
        let dummyStream: osr_complete_stream_t = { _, _, _ in nil }
        let dummyEmbed: osr_embed_t = { _ in nil }
        let dummyModels: osr_list_models_t = { nil }
        let dummyHTTP: osr_http_request_t = { _ in nil }

        let api = osr_host_api(
            version: 2,
            config_get: dummyGet,
            config_set: dummySet,
            config_delete: dummyDel,
            db_exec: dummyExec,
            db_query: dummyQuery,
            log: dummyLog,
            dispatch: dummyDispatch,
            task_status: dummyStatus,
            dispatch_cancel: dummyCancel,
            dispatch_clarify: dummyClarify,
            complete: dummyComplete,
            complete_stream: dummyStream,
            embed: dummyEmbed,
            list_models: dummyModels,
            http_request: dummyHTTP
        )

        #expect(api.config_get != nil)
        #expect(api.config_set != nil)
        #expect(api.config_delete != nil)
        #expect(api.db_exec != nil)
        #expect(api.db_query != nil)
        #expect(api.log != nil)
        #expect(api.dispatch != nil)
        #expect(api.task_status != nil)
        #expect(api.dispatch_cancel != nil)
        #expect(api.dispatch_clarify != nil)
        #expect(api.complete != nil)
        #expect(api.complete_stream != nil)
        #expect(api.embed != nil)
        #expect(api.list_models != nil)
        #expect(api.http_request != nil)
    }
}

// MARK: - Plugin API Struct Layout

struct PluginAPIStructTests {

    @Test func v1PluginHasZeroedV2Fields() {
        let api = osr_plugin_api(
            free_string: nil,
            init: nil,
            destroy: nil,
            get_manifest: nil,
            invoke: nil,
            version: 0,
            handle_route: nil,
            on_config_changed: nil,
            on_task_completed: nil
        )
        #expect(api.version == 0)
        #expect(api.handle_route == nil)
        #expect(api.on_config_changed == nil)
        #expect(api.on_task_completed == nil)
    }

    @Test func v2PluginFieldsPopulated() {
        let dummyRoute: osr_handle_route_t = { _, _ in nil }
        let dummyConfig: osr_on_config_changed_t = { _, _, _ in }
        let dummyCompleted: osr_on_task_completed_t = { _, _, _ in }

        let api = osr_plugin_api(
            free_string: nil,
            init: nil,
            destroy: nil,
            get_manifest: nil,
            invoke: nil,
            version: 2,
            handle_route: dummyRoute,
            on_config_changed: dummyConfig,
            on_task_completed: dummyCompleted
        )
        #expect(api.version == 2)
        #expect(api.handle_route != nil)
        #expect(api.on_config_changed != nil)
        #expect(api.on_task_completed != nil)
    }
}

// MARK: - Dispatch Rate Limiting

struct DispatchRateLimitTests {

    private func makeContext() throws -> PluginHostContext {
        try PluginHostContext(pluginId: "com.test.ratelimit.\(UUID().uuidString)")
    }

    @Test func allowsFirstRequest() throws {
        let ctx = try makeContext()
        defer { ctx.teardown() }
        #expect(ctx.checkDispatchRateLimit() == true)
    }

    @Test func allowsUpTo10Requests() throws {
        let ctx = try makeContext()
        defer { ctx.teardown() }
        for i in 0 ..< 10 {
            #expect(ctx.checkDispatchRateLimit() == true, "Request \(i) should be allowed")
        }
    }

    @Test func denies11thRequest() throws {
        let ctx = try makeContext()
        defer { ctx.teardown() }
        for _ in 0 ..< 10 {
            _ = ctx.checkDispatchRateLimit()
        }
        #expect(ctx.checkDispatchRateLimit() == false)
    }

    @Test func separateContextsHaveIndependentLimits() throws {
        let ctx1 = try makeContext()
        defer { ctx1.teardown() }
        let ctx2 = try makeContext()
        defer { ctx2.teardown() }

        for _ in 0 ..< 10 {
            _ = ctx1.checkDispatchRateLimit()
        }
        #expect(ctx1.checkDispatchRateLimit() == false)
        #expect(ctx2.checkDispatchRateLimit() == true)
    }
}

// MARK: - Thread-Local Plugin Context

struct PluginContextTLSTests {

    @Test func setAndClearActivePlugin() {
        PluginHostContext.setActivePlugin("com.test.tls")
        let key = "ai.osaurus.plugin.active"
        let stored = Thread.current.threadDictionary[key] as? String
        #expect(stored == "com.test.tls")

        PluginHostContext.clearActivePlugin()
        let cleared = Thread.current.threadDictionary[key] as? String
        #expect(cleared == nil)
    }
}

// MARK: - Agent Resolution

@MainActor
struct AgentResolutionTests {

    @Test func resolveDefaultAgentByUUID() {
        let manager = AgentManager.shared
        let result = manager.resolveAgentId(Agent.defaultId.uuidString)
        #expect(result == Agent.defaultId)
    }

    @Test func resolveUnknownUUID_returnsNil() {
        let manager = AgentManager.shared
        let fakeId = UUID().uuidString
        #expect(manager.resolveAgentId(fakeId) == nil)
    }

    @Test func resolveGarbageString_returnsNil() {
        let manager = AgentManager.shared
        #expect(manager.resolveAgentId("not-a-uuid-or-address") == nil)
        #expect(manager.resolveAgentId("") == nil)
    }

    @Test func agentByAddress_noMatch_returnsNil() {
        let manager = AgentManager.shared
        #expect(manager.agent(byAddress: "0xdeadbeef0000000000000000000000000000cafe") == nil)
    }

    @Test func agentByAddress_caseInsensitive() {
        let manager = AgentManager.shared
        let agents = manager.agents.filter { $0.agentAddress != nil }
        guard let agent = agents.first, let address = agent.agentAddress else { return }
        #expect(manager.agent(byAddress: address.uppercased())?.id == agent.id)
        #expect(manager.agent(byAddress: address.lowercased())?.id == agent.id)
    }

    @Test func resolveAgentId_addressFallback() {
        let manager = AgentManager.shared
        let agents = manager.agents.filter { $0.agentAddress != nil }
        guard let agent = agents.first, let address = agent.agentAddress else { return }
        let result = manager.resolveAgentId(address)
        #expect(result == agent.id)
    }
}
