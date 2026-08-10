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
    func sandboxBeatsFolder_whenAutonomousAndSandboxRegistered() async {
        await SandboxTestLock.shared.run {
            registerSandboxExec()
            defer { ToolRegistry.shared.unregisterAllSandboxTools() }

            let folder = sampleFolderContext()
            let mode = ToolRegistry.shared.resolveExecutionMode(
                folderContext: folder,
                autonomousEnabled: true
            )
            #expect(mode.usesSandboxTools)
            #expect(!mode.usesHostFolderTools)
            // The selected folder is suspended rather than bridged into the
            // VM. Disabling sandbox resumes the same folder separately.
            #expect(!mode.allowsHostReadTools)
            #expect(mode.hostReadContext == nil)
            #expect(mode.folderContext == nil)
            #expect(!mode.allowsHostWriteTools)
        }
    }

    @Test
    func legacyWriteGrant_neverBridgesFolderIntoSandbox() async {
        await SandboxTestLock.shared.run {
            registerSandboxExec()
            defer { ToolRegistry.shared.unregisterAllSandboxTools() }

            // A legacy host-write grant is inert in sandbox mode.
            let writable = ToolRegistry.shared.resolveExecutionMode(
                folderContext: sampleFolderContext(),
                autonomousEnabled: true,
                allowHostFolderWrites: true
            )
            #expect(writable.usesSandboxTools)
            #expect(!writable.allowsHostReadTools)
            #expect(!writable.allowsHostWriteTools)

            // Grant without a folder is inert (nothing to write).
            let noFolder = ToolRegistry.shared.resolveExecutionMode(
                folderContext: nil,
                autonomousEnabled: true,
                allowHostFolderWrites: true
            )
            #expect(noFolder.usesSandboxTools)
            #expect(!noFolder.allowsHostWriteTools)

            // Grant in plain folder mode (autonomous off) resolves to
            // `.hostFolder`, which is natively writable — the combined
            // write grant never applies there.
            let plainFolder = ToolRegistry.shared.resolveExecutionMode(
                folderContext: sampleFolderContext(),
                autonomousEnabled: false,
                allowHostFolderWrites: true
            )
            #expect(plainFolder.usesHostFolderTools)
            #expect(!plainFolder.allowsHostWriteTools)
        }
    }

    @Test
    func sandboxWithoutFolder_hasNoHostReadContext() async {
        await SandboxTestLock.shared.run {
            registerSandboxExec()
            defer { ToolRegistry.shared.unregisterAllSandboxTools() }

            let mode = ToolRegistry.shared.resolveExecutionMode(
                folderContext: nil,
                autonomousEnabled: true
            )
            #expect(mode.usesSandboxTools)
            #expect(!mode.allowsHostReadTools)
            #expect(mode.hostReadContext == nil)
        }
    }

    @Test
    func folderWinsWhenAutonomousOff() async {
        await SandboxTestLock.shared.run {
            registerSandboxExec()
            defer { ToolRegistry.shared.unregisterAllSandboxTools() }

            let mode = ToolRegistry.shared.resolveExecutionMode(
                folderContext: sampleFolderContext(),
                autonomousEnabled: false
            )
            #expect(mode.usesHostFolderTools)
            #expect(!mode.usesSandboxTools)
        }
    }

    @Test
    func noFolderAutonomousOff_yieldsNone_evenIfSandboxRegistered() async {
        // The legacy single-arg overload would have returned `.sandbox`
        // here just because `sandbox_exec` happens to be registered. The
        // unified resolver requires the autonomous toggle to be on.
        await SandboxTestLock.shared.run {
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
    }

    @Test
    func noFolderAutonomousOn_butSandboxNotRegistered_yieldsNone() async {
        // Sandbox is opt-in but the container hasn't been provisioned yet;
        // the resolver should not lie and say `.sandbox` until the tool is
        // actually in the registry. The composer's "Sandbox not ready"
        // notice + placeholder tool fill the gap in the meantime.
        //
        // Defensive: explicitly clear any sandbox tools a prior test in
        // a different suite may have left registered. Test isolation is
        // serialised within a suite but not across suites in this package.
        await SandboxTestLock.shared.run {
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

    @Test
    func folderDoesNotBecomeFallback_whenRequestedSandboxIsUnavailable() async {
        await SandboxTestLock.shared.run {
            ToolRegistry.shared.unregisterAllSandboxTools()
            let mode = ToolRegistry.shared.resolveExecutionMode(
                folderContext: sampleFolderContext(),
                autonomousEnabled: true
            )
            switch mode {
            case .none: break
            default: Issue.record("expected fail-closed .none, got \(mode)")
            }
            #expect(mode.folderContext == nil)
        }
    }
}
