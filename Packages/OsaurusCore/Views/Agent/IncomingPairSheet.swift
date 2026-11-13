//
//  IncomingPairSheet.swift
//  osaurus
//
//  "Add Shared Agent": shown when this device opens a guest link
//  (`osaurus://...?pair=...`). Says what the agent's owner will see before
//  the receiver consents; only then do we POST the invite back to the
//  owner's `/pair-invite` endpoint and save a RemoteAgent locally.
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

    private var displayName: String { invite.name.isEmpty ? L("Untitled Agent") : invite.name }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            SettingsSheetHeader(
                icon: "person.crop.circle.badge.plus",
                title: "Add Shared Agent",
                subtitle: "Someone shared an agent with you. It runs on their Mac.",
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    SettingsSection {
                        SettingsRow(
                            title: displayName,
                            description: invite.desc.flatMap { $0.isEmpty ? nil : $0 } ?? invite.shortAddress,
                            verbatimTitle: true,
                            leading: {
                                AgentAvatarView(
                                    mascotId: nil,
                                    name: displayName,
                                    tint: theme.dataInk(seed: invite.name),
                                    diameter: 36,
                                    monogramFontSize: 15,
                                    borderWidth: theme.stroke.default
                                )
                            },
                            trailing: { EncryptionBadge() }
                        )
                        SettingsValueRow(
                            title: "Link Expires",
                            value: invite.expirationDate.formatted(date: .abbreviated, time: .shortened)
                        )
                    }

                    if let existing = existingPairing {
                        SheetHintRow(
                            kind: .warning,
                            message: L(
                                "You already added this agent on \(existing.pairedAt.formatted(date: .abbreviated, time: .omitted)). Adding it again replaces that one."
                            )
                        )
                    }

                    SettingsCallout(
                        icon: "eye",
                        title: "What the Owner Can See",
                        message:
                            "Your messages and the files you attach in chats with this agent go to the owner's Mac, where it runs, and the owner can read those chats. Your other agents and chats stay private. The owner can remove your access at any time."
                    )

                    SettingsSection(title: "Note") {
                        SettingsTextField(
                            placeholder: L("e.g., Alice's research agent"),
                            text: $note,
                            icon: "text.alignleft"
                        )
                    }

                    if let errorMessage {
                        SheetHintRow(kind: .error, message: errorMessage)
                    }
                }
                .padding(theme.settingsSheetInset)
            }
            .background(theme.surface.overlay)

            SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: isWorking ? "Adding…" : "Add Shared Agent",
                    isEnabled: !isWorking,
                    isLoading: isWorking,
                    handler: { Task { await accept() } }
                ),
                secondary: SettingsSheetFooter.Action(
                    label: "Not Now",
                    isEnabled: !isWorking,
                    handler: { dismiss() }
                ),
                hint: "+ Enter to add"
            )
        }
        .fittedSheetFrame(width: 480, height: 600)
        .background(theme.surface.raised)
        .onAppear {
            existingPairing = RemoteAgentManager.shared.remoteAgent(forAddress: invite.addr)
        }
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
