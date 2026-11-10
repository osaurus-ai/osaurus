import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private final class ImageRunApprovalProbe {
    var count = 0
    var commits = 0
    var ids: [UUID] = []
    var resolution: ToolPermissionPromptService.PromptResolution = .allowForRun
    var offers: [Bool] = []
    var presenter: ToolPermissionPromptService.TestPresenter {
        { [self] id, _, _ in
            Task { @MainActor in
                count += 1
                ids.append(id)
                offers.append(ToolPermissionPromptService.remotePrompts.first { $0.id == id }?.offersRunLease == true)
                ToolPermissionPromptService.resolveForTesting(id: id, outcome: resolution)
            }
        }
    }
}

@MainActor
@Suite("Image run approval contract", .serialized, .timeLimit(.minutes(1)))
struct ImageRunApprovalContractTests {
    @Test("Caller-owned approval commits once before returning")
    func approvalCommitsOnce() async throws {
        let probe = ImageRunApprovalProbe()
        probe.resolution = .alwaysAllow
        let registryBefore = ToolRegistry.shared.configuredPolicy(for: "image")
        let outcome = await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            await ToolPermissionPromptService.requestPolicyApprovalOutcome(
                toolName: "image",
                description: "Create an image",
                argumentsJSON: "{}",
                commitApproval: { _ in probe.commits += 1 }
            )
        }
        #expect(outcome == .alwaysAllow)
        #expect(probe.commits == 1)
        let id = try #require(probe.ids.first)
        ToolPermissionPromptService.resolveForTesting(id: id, outcome: .alwaysAllow)
        #expect(probe.commits == 1)
        #expect(ToolRegistry.shared.configuredPolicy(for: "image") == registryBefore)
    }

    @Test("Headless caller-owned approval cannot commit a grant")
    func headlessApprovalCannotCommit() async {
        let probe = ImageRunApprovalProbe()
        let outcome = await ToolPermissionPromptService.requestPolicyApprovalOutcome(
            toolName: "image",
            description: "Create an image",
            argumentsJSON: "{}",
            offersRunLease: true,
            commitApproval: { _ in probe.commits += 1 }
        )
        #expect(outcome == .denied)
        #expect(probe.commits == 0)
    }

    @Test("Run approval covers repeated local images only within one task", arguments: [false, true])
    func localRunApprovalExpires(edit: Bool) async throws {
        let lease = await acquireSubagentStoreSandbox("image-run-approval")
        defer { lease.release() }
        // This case represents an already initialized installation. Retain the
        // full configuration comparison without mixing the one-time spawn-pool migration into image approval.
        var configuration = SubagentConfiguration()
        configuration.spawnPoolSeeded = true
        SubagentConfigurationStore.save(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(SubagentConfigurationStore.snapshot())
        let registryBefore = ToolRegistry.shared.configuredPolicy(for: "image")
        var args: [String: Any] = ["prompt": "recolor"]
        if edit { args["source_paths"] = ["/not-opened.png"] }
        let kind = ImageSubagentKind(params: ImageTool.buildParams(args: args, prompt: "recolor"), argumentsJSON: "{}")
        let scope = SubagentScope(sessionId: "image-run-approval", toolCallId: "first", agentId: Agent.defaultId)
        let resolved = ResolvedModel(name: "fixture/no-load", isLocal: true)
        let probe = ImageRunApprovalProbe()
        let firstRun = ToolPermissionRunScope()
        let firstTwo = await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            await ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                await ChatExecutionContext.$toolPermissionRunScope.withValue(firstRun) {
                    [await kind.permission(scope, resolved), await kind.permission(scope, resolved)]
                }
            }
        }
        let countAfterFirstRun = probe.count
        let firstLeaseGranted = firstRun.allows("image")
        let nextRun = ToolPermissionRunScope()
        let third = await ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            await ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                await ChatExecutionContext.$toolPermissionRunScope.withValue(nextRun) {
                    await kind.permission(scope, resolved)
                }
            }
        }
        let after = try encoder.encode(SubagentConfigurationStore.snapshot())
        if let evidence = ProcessInfo.processInfo.environment["OSAURUS_TEST_EVIDENCE_DIR"] {
            let output = URL(fileURLWithPath: evidence).appendingPathComponent("run-approval-\(edit)-\(UUID()).json")
            let data: [String: Any] = [
                "edit": edit, "promptsAfterFirstTask": countAfterFirstRun,
                "promptsAfterSecondTask": probe.count, "offersRunLease": probe.offers,
                "firstTaskLeaseGranted": firstLeaseGranted, "secondTaskLeaseGranted": nextRun.allows("image"),
                "pid": ProcessInfo.processInfo.processIdentifier,
                "actualRuntimeFlags": ProcessInfo.processInfo.environment.filter {
                    [
                        "OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS", "OSAURUS_TEST_ROOT", "OSU_MODELS_DIR",
                        "OSAURUS_IMAGE_MODELS_DIR", "OSAURUS_TEST_EVIDENCE_DIR",
                    ].contains($0.key)
                },
                "policyBefore": String(decoding: before, as: UTF8.self),
                "policyAfter": String(decoding: after, as: UTF8.self),
            ]
            try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        }
        #expect(firstTwo.allSatisfy { $0 == .allow })
        #expect(third == .allow)
        #expect(probe.offers.allSatisfy { $0 })
        #expect(firstLeaseGranted)
        #expect(countAfterFirstRun == 1)
        #expect(probe.count == 2)
        #expect(ChatExecutionContext.toolPermissionRunScope == nil)
        #expect(before == after)
        #expect(ToolRegistry.shared.configuredPolicy(for: "image") == registryBefore)
    }
}
