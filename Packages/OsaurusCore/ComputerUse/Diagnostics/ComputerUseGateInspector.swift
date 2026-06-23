//
//  ComputerUseGateInspector.swift
//  OsaurusCore - Computer Use
//
//  Observational autonomy diagnostics for Settings -> Computer Use. The
//  inspector deliberately calls the same classifier and gate used by the live
//  loop, then annotates the decision with the policy merge inputs.
//

import Foundation

enum ComputerUseGateDecisionKind: String, Sendable, Equatable {
    case run
    case confirm
    case reject
}

struct ComputerUseAllowlistInspection: Sendable, Equatable {
    let isReached: Bool
    let isActive: Bool
    let isAllowed: Bool
    let normalizedApp: String?
    let entries: [String]

    var displayValue: String {
        if !isReached { return "Not reached" }
        if !isActive { return "Open" }
        return isAllowed ? "Allowed" : "Blocked"
    }
}

struct ComputerUseGateContribution: Sendable, Equatable {
    let label: String
    let disposition: AutonomyDisposition
}

struct ComputerUseGateInspectionInput: Sendable, Equatable {
    var policy: AutonomyPolicy
    var ceiling: AutonomyCeiling?
    var appName: String?
    var verb: AgentVerb
    var targetLabel: String?
    var targetRole: String?
    var targetValue: String?
    var targetRoleDescription: String?
    var targetDescription: String?
    var note: String?
    var text: String?
    var key: String?
    var modifiers: [String]

    init(
        policy: AutonomyPolicy,
        ceiling: AutonomyCeiling? = nil,
        appName: String? = "Notes",
        verb: AgentVerb = .click,
        targetLabel: String? = "Save",
        targetRole: String? = "AXButton",
        targetValue: String? = nil,
        targetRoleDescription: String? = nil,
        targetDescription: String? = nil,
        note: String? = nil,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String] = []
    ) {
        self.policy = policy
        self.ceiling = ceiling
        self.appName = appName
        self.verb = verb
        self.targetLabel = targetLabel
        self.targetRole = targetRole
        self.targetValue = targetValue
        self.targetRoleDescription = targetRoleDescription
        self.targetDescription = targetDescription
        self.note = note
        self.text = text
        self.key = key
        self.modifiers = modifiers
    }
}

struct ComputerUseGateInspection: Sendable, Equatable {
    let action: AgentAction
    let effect: EffectClass
    let gateIsReached: Bool
    let allowlist: ComputerUseAllowlistInspection
    let globalContribution: ComputerUseGateContribution
    let perAppContribution: ComputerUseGateContribution?
    let ceilingContribution: ComputerUseGateContribution?
    let policyDisposition: AutonomyDisposition
    let dangerousAppRequiresConfirm: Bool
    let finalDisposition: AutonomyDisposition?
    let decision: GateDecision
    let decisionKind: ComputerUseGateDecisionKind
    let decisionSummary: String
}

enum ComputerUseGateInspector {
    static func inspect(_ input: ComputerUseGateInspectionInput) async -> ComputerUseGateInspection {
        let action = makeAction(from: input)
        let appName = appNameForGate(input: input, action: action)
        let targetLabel = targetLabelForGate(input: input, action: action)
        let isOpen = action.verb == .open
        let effect = EffectClassifier.classify(
            action: action,
            resolvedRole: isOpen ? nil : nonEmpty(input.targetRole),
            resolvedLabel: isOpen ? nil : nonEmpty(input.targetLabel),
            resolvedValue: isOpen ? nil : nonEmpty(input.targetValue),
            resolvedRoleDescription: isOpen ? nil : nonEmpty(input.targetRoleDescription),
            appName: appName,
            recipeSignals: AppRecipes.signals(for: appName)
        )

        let gateIsReached = isGatedVerb(input.verb)
        let allowlist = allowlistInspection(
            policy: input.policy,
            appName: appName,
            isReached: gateIsReached
        )
        let global = ComputerUseGateContribution(
            label: input.policy.globalPreset.displayLabel,
            disposition: input.policy.globalPreset.disposition(for: effect)
        )
        let perApp = perAppContribution(policy: input.policy, appName: appName, effect: effect)
        let ceiling = ceilingContribution(ceiling: input.ceiling, effect: effect)
        let policyDisposition = input.policy.disposition(
            for: effect,
            app: appName,
            ceiling: input.ceiling
        )
        let dangerousConfirm = effect >= .navigate && input.policy.requiresForcedConfirm(app: appName)
        let finalDisposition: AutonomyDisposition?
        let decision: GateDecision
        let decisionText: String
        if gateIsReached {
            finalDisposition =
                allowlist.isAllowed
                ? (dangerousConfirm
                    ? AutonomyDisposition.strictest(policyDisposition, .confirm)
                    : policyDisposition)
                : nil
            decision = await ComputerUseGate(policy: input.policy, ceiling: input.ceiling).evaluate(
                action: action,
                effect: effect,
                appName: appName,
                targetLabel: targetLabel
            )
            decisionText = decisionSummary(decision)
        } else {
            finalDisposition = nil
            decision = .run
            decisionText = "Handled before autonomy gating in the live loop."
        }

        return ComputerUseGateInspection(
            action: action,
            effect: effect,
            gateIsReached: gateIsReached,
            allowlist: allowlist,
            globalContribution: global,
            perAppContribution: perApp,
            ceilingContribution: ceiling,
            policyDisposition: policyDisposition,
            dangerousAppRequiresConfirm: dangerousConfirm,
            finalDisposition: finalDisposition,
            decision: decision,
            decisionKind: decisionKind(decision),
            decisionSummary: decisionText
        )
    }

