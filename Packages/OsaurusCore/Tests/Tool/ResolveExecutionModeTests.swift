//
//  ResolveExecutionModeTests.swift
//  osaurusTests
//
//  Pins the priority rule for the unified `ToolRegistry.resolveExecutionMode`
//  helper: sandbox > host folder > none. Used to be two overloads with
//  different priorities, leading to the same agent getting different
//  execution modes depending on entry point (chat vs plugin vs HTTP).
//
//  These tests are the regression net so the overload doesn't grow back.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ResolveExecutionModeTests {

    private func registerSandboxExec() {
        BuiltinSandboxTools.register(
            agentId: "resolve-mode-test",
            agentName: "resolve-mode-test",
            config: AutonomousExecConfig(enabled: true)
        )
    }

    private func sampleFolderContext() -> FolderContext {
        FolderContext(
            rootPath: URL(fileURLWithPath: NSTemporaryDirectory()),
            projectType: .unknown,
            tree: "",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false,
            contextFiles: nil
        )
    }

    @Test
    func sandboxBeatsFolder_whenAutonomousAndSandboxRegistered() {
        registerSandboxExec()
        defer { ToolRegistry.shared.unregisterAllSandboxTools() }

        let mode = ToolRegistry.shared.resolveExecutionMode(
            folderContext: sampleFolderContext(),
            autonomousEnabled: true
        )
        #expect(mode.usesSandboxTools)
        #expect(!mode.usesHostFolderTools)
    }

    @Test
    func folderWinsWhenAutonomousOff() {
        registerSandboxExec()
        defer { ToolRegistry.shared.unregisterAllSandboxTools() }

        let mode = ToolRegistry.shared.resolveExecutionMode(
            folderContext: sampleFolderContext(),
            autonomousEnabled: false
        )
        #expect(mode.usesHostFolderTools)
        #expect(!mode.usesSandboxTools)
    }

    @Test
    func noFolderAutonomousOff_yieldsNone_evenIfSandboxRegistered() {
        // The legacy single-arg overload would have returned `.sandbox`
        // here just because `sandbox_exec` happens to be registered. The
        // unified resolver requires the autonomous toggle to be on.
        registerSandboxExec()
        defer { ToolRegistry.shared.unregisterAllSandboxTools() }

        let mode = ToolRegistry.shared.resolveExecutionMode(
            folderContext: nil,
            autonomousEnabled: false
        )
        switch mode {
        case .none: break
        default: Issue.record("expected .none, got \(mode)")
        }
    }

    @Test
    func noFolderAutonomousOn_butSandboxNotRegistered_yieldsNone() {
        // Sandbox is opt-in but the container hasn't been provisioned yet;
        // the resolver should not lie and say `.sandbox` until the tool is
        // actually in the registry. The composer's "Sandbox not ready"
        // notice + placeholder tool fill the gap in the meantime.
        //
        // Defensive: explicitly clear any sandbox tools a prior test in
        // a different suite may have left registered. Test isolation is
        // serialised within a suite but not across suites in this package.
        ToolRegistry.shared.unregisterAllSandboxTools()
        let mode = ToolRegistry.shared.resolveExecutionMode(
            folderContext: nil,
            autonomousEnabled: true
        )
        switch mode {
        case .none: break
        default: Issue.record("expected .none when sandbox_exec missing, got \(mode)")
        }
    }
}
