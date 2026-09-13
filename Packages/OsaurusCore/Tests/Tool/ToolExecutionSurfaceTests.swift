//
//  ToolExecutionSurfaceTests.swift
//  osaurusTests
//
//  Pins the execution-surface answer shown on the approval card
//  (osaurus#2651): the public workspace tools keep one name in
//  every mode and are routed to the VM at execution time, so the surface
//  must be derived from the same state the tool body routes on.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Pure resolution

struct ToolExecutionSurfaceResolutionTests {

    @Test("pure VM mode routes every workspace tool into the sandbox")
    func pureVMModeIsSandbox() {
        for name in ToolExecutionSurface.contextRoutedToolNames {
            #expect(
                ToolExecutionSurface.forContextRoutedTool(
                    name: name,
                    pathArgument: "notes.md",
                    hasSandboxBridge: true,
                    hasFolderRoot: false
                ) == .sandboxVM,
                "\(name) with no host root must serve the VM"
            )
        }
    }

    @Test("no sandbox bridge means the host, whatever the path says")
    func noBridgeIsHost() {
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "file_write",
                pathArgument: "/workspace/out.txt",
                hasSandboxBridge: false,
                hasFolderRoot: false
            ) == .nativeHost
        )
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "shell_run",
                pathArgument: nil,
                hasSandboxBridge: false,
                hasFolderRoot: true
            ) == .nativeHost
        )
    }

    @Test("shell_run with a host root never bridges into the VM")
    func shellRunWithRootIsHost() {
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "shell_run",
                pathArgument: nil,
                hasSandboxBridge: true,
                hasFolderRoot: true
            ) == .nativeHost
        )
    }

    @Test("file tools with a host root route by the /workspace prefix")
    func fileToolsRouteByPathWithRoot() {
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "file_write",
                pathArgument: "/workspace/shared/out.txt",
                hasSandboxBridge: true,
                hasFolderRoot: true
            ) == .sandboxVM
        )
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "file_write",
                pathArgument: "src/main.swift",
                hasSandboxBridge: true,
                hasFolderRoot: true
            ) == .nativeHost
        )
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "file_read",
                pathArgument: nil,
                hasSandboxBridge: true,
                hasFolderRoot: true
            ) == .nativeHost
        )
    }

    @Test("routed path argument is `path`, or `destination` for file_copy")
    func routedPathArgument() {
        #expect(
            ToolExecutionSurface.routedPathArgument(
                toolName: "file_write",
                argumentsJSON: #"{"path":"/workspace/a.txt","content":"x"}"#
            ) == "/workspace/a.txt"
        )
        #expect(
            ToolExecutionSurface.routedPathArgument(
                toolName: "file_copy",
                argumentsJSON: #"{"source":"a.txt","destination":"/workspace/b.txt"}"#
            ) == "/workspace/b.txt"
        )
        #expect(
            ToolExecutionSurface.routedPathArgument(toolName: "shell_run", argumentsJSON: "not json") == nil
        )
    }

    @Test("MCP tools follow the provider's transport and execution host")
    func mcpProviderSurface() {
        #expect(ToolExecutionSurface.forMCPProvider(transport: .http, executionHost: .sandbox) == .remoteServer)
        #expect(ToolExecutionSurface.forMCPProvider(transport: .stdio, executionHost: .sandbox) == .sandboxVM)
        #expect(ToolExecutionSurface.forMCPProvider(transport: .stdio, executionHost: .host) == .nativeHost)
        // Unresolvable provider: the conservative answer for a consent prompt.
        #expect(ToolExecutionSurface.forMCPProvider(transport: nil, executionHost: nil) == .nativeHost)
    }

    @Test("every surface has user-facing copy")
    func presentationIsComplete() {
        for surface in ToolExecutionSurface.allCases {
            #expect(!surface.title.isEmpty)
            #expect(!surface.consentDetail.isEmpty)
            #expect(!surface.symbolName.isEmpty)
        }
    }
}

// MARK: - Registry resolution on live routing state

@Suite(.serialized)
@MainActor
struct ToolRegistryExecutionSurfaceTests {

    private func registerSandboxExec() {
        BuiltinSandboxTools.register(
            agentId: "surface-test",
            agentName: "surface-test",
            config: AutonomousExecConfig(enabled: true)
        )
    }

