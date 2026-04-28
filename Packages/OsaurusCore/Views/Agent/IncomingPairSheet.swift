//
//  IncomingPairSheet.swift
//  osaurus
//
//  Approval modal shown when this device opens an `osaurus://...?pair=...`
//  deeplink. The receiver explicitly consents before we POST the invite back
//  to the source agent's relay-tunnel `/pair-invite` endpoint and persist a
//  RemoteAgent locally.
//

import SwiftUI

struct IncomingPairSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let invite: AgentInvite
    let onCompleted: (RemoteAgent) -> Void

    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @State private var note: String = ""
    @State private var existingPairing: RemoteAgent?

    var body: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(
                icon: "person.crop.circle.badge.plus",
                title: "Add Remote Agent",
                subtitle: "Authorize this invite to chat with someone else's agent.",
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    agentCard
                    if let existing = existingPairing {
                        replaceNotice(for: existing)
                    }
                    detailsCard
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                }
                .padding(20)
            }
            .background(theme.primaryBackground)

            AgentSheetFooter(
                primary: AgentSheetFooter.Action(
                    label: isWorking ? "Adding…" : "Add Remote Agent",
                    isEnabled: !isWorking,
                    isLoading: isWorking,
                    handler: { Task { await accept() } }
                ),
                secondary: AgentSheetFooter.Action(
                    label: "Decline",
                    isEnabled: !isWorking,
                    handler: { dismiss() }
                ),
                hint: "+ Enter to add"
            )
        }
        .frame(width: 480, height: 580)
        .background(theme.cardBackground)
        .onAppear {
            existingPairing = RemoteAgentManager.shared.remoteAgent(forAddress: invite.addr)
        }
    }

    // MARK: Sections

    private var agentCard: some View {
        let color = agentColorFor(invite.name)
        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.2), color.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle().strokeBorder(color.opacity(0.5), lineWidth: 2)
                Text(invite.name.isEmpty ? "?" : invite.name.prefix(1).uppercased())
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(invite.name.isEmpty ? "Untitled Agent" : invite.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                if let desc = invite.desc, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                }
                Text(invite.shortAddress)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.inputBackground.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private func replaceNotice(for existing: RemoteAgent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(theme.warningColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Already paired with this agent", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Accepting will replace the existing pairing (added \(existing.pairedAt.formatted(date: .abbreviated, time: .omitted))).",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.warningColor.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.warningColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            metadataRow(label: "Source", value: invite.url, mono: true)
            metadataRow(
                label: "Expires",
                value: invite.expirationDate.formatted(date: .abbreviated, time: .shortened),
                mono: false
            )

            VStack(alignment: .leading, spacing: 6) {
                AgentSheetSectionLabel("Note (optional)")
                StyledTextField(
                    placeholder: "e.g., Alice's research agent",
                    text: $note,
                    icon: "text.alignleft"
                )
                Text("Will be saved when you accept.", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            Text(
                "On approve, your device will fetch a private access key from the agent's server. The agent's owner can revoke this at any time.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .padding(.top, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func metadataRow(label: String, value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.errorColor)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.errorColor)
                .lineLimit(3)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.errorColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.errorColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: Actions

    private func accept() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = try await RemoteAgentManager.shared.pairAndAdd(
                invite: invite,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
            onCompleted(remote)
            dismiss()
        } catch let error as RemoteAgentPairError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
