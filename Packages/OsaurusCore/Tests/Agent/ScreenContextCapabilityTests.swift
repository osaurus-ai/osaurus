//
//  ScreenContextCapabilityTests.swift
//  OsaurusCoreTests — Agent
//
//  Pins the per-agent screen-context resolution: it is a child of Computer
//  Use, so `AgentManager.effectiveCapabilities(for:).screenContextEnabled`
//  must resolve to `computerUseEnabled && screenContextEnabled`. A regression
//  here would either leak ambient screen context to agents without Computer
//  Use or silently drop it for agents that opted in.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ScreenContextCapabilityTests {

    /// Register a custom agent with the given Computer Use / screen-context
    /// flags under an isolated storage root, run the body, then clean up.
    /// Holds the storage + sandbox locks because `effectiveCapabilities`
    /// reads `AgentManager.shared`, which loads from `OsaurusPaths.overrideRoot`.
    private func withCustomAgent(
        computerUseEnabled: Bool,
        screenContextEnabled: Bool,
        body: @MainActor @Sendable (UUID) async -> Void
    ) async {
        await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-screen-context-caps-\(UUID().uuidString)",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            var settings = AgentSettings.defaultDisabled
            settings.computerUseEnabled = computerUseEnabled
            settings.screenContextEnabled = screenContextEnabled
            let agent = Agent(
                name: "ScreenCtxTestAgent-\(UUID().uuidString.prefix(6))",
                agentAddress: "test-screen-context-\(UUID().uuidString)",
                settings: settings
            )
            AgentManager.shared.add(agent)
            await body(agent.id)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("screen context resolves on only when Computer Use AND the flag are on")
    func resolvesOnlyUnderComputerUse() async {
        await withCustomAgent(computerUseEnabled: true, screenContextEnabled: true) { id in
            #expect(AgentManager.shared.effectiveCapabilities(for: id).screenContextEnabled == true)
        }
    }

    @Test("screen context resolves off when Computer Use is off even if the flag is on")
    func offWhenComputerUseOff() async {
        await withCustomAgent(computerUseEnabled: false, screenContextEnabled: true) { id in
            #expect(AgentManager.shared.effectiveCapabilities(for: id).screenContextEnabled == false)
        }
    }

    @Test("screen context resolves off when the flag is off even if Computer Use is on")
    func offWhenFlagOff() async {
        await withCustomAgent(computerUseEnabled: true, screenContextEnabled: false) { id in
            #expect(AgentManager.shared.effectiveCapabilities(for: id).screenContextEnabled == false)
        }
    }
}
