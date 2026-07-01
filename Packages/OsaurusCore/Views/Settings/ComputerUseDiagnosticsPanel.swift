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
            VStack(alignment: .leading, spacing: 18) {
                permissionDoctorSection
                Divider().background(theme.cardBorder)
                gateInspectorSection
            }
            .padding(.top, 14)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Diagnostics"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(L("Permission Doctor and autonomy gate inspector."))
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
        }
        .accentColor(theme.tertiaryText)
        .task(id: inspectorFingerprint) {
            await refreshInspection()
        }
    }

    // MARK: - Permission Doctor

    private var permissionDoctorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("Permission Doctor"))
            helperText(
                L("Read-only snapshot of the cached permission and consent state Computer Use already uses.")
            )

            VStack(spacing: 8) {
                ForEach(doctorSnapshot.rows) { row in
                    diagnosticRow(row)
                }
            }

            if !doctorSnapshot.agentAvailability.rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Agent availability"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
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
        VStack(alignment: .leading, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                labeledTextField(L("App"), text: $previewApp, placeholder: L("Notes"))
                verbPicker
            }
            HStack(alignment: .top, spacing: 10) {
                labeledTextField(L("Target label"), text: $previewTargetLabel, placeholder: L("Save"))
                labeledTextField(L("Target role"), text: $previewTargetRole, placeholder: L("AXButton"))
            }
            HStack(alignment: .top, spacing: 10) {
                labeledTextField(L("Target value"), text: $previewTargetValue, placeholder: L("Optional"))
                labeledTextField(
                    L("Role description"),
                    text: $previewRoleDescription,
                    placeholder: L("Optional")
                )
            }
            HStack(alignment: .top, spacing: 10) {
                labeledTextField(L("Typed text"), text: $previewText, placeholder: L("For type/set"))
                labeledTextField(L("Key"), text: $previewKey, placeholder: L("For press_key"))
            }
            HStack(alignment: .top, spacing: 10) {
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
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(L("Verb"))
            Menu {
                ForEach(AgentVerb.allCases, id: \.self) { verb in
                    Button {
                        previewVerb = verb
                    } label: {
                        if previewVerb == verb {
                            Label {
                                Text(verbatim: verbLabel(verb))
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(verbatim: verbLabel(verb))
                        }
                    }
                }
            } label: {
                pickerLabel(verbLabel(previewVerb))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ceilingPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(L("Preview ceiling"))
            Menu {
                Button {
                    previewCeilingPreset = nil
                } label: {
                    if previewCeilingPreset == nil {
                        Label {
                            Text(L("No ceiling"))
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text(L("No ceiling"))
                    }
                }
                Divider()
                ForEach(AutonomyPreset.allCases) { preset in
                    Button {
                        previewCeilingPreset = preset
                    } label: {
                        if previewCeilingPreset == preset {
                            Label {
                                Text(preset.displayLabel)
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(preset.displayLabel)
                        }
                    }
                }
            } label: {
                pickerLabel(previewCeilingPreset?.displayLabel ?? L("No ceiling"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorResults(_ inspection: ComputerUseGateInspection) -> some View {
        VStack(spacing: 8) {
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
        HStack(alignment: .top, spacing: 8) {
            statusDot(row.severity)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: row.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(verbatim: row.value)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(color(for: row.severity))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(color(for: row.severity).opacity(0.1)))
                }
                Text(verbatim: row.detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(10)
        .diagnosticsSurface(cornerRadius: 8, fill: theme.inputBackground, stroke: theme.inputBorder)
    }

    private func resultRow(
        title: String,
        value: String,
        detail: String,
        severity: ComputerUseDiagnosticSeverity
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusDot(severity)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(verbatim: value)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(color(for: severity))
                }
                Text(verbatim: detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(10)
        .diagnosticsSurface(cornerRadius: 8, fill: theme.inputBackground, stroke: theme.inputBorder)
    }

    private func statusDot(_ severity: ComputerUseDiagnosticSeverity) -> some View {
        Circle()
            .fill(color(for: severity))
            .frame(width: 7, height: 7)
    }

    private func labeledTextField(
        _ label: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            ZStack(alignment: .leading) {
                if text.wrappedValue.isEmpty {
                    Text(verbatim: placeholder)
                        .font(.system(size: 11))
                        .foregroundColor(theme.placeholderText)
                        .allowsHitTesting(false)
                }
                TextField("", text: text)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 11))
                    .foregroundColor(theme.primaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .diagnosticsSurface(cornerRadius: 7, fill: theme.inputBackground, stroke: theme.inputBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.secondaryText)
    }

    private func pickerLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText)
            Spacer(minLength: 6)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .diagnosticsSurface(cornerRadius: 7, fill: theme.inputBackground, stroke: theme.inputBorder)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(theme.primaryText)
    }

    private func helperText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
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

    private func color(for severity: ComputerUseDiagnosticSeverity) -> Color {
        switch severity {
        case .ready: return theme.successColor
        case .attention: return theme.warningColor
        case .inactive: return theme.tertiaryText
        case .info: return theme.accentColor
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

private extension View {
    func diagnosticsSurface(
        cornerRadius: CGFloat,
        fill: Color,
        stroke: Color = .clear,
        lineWidth: CGFloat = 1
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(stroke, lineWidth: lineWidth)
                )
        )
    }
}
