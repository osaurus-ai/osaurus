//
//  ComputerUsePermissionDoctor.swift
//  OsaurusCore - Computer Use
//
//  Read-only diagnostics for the Computer Use settings panel. This file keeps
//  the status mapping pure so the UI can summarize existing cached state
//  without adding new live Accessibility probes.
//

import Foundation

enum ComputerUseDiagnosticSeverity: String, Sendable, Equatable {
    case ready
    case attention
    case inactive
    case info
}

enum ComputerUsePermissionDoctorRowID: String, Sendable, CaseIterable {
    case accessibility
    case screenRecording
    case axPosture
    case cloudVision
    case screenContext
    case perAgent
    case dangerousAppGuardrail
}

struct ComputerUseDiagnosticRow: Identifiable, Sendable, Equatable {
    let id: ComputerUsePermissionDoctorRowID
    let title: String
    let value: String
    let detail: String
    let severity: ComputerUseDiagnosticSeverity
}

struct ComputerUseAgentAvailabilityInput: Sendable, Equatable {
    let id: UUID
    let displayName: String
    let isBuiltIn: Bool
    let computerUseEnabled: Bool
    let hasEffectiveModel: Bool
    let ceilingPreset: AutonomyPreset?

    init(
        id: UUID = UUID(),
        displayName: String,
        isBuiltIn: Bool,
        computerUseEnabled: Bool,
        hasEffectiveModel: Bool,
        ceilingPreset: AutonomyPreset? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isBuiltIn = isBuiltIn
        self.computerUseEnabled = computerUseEnabled
        self.hasEffectiveModel = hasEffectiveModel
        self.ceilingPreset = ceilingPreset
    }
}

struct ComputerUseCloudVisionDoctorInput: Sendable, Equatable {
    let isGranted: Bool
    let isPersistentlyGranted: Bool
    let isSessionGranted: Bool
    let scrubMode: ScrubMode
}

struct ComputerUsePermissionDoctorInput: Sendable, Equatable {
    let availability: MacDriverAvailability
    let cloudVision: ComputerUseCloudVisionDoctorInput
    let screenContextEnabled: Bool
    let agents: [ComputerUseAgentAvailabilityInput]
}

struct ComputerUseAgentAvailabilityRow: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let value: String
    let detail: String
    let severity: ComputerUseDiagnosticSeverity
}

struct ComputerUseAgentAvailabilitySummary: Sendable, Equatable {
    let customAgentCount: Int
    let enabledCustomAgentCount: Int
    let rows: [ComputerUseAgentAvailabilityRow]
}

struct ComputerUsePermissionDoctorSnapshot: Sendable, Equatable {
    let rows: [ComputerUseDiagnosticRow]
    let agentAvailability: ComputerUseAgentAvailabilitySummary
    let dangerousAppNeedleCount: Int

    func row(_ id: ComputerUsePermissionDoctorRowID) -> ComputerUseDiagnosticRow? {
        rows.first { $0.id == id }
    }
}

enum ComputerUsePermissionDoctor {
    static func snapshot(input: ComputerUsePermissionDoctorInput) -> ComputerUsePermissionDoctorSnapshot {
        let agentSummary = agentAvailability(from: input.agents)
        let rows: [ComputerUseDiagnosticRow] = [
            accessibilityRow(granted: input.availability.accessibility),
            screenRecordingRow(granted: input.availability.screenRecording),
            axPostureRow(availability: input.availability),
            cloudVisionRow(
                screenRecordingGranted: input.availability.screenRecording,
                cloudVision: input.cloudVision
            ),
            screenContextRow(
                enabled: input.screenContextEnabled,
                accessibilityGranted: input.availability.accessibility
            ),
            perAgentRow(summary: agentSummary),
            dangerousAppGuardrailRow(),
        ]
        return ComputerUsePermissionDoctorSnapshot(
            rows: rows,
            agentAvailability: agentSummary,
            dangerousAppNeedleCount: AutonomyPolicy.forcedConfirmAppNeedles.count
        )
    }

    private static func accessibilityRow(granted: Bool) -> ComputerUseDiagnosticRow {
        ComputerUseDiagnosticRow(
            id: .accessibility,
            title: "Accessibility",
            value: granted ? "Granted" : "Missing",
            detail: granted
                ? "AX tree reads and input control are available to Computer Use."
                : "Computer Use cannot start until Accessibility is granted.",
            severity: granted ? .ready : .attention
        )
    }

    private static func screenRecordingRow(granted: Bool) -> ComputerUseDiagnosticRow {
        ComputerUseDiagnosticRow(
            id: .screenRecording,
            title: "Screen Recording",
            value: granted ? "Granted" : "Optional",
            detail: granted
                ? "Screenshot tiers are available when AX text is not enough."
                : "Screenshot tiers are unavailable; the harness stays on AX-only capture.",
            severity: granted ? .ready : .inactive
        )
    }

    private static func axPostureRow(availability: MacDriverAvailability) -> ComputerUseDiagnosticRow {
        if !availability.accessibility {
            return ComputerUseDiagnosticRow(
                id: .axPosture,
                title: "AX-only posture",
                value: "Blocked",
                detail: "AX-only mode still needs Accessibility before any run can start.",
                severity: .attention
            )
        }
        if availability.screenRecording {
            return ComputerUseDiagnosticRow(
                id: .axPosture,
                title: "AX-only posture",
                value: "AX-first with screenshot fallback",
                detail: "Runs start from Accessibility text and may escalate to SOM/Vision when needed.",
                severity: .ready
            )
        }
        return ComputerUseDiagnosticRow(
            id: .axPosture,
            title: "AX-only posture",
            value: "AX-only",
            detail: "Runs can read and act through Accessibility text without capturing pixels.",
            severity: .ready
        )
    }

