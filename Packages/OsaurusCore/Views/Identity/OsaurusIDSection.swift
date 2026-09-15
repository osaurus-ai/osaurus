//
//  OsaurusIDSection.swift
//  osaurus
//
//  Settings ▸ Identity ▸ Osaurus ID: the human-facing handle a person claims
//  for their master key. One card, one decision:
//
//   - Unclaimed: a single `@handle` field with live availability underneath
//     and a Claim button. Only the handle is required; everything else is
//     editable after.
//   - Claimed: the handle (copyable), the display name and bio, and an
//     inline Edit form. No sheets, no wizard.
//
//  Router off / unreachable states stay quiet: one line and a way forward.
//

import AppKit
import SwiftUI

struct OsaurusIDSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var service = OsaurusIDService.shared

    @State private var handleInput = ""
    @State private var availability: OsaurusIDAvailabilityStatus?
    @State private var isCheckingAvailability = false
    @State private var claimError: String?
    /// The handle awaiting the "are you sure" step. A claim is permanent,
    /// so neither the Claim button nor Enter sends it straight away.
    @State private var pendingClaimHandle: String?

    @State private var isEditing = false
    @State private var draftDisplayName = ""
    @State private var draftBio = ""
    @State private var saveError: String?
    @State private var copied = false
    /// Why the last profile pull couldn't reach the router, while the state
    /// is still `.unknown`. Drives the Retry row.
    @State private var unavailableMessage: String?

    @FocusState private var handleFocused: Bool

    private var routerEnabled: Bool { OsaurusRouter.isEnabled }

    private var trimmedHandle: String {
        handleInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isHandleValid: Bool {
        OsaurusIDValidator.isValid(trimmedHandle)
    }

    /// Claim gate: the format must be right and the handle not known-unclaimable.
    /// An unknown availability (offline, router unreachable) does not block —
    /// the claim itself remains the authority.
    private var canClaim: Bool {
        isHandleValid && availability != .taken && availability != .reserved
            && availability != .invalid && !service.isClaiming
    }

    var body: some View {
        IdentitySection(title: L("OSAURUS ID"), icon: "at") {
            content
        }
        .task {
            guard routerEnabled, service.state == .unknown else { return }
            await load()
        }
        .task(id: trimmedHandle) {
            // Debounced as-you-type availability. `task(id:)` cancels the
            // previous check on every keystroke, so only a settled handle
            // reaches the router. Editing also clears a stale claim error.
            availability = nil
            claimError = nil
            guard isHandleValid else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            isCheckingAvailability = true
            let status = await service.checkAvailability(trimmedHandle)
            isCheckingAvailability = false
            guard !Task.isCancelled else { return }
            availability = status
        }
        // A handle can never be changed once claimed, and the field's fine
        // print is easy to miss on the way to Enter. Ask once, plainly.
        .themedAlert(
            pendingClaimHandle.map { String(format: L("Claim @%@?"), $0) } ?? "",
            isPresented: Binding(
                get: { pendingClaimHandle != nil },
                set: { if !$0 { pendingClaimHandle = nil } }
            ),
            message: L(
                "Your Osaurus ID is permanent and public. It cannot be changed or released later, so make sure this is the handle you want."
            ),
            // The handle is captured when the alert is built rather than read
            // back on confirm, so the claim does not depend on whether the
            // dialog clears `pendingClaimHandle` before or after its action.
            primaryButton: .primary(L("Claim")) { [handle = pendingClaimHandle] in
                pendingClaimHandle = nil
                if let handle { claim(handle) }
            },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    // MARK: - State routing

    @ViewBuilder
    private var content: some View {
        if !routerEnabled {
            routerOffRow
        } else {
            switch service.state {
            case .claimed:
                if let profile = service.profile {
                    claimedContent(profile)
                } else {
                    loadingRow
                }
            case .unclaimed:
                claimContent
            case .unknown:
                if let unavailableMessage, !service.isRefreshing {
                    unreachableRow(unavailableMessage)
                } else {
                    loadingRow
                }
            }
        }
    }

    // MARK: - Router off / loading / unreachable

    private var routerOffRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Osaurus ID needs Osaurus Router", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Your handle lives on the router, next to your credits and workspaces. Turn it on to claim one.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: { ManagementStateManager.shared.selectedTab = .settings }) {
                Text("Open Router settings", bundle: .module)
            }
            .buttonStyle(SecondaryButtonStyle(size: .compact))
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking your Osaurus ID…", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func unreachableRow(_ message: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't reach Osaurus", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: { Task { await load() } }) {
                Text("Retry", bundle: .module)
            }
            .buttonStyle(SecondaryButtonStyle(isLoading: service.isRefreshing, size: .compact))
            .disabled(service.isRefreshing)
        }
    }

    /// Pull the profile and remember why it couldn't be reached, so the
    /// card can offer Retry instead of spinning forever.
    private func load() async {
        unavailableMessage = nil
        if case .unavailable(let message) = await service.refresh(), service.state == .unknown {
            unavailableMessage = message
        }
    }

    // MARK: - Unclaimed: claim row

    private var claimContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Your public handle across Osaurus. Workspaces, invites, and usage show it instead of your master address.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                handleField
                Button(action: requestClaim) {
                    Text("Claim", bundle: .module)
                }
                .buttonStyle(PrimaryButtonStyle(isLoading: service.isClaiming, size: .compact))
                .disabled(!canClaim)
                .accessibilityIdentifier("identity.osaurusId.claim")
            }

            availabilityStatusLine

            if let claimError {
                Text(claimError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            Text(
                "Permanent and public. You can add a display name and bio after.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
        }
        .animation(.easeOut(duration: 0.18), value: claimError)
        .animation(.easeOut(duration: 0.18), value: availability)
    }

    private var handleField: some View {
        HStack(spacing: 4) {
            Text(verbatim: "@")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
            TextField(text: sanitizedHandleBinding, prompt: Text(verbatim: "your-handle")) {
                Text("Osaurus ID", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(theme.primaryText)
            .focused($handleFocused)
            .onSubmit { if canClaim { requestClaim() } }
            .accessibilityIdentifier("identity.osaurusId.handle")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(handleFocused ? theme.accentColor.opacity(0.6) : theme.inputBorder, lineWidth: 1)
                )
        )
        .frame(maxWidth: 320)
        .onTapGesture { handleFocused = true }
    }

    /// Lowercases / strips as the user types so the field only ever holds a
    /// candidate the server could accept.
    private var sanitizedHandleBinding: Binding<String> {
        Binding(
            get: { handleInput },
            set: { handleInput = OsaurusIDValidator.sanitizedInput($0) }
        )
    }

    /// Live verdict under the field: format rules while the handle is short
    /// or malformed, then the router's availability answer. When the check
    /// can't run (offline), nothing shows — the claim is the authority.
    @ViewBuilder
    private var availabilityStatusLine: some View {
        Group {
            if trimmedHandle.isEmpty {
                Text("3–20 characters: a–z, 0–9, and hyphens.", bundle: .module)
                    .foregroundColor(theme.tertiaryText)
            } else if !isHandleValid {
                Text(
                    "3–20 characters: a–z, 0–9, and hyphens. Must start and end with a letter or digit.",
                    bundle: .module
                )
                .foregroundColor(theme.tertiaryText)
            } else if isCheckingAvailability {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking availability…", bundle: .module)
                        .foregroundColor(theme.secondaryText)
                }
            } else {
                switch availability {
                case .available:
                    Label(
                        String(format: L("@%@ is available"), trimmedHandle),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundColor(theme.successColor)
                case .taken:
                    Label(
                        String(format: L("@%@ is already taken"), trimmedHandle),
                        systemImage: "xmark.circle.fill"
                    )
                    .foregroundColor(theme.errorColor)
                case .reserved:
                    Label(L("That name is reserved"), systemImage: "lock.fill")
                        .foregroundColor(theme.errorColor)
                case .invalid:
                    Label(L("That name isn't allowed"), systemImage: "xmark.circle.fill")
                        .foregroundColor(theme.errorColor)
                case nil:
                    // Valid format, no verdict (yet): keep the height stable.
                    Text(verbatim: " ")
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .frame(height: 14, alignment: .leading)
    }

    /// Opens the confirmation for the current handle; the claim itself only
    /// goes out from the dialog's confirm button.
    private func requestClaim() {
        guard canClaim else { return }
        claimError = nil
        pendingClaimHandle = trimmedHandle
    }

    private func claim(_ handle: String) {
        claimError = nil
        Task {
            switch await service.claim(handle: handle) {
            case .claimed, .adopted:
                handleInput = ""
                availability = nil
            case .failed(let message):
                claimError = message
                // A claim that lost a race re-checks the field so the
                // verdict under it matches the error above it.
                availability = await service.checkAvailability(handle)
            }
        }
    }

    // MARK: - Claimed: profile card

    private func claimedContent(_ profile: OsaurusIDProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.handle)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("identity.osaurusId.handleLabel")
                    if !isEditing {
                        Text(profile.effectiveName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(profile.displayName.isEmpty ? theme.tertiaryText : theme.primaryText)
                        if !profile.bio.isEmpty {
                            Text(profile.bio)
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer()

                if !isEditing {
                    Button(action: beginEditing) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .medium))
                            Text("Edit", bundle: .module)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .compact))
                    .accessibilityIdentifier("identity.osaurusId.edit")

                    Button(action: { copy(profile.handle) }) {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                            Text(copied ? L("Copied") : L("Copy"))
                        }
                        .foregroundColor(copied ? theme.successColor : theme.primaryText)
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .compact))
                }
            }

            if isEditing {
                editForm(profile)
            } else {
                Divider().background(theme.secondaryBorder)
                Text(
                    "Shown to teammates in workspaces, invites, and usage. The handle is permanent; the display name and bio are yours to change.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isEditing)
    }

    private func editForm(_ profile: OsaurusIDProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Display name", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                TextField(text: $draftDisplayName, prompt: Text(profile.osaurusID)) {
                    Text("Display name", bundle: .module)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(8)
                .background(inputChrome)
                .onChange(of: draftDisplayName) { _, value in
                    if value.count > OsaurusIDDisplayName.maxLength {
                        draftDisplayName = String(value.prefix(OsaurusIDDisplayName.maxLength))
                    }
                }
                .accessibilityIdentifier("identity.osaurusId.displayName")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Bio", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Text(verbatim: "\(draftBio.count)/\(OsaurusIDBio.maxLength)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }
                TextEditor(text: $draftBio)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 56, maxHeight: 110)
                    .padding(6)
                    .background(inputChrome)
                    .onChange(of: draftBio) { _, value in
                        if value.count > OsaurusIDBio.maxLength {
                            draftBio = String(value.prefix(OsaurusIDBio.maxLength))
                        }
                    }
                    .accessibilityIdentifier("identity.osaurusId.bio")
            }

            if let saveError {
                Text(saveError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(action: cancelEditing) {
                    Text("Cancel", bundle: .module)
                }
                .buttonStyle(SecondaryButtonStyle(size: .compact))
                .disabled(service.isSaving)

                Button(action: { save(profile) }) {
                    Text("Save", bundle: .module)
                }
                .buttonStyle(PrimaryButtonStyle(isLoading: service.isSaving, size: .compact))
                .disabled(service.isSaving)
                .accessibilityIdentifier("identity.osaurusId.save")
            }
        }
    }

    private var inputChrome: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.inputBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.inputBorder, lineWidth: 1)
            )
    }

    private func beginEditing() {
        guard let profile = service.profile else { return }
        draftDisplayName = profile.displayName
        draftBio = profile.bio
        saveError = nil
        isEditing = true
    }

    private func cancelEditing() {
        isEditing = false
        saveError = nil
    }

    private func save(_ profile: OsaurusIDProfile) {
        let name = OsaurusIDDisplayName.sanitized(draftDisplayName)
        let bio = OsaurusIDBio.sanitized(draftBio)
        // Only send what changed; an untouched field stays out of the patch.
        let displayName: String? = name == profile.displayName ? nil : name
        let bioPatch: String? = bio == profile.bio ? nil : bio
        guard displayName != nil || bioPatch != nil else {
            isEditing = false
            return
        }
        saveError = nil
        Task {
            switch await service.update(displayName: displayName, bio: bioPatch) {
            case .updated:
                isEditing = false
            case .failed(let message):
                saveError = message
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}
