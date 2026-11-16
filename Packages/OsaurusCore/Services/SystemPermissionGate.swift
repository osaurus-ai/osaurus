//
//  SystemPermissionGate.swift
//  osaurus
//
//  What the tool permission gate does for one missing macOS permission:
//  ask macOS first, and when macOS cannot ask (denied before, or a
//  permission it never asks for) show the Osaurus panel instead of failing
//  with nothing on screen.
//

import Foundation

@MainActor
enum SystemPermissionGate {
    enum Outcome: Equatable, Sendable {
        case granted
        /// The Automation probe could not decide (a timeout, or the app did
        /// not answer). The tool runs and reports its own error.
        case undetermined
        /// The person answered the macOS dialog with "Don't Allow" just now.
        case declined
        /// The person chose Not Now on the Osaurus panel, or no panel could
        /// be shown (headless, a paired phone, a synced device).
        case notNow
        /// The panel timed out with no answer.
        case notAnswered

        var allowsCall: Bool { self == .granted || self == .undetermined }
    }

    /// The system calls the gate makes, replaceable for tests.
    struct Environment: Sendable {
        var macOSCanAsk: @MainActor @Sendable (SystemPermission) async -> Bool
        var request: @MainActor @Sendable (SystemPermission) async -> PermissionProbeResult.Status
        var isGranted: @MainActor @Sendable (SystemPermission) async -> Bool
        var calendarIsAddOnly: @MainActor @Sendable () async -> Bool

        static let live = Environment(
            macOSCanAsk: { await SystemPermissionService.shared.macOSCanAsk($0) },
            request: { await SystemPermissionService.shared.requestPermissionDecision($0) },
            isGranted: { await SystemPermissionService.shared.missingPermissions(from: [$0.rawValue]).isEmpty },
            calendarIsAddOnly: { await SystemPermissionService.shared.calendarIsAddOnly() }
        )
    }

    @TaskLocal static var environmentOverrideForTests: Environment?

    static func ensure(_ permission: SystemPermission, toolName: String) async -> Outcome {
        let env = environmentOverrideForTests ?? .live
        let macOSAsks = permission.promptsWhenMissing ? await env.macOSCanAsk(permission) : false
        switch await env.request(permission) {
        case .granted: return .granted
        case .unknown: return .undetermined
        case .denied: break
        }
        if macOSAsks { return .declined }

        let reason: SystemPermissionPanelService.Reason
        if !permission.promptsWhenMissing {
            reason = .settingsOnly
        } else if permission == .calendar, await env.calendarIsAddOnly() {
            reason = .addOnly
        } else {
            reason = .turnedOff
        }
        let request = SystemPermissionPanelService.Request(
            permission: permission,
            toolName: toolName,
            requesterName: requesterName(),
            reason: reason
        )
        let recheck: SystemPermissionPanelService.Recheck = { permission in
            if permission.isAutomationBased { return await env.request(permission) == .granted }
            return await env.isGranted(permission)
        }
        switch await SystemPermissionPanelService.ask(request, recheck: recheck) {
        case .granted: return .granted
        case .notNow: return .notNow
        case .timedOut: return .notAnswered
        }
    }

    /// Calendar is granted as Add Only: events can be added, not read.
    static func calendarIsAddOnly() async -> Bool {
        await (environmentOverrideForTests ?? .live).calendarIsAddOnly()
    }

    /// The running agent's name for the panel title; "Osaurus" for the
    /// Orchestrator and for runs with no agent.
    static func requesterName() -> String {
        guard let id = ChatExecutionContext.currentAgentId, id != Agent.defaultId,
            let agent = AgentManager.shared.agent(for: id)
        else { return L("Osaurus") }
        return agent.displayName
    }
}
