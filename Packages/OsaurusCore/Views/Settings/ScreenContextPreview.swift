//
//  ScreenContextPreview.swift
//  OsaurusCore — Computer Use
//
//  A self-contained, on-demand preview of the screen-context snapshot a new
//  chat would freeze and share. Shared by the global Computer Use settings card
//  and the per-agent "Share screen context" toggle so the two never drift.
//  Owns its own capture state and reads Accessibility + theme from the shared
//  singletons, so it drops cleanly into either a card or a popover.
//

import SwiftUI

struct ScreenContextPreview: View {
    /// Capture as soon as the view appears instead of waiting for a manual
    /// Refresh. The default suits a popover (the user opened it to look) and the
    /// always-rendered settings card alike.
    var autoCaptureOnAppear: Bool = true
    /// Shown when Accessibility is missing. Phrased for the host by default for
    /// the popover; the settings card overrides it to point "above" at its own
    /// permission row.
    var accessibilityHint: String = "Grant Accessibility to preview what would be shared."
    /// Definite height for the scrolling snapshot area. A `ScrollView` has no
    /// intrinsic height, so inside a self-sizing container (a popover) it
    /// collapses to nothing; pass a height there. `nil` keeps it flexible
    /// (capped at 220) for the settings card, which sits inside an outer
    /// ScrollView that already hands it a definite height.
    var previewHeight: CGFloat? = nil

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared

    @State private var snapshot: ScreenContextSnapshot?
    @State private var isLoading = false
    /// Number of PII spans the Privacy Filter would mask, when the filter is on
    /// and its model is loaded. nil = not computed.
    @State private var maskedCount: Int?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var isAccessibilityGranted: Bool {
        permissionService.permissionStates[.accessibility] ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .onAppear {
            if autoCaptureOnAppear, snapshot == nil { refresh() }
        }
    }

    private var header: some View {
        HStack {
            Text(L("Preview"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                Text(L("Refresh"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(roundedSurface(fill: theme.tertiaryBackground, stroke: theme.inputBorder, cornerRadius: 6))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isAccessibilityGranted || isLoading)
    }

    @ViewBuilder
    private var content: some View {
        if !isAccessibilityGranted {
            hint(accessibilityHint)
        } else if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                hint("Reading the screen…")
            }
        } else if let snapshot {
            let text = snapshot.render()
            if text.isEmpty {
                hint("Nothing shareable detected on screen right now.")
            } else {
                snapshotScroll(text)
                privacyNote
            }
        } else {
            hint("Tap Refresh to see what would be shared.")
        }
    }

    @ViewBuilder
    private func snapshotScroll(_ text: String) -> some View {
        let scroll = ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(roundedSurface(fill: theme.inputBackground, stroke: theme.inputBorder, cornerRadius: 8))

        if let previewHeight {
            scroll.frame(height: previewHeight)
        } else {
            scroll.frame(maxHeight: 220)
        }
    }

    @ViewBuilder
    private var privacyNote: some View {
        if PrivacyFilterStore.snapshot().enabled {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundColor(theme.successColor)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("The Privacy Filter scrubs this before it reaches a cloud model."))
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let count = maskedCount, count > 0 {
                        Text(maskedCountText(count))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.warningColor)
                    }
                }
            }
        } else {
            hint("Local models receive this as-is. Turn on the Privacy Filter to scrub it before cloud sends.")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func roundedSurface(fill: Color, stroke: Color, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(stroke, lineWidth: 1)
            )
    }

    private func maskedCountText(_ count: Int) -> String {
        count == 1
            ? L("~1 item would be masked before cloud send.")
            : String(format: L("~%d items would be masked before cloud send."), count)
    }

    private func refresh() {
        guard isAccessibilityGranted else {
            snapshot = nil
            maskedCount = nil
            return
        }
        isLoading = true
        maskedCount = nil
        Task { @MainActor in
            let captured = await ScreenContextDistiller.captureForChat()
            snapshot = captured
            isLoading = false
            await computeMaskedCount(for: captured.render())
        }
    }

    /// Best-effort count of spans the Privacy Filter would mask, shown so the
    /// user can gauge exposure. Only runs when the filter is enabled and its
    /// on-device model is already loaded — never blocks the preview on a model
    /// load.
    private func computeMaskedCount(for text: String) async {
        let config = PrivacyFilterStore.snapshot()
        guard config.enabled, !text.isEmpty, PrivacyFilterEngine.shared.isLoaded else {
            maskedCount = nil
            return
        }
        let map = RedactionMap(conversationID: UUID())
        let detected = try? await PrivacyFilterEngine.shared.detect(
            in: text,
            map: map,
            skipCodeBlocks: config.skipCodeBlocks
        )
        maskedCount = detected?.count
    }
}