    @Test("sandbox-registered tools are always the VM")
    func sandboxToolIsVM() async {
        await SandboxTestLock.shared.run {
            registerSandboxExec()
            defer { ToolRegistry.shared.unregisterAllSandboxTools() }
            #expect(
                ToolRegistry.shared.executionSurface(
                    for: "sandbox_exec",
                    argumentsJSON: #"{"command":"ls"}"#
                ) == .sandboxVM
            )
        }
    }

    @Test("shell_run reports the VM in pure sandbox mode and the host with a folder root")
    func shellRunFollowsRouting() async {
        await SandboxTestLock.shared.run {
            registerSandboxExec()
            defer { ToolRegistry.shared.unregisterAllSandboxTools() }
            let agentId = UUID()
            let args = #"{"command":"rm -rf build"}"#

            ChatExecutionContext.$currentAgentId.withValue(agentId) {
                ChatExecutionContext.$currentFolderRoot.withValue(nil) {
                    #expect(
                        ToolRegistry.shared.executionSurface(for: "shell_run", argumentsJSON: args)
                            == .sandboxVM
                    )
                }
                ChatExecutionContext.$currentFolderRoot.withValue(
                    URL(fileURLWithPath: NSTemporaryDirectory())
                ) {
                    #expect(
                        ToolRegistry.shared.executionSurface(for: "shell_run", argumentsJSON: args)
                            == .nativeHost
                    )
                }
            }
        }
    }

    @Test("a dispatched host folder is the host even while sandbox tools are registered")
    func dispatchFolderIsHost() async {
        await SandboxTestLock.shared.run {
            registerSandboxExec()
            defer { ToolRegistry.shared.unregisterAllSandboxTools() }
            ChatExecutionContext.$currentAgentId.withValue(UUID()) {
                ChatExecutionContext.$hostFolderIsDispatchTarget.withValue(true) {
                    ChatExecutionContext.$currentFolderRoot.withValue(
                        URL(fileURLWithPath: NSTemporaryDirectory())
                    ) {
                        #expect(
                            ToolRegistry.shared.executionSurface(
                                for: "file_write",
                                argumentsJSON: #"{"path":"/workspace/x.txt","content":""}"#
                            ) == .nativeHost
                        )
                    }
                }
            }
        }
    }

    @Test("without sandbox tools registered, workspace tools are the host")
    func noSandboxIsHost() async {
        await SandboxTestLock.shared.run {
            ToolRegistry.shared.unregisterAllSandboxTools()
            FolderToolManager.shared.ensureFolderToolsRegistered()
            ChatExecutionContext.$currentAgentId.withValue(UUID()) {
                #expect(
                    ToolRegistry.shared.executionSurface(
                        for: "shell_run",
                        argumentsJSON: #"{"command":"ls"}"#
                    ) == .nativeHost
                )
            }
        }
    }

    @Test("unknown tool names resolve to the host")
    func unknownToolIsHost() {
        #expect(
            ToolRegistry.shared.executionSurface(for: "no_such_tool_\(UUID().uuidString)", argumentsJSON: "{}")
                == .nativeHost
        )
    }
}

// MARK: - Gate → card

/// Minimal `.ask` tool so the gate reaches the prompt without system
/// permissions.
private final class AskProbeTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description = "Surface probe."
    let parameters: JSONValue? = nil
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .ask

    init(name: String) { self.name = name }

    func execute(argumentsJSON: String) async throws -> String {
        ToolEnvelope.success(tool: name, text: "ran")
    }
}

private final class SurfacePresenterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []

    var presented: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    var presenter: ToolPermissionPromptService.TestPresenter {
        { [self] id, _, _ in
            lock.lock()
            ids.append(id)
            lock.unlock()
        }
    }

    func waitForPresented() async {
        for _ in 0 ..< 400 where presented.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

// These drive the process-wide prompt queue, so they join the existing
// serialized queue suite rather than forming a second suite that Swift
// Testing would run concurrently against it (both reset the shared state).
extension ToolPermissionPromptQueueTests {

    @Test("the generic registry gate presents the tool's resolved surface")
    @MainActor
    func gatePassesSurfaceToCard() async {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let tool = AskProbeTool(name: "test_surface_ask_probe_\(UUID().uuidString.prefix(8))")
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }
        let probe = SurfacePresenterProbe()

        let gate = ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            Task { @MainActor in
                do {
                    try await ToolRegistry.shared.resolvePermissionGate(
                        name: tool.name,
                        argumentsJSON: "{}"
                    )
                    return true
                } catch {
                    return false
                }
            }
        }

        await probe.waitForPresented()
        #expect(probe.presented.count == 1)
        #expect(ToolPermissionPromptService.presentedExecutionSurfaceForTesting == .nativeHost)

        ToolPermissionPromptService.resolveForTesting(id: probe.presented[0], outcome: .denied)
        #expect(await gate.value == false)
        #expect(ToolPermissionPromptService.presentedExecutionSurfaceForTesting == nil)
    }

    @Test("policy prompts that are not about a machine show no surface")
    @MainActor
    func policyPromptHasNoSurface() async {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let probe = SurfacePresenterProbe()

        let task = ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            Task { @MainActor in
                await ToolPermissionPromptService.requestPolicyApproval(
                    toolName: "spawn_agent",
                    description: "Spawn",
                    argumentsJSON: "{}"
                )
            }
        }
        await probe.waitForPresented()
        #expect(probe.presented.count == 1)
        #expect(ToolPermissionPromptService.presentedExecutionSurfaceForTesting == nil)
        ToolPermissionPromptService.resolveForTesting(id: probe.presented[0], outcome: .denied)
        _ = await task.value
    }
}
