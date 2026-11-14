//
//  ComputerUseDiagnosticsPanel.swift
//  OsaurusCore - Computer Use
//
//  Read-only diagnostics for Settings -> Computer Use. Local preview fields
//  can change, but the panel does not mutate policy or tool behavior.
//

import SwiftUI

struct ComputerUseDiagnosticsPanel: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared
    @ObservedObject private var cloudVisionConsent = CloudVisionConsent.shared
    @ObservedObject private var agentManager = AgentManager.shared

    let policy: AutonomyPolicy

    @State private var isExpanded = false
    @State private var previewApp = "Notes"
    @State private var previewVerb: AgentVerb = .click
    @State private var previewTargetLabel = "Save"
    @State private var previewTargetRole = "AXButton"
    @State private var previewTargetValue = ""
    @State private var previewRoleDescription = ""
    @State private var previewNote = ""
    @State private var previewText = ""
    @State private var previewKey = "return"
    @State private var previewModifiers = ""
    @State private var previewCeilingPreset: AutonomyPreset?
    @State private var inspection: ComputerUseGateInspection?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                permissionDoctorSection
                Divider().background(theme.border.default)
                gateInspectorSection
            }
            .padding(.top, theme.space.s12)
        } label: {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "wrench.and.screwdriver")
                    .glyphSize(.body, weight: .medium)
                    .foregroundColor(theme.text.link)
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(L("Diagnostics"))
                        .font(SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                    Text(L("Permission Doctor and autonomy gate inspector."))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(theme.motion.quick) {
                    isExpanded.toggle()
                }
            }
        }
        .tint(theme.text.tertiary)
        .task(id: inspectorFingerprint) {
            await refreshInspection()
        }
    }

    // MARK: - Permission Doctor

    private var permissionDoctorSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            sectionTitle(L("Permission Doctor"))
            helperText(
                L("Read-only snapshot of the cached permission and consent state Computer Use already uses.")
            )

            VStack(spacing: theme.space.s8) {
                ForEach(doctorSnapshot.rows) { row in
                    diagnosticRow(row)
                }
            }

            if !doctorSnapshot.agentAvailability.rows.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text(L("Agent availability"))
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)
                    ForEach(doctorSnapshot.agentAvailability.rows) { row in
                        agentAvailabilityRow(row)
                    }
                }
            }
        }
    }

    private var doctorSnapshot: ComputerUsePermissionDoctorSnapshot {
        ComputerUsePermissionDoctor.snapshot(
            input: ComputerUsePermissionDoctorInput(
                availability: MacDriverAvailability(
                    accessibility: permissionService.cachedIsGranted(.accessibility),
                    screenRecording: permissionService.cachedIsGranted(.screenRecording),
                    skyLight: false
                ),
                cloudVision: ComputerUseCloudVisionDoctorInput(
                    isGranted: cloudVisionConsent.isGranted,
                    isPersistentlyGranted: cloudVisionConsent.isPersistentlyGranted,
                    isSessionGranted: cloudVisionConsent.isSessionGranted,
                    scrubMode: cloudVisionConsent.scrubMode
                ),
                // Screen context is per-agent now (a child of Computer Use), so
                // the global diagnostics row reflects whether ANY agent has it
                // effectively enabled.
                screenContextEnabled: agentManager.agents.contains {
                    agentManager.effectiveCapabilities(for: $0.id).screenContextEnabled
                },
                agents: agentInputs
            )
        )
    }

    private var agentInputs: [ComputerUseAgentAvailabilityInput] {
        agentManager.agents.map { agent in
            let model = agentManager.effectiveModel(for: agent.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ComputerUseAgentAvailabilityInput(
                id: agent.id,
                displayName: agent.displayName,
                isBuiltIn: agent.isBuiltIn,
                computerUseEnabled: agentManager.effectiveCapabilities(for: agent.id).computerUseEnabled,
                hasEffectiveModel: model?.isEmpty == false,
                ceilingPreset: agent.settings.computerUseCeiling?.matchingPreset
            )
        }
    }

    // MARK: - Gate Inspector

    private var gateInspectorSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            sectionTitle(L("Autonomy Gate Inspector"))
            helperText(
                L("Preview a proposed app action against the current policy without running it.")
            )

            inspectorInputs

            if let inspection {
                inspectorResults(inspection)
            } else {
                helperText(L("Preparing inspection..."))
            }
        }
    }

    private var inspectorInputs: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack(alignment: .top, spacing: theme.space.s10) {
                labeledTextField(L("App"), text: $previewApp, placeholder: L("Notes"))
                verbPicker
            }
            HStack(alignment: .top, spacing: theme.space.s10) {
                labeledTextField(L("Target label"), text: $previewTargetLabel, placeholder: L("Save"))
                labeledTextField(L("Target role"), text: $previewTargetRole, placeholder: L("AXButton"))
            }
            HStack(alignment: .top, spacing: theme.space.s10) {
                labeledTextField(L("Target value"), text: $previewTargetValue, placeholder: L("Optional"))
                labeledTextField(
                    L("Role description"),
                    text: $previewRoleDescription,
                    placeholder: L("Optional")
                )
            }
            HStack(alignment: .top, spacing: theme.space.s10) {
                labeledTextField(L("Typed text"), text: $previewText, placeholder: L("For type/set"))
                labeledTextField(L("Key"), text: $previewKey, placeholder: L("For press_key"))
            }
            HStack(alignment: .top, spacing: theme.space.s10) {
                labeledTextField(
                    L("Modifiers"),
                    text: $previewModifiers,
                    placeholder: L("cmd, shift")
                )
                ceilingPicker
            }
            labeledTextField(
                L("Note"),
                text: $previewNote,
                placeholder: L("Optional rationale or surrounding context")
            )
        }
    }

    private var verbPicker: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            fieldLabel(L("Verb"))
            SettingsMenuPicker(selection: $previewVerb) {
                ForEach(AgentVerb.allCases, id: \.self) { verb in
                    Text(verbatim: verbLabel(verb)).tag(verb)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ceilingPicker: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            fieldLabel(L("Preview ceiling"))
            SettingsMenuPicker(selection: $previewCeilingPreset) {
                Text(L("No ceiling")).tag(AutonomyPreset?.none)
                Divider()
                ForEach(AutonomyPreset.allCases) { preset in
                    Text(preset.displayLabel).tag(AutonomyPreset?.some(preset))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorResults(_ inspection: ComputerUseGateInspection) -> some View {
        VStack(spacing: theme.space.s8) {
            resultRow(
                title: L("Effect class"),
                value: inspection.effect.displayLabel,
                detail: String(
                    format: L("Verb baseline: %@"),
                    inspection.action.baselineEffect.displayLabel
                ),
                severity: severity(for: inspection.effect)
            )
            resultRow(
                title: L("Gate decision"),
                value: decisionLabel(inspection.decisionKind),
                detail: inspection.decisionSummary,
                severity: severity(for: inspection.decisionKind)
            )
            resultRow(
                title: L("Allowlist"),
                value: inspection.allowlist.displayValue,
                detail: allowlistDetail(inspection.allowlist),
                severity: inspection.allowlist.isReached
                    ? (inspection.allowlist.isAllowed ? .ready : .attention)
                    : .info
            )
            resultRow(
                title: L("Disposition"),
                value: inspection.finalDisposition?.displayLabel ?? L("Not reached"),
                detail: dispositionDetail(inspection),
                severity: inspection.gateIsReached
                    ? (inspection.finalDisposition.map(severity(for:)) ?? .attention)
                    : .info
            )
            resultRow(
                title: L("Per-app contribution"),
                value: inspection.perAppContribution?.disposition.displayLabel ?? L("None"),
                detail: inspection.perAppContribution?.label
                    ?? L("No matching per-app override for the preview app."),
                severity: inspection.perAppContribution.map { severity(for: $0.disposition) } ?? .info
            )
            resultRow(
                title: L("Ceiling contribution"),
                value: inspection.ceilingContribution?.disposition.displayLabel ?? L("None"),
                detail: inspection.ceilingContribution?.label
                    ?? L("No preview ceiling is applied."),
                severity: inspection.ceilingContribution.map { severity(for: $0.disposition) } ?? .info
            )
            resultRow(
                title: L("Dangerous-app confirm"),
                value: inspection.dangerousAppRequiresConfirm ? L("Yes") : L("No"),
                detail: inspection.dangerousAppRequiresConfirm
                    ? L("The preview app matches the forced-confirm guardrail.")
                    : L("No forced-confirm app match for this preview."),
                severity: inspection.dangerousAppRequiresConfirm ? .attention : .info
            )
        }
    }

    private var inspectorInput: ComputerUseGateInspectionInput {
        ComputerUseGateInspectionInput(
            policy: policy,
            ceiling: previewCeilingPreset.map(AutonomyCeiling.cappedAt),
            appName: previewApp,
            verb: previewVerb,
            targetLabel: previewTargetLabel,
            targetRole: previewTargetRole,
            targetValue: previewTargetValue,
            targetRoleDescription: previewRoleDescription,
            note: previewNote,
            text: previewText,
            key: previewKey,
            modifiers: parsedModifiers
        )
    }

    private var parsedModifiers: [String] {
        previewModifiers
            .split { $0 == "," || $0 == "+" || $0 == " " || $0 == "\t" }
            .map { String($0).lowercased() }
    }

    private var inspectorFingerprint: InspectorFingerprint {
        InspectorFingerprint(
            policy: policy,
            app: previewApp,
            verb: previewVerb,
            targetLabel: previewTargetLabel,
            targetRole: previewTargetRole,
            targetValue: previewTargetValue,
            roleDescription: previewRoleDescription,
            note: previewNote,
            text: previewText,
            key: previewKey,
            modifiers: previewModifiers,
            ceilingPreset: previewCeilingPreset
        )
    }

    @MainActor
    private func refreshInspection() async {
        inspection = await ComputerUseGateInspector.inspect(inspectorInput)
    }

    // MARK: - Row helpers

    private func diagnosticRow(_ row: ComputerUseDiagnosticRow) -> some View {
        resultRow(
            title: row.title,
            value: row.value,
            detail: row.detail,
            severity: row.severity
        )
    }

    private func agentAvailabilityRow(_ row: ComputerUseAgentAvailabilityRow) -> some View {
        SettingsFindingRow(
            severity: findingSeverity(row.severity),
            title: row.name,
            value: row.value,
            detail: row.detail
        )
    }

    private func resultRow(
        title: String,
        value: String,
        detail: String,
        severity: ComputerUseDiagnosticSeverity
    ) -> some View {
        SettingsFindingRow(
            severity: findingSeverity(severity),
            title: title,
            value: value,
            detail: detail
        )
    }

    private func findingSeverity(_ severity: ComputerUseDiagnosticSeverity) -> SettingsFindingRow.Severity {
        switch severity {
        case .ready: .ok
        case .attention: .warning
        case .inactive: .inactive
        case .info: .info
        }
    }

    private func labeledTextField(
        _ label: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            fieldLabel(label)
            SettingsTextField(placeholder: placeholder, text: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SettingsFont.chip)
            .foregroundColor(theme.text.secondary)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SettingsFont.compactLabel)
            .foregroundColor(theme.text.primary)
    }

    private func helperText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Formatting

    private func verbLabel(_ verb: AgentVerb) -> String {
        switch verb {
        case .observe: return L("Observe")
        case .wait: return L("Wait")
        case .find: return L("Find")
        case .click: return L("Click")
        case .doubleClick: return L("Double-click")
        case .rightClick: return L("Right-click")
        case .drag: return L("Drag")
        case .type: return L("Type")
        case .setValue: return L("Set value")
        case .clear: return L("Clear")
        case .pressKey: return L("Press key")
        case .scroll: return L("Scroll")
        case .open: return L("Open app")
        case .done: return L("Done")
        case .giveUp: return L("Give up")
        }
    }

    private func decisionLabel(_ kind: ComputerUseGateDecisionKind) -> String {
        switch kind {
        case .run: return L("Auto-run")
        case .confirm: return L("Ask first")
        case .reject: return L("Block")
        }
    }

    private func allowlistDetail(_ allowlist: ComputerUseAllowlistInspection) -> String {
        guard allowlist.isReached else {
            return L("This preview verb is handled before app allowlist gating.")
        }
        guard allowlist.isActive else {
            return L("No app allowlist is active.")
        }
        let app = allowlist.normalizedApp ?? L("unknown app")
        let entries = allowlist.entries.joined(separator: ", ")
        return String(format: L("Preview app: %@. Allowed apps: %@."), app, entries)
    }

    private func dispositionDetail(_ inspection: ComputerUseGateInspection) -> String {
        guard inspection.gateIsReached else {
            return L("This preview verb is handled before autonomy gating.")
        }
        var parts = [
            String(
                format: L("Global %@ -> %@"),
                inspection.globalContribution.label,
                inspection.globalContribution.disposition.displayLabel
            )
        ]
        if let perApp = inspection.perAppContribution {
            parts.append(
                String(
                    format: L("per-app %@ -> %@"),
                    perApp.label,
                    perApp.disposition.displayLabel
                )
            )
        }
        if let ceiling = inspection.ceilingContribution {
            parts.append(
                String(
                    format: L("ceiling %@ -> %@"),
                    ceiling.label,
                    ceiling.disposition.displayLabel
                )
            )
        }
        if inspection.dangerousAppRequiresConfirm {
            parts.append(L("dangerous-app floor -> Ask first"))
        }
        if !inspection.allowlist.isAllowed {
            parts.append(L("allowlist blocks before disposition"))
        }
        return parts.joined(separator: "; ")
    }

    private func severity(for effect: EffectClass) -> ComputerUseDiagnosticSeverity {
        switch effect {
        case .read, .navigate: return .ready
        case .edit: return .attention
        case .consequential: return .attention
        }
    }

    private func severity(for disposition: AutonomyDisposition) -> ComputerUseDiagnosticSeverity {
        switch disposition {
        case .allow: return .ready
        case .confirm: return .attention
        case .deny: return .attention
        }
    }

    private func severity(for decision: ComputerUseGateDecisionKind) -> ComputerUseDiagnosticSeverity {
        switch decision {
        case .run: return .ready
        case .confirm, .reject: return .attention
        }
    }
}

private struct InspectorFingerprint: Equatable {
    let policy: AutonomyPolicy
    let app: String
    let verb: AgentVerb
    let targetLabel: String
    let targetRole: String
    let targetValue: String
    let roleDescription: String
    let note: String
    let text: String
    let key: String
    let modifiers: String
    let ceilingPreset: AutonomyPreset?
}

