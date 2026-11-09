import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private final class ImagePermissionPresenter {
    var count = 0
    var ids: [UUID] = []
    var outcome: ToolPermissionPromptService.PromptResolution? = .alwaysAllow
    var presenter: ToolPermissionPromptService.TestPresenter {
        { [self] id, _, _ in
            Task { @MainActor in
                count += 1
                ids.append(id)
                if let outcome {
                    ToolPermissionPromptService.resolveForTesting(id: id, outcome: outcome)
                }
            }
        }
    }
}

@MainActor
@Suite("Image permission uses its owning policy", .serialized, .timeLimit(.minutes(1)))
struct ImagePermissionOwnershipRegressionTests {
    private func kind(edit: Bool) -> ImageSubagentKind {
        var args: [String: Any] = ["prompt": "recolor"]
        if edit { args["source_paths"] = ["/missing-not-opened.png"] }
        return ImageSubagentKind(params: ImageTool.buildParams(args: args, prompt: "recolor"), argumentsJSON: "{}")
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func restoreRegistry(_ previous: ToolPermissionPolicy?) {
        if let previous {
            ToolRegistry.shared.setPolicy(previous, for: "image")
        } else {
            ToolRegistry.shared.clearPolicy(for: "image")
        }
    }

    @Test(
        "Default-agent Always Allow persists the image kind, not the registry",
        arguments: [false, true],
        [ToolPermissionPolicy.ask, .auto]
    )
    func defaultAgentApprovalPersists(edit: Bool, registryPolicy: ToolPermissionPolicy) async throws {
        let lease = await acquireSubagentStoreSandbox("image-owner-default")
        defer { lease.release() }
        let previous = ToolRegistry.shared.configuredPolicy(for: "image")
        defer { restoreRegistry(previous) }
        ToolRegistry.shared.setPolicy(registryPolicy, for: "image")
        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.image.id)
        SubagentConfigurationStore.save(.init(permissionDefaults: permissions))
        let before = try json(SubagentConfigurationStore.snapshot())
        let probe = ImagePermissionPresenter()
        let operation = kind(edit: edit)
        let resolved = ResolvedModel(name: "fixture/no-load", isLocal: true)
        let first = SubagentScope(sessionId: "image-owner-default", toolCallId: "first", agentId: Agent.defaultId)
        let second = SubagentScope(sessionId: "image-owner-default", toolCallId: "second", agentId: Agent.defaultId)
        let decisions = await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            [await operation.permission(first, resolved), await operation.permission(second, resolved)]
        }
        let policy = SubagentConfigurationStore.snapshot().permissionDefaults.policy(
            for: SubagentCapabilityRegistry.image.id
        )
        let registry = ToolRegistry.shared.configuredPolicy(for: "image")
        try retainImagePermissionObservation(
            "image-default-owner",
            [
                "edit": edit, "prompts": probe.count,
                "before": before, "after": try json(SubagentConfigurationStore.snapshot()),
                "policy": String(describing: policy), "registry": String(describing: registry),
            ]
        )
        #expect(decisions.allSatisfy { $0 == .allow })
        #expect(policy == .alwaysAllow)
        #expect(registry == registryPolicy)
        #expect(probe.count == 1)
    }

    @Test("Custom-agent Always Allow stays in that agent only", arguments: [false, true])
    func customAgentApprovalIsScoped(edit: Bool) async throws {
        let lease = await acquireSubagentStoreSandbox("image-owner-custom")
        defer { lease.release() }
        let previous = ToolRegistry.shared.configuredPolicy(for: "image")
        defer { restoreRegistry(previous) }
        ToolRegistry.shared.setPolicy(.ask, for: "image")
        SubagentConfigurationStore.save(.init())
        var a = Agent(
            name: "Image owner A \(UUID())",
            description: "Permission fixture",
            defaultModel: "fixture/no-load",
            autonomousExec: .init(enabled: false),
            memoryEnabled: false
        )
        var b = Agent(
            name: "Image owner B \(UUID())",
            description: "Permission fixture",
            defaultModel: "fixture/no-load",
            autonomousExec: .init(enabled: false),
            memoryEnabled: false
        )
        a.settings.imageEnabled = true
        b.settings.imageEnabled = true
        AgentStore.save(a); AgentStore.save(b); AgentManager.shared.refresh()
        defer { AgentStore.delete(id: a.id); AgentStore.delete(id: b.id); AgentManager.shared.refresh() }
        let beforeA = try #require(AgentManager.shared.agent(for: a.id))
        let beforeB = try json(#require(AgentManager.shared.agent(for: b.id)))
        let globalBefore = try json(SubagentConfigurationStore.snapshot())
        let probe = ImagePermissionPresenter()
        let operation = kind(edit: edit)
        let resolved = ResolvedModel(name: "fixture/no-load", isLocal: true)
        let first = SubagentScope(sessionId: "image-owner-custom", toolCallId: "first", agentId: a.id)
        let second = SubagentScope(sessionId: "image-owner-custom", toolCallId: "second", agentId: a.id)
        let decisions = await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            [await operation.permission(first, resolved), await operation.permission(second, resolved)]
        }
        let afterA = try #require(AgentManager.shared.agent(for: a.id))
        let afterB = try json(#require(AgentManager.shared.agent(for: b.id)))
        let policy = afterA.settings.subagentPermissions.policy(for: SubagentCapabilityRegistry.image.id)
        let registry = ToolRegistry.shared.configuredPolicy(for: "image")
        var beforeSettings = try #require(
            JSONSerialization.jsonObject(with: Data(json(beforeA.settings).utf8)) as? [String: Any]
        )
        var afterSettings = try #require(
            JSONSerialization.jsonObject(with: Data(json(afterA.settings).utf8)) as? [String: Any]
        )
        beforeSettings.removeValue(forKey: "subagentPermissions")
        afterSettings.removeValue(forKey: "subagentPermissions")
        try retainImagePermissionObservation(
            "image-custom-owner",
            [
                "edit": edit, "prompts": probe.count,
                "agentBefore": try json(beforeA), "agentAfter": try json(afterA), "otherBefore": beforeB,
                "otherAfter": afterB,
                "globalBefore": globalBefore, "globalAfter": try json(SubagentConfigurationStore.snapshot()),
                "policy": String(describing: policy), "registry": String(describing: registry),
            ]
        )
        #expect(decisions.allSatisfy { $0 == .allow })
        #expect(policy == .alwaysAllow)
        #expect(registry == .ask)
        #expect(probe.count == 1)
        #expect(afterA.defaultModel == beforeA.defaultModel)
        #expect(NSDictionary(dictionary: beforeSettings).isEqual(to: afterSettings))
        #expect(beforeB == afterB)
        #expect(try json(SubagentConfigurationStore.snapshot()) == globalBefore)
    }

    @Test("Registry auto never overrides an explicit image Deny", arguments: [false, true])
    func explicitDenyStillWins(edit: Bool) async throws {
        let lease = await acquireSubagentStoreSandbox("image-owner-deny")
        defer { lease.release() }
        let previous = ToolRegistry.shared.configuredPolicy(for: "image")
        defer { restoreRegistry(previous) }
        ToolRegistry.shared.setPolicy(.auto, for: "image")
        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.deny, for: SubagentCapabilityRegistry.image.id)
        SubagentConfigurationStore.save(.init(permissionDefaults: permissions))
        let probe = ImagePermissionPresenter()
        let operation = kind(edit: edit)
        let scope = SubagentScope(sessionId: "image-owner-deny", toolCallId: "denied", agentId: Agent.defaultId)
        let decision = await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            await operation.permission(scope, ResolvedModel(name: "fixture/no-load", isLocal: true))
        }
        try retainImagePermissionObservation(
            "image-deny-owner",
            [
                "edit": edit, "prompts": probe.count,
                "decision": String(describing: decision), "config": try json(SubagentConfigurationStore.snapshot()),
            ]
        )
        if case .denied = decision {} else { Issue.record("Image Deny was bypassed") }
        #expect(probe.count == 0)
    }

    @Test("Allow Once and Deny do not persist an image grant", arguments: [false, true])
    func oneCallDecisionsDoNotPersist(edit: Bool) async throws {
        let lease = await acquireSubagentStoreSandbox("image-owner-once")
        defer { lease.release() }
        let previous = ToolRegistry.shared.configuredPolicy(for: "image")
        defer { restoreRegistry(previous) }
        ToolRegistry.shared.setPolicy(.ask, for: "image")
        SubagentConfigurationStore.save(.init())
        let before = try json(SubagentConfigurationStore.snapshot())
        let probe = ImagePermissionPresenter()
        let operation = kind(edit: edit)
        let scope = SubagentScope(sessionId: "once", toolCallId: "once", agentId: Agent.defaultId)
        let resolved = ResolvedModel(name: "fixture/no-load", isLocal: true)
        probe.outcome = .allowOnce
        let first = await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            await operation.permission(scope, resolved)
        }
        probe.outcome = .denied
        let second = await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            await operation.permission(scope, resolved)
        }
        #expect(first == .allow)
        #expect(second != .allow)
        #expect(probe.count == 2)
        #expect(try json(SubagentConfigurationStore.snapshot()) == before)
        #expect(ToolRegistry.shared.configuredPolicy(for: "image") == .ask)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(predicate())
    }

    @Test("Cancelling an image approval drains it without a persistent grant", arguments: [false, true])
    func cancelledPromptDoesNotPersist(edit: Bool) async throws {
        let lease = await acquireSubagentStoreSandbox("image-owner-cancel")
        defer { lease.release() }
        SubagentConfigurationStore.save(.init())
        let before = try json(SubagentConfigurationStore.snapshot())
        let registryBefore = ToolRegistry.shared.configuredPolicy(for: "image")
        let probe = ImagePermissionPresenter()
        probe.outcome = nil
        let operation = kind(edit: edit)
        let scope = SubagentScope(sessionId: "cancel", toolCallId: "cancel", agentId: Agent.defaultId)
        let task = Task {
            await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
                await operation.permission(scope, ResolvedModel(name: "fixture/no-load", isLocal: true))
            }
        }
        defer { task.cancel() }
        try await waitUntil { probe.count == 1 }
        task.cancel()
        #expect(await task.value != .allow)
        #expect(ToolPermissionPromptService.presentedPromptIDForTesting == nil)
        #expect(try json(SubagentConfigurationStore.snapshot()) == before)
        #expect(ToolRegistry.shared.configuredPolicy(for: "image") == registryBefore)
    }

    @Test("Queued image approval rereads its owning policy", arguments: [false, true])
    func queuedApprovalRevalidates(deny: Bool) async throws {
        let lease = await acquireSubagentStoreSandbox("image-owner-queue")
        defer { lease.release() }
        SubagentConfigurationStore.save(.init())
        let registryBefore = ToolRegistry.shared.configuredPolicy(for: "image")
        let probe = ImagePermissionPresenter()
        probe.outcome = nil
        let blocker = Task {
            await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
                await ToolPermissionPromptService.requestPolicyApproval(
                    toolName: "image-owner-blocker",
                    description: "Hold approval queue",
                    argumentsJSON: "{}"
                )
            }
        }
        defer { blocker.cancel() }
        try await waitUntil { probe.count == 1 }
        let operation = kind(edit: false)
        let scope = SubagentScope(sessionId: "queued", toolCallId: "queued", agentId: Agent.defaultId)
        let task = Task {
            await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
                await operation.permission(scope, ResolvedModel(name: "fixture/no-load", isLocal: true))
            }
        }
        defer { task.cancel() }
        try await waitUntil { ToolPermissionPromptService.queuedPromptCountForTesting >= 1 }
        SubagentConfigurationStore.mutate { config in
            config.permissionDefaults.setPolicy(deny ? .deny : .alwaysAllow, for: "image")
        }
        // A regression that presents another card must return a concrete
        // failure rather than leaving the test waiting on an unanswered card.
        probe.outcome = .allowOnce
        ToolPermissionPromptService.resolveForTesting(id: probe.ids[0], outcome: .allowOnce)
        _ = await blocker.value
        let decision = await task.value
        #expect((decision == .allow) == !deny)
        #expect(probe.count == 1)
        #expect(ToolRegistry.shared.configuredPolicy(for: "image") == registryBefore)
    }

    @Test("A deleted launching agent never redirects Always Allow into defaults")
    func missingOwnerDoesNotGrantGlobally() async throws {
        let lease = await acquireSubagentStoreSandbox("image-owner-missing")
        defer { lease.release() }
        SubagentConfigurationStore.save(.init())
        let before = try json(SubagentConfigurationStore.snapshot())
        let registryBefore = ToolRegistry.shared.configuredPolicy(for: "image")
        let probe = ImagePermissionPresenter()
        let operation = kind(edit: false)
        let scope = SubagentScope(sessionId: "missing", toolCallId: "missing", agentId: UUID())
        let decision = await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            await operation.permission(scope, ResolvedModel(name: "fixture/no-load", isLocal: true))
        }
        #expect(decision == .allow)
        #expect(probe.count == 1)
        #expect(try json(SubagentConfigurationStore.snapshot()) == before)
        #expect(ToolRegistry.shared.configuredPolicy(for: "image") == registryBefore)
    }
}

private func retainImagePermissionObservation(_ label: String, _ values: [String: Any]) throws {
    guard let root = ProcessInfo.processInfo.environment["OSAURUS_TEST_EVIDENCE_DIR"] else { return }
    let directory = URL(fileURLWithPath: root, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(label)-\(UUID().uuidString).json")
    try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