    private static func cloudVisionRow(
        screenRecordingGranted: Bool,
        cloudVision: ComputerUseCloudVisionDoctorInput
    ) -> ComputerUseDiagnosticRow {
        guard screenRecordingGranted else {
            return ComputerUseDiagnosticRow(
                id: .cloudVision,
                title: "Cloud vision",
                value: "Unavailable",
                detail: "Remote image fallback needs Screen Recording plus explicit consent.",
                severity: .inactive
            )
        }
        guard cloudVision.isGranted else {
            return ComputerUseDiagnosticRow(
                id: .cloudVision,
                title: "Cloud vision",
                value: "Off",
                detail: "Remote image models receive no screenshots unless consent is granted.",
                severity: .inactive
            )
        }

        let scope: String
        if cloudVision.isPersistentlyGranted {
            scope = "persistent"
        } else if cloudVision.isSessionGranted {
            scope = "this launch"
        } else {
            scope = "granted"
        }
        return ComputerUseDiagnosticRow(
            id: .cloudVision,
            title: "Cloud vision",
            value: "On (\(scope))",
            detail: "Scrub mode: \(scrubModeLabel(cloudVision.scrubMode)).",
            severity: cloudVision.scrubMode == .allText ? .ready : .attention
        )
    }

    private static func screenContextRow(
        enabled: Bool,
        accessibilityGranted: Bool
    ) -> ComputerUseDiagnosticRow {
        if enabled, !accessibilityGranted {
            return ComputerUseDiagnosticRow(
                id: .screenContext,
                title: "Screen Context",
                value: "On, blocked",
                detail: "The opt-in is enabled, but snapshots need Accessibility before chat send.",
                severity: .attention
            )
        }
        return ComputerUseDiagnosticRow(
            id: .screenContext,
            title: "Screen Context",
            value: enabled ? "On" : "Off",
            detail: enabled
                ? "Chat can receive a frozen AX-text snapshot at send time."
                : "No ambient screen context is injected into chat.",
            severity: enabled ? .ready : .inactive
        )
    }

    private static func perAgentRow(summary: ComputerUseAgentAvailabilitySummary) -> ComputerUseDiagnosticRow {
        if summary.customAgentCount == 0 {
            return ComputerUseDiagnosticRow(
                id: .perAgent,
                title: "Per-agent enablement",
                value: "No custom agents",
                detail: "Computer Use is hidden for the built-in Default agent.",
                severity: .inactive
            )
        }
        let enabled = summary.enabledCustomAgentCount
        return ComputerUseDiagnosticRow(
            id: .perAgent,
            title: "Per-agent enablement",
            value: "\(enabled)/\(summary.customAgentCount) custom enabled",
            detail: "Only custom agents with the feature enabled can receive the computer_use tool.",
            severity: enabled > 0 ? .ready : .inactive
        )
    }

    private static func dangerousAppGuardrailRow() -> ComputerUseDiagnosticRow {
        ComputerUseDiagnosticRow(
            id: .dangerousAppGuardrail,
            title: "Dangerous-app guardrail",
            value: "Confirm floor active",
            detail:
                "Sensitive apps such as Terminal, System Settings, Keychain Access, and password managers always confirm for actions.",
            severity: .info
        )
    }

    private static func agentAvailability(
        from agents: [ComputerUseAgentAvailabilityInput]
    ) -> ComputerUseAgentAvailabilitySummary {
        let customAgents = agents.filter { !$0.isBuiltIn }
        let enabledCount = customAgents.filter(\.computerUseEnabled).count
        let rows = agents.map { agent -> ComputerUseAgentAvailabilityRow in
            if agent.isBuiltIn {
                return ComputerUseAgentAvailabilityRow(
                    id: agent.id,
                    name: agent.displayName,
                    value: "Unavailable",
                    detail: "Built-in agents cannot enable Computer Use.",
                    severity: .inactive
                )
            }
            if !agent.computerUseEnabled {
                return ComputerUseAgentAvailabilityRow(
                    id: agent.id,
                    name: agent.displayName,
                    value: "Off",
                    detail: "Enable Computer Use in this agent's Features tab.",
                    severity: .inactive
                )
            }
            let ceilingText = agent.ceilingPreset.map { " Ceiling: \($0.displayLabel)." } ?? ""
            let modelText = agent.hasEffectiveModel ? "Model selected." : "No model selected."
            return ComputerUseAgentAvailabilityRow(
                id: agent.id,
                name: agent.displayName,
                value: agent.hasEffectiveModel ? "Enabled" : "Enabled, missing model",
                detail: modelText + ceilingText,
                severity: agent.hasEffectiveModel ? .ready : .attention
            )
        }
        return ComputerUseAgentAvailabilitySummary(
            customAgentCount: customAgents.count,
            enabledCustomAgentCount: enabledCount,
            rows: rows
        )
    }

    private static func scrubModeLabel(_ mode: ScrubMode) -> String {
        switch mode {
        case .allText:
            return "mask all recognized text"
        case .pii:
            return "mask only detected sensitive text"
        }
    }
}
