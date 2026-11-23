//
//  PreviousIdentitiesSheet.swift
//  osaurus
//
//  Lists the identities kept in `MasterKeyArchive` and switches back to one.
//  "Unlock to compare" reads every archived seed behind one prompt and
//  scores each against this Mac's agents and access keys, so the identity
//  they were made with ranks first. Switching runs the phrase-restore engine
//  (`OsaurusIdentity.switchTo`) and replaces the synced master everywhere.
//

import LocalAuthentication
import SwiftUI

struct PreviousIdentitiesSheet: View {
    @Environment(\.theme) private var theme

    /// The installed master, or nil when this Mac has none.
    let currentAddress: OsaurusID?
    let onSwitched: (OsaurusIdentity.RestoreResult) -> Void
    let onClose: () -> Void

    @State private var entries: [ArchivedIdentity] = MasterKeyArchive.list()
    @State private var matches: [String: IdentityCandidateMatch]?
    @State private var isUnlocking = false
    @State private var switchingId: String?
    @State private var switchTarget: ArchivedIdentity?
    @State private var forgetTarget: ArchivedIdentity?
    @State private var errorMessage: String?

    var body: some View {
        SettingsSheet(
            icon: "clock.arrow.circlepath",
            title: "Previous Identities",
            subtitle:
                "Identities this Mac has used. If a new identity replaced the one your agents were made with, switch back to it here.",
            width: SettingsSheetWidth.regular,
            primary: matches == nil && !entries.isEmpty
                ? .init(label: "Unlock to compare", isLoading: isUnlocking, handler: unlock)
                : nil,
            secondary: .init(label: "Done", handler: onClose),
            onClose: onClose
        ) {
            if let errorMessage {
                InlineBanner(kind: .error, title: errorMessage, onDismiss: { self.errorMessage = nil })
            }

            if entries.isEmpty {
                SettingsEmptyState(
                    icon: "clock.arrow.circlepath",
                    title: "No previous identities on this Mac",
                    subtitle:
                        "Osaurus keeps a copy of each identity it creates, restores or reads on this Mac. Identities replaced before this version, or never used here, can only come back with their recovery phrase.",
                    style: .inline
                )
            } else {
                SettingsSection(title: "On This Mac") {
                    ForEach(orderedEntries) { entry in
                        row(for: entry)
                    }
                }
                Text(
                    "Switching replaces the identity on every Mac signed in to this iCloud Keychain. Agents that don't match the identity you pick get new addresses, and access keys it didn't sign are revoked.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert(
            Text("Switch Identity?", bundle: .module),
            isPresented: Binding(get: { switchTarget != nil }, set: { if !$0 { switchTarget = nil } }),
            presenting: switchTarget,
            actions: { target in
                Button(localized: "Switch", role: .destructive) { performSwitch(to: target) }
                Button(localized: "Cancel", role: .cancel) {}
            },
            message: { target in
                Text(verbatim: switchConfirmMessage(for: target))
            }
        )
        .alert(
            Text("Forget This Identity?", bundle: .module),
            isPresented: Binding(get: { forgetTarget != nil }, set: { if !$0 { forgetTarget = nil } }),
            presenting: forgetTarget,
            actions: { target in
                Button(localized: "Forget", role: .destructive) { forget(target) }
                Button(localized: "Cancel", role: .cancel) {}
            },
            message: { _ in
                Text(
                    "This Mac's copy is deleted. Without its recovery phrase you can't switch back to it.",
                    bundle: .module
                )
            }
        )
    }

    // MARK: - Rows

    private var orderedEntries: [ArchivedIdentity] {
        guard let matches else { return entries }
        let ranked = IdentityHealthCheck.rank(entries.compactMap { matches[$0.id] })
        let order = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.address.lowercased(), $0.offset) })
        return entries.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    private func isCurrent(_ entry: ArchivedIdentity) -> Bool {
        currentAddress?.lowercased() == entry.id
    }

