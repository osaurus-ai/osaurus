//
//  ComputerUseDiagnosticsTests.swift
//  OsaurusCoreTests - Computer Use
//
//  Coverage for the read-only Computer Use settings diagnostics.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ComputerUsePermissionDoctorTests: XCTestCase {
    func testMapsAxOnlyPermissionPosture() {
        let snapshot = ComputerUsePermissionDoctor.snapshot(
            input: ComputerUsePermissionDoctorInput(
                availability: MacDriverAvailability(
                    accessibility: true,
                    screenRecording: false,
                    skyLight: false
                ),
                cloudVision: ComputerUseCloudVisionDoctorInput(
                    isGranted: false,
                    isPersistentlyGranted: false,
                    isSessionGranted: false,
                    scrubMode: .allText
                ),
                screenContextEnabled: false,
                agents: []
            )
        )

        XCTAssertEqual(snapshot.row(.accessibility)?.value, "Granted")
        XCTAssertEqual(snapshot.row(.screenRecording)?.value, "Optional")
        XCTAssertEqual(snapshot.row(.axPosture)?.value, "AX-only")
        XCTAssertEqual(snapshot.row(.cloudVision)?.value, "Unavailable")
        XCTAssertEqual(snapshot.row(.screenContext)?.value, "Off")
        XCTAssertEqual(snapshot.row(.perAgent)?.value, "No custom agents")
    }

    func testMapsCloudVisionScreenContextAndAgentAvailability() {
        let customEnabled = UUID()
        let customMissingModel = UUID()
        let snapshot = ComputerUsePermissionDoctor.snapshot(
            input: ComputerUsePermissionDoctorInput(
                availability: MacDriverAvailability(
                    accessibility: true,
                    screenRecording: true,
                    skyLight: false
                ),
                cloudVision: ComputerUseCloudVisionDoctorInput(
                    isGranted: true,
                    isPersistentlyGranted: true,
                    isSessionGranted: false,
                    scrubMode: .pii
                ),
                screenContextEnabled: true,
                agents: [
                    ComputerUseAgentAvailabilityInput(
                        id: Agent.defaultId,
                        displayName: "Osaurus",
                        isBuiltIn: true,
                        computerUseEnabled: false,
                        hasEffectiveModel: true
                    ),
                    ComputerUseAgentAvailabilityInput(
                        id: customEnabled,
                        displayName: "Desk Agent",
                        isBuiltIn: false,
                        computerUseEnabled: true,
                        hasEffectiveModel: true,
                        ceilingPreset: .balanced
                    ),
                    ComputerUseAgentAvailabilityInput(
                        id: customMissingModel,
                        displayName: "No Model Agent",
                        isBuiltIn: false,
                        computerUseEnabled: true,
                        hasEffectiveModel: false
                    ),
                ]
            )
        )

        XCTAssertEqual(snapshot.row(.cloudVision)?.value, "On (persistent)")
        XCTAssertEqual(snapshot.row(.cloudVision)?.severity, .attention)
        XCTAssertEqual(snapshot.row(.screenContext)?.value, "On")
        XCTAssertEqual(snapshot.row(.perAgent)?.value, "2/2 custom enabled")
        XCTAssertEqual(snapshot.agentAvailability.customAgentCount, 2)
        XCTAssertEqual(snapshot.agentAvailability.enabledCustomAgentCount, 2)
        XCTAssertEqual(
            snapshot.agentAvailability.rows.first { $0.id == Agent.defaultId }?.value,
            "Unavailable"
        )
        XCTAssertEqual(
            snapshot.agentAvailability.rows.first { $0.id == customMissingModel }?.severity,
            .attention
        )
    }
}

final class ComputerUseGateInspectorTests: XCTestCase {
    private struct ParityCase {
        let name: String
        let input: ComputerUseGateInspectionInput
        let expectedEffect: EffectClass
        let expectedDecision: ComputerUseGateDecisionKind
        let expectedFinalDisposition: AutonomyDisposition?
        let expectedAllowlistAllowed: Bool
        let expectedDangerousConfirm: Bool
        let expectedPerAppContribution: AutonomyDisposition?
        let expectedCeilingContribution: AutonomyDisposition?
    }

