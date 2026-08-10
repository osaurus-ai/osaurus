import Testing

@testable import OsaurusCore

@Suite("Agent capability readiness")
struct AgentCapabilityReadinessTests {
    @Test("configured and callable is active")
    func active() {
        let readiness = AgentCapabilityReadiness.resolve(
            configured: true,
            toolsEnabled: true
        )

        #expect(readiness.state == .active)
        #expect(readiness.isCallable)
        #expect(readiness.blockers.isEmpty)
    }

    @Test("tools off pauses configuration without erasing it")
    func toolsOff() {
        let readiness = AgentCapabilityReadiness.resolve(
            configured: true,
            toolsEnabled: false,
            blockers: [.noModelSelected]
        )

        #expect(readiness.configured)
        #expect(readiness.state == .paused)
        #expect(readiness.primaryBlocker == .toolsDisabled)
        #expect(readiness.blockers.contains(.noModelSelected))
    }

    @Test("spawn distinguishes missing configuration from unavailable targets")
    func spawnSetupAndAvailability() {
        let noTargets = AgentCapabilityReadiness.subagent(
            flag: .spawn,
            configured: true,
            toolsEnabled: true,
            hasResolvedModel: true
        )
        #expect(noTargets.state == .needsSetup)
        #expect(noTargets.primaryBlocker == .noConfiguredTargets)

        let unavailable = AgentCapabilityReadiness.subagent(
            flag: .spawn,
            configured: true,
            toolsEnabled: true,
            hasResolvedModel: true,
            configuredSpawnTargetCount: 2,
            runnableSpawnTargetCount: 0
        )
        #expect(unavailable.state == .unavailable)
        #expect(unavailable.primaryBlocker == .noRunnableTargets)
    }

    @Test("dedicated subagents report missing installed models")
    func installedModelGates() {
        let image = AgentCapabilityReadiness.subagent(
            flag: .image,
            configured: true,
            toolsEnabled: true,
            hasResolvedModel: true
        )
        let appleScript = AgentCapabilityReadiness.subagent(
            flag: .appleScript,
            configured: true,
            toolsEnabled: true,
            hasResolvedModel: true
        )

        #expect(image.primaryBlocker == .noImageModel)
        #expect(appleScript.primaryBlocker == .noAppleScriptModel)
    }

    @Test("deny policy is an explicit unavailable state")
    func permissionDenied() {
        let readiness = AgentCapabilityReadiness.subagent(
            flag: .spawn,
            configured: true,
            toolsEnabled: true,
            hasResolvedModel: true,
            configuredSpawnTargetCount: 1,
            runnableSpawnTargetCount: 1,
            permission: .deny
        )

        #expect(readiness.state == .unavailable)
        #expect(readiness.primaryBlocker == .permissionDenied)
    }

    @Test("one runnable spawn target stays active while another is checking")
    func partialSpawnPoolIsCallable() {
        let readiness = AgentCapabilityReadiness.subagent(
            flag: .spawn,
            configured: true,
            toolsEnabled: true,
            hasResolvedModel: true,
            configuredSpawnTargetCount: 2,
            runnableSpawnTargetCount: 1,
            isCheckingSpawnTargets: true
        )

        #expect(readiness.state == .active)
    }

    @Test("knowledge and context blockers map to distinct readiness states")
    func genericBlockerStates() {
        let knowledge = AgentCapabilityReadiness.resolve(
            configured: true,
            toolsEnabled: true,
            blockers: [.noKnowledgeCollections]
        )
        let context = AgentCapabilityReadiness.resolve(
            configured: true,
            toolsEnabled: true,
            blockers: [.contextLimit]
        )

        #expect(knowledge.state == .needsSetup)
        #expect(context.state == .paused)
    }
}
