//
//  ShareThemeSheet.swift
//  osaurus
//
//  Sheet that uploads a theme to themes.osaurus.ai (signed with the master
//  key) and renders a hero preview, a QR code, and the resulting
//  `osaurus://` deep link with Copy / Open Web actions. Mirrors the visual
//  rhythm of `ShareAgentSheet` so both share flows feel like first-class
//  siblings.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct ShareThemeSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let themeToShare: CustomTheme
    let onSuccess: (ThemeShareOutcome) -> Void

    private struct FailureDetail {
        let message: String
        let hint: String?
    }

    private enum Phase {
        case uploading
        case success(ThemeShareOutcome)
        case failure(FailureDetail)
    }

    @State private var phase: Phase = .uploading
    @State private var advancedExpanded = false
    @State private var copyFlash = false

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
        .frame(width: 520, height: 560)
        .background(theme.cardBackground)
        .task { await runUpload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up.on.square.fill")
                .font(.system(size: 18))
                .foregroundColor(theme.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text("Share Theme", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Upload \"\(themeToShare.metadata.name)\" so anyone with the link can install it.",
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
        case .uploading:
            uploadingView
        case .success(let outcome):
            successView(outcome)
        case .failure(let detail):
            failureView(detail)
        }
    }

    // MARK: - Uploading

    private var uploadingView: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 30)

            ProgressView()
                .scaleEffect(1.2)

            VStack(spacing: 4) {
                Text("Uploading theme…", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "You may be asked to authenticate to sign the upload.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 380)
    }

    // MARK: - Success

    private func successView(_ outcome: ThemeShareOutcome) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            successBadge
            ThemeShareHeroCard(theme: themeToShare)
            shareLinkSection(outcome)
            advancedSection(outcome)
            warningFootnote
        }
    }

    private var successBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.successColor)
            Text("Theme uploaded", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.successColor)
        }
    }

    private func shareLinkSection(_ outcome: ThemeShareOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentSheetSectionLabel("Share Link")

            HStack(alignment: .top, spacing: 14) {
                ThemeQRCardView(text: outcome.deepLinkURL.absoluteString)
                    .frame(width: 124, height: 124)

                VStack(alignment: .leading, spacing: 8) {
                    deepLinkDisplay(outcome.deepLinkURL.absoluteString)
                    shareLinkActions(outcome)
                }
            }
        }
    }

    private func deepLinkDisplay(_ url: String) -> some View {
        Text(url)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(theme.secondaryText)
            .lineLimit(4)
            .truncationMode(.middle)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
    }

    private func shareLinkActions(_ outcome: ThemeShareOutcome) -> some View {
        HStack(spacing: 8) {
            Button {
                copyDeepLink(outcome.deepLinkURL.absoluteString)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copyFlash ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                    Text(copyFlash ? "Copied" : "Copy", bundle: .module)
                }
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                NSWorkspace.shared.open(outcome.serverURL)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                        .font(.system(size: 11))
                    Text("Open Web", bundle: .module)
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func advancedSection(_ outcome: ThemeShareOutcome) -> some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(spacing: 10) {
                ThemeCopyRow(label: "Theme ID", value: outcome.hash)
                ThemeCopyRow(label: "Web URL", value: outcome.serverURL.absoluteString)
            }
            .padding(.top, 10)
        } label: {
            Text("Advanced details", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .accentColor(theme.secondaryText)
    }

    private var warningFootnote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text(
                "Anyone with the link can install this theme. Theme JSON is public — don't share secrets in custom themes.",
                bundle: .module
            )
            .font(.system(size: 11))
            .lineLimit(3)
        }
        .foregroundColor(theme.tertiaryText)
    }

    // MARK: - Failure

    private func failureView(_ detail: FailureDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(theme.errorColor)
                Text("Upload failed", bundle: .module)
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

            HStack(spacing: 10) {
                Button {
                    phase = .uploading
                    Task { await runUpload() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Try Again", bundle: .module)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    dismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            switch phase {
            case .success:
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: .module)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
            case .uploading, .failure:
                Button {
                    dismiss()
                } label: {
                    Text("Close", bundle: .module)
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground)
    }

    // MARK: - Actions

    private func runUpload() async {
        do {
            let outcome = try await ThemeShareService.shared.share(themeToShare)
            phase = .success(outcome)
            onSuccess(outcome)
        } catch {
            phase = .failure(Self.detail(from: error))
        }
    }

    private static func detail(from error: Error) -> FailureDetail {
        let message =
            (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let hint = (error as? ThemeShareError)?.diagnosticHint
        return FailureDetail(message: message, hint: hint)
    }

    private func copyDeepLink(_ string: String) {
        setPasteboardString(string)
        copyFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copyFlash = false
        }
    }
}

// MARK: - Hero Card

/// Compact preview of the theme being shared. Mirrors the swatch row of
/// `ThemePreviewCard` so the user immediately recognises which theme they're
/// publishing.
private struct ThemeShareHeroCard: View {
    @Environment(\.theme) private var currentTheme
    let theme: CustomTheme

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(currentTheme.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 16))
                    .foregroundColor(currentTheme.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(theme.metadata.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(currentTheme.primaryText)
                    .lineLimit(1)

                Text(verbatim: "by \(theme.metadata.author)")
                    .font(.system(size: 11))
                    .foregroundColor(currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                swatch(theme.colors.primaryBackground)
                swatch(theme.colors.accentColor)
                swatch(theme.colors.successColor)
                swatch(theme.colors.warningColor)
                swatch(theme.colors.errorColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(currentTheme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(currentTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func swatch(_ hex: String) -> some View {
        Circle()
            .fill(Color(themeHex: hex))
            .frame(width: 14, height: 14)
            .overlay(
                Circle()
                    .stroke(currentTheme.primaryBorder, lineWidth: 1)
            )
    }
}

// MARK: - QR Card

/// White-backed QR card. Re-renders the bitmap whenever `text` changes so
/// callers can swap the encoded string in place without flicker.
private struct ThemeQRCardView: View {
    @Environment(\.theme) private var theme
    let text: String

    @State private var qrImage: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
            if let img = qrImage {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 36))
                    .foregroundColor(theme.tertiaryText.opacity(0.5))
            }
        }
        .onAppear { qrImage = Self.renderQR(text) }
        .onChange(of: text) { _, newValue in
            qrImage = Self.renderQR(newValue)
        }
    }

    private static func renderQR(_ string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale: CGFloat = 8
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaled.extent.width, height: scaled.extent.height)
        )
    }
}

// MARK: - Copy Row

/// Single-line monospaced value with a trailing copy button. Used for the
/// raw hash and web URL inside the Advanced section. Foreground colors are
/// pinned to `primaryText` / `tertiaryBackground` so the icon stays readable
/// across themes where `buttonBackground` matches `primaryText`.
private struct ThemeCopyRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)

            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )

                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(copied ? theme.successColor : theme.primaryText)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(
                    copied
                        ? Text("Copied!", bundle: .module)
                        : Text("Copy to clipboard", bundle: .module)
                )
            }
        }
    }

    private func copy() {
        setPasteboardString(value)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
        }
    }
}

// MARK: - Pasteboard helper

private func setPasteboardString(_ string: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(string, forType: .string)
}
