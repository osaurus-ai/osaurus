//
//  IdentityView.swift
//  osaurus
//
//  Osaurus Identity management UI: master address, agent addresses,
//  device status, setup flow, and recovery code handling.
//

import AppKit
import LocalAuthentication
import SwiftUI

// MARK: - Identity View

struct IdentityView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var phase: IdentityPhase = .checking

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .checking:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    case .noIdentity:
                        IdentitySetupCard(onCreated: handleIdentityCreated)
                    case .recoveryPrompt(let info):
                        RecoveryPromptCard(info: info, onDismiss: handleRecoveryDismissed)
                    case .ready(let osaurusId, let deviceId):
                        MasterAddressSection(osaurusId: osaurusId)
                        AgentAddressesSection(masterAddress: osaurusId)
                        DeviceSection(deviceId: deviceId)
                    }
                }
                .padding(24)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            checkIdentityStatus()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Identity",
            subtitle: subtitleText
        ) {
            EmptyView()
        }
    }

    private var subtitleText: String {
        switch phase {
        case .checking:
            "Loading identity..."
        case .noIdentity:
            "Set up your Osaurus Identity"
        case .recoveryPrompt:
            "Save your recovery code"
        case .ready:
            "Your identity is active"
        }
    }

    // MARK: - State Machine

    private func checkIdentityStatus() {
        if OsaurusAccount.exists() {
            loadExistingIdentity()
        } else {
            phase = .noIdentity
        }
    }

    private func loadExistingIdentity() {
        do {
            let deviceId = try DeviceKey.currentDeviceId()
            let context = OsaurusIdentityContext.biometric()
            let osaurusId = try MasterKey.getOsaurusId(context: context)
            phase = .ready(osaurusId: osaurusId, deviceId: deviceId)
        } catch {
            phase = .noIdentity
        }
    }

    private func handleIdentityCreated(_ info: AccountInfo) {
        phase = .recoveryPrompt(info: info)
    }

    private func handleRecoveryDismissed(_ osaurusId: OsaurusID, _ deviceId: String) {
        phase = .ready(osaurusId: osaurusId, deviceId: deviceId)
    }
}

// MARK: - Identity Phase

private enum IdentityPhase {
    case checking
    case noIdentity
    case recoveryPrompt(info: AccountInfo)
    case ready(osaurusId: OsaurusID, deviceId: String)
}

// MARK: - Biometric Context Helper

enum OsaurusIdentityContext {
    static func biometric() -> LAContext {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300
        return context
    }
}

// MARK: - Setup Card

private struct IdentitySetupCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let onCreated: (AccountInfo) -> Void

    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 40)

            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 48))
                .foregroundStyle(theme.accentColor)

            VStack(spacing: 8) {
                Text("Create Your Osaurus Identity")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text("Generate a cryptographic identity stored securely\nin your iCloud Keychain and Secure Enclave.")
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.errorColor.opacity(0.1))
                    )
            }

            Button(action: createIdentity) {
                HStack(spacing: 8) {
                    if isCreating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "key.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text("Generate Identity")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isCreating)

            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func createIdentity() {
        isCreating = true
        errorMessage = nil

        Task {
            do {
                let info = try await OsaurusAccount.setup()
                await MainActor.run {
                    isCreating = false
                    onCreated(info)
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Recovery Prompt Card

private struct RecoveryPromptCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let info: AccountInfo
    let onDismiss: (OsaurusID, String) -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text("Print this now. It won't be shown again.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.warningColor)
            }

            recoveryCard

            HStack(spacing: 12) {
                Button(action: printRecoveryCode) {
                    HStack(spacing: 6) {
                        Image(systemName: "printer.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Print")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: dismiss) {
                    Text("I've saved it")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OSAURUS IDENTITY RECOVERY")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .tracking(1)

            VStack(alignment: .leading, spacing: 6) {
                recoveryField(label: "Master Address", value: info.osaurusId)
                recoveryField(label: "Recovery Code", value: info.recovery.code)
            }

            Divider()
                .background(theme.secondaryBorder)

            VStack(alignment: .leading, spacing: 4) {
                bulletPoint("Single-use — consumed on recovery")
                bulletPoint("Store in a safe place")
                bulletPoint("Cannot be retrieved by Osaurus")
            }

            Text("Generated: \(formattedDate)")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.secondaryBorder, lineWidth: 1)
                )
        )
    }

    private func recoveryField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label + ":")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
        }
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: Date())
    }

    private func printRecoveryCode() {
        let printContent = """
            OSAURUS IDENTITY RECOVERY

            Master Address:
            \(info.osaurusId)

            Recovery Code:
            \(info.recovery.code)

            • Single-use — consumed on recovery
            • Store in a safe place
            • Cannot be retrieved by Osaurus

            Generated: \(formattedDate)
            """

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 300))
        textView.string = printContent
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let printOp = NSPrintOperation(view: textView)
        printOp.printInfo.isHorizontallyCentered = true
        printOp.printInfo.isVerticallyCentered = false
        printOp.printInfo.topMargin = 72
        printOp.printInfo.leftMargin = 72
        printOp.runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func dismiss() {
        onDismiss(info.osaurusId, info.deviceId)
    }
}