    private static func isGatedVerb(_ verb: AgentVerb) -> Bool {
        switch verb {
        case .observe, .wait, .find, .done, .giveUp:
            return false
        case .click, .doubleClick, .rightClick, .drag, .type, .setValue, .clear, .pressKey, .scroll, .open:
            return true
        }
    }

    private static func makeAction(from input: ComputerUseGateInspectionInput) -> AgentAction {
        let target = target(from: input)
        let note = nonEmpty(input.note)
        switch input.verb {
        case .observe:
            return AgentAction(verb: .observe, note: note)
        case .wait:
            return AgentAction(verb: .wait, seconds: 1, note: note)
        case .find:
            return AgentAction(
                verb: .find,
                query: nonEmpty(input.targetLabel) ?? nonEmpty(input.targetDescription),
                roles: nonEmpty(input.targetRole).map { [$0] } ?? [],
                note: note
            )
        case .click, .doubleClick, .rightClick:
            return AgentAction(verb: input.verb, target: target, note: note)
        case .drag:
            return AgentAction(verb: .drag, target: target, to: AgentTarget(describe: "destination"), note: note)
        case .type:
            return AgentAction(
                verb: .type,
                target: target,
                text: nonEmpty(input.text) ?? "sample text",
                replace: true,
                note: note
            )
        case .setValue:
            return AgentAction(
                verb: .setValue,
                target: target,
                text: nonEmpty(input.text) ?? "sample value",
                note: note
            )
        case .clear:
            return AgentAction(verb: .clear, target: target, note: note)
        case .pressKey:
            return AgentAction(
                verb: .pressKey,
                key: nonEmpty(input.key) ?? "return",
                modifiers: input.modifiers,
                note: note
            )
        case .scroll:
            return AgentAction(verb: .scroll, target: target, direction: .down, amount: 3, note: note)
        case .open:
            return AgentAction(verb: .open, app: nonEmpty(input.appName), note: note)
        case .done:
            return AgentAction(verb: .done, note: note, reason: note)
        case .giveUp:
            return AgentAction(verb: .giveUp, note: note, reason: note)
        }
    }

    private static func target(from input: ComputerUseGateInspectionInput) -> AgentTarget? {
        guard let describe = nonEmpty(input.targetDescription) ?? nonEmpty(input.targetLabel) else {
            return nil
        }
        return AgentTarget(describe: describe)
    }

    private static func appNameForGate(input: ComputerUseGateInspectionInput, action: AgentAction) -> String? {
        if action.verb == .open {
            return nonEmpty(action.app) ?? nonEmpty(input.appName)
        }
        return nonEmpty(input.appName)
    }

    private static func targetLabelForGate(input: ComputerUseGateInspectionInput, action: AgentAction) -> String? {
        if action.verb == .open {
            return nonEmpty(action.app) ?? nonEmpty(input.appName)
        }
        return nonEmpty(input.targetLabel) ?? nonEmpty(input.targetDescription)
    }

    private static func allowlistInspection(
        policy: AutonomyPolicy,
        appName: String?,
        isReached: Bool
    ) -> ComputerUseAllowlistInspection {
        let entries = (policy.allowlist ?? []).map(AutonomyPolicy.normalize).sorted()
        let normalizedApp = nonEmpty(appName).map(AutonomyPolicy.normalize)
        return ComputerUseAllowlistInspection(
            isReached: isReached,
            isActive: !entries.isEmpty,
            isAllowed: policy.isAppAllowed(appName),
            normalizedApp: normalizedApp,
            entries: entries
        )
    }

    private static func perAppContribution(
        policy: AutonomyPolicy,
        appName: String?,
        effect: EffectClass
    ) -> ComputerUseGateContribution? {
        guard let appName else { return nil }
        guard let preset = policy.perApp[AutonomyPolicy.normalize(appName)] else { return nil }
        return ComputerUseGateContribution(
            label: preset.displayLabel,
            disposition: preset.disposition(for: effect)
        )
    }

    private static func ceilingContribution(
        ceiling: AutonomyCeiling?,
        effect: EffectClass
    ) -> ComputerUseGateContribution? {
        guard let cap = ceiling?.cap(for: effect) else { return nil }
        let label = ceiling?.matchingPreset.map { "At most: \($0.displayLabel)" } ?? "Custom ceiling"
        return ComputerUseGateContribution(label: label, disposition: cap)
    }

    private static func decisionKind(_ decision: GateDecision) -> ComputerUseGateDecisionKind {
        switch decision {
        case .run:
            return .run
        case .confirm:
            return .confirm
        case .reject:
            return .reject
        }
    }

    private static func decisionSummary(_ decision: GateDecision) -> String {
        switch decision {
        case .run:
            return "Auto-run"
        case .confirm(let preview):
            return "Ask first: \(preview.summary)"
        case .reject(let reason):
            return "Blocked: \(reason)"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