    func testInspectorMatchesClassifierPolicyAndGate() async {
        var trustedWithCautiousNotes = AutonomyPolicy(globalPreset: .trusted)
        trustedWithCautiousNotes.perApp["notes"] = .cautious

        let cases: [ParityCase] = [
            ParityCase(
                name: "send",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .balanced),
                    appName: "Mail",
                    verb: .click,
                    targetLabel: "Send",
                    targetRole: "AXButton"
                ),
                expectedEffect: .consequential,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "delete",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .trusted),
                    appName: "Notes",
                    verb: .click,
                    targetLabel: "Delete",
                    targetRole: "AXButton"
                ),
                expectedEffect: .consequential,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "save with per-app override",
                input: ComputerUseGateInspectionInput(
                    policy: trustedWithCautiousNotes,
                    appName: "Notes",
                    verb: .click,
                    targetLabel: "Save",
                    targetRole: "AXButton"
                ),
                expectedEffect: .edit,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: .confirm,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "OK",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .balanced),
                    appName: "Dialog",
                    verb: .click,
                    targetLabel: "OK",
                    targetRole: "AXButton"
                ),
                expectedEffect: .edit,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "icon-only",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .balanced),
                    appName: "Notes",
                    verb: .click,
                    targetLabel: nil,
                    targetRole: "AXButton"
                ),
                expectedEffect: .edit,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "System Settings",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .autonomous),
                    appName: "System Settings",
                    verb: .click,
                    targetLabel: "Displays",
                    targetRole: "AXButton"
                ),
                expectedEffect: .navigate,
                expectedDecision: .confirm,
                expectedFinalDisposition: .confirm,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: true,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "open app",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .balanced, allowlist: ["mail"]),
                    appName: "Mail",
                    verb: .open,
                    targetLabel: "Save",
                    targetRole: "AXButton",
                    targetValue: "Draft invoice",
                    targetRoleDescription: "button"
                ),
                expectedEffect: .navigate,
                expectedDecision: .run,
                expectedFinalDisposition: .allow,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "allowlist",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .balanced, allowlist: ["notes"]),
                    appName: "Mail",
                    verb: .click,
                    targetLabel: "Files",
                    targetRole: "AXButton"
                ),
                expectedEffect: .navigate,
                expectedDecision: .reject,
                expectedFinalDisposition: nil,
                expectedAllowlistAllowed: false,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: nil
            ),
            ParityCase(
                name: "read-only ceiling",
                input: ComputerUseGateInspectionInput(
                    policy: AutonomyPolicy(globalPreset: .autonomous),
                    ceiling: AutonomyCeiling.cappedAt(.readOnly),
                    appName: "Notes",
                    verb: .click,
                    targetLabel: "Save",
                    targetRole: "AXButton"
                ),
                expectedEffect: .edit,
                expectedDecision: .reject,
                expectedFinalDisposition: .deny,
                expectedAllowlistAllowed: true,
                expectedDangerousConfirm: false,
                expectedPerAppContribution: nil,
                expectedCeilingContribution: .deny
            ),
        ]

        for testCase in cases {
            let inspection = await ComputerUseGateInspector.inspect(testCase.input)
            let appName = appNameForGate(testCase.input, action: inspection.action)
            let isOpen = inspection.action.verb == .open
            let directEffect = EffectClassifier.classify(
                action: inspection.action,
                resolvedRole: isOpen ? nil : nonEmpty(testCase.input.targetRole),
                resolvedLabel: isOpen ? nil : nonEmpty(testCase.input.targetLabel),
                resolvedValue: isOpen ? nil : nonEmpty(testCase.input.targetValue),
                resolvedRoleDescription: isOpen ? nil : nonEmpty(testCase.input.targetRoleDescription),
                appName: appName,
                recipeSignals: AppRecipes.signals(for: appName)
            )
            let directDecision = await ComputerUseGate(
                policy: testCase.input.policy,
                ceiling: testCase.input.ceiling
            ).evaluate(
                action: inspection.action,
                effect: directEffect,
                appName: appName,
                targetLabel: targetLabelForGate(testCase.input, action: inspection.action)
            )

            XCTAssertTrue(inspection.gateIsReached, testCase.name)
            XCTAssertEqual(inspection.effect, directEffect, testCase.name)
            XCTAssertEqual(inspection.decision, directDecision, testCase.name)
            XCTAssertEqual(inspection.effect, testCase.expectedEffect, testCase.name)
            XCTAssertEqual(inspection.decisionKind, testCase.expectedDecision, testCase.name)
            XCTAssertEqual(inspection.finalDisposition, testCase.expectedFinalDisposition, testCase.name)
            XCTAssertEqual(inspection.allowlist.isAllowed, testCase.expectedAllowlistAllowed, testCase.name)
            XCTAssertEqual(
                inspection.dangerousAppRequiresConfirm,
                testCase.expectedDangerousConfirm,
                testCase.name
            )
            XCTAssertEqual(
                inspection.perAppContribution?.disposition,
                testCase.expectedPerAppContribution,
                testCase.name
            )
            XCTAssertEqual(
                inspection.ceilingContribution?.disposition,
                testCase.expectedCeilingContribution,
                testCase.name
            )
        }
    }

    func testReadAndTerminalPreviewVerbsBypassAutonomyGateLikeLiveLoop() async {
        let policy = AutonomyPolicy(globalPreset: .readOnly, allowlist: ["Notes"])
        let verbs: [AgentVerb] = [.observe, .wait, .find, .done, .giveUp]

        for verb in verbs {
            let inspection = await ComputerUseGateInspector.inspect(
                ComputerUseGateInspectionInput(
                    policy: policy,
                    appName: "Mail",
                    verb: verb,
                    targetLabel: "Inbox",
                    targetRole: "AXGroup",
                    note: "Preview"
                )
            )

            XCTAssertFalse(inspection.gateIsReached, verb.rawValue)
            XCTAssertFalse(inspection.allowlist.isReached, verb.rawValue)
            XCTAssertEqual(inspection.allowlist.displayValue, "Not reached", verb.rawValue)
            XCTAssertEqual(inspection.allowlist.isAllowed, false, verb.rawValue)
            XCTAssertEqual(inspection.finalDisposition, nil, verb.rawValue)
            XCTAssertEqual(inspection.decision, .run, verb.rawValue)
            XCTAssertEqual(inspection.decisionKind, .run, verb.rawValue)
            XCTAssertEqual(
                inspection.decisionSummary,
                "Handled before autonomy gating in the live loop.",
                verb.rawValue
            )
        }
    }

    private func appNameForGate(_ input: ComputerUseGateInspectionInput, action: AgentAction) -> String? {
        if action.verb == .open {
            return nonEmpty(action.app) ?? nonEmpty(input.appName)
        }
        return nonEmpty(input.appName)
    }

    private func targetLabelForGate(_ input: ComputerUseGateInspectionInput, action: AgentAction) -> String? {
        if action.verb == .open {
            return nonEmpty(action.app) ?? nonEmpty(input.appName)
        }
        return nonEmpty(input.targetLabel) ?? nonEmpty(input.targetDescription)
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