    private func row(for entry: ArchivedIdentity) -> some View {
        SettingsRow(
            title: entry.address,
            description: description(for: entry),
            verbatimTitle: true,
            verbatimDescription: true
        ) {
            HStack(spacing: theme.space.s8) {
                if isCurrent(entry) {
                    StatusChip(L("Current"), tone: .success, showsDot: true)
                } else {
                    SettingsButton(
                        .secondary,
                        "Switch",
                        isLoading: switchingId == entry.id,
                        size: .compact
                    ) { switchTarget = entry }
                    .disabled(switchingId != nil)
                    SettingsIconButton(
                        "trash",
                        help: L("Forget"),
                        size: .compact,
                        isDestructive: true
                    ) { forgetTarget = entry }
                    .disabled(switchingId != nil)
                }
            }
        }
    }

    private func description(for entry: ArchivedIdentity) -> String {
        let source: String =
            switch entry.source {
            case .created: L("Created on this Mac")
            case .restored: L("Restored on this Mac")
            case .keychain: L("Found in Keychain")
            }
        let seen = entry.firstSeenAt.formatted(date: .abbreviated, time: .omitted)
        var lines = [L("\(source) · First seen \(seen)")]
        if let match = matches?[entry.id] {
            lines.append(Self.matchSummary(match))
        }
        return lines.joined(separator: "\n")
    }

    /// One-line result of the comparison. Internal for tests.
    static func matchSummary(_ match: IdentityCandidateMatch) -> String {
        if !match.matchesAnything {
            return L("Matches none of this Mac's agents or access keys")
        }
        return L(
            "Matches \(match.matchedAgents) of \(match.addressedAgents) agents and \(match.matchedAccessKeys) access keys"
        )
    }

    private func switchConfirmMessage(for target: ArchivedIdentity) -> String {
        var message = L(
            "\(target.address) becomes the identity on this Mac and on every Mac signed in to this iCloud Keychain."
        )
        if let match = matches?[target.id] {
            message += "\n\n" + Self.matchSummary(match) + "."
        }
        return message
    }

    // MARK: - Actions

    private func unlock() {
        guard !isUnlocking else { return }
        isUnlocking = true
        errorMessage = nil
        let candidates = entries
        let agents = AgentManager.shared.agents
        Task { @MainActor in
            let outcome: Result<[String: IdentityCandidateMatch], Error> = await Task.detached(
                priority: .userInitiated
            ) {
                let deviceScope = try? await OsaurusIdentity.ensureDeviceAttested()
                let accessKeys = APIKeyManager.shared.listKeys()
                let context = OsaurusIdentityContext.biometric()
                var found: [String: IdentityCandidateMatch] = [:]
                var lastError: Error?
                for candidate in candidates {
                    do {
                        var seed = try MasterKeyArchive.loadSeed(address: candidate.address, context: context)
                        defer { seed.zeroOut() }
                        found[candidate.id] = IdentityHealthCheck.match(
                            masterKey: seed,
                            agents: agents,
                            accessKeys: accessKeys,
                            currentDeviceScope: deviceScope
                        )
                    } catch {
                        lastError = error
                    }
                }
                if found.isEmpty, let lastError { return .failure(lastError) }
                return .success(found)
            }.value

            switch outcome {
            case .success(let found): matches = found
            case .failure(let error): errorMessage = error.localizedDescription
            }
            isUnlocking = false
        }
    }

    private func performSwitch(to target: ArchivedIdentity) {
        switchingId = target.id
        errorMessage = nil
        Task { @MainActor in
            do {
                let result = try await OsaurusIdentity.switchTo(
                    archivedAddress: target.address,
                    context: OsaurusIdentityContext.biometric()
                )
                switchingId = nil
                onSwitched(result)
            } catch {
                switchingId = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func forget(_ target: ArchivedIdentity) {
        guard !isCurrent(target) else { return }
        if !MasterKeyArchive.forget(address: target.address) {
            errorMessage = L("Couldn't remove this identity from the Keychain.")
        }
        entries = MasterKeyArchive.list()
        matches?[target.id] = nil
    }
}
