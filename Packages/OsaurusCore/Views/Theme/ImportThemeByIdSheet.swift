//
//  ImportThemeByIdSheet.swift
//  osaurus
//
//  Sheet that accepts a theme hash, an `osaurus://themes-install?hash=…`
//  deep link, or a public web URL, and installs the theme via
//  ThemeShareService. Auto-prefills from the clipboard or a pending
//  deeplink hash queued by ThemesDeepLinkRouter.
//

import AppKit
import SwiftUI

struct ImportThemeByIdSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Optional pre-supplied input. When non-empty (e.g. set from a deep link)
    /// the sheet starts directly in the importing phase.
    let initialInput: String?
    let onCompleted: (CustomTheme) -> Void
    let onError: (String) -> Void

    private struct FailureDetail {
        let message: String
        let hint: String?
    }

    private enum Phase {
        case input
        case importing
        case failure(FailureDetail)
    }

    @State private var input: String = ""
    @State private var phase: Phase = .input

    init(
        initialInput: String? = nil,
        onCompleted: @escaping (CustomTheme) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.initialInput = initialInput
        self.onCompleted = onCompleted
        self.onError = onError
    }

    private var isInputValid: Bool {
        ThemeShareService.parseHash(from: input) != nil
    }

    private var diagnostics: ThemeImportDiagnostics {
        ThemeLibraryManagementService.diagnoseImportInput(
            input,
            installedThemes: themeManager.installedThemes
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.primaryBackground)

            Divider().opacity(0.5)

            footer
        }
        .frame(width: 520, height: 430)
        .background(theme.cardBackground)
        .onAppear { applyInitialInput() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 18))
                .foregroundColor(theme.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text("Import by ID", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Paste a Theme ID, share link, or web URL.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .input:
            inputView
        case .importing:
            importingView
        case .failure(let detail):
            failureView(detail)
        }
    }

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AgentSheetSectionLabel("Theme ID or Link")
                Spacer()
                Button(action: pasteFromClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 10, weight: .medium))
                        Text("Paste", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(Text("Paste from clipboard", bundle: .module))
            }

            StyledTextField(
                placeholder: String(localized: "Paste theme ID or link…", bundle: .module),
                text: $input,
                icon: "link"
            )
            .onSubmit {
                if isInputValid { runImport() }
            }

            if !input.isEmpty && !isInputValid {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(
                        "Doesn't look like a 64-character theme ID or osaurus://themes-install link.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .lineLimit(2)
                }
                .foregroundColor(theme.warningColor)
            }

            if !input.isEmpty {
                diagnosticsView(diagnostics)
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text(
                    verbatim:
                        "Accepts a 64-character ID, osaurus://themes-install?hash=… or https://themes.osaurus.ai/themes/…"
                )
                .font(.system(size: 11))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(theme.tertiaryText)
        }
    }

    private var importingView: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 30)
            ProgressView()
                .scaleEffect(1.1)
            Text("Downloading theme…", bundle: .module)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220)
    }

    private func failureView(_ detail: FailureDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(theme.errorColor)
                Text("Couldn't import theme", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            Text(detail.message)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let hint = detail.hint {
                Text(verbatim: hint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground)
                    )
            }

            StyledTextField(
                placeholder: String(localized: "Paste theme ID or link…", bundle: .module),
                text: $input,
                icon: "link"
            )
            .onSubmit {
                if isInputValid { runImport() }
            }

            if !input.isEmpty && !isInputValid {
                Text(
                    "Doesn't look like a 64-character theme ID or osaurus://themes-install link.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.warningColor)
            }

            if !input.isEmpty {
                diagnosticsView(diagnostics)
            }
        }
    }

    private func diagnosticsView(_ diagnostics: ThemeImportDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: diagnostics.canImport ? "checkmark.seal.fill" : "stethoscope")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(diagnostics.canImport ? theme.successColor : theme.secondaryText)
                Text("Import diagnostics", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(LocalizedStringKey(diagnosticKindLabel(diagnostics.kind)), bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.tertiaryBackground))
            }

            if let hash = diagnostics.normalizedHash {
                Text(verbatim: hash)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if diagnostics.installedMatches.isEmpty {
                    Text("No installed theme has this shared ID yet.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                } else {
                    Text(
                        "Already installed as \(diagnostics.installedMatches.map(\.name).joined(separator: ", ")).",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                    .lineLimit(2)
                }
            } else {
                Text("Paste a valid ID or link to see normalized server details.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.primaryBorder.opacity(0.6), lineWidth: 1)
                )
        )
    }

    private func diagnosticKindLabel(_ kind: ThemeImportInputKind) -> String {
        switch kind {
        case .empty: return "Waiting"
        case .rawHash: return "Raw ID"
        case .deepLink: return "Deep link"
        case .webURL: return "Web URL"
        case .invalid: return "Invalid"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Cancel", bundle: .module)
            }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)

            Button(action: runImport) {
                HStack(spacing: 6) {
                    if case .importing = phase {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text("Import", bundle: .module)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canImport)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground)
    }

    private var canImport: Bool {
        if case .importing = phase { return false }
        return isInputValid
    }

    // MARK: - Actions

    private func applyInitialInput() {
        if let initial = initialInput?.trimmingCharacters(in: .whitespacesAndNewlines),
            !initial.isEmpty
        {
            input = initial
            // Auto-run for deep-link supplied hashes — the user already
            // confirmed by clicking the link.
            runImport()
            return
        }

        // Convenience: prefill from clipboard if it parses cleanly. Doesn't
        // auto-import; we only kick off the network round trip on explicit
        // confirmation.
        if let clipped = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            ThemeShareService.parseHash(from: clipped) != nil
        {
            input = clipped
        }
    }

    private func pasteFromClipboard() {
        if let clipped = NSPasteboard.general.string(forType: .string) {
            input = clipped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func runImport() {
        guard isInputValid else { return }
        let captured = input
        phase = .importing

        Task {
            do {
                let imported = try await ThemeShareService.shared.install(hashOrLink: captured)
                onCompleted(imported)
                dismiss()
            } catch {
                let detail = Self.detail(from: error)
                phase = .failure(detail)
                onError(detail.message)
            }
        }
    }

    private static func detail(from error: Error) -> FailureDetail {
        let message =
            (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let hint = (error as? ThemeShareError)?.diagnosticHint
        return FailureDetail(message: message, hint: hint)
    }
}