// MARK: - Master Address Section

private struct MasterAddressSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let osaurusId: OsaurusID

    @State private var copied = false

    var body: some View {
        IdentitySection(title: "MASTER ADDRESS", icon: "person.badge.key.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Master Address")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                        Text(osaurusId)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button(action: copyId) {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                            Text(copied ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(copied ? theme.successColor : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Divider().background(theme.secondaryBorder)

                HStack(spacing: 24) {
                    statusField(
                        label: "Recovery",
                        value: "Recovery code saved",
                        icon: "checkmark.shield.fill",
                        color: theme.successColor
                    )
                    statusField(label: "Status", value: "Active", icon: "circle.fill", color: theme.successColor)
                }
            }
        }
    }

    private func statusField(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
            }
        }
    }

    private func copyId() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(osaurusId, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}

// MARK: - Agent Addresses Section

private struct AgentAddressesSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let masterAddress: OsaurusID

    @State private var copiedAddress: OsaurusID?
    @State private var generatingAgentId: UUID?
    @State private var errorMessage: String?

    private var customAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
    }

    var body: some View {
        IdentitySection(title: "AGENT ADDRESSES", icon: "person.2.badge.key.fill") {
            VStack(alignment: .leading, spacing: 8) {
                if customAgents.isEmpty {
                    Text("No agents yet — create one in the Agents tab")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.vertical, 4)
                } else {
                    ForEach(customAgents) { agent in
                        agentRow(agent: agent)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.errorColor)
                }
            }
        }
    }

    private func agentRow(agent: Agent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 10))
                .foregroundColor(theme.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                if let address = agent.agentAddress {
                    Text(address)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                } else {
                    Text("No address")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            Spacer()

            if let address = agent.agentAddress {
                let isCopied = copiedAddress == address
                Button(action: { copyAddress(address) }) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isCopied ? theme.successColor : theme.secondaryText)
                        .padding(5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button(action: { generateAddress(for: agent) }) {
                    HStack(spacing: 4) {
                        if generatingAgentId == agent.id {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "key.fill")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        Text("Generate")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(generatingAgentId != nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private func generateAddress(for agent: Agent) {
        generatingAgentId = agent.id
        errorMessage = nil

        do {
            let context = OsaurusIdentityContext.biometric()
            var masterKeyData = try MasterKey.getPrivateKey(context: context)
            defer {
                masterKeyData.withUnsafeMutableBytes { ptr in
                    if let base = ptr.baseAddress { memset(base, 0, ptr.count) }
                }
            }

            let usedIndices = Set(agentManager.agents.compactMap(\.agentIndex))
            var nextIndex: UInt32 = 0
            while usedIndices.contains(nextIndex) { nextIndex += 1 }

            let address = try AgentKey.deriveAddress(masterKey: masterKeyData, index: nextIndex)

            var updated = agent
            updated.agentIndex = nextIndex
            updated.agentAddress = address
            agentManager.update(updated)

            generatingAgentId = nil
        } catch {
            errorMessage = error.localizedDescription
            generatingAgentId = nil
        }
    }

    private func copyAddress(_ address: OsaurusID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        withAnimation { copiedAddress = address }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copiedAddress = nil }
        }
    }
}

// MARK: - Device Section

private struct DeviceSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let deviceId: String

    var body: some View {
        IdentitySection(title: "DEVICES", icon: "desktopcomputer") {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 20))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Host.current().localizedName ?? "This Mac")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("(this device)")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                    Text("Device ID: \(deviceId)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(theme.successColor)
                        .frame(width: 6, height: 6)
                    Text("Active")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.successColor)
                }
            }
        }
    }
}

// MARK: - Reusable Section Container

private struct IdentitySection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}
