//
//  ExportChooserSheet.swift
//  osaurus
//
//  Two-page chooser presented as themed-alert custom content. Page 1
//  selects the export format; page 2 surfaces opt-in timing toggles
//  (defaults remembered across exports via UserDefaults).
//

import SwiftUI

struct ExportChooserSheet: View {
    let session: ChatSessionData
    /// Invoked when the user taps Export on page 2. The caller is
    /// responsible for dismissing the alert and running the export.
    let onExport: (ChatSessionSidebar.ExportFormat, ChatExportOptions) -> Void

    @Environment(\.theme) private var theme
    @State private var page: Page = .format
    @State private var direction: SlideDirection = .forward
    @State private var selectedFormat: ChatSessionSidebar.ExportFormat?
    @State private var options: ChatExportOptions = ChatExportOptions.loadLast()
    @State private var hydratedHasTimingData: Bool?

    private enum Page { case format, options }
    private enum SlideDirection { case forward, backward }

    private let contentWidth: CGFloat = 372
    private let pageHeight: CGFloat = 260

    /// Disable the toggles if no turn carries timing data so users
    /// aren't tricked into selecting flags that would produce nothing.
    private var hasTimingData: Bool {
        session.hasAnyTimingData || hydratedHasTimingData == true
    }

    var body: some View {
        ZStack {
            pageBody
                .id(page)
                .transition(slideTransition)
        }
        .frame(width: contentWidth, height: pageHeight, alignment: .top)
        .task(id: session.id) {
            hydratedHasTimingData = nil
            let available = await ChatSessionExportCoordinator.hasTimingData(metadataSession: session)
            guard !Task.isCancelled else { return }
            hydratedHasTimingData = available
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        switch page {
        case .format: formatPage
        case .options: optionsPage
        }
    }

    private func navigate(to next: Page, direction: SlideDirection) {
        self.direction = direction
        withAnimation(theme.motion.springAnimation) {
            page = next
        }
    }

    private var slideTransition: AnyTransition {
        let dx: CGFloat = 32
        let inOffset = direction == .forward ? dx : -dx
        let outOffset = direction == .forward ? -dx : dx
        return .asymmetric(
            insertion: .offset(x: inOffset).combined(with: .opacity),
            removal: .offset(x: outOffset).combined(with: .opacity)
        )
    }

    // MARK: - Page 1: format

    private var formatPage: some View {
        VStack(spacing: theme.space.s0) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text("Choose a format to export this conversation.", bundle: .module)
                    .textStyle(.bodySmall)
                    .foregroundColor(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, theme.space.s4)

                formatRow(.markdown, icon: "doc.text", label: "Markdown")
                formatRow(.pdf, icon: "doc.richtext", label: "PDF")
                formatRow(.zip, icon: "doc.zipper", label: "Zip Bundle")
            }

            Spacer(minLength: 0)

            SettingsSheetFooter(
                primary: .init(label: "Next", isEnabled: selectedFormat != nil) {
                    navigate(to: .options, direction: .forward)
                },
                embedded: true
            )
        }
        .frame(width: contentWidth, height: pageHeight)
    }

    private func formatRow(_ format: ChatSessionSidebar.ExportFormat, icon: String, label: LocalizedStringKey)
        -> some View
    {
        let isSelected = selectedFormat == format
        return Button {
            selectedFormat = format
        } label: {
            HStack(spacing: theme.space.s10) {
                Image(systemName: icon)
                    .glyphSize(.body)
                    .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
                    .frame(width: 18)
                Text(label, bundle: .module)
                    .textStyle(.label)
                    .foregroundColor(theme.text.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .glyphSize(.footnote, weight: .bold)
                        .foregroundColor(theme.text.primary)
                }
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s10)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(isSelected ? theme.surface.selected : theme.surface.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .stroke(isSelected ? theme.border.strong : theme.border.default, lineWidth: theme.stroke.default)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Page 2: options

    private var optionsPage: some View {
        VStack(spacing: theme.space.s0) {
            VStack(alignment: .leading, spacing: theme.space.s10) {
                Text("Include in export", bundle: .module)
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.secondary)

                toggleRow("Timestamps", binding: $options.includeTimestamps)
                toggleRow("Deltas", binding: $options.includeDeltas)
                toggleRow("Token usage", binding: $options.includeTokenUsage)

                if !hasTimingData, hydratedHasTimingData == nil {
                    SettingsSpinner()
                } else if !hasTimingData {
                    Text("No timing data captured for this conversation.", bundle: .module)
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .padding(.top, theme.space.s2)
                }
            }

            Spacer(minLength: 0)

            SettingsSheetFooter(
                primary: .init(label: "Export", isEnabled: selectedFormat != nil) {
                    options.saveAsLast()
                    if let selectedFormat {
                        onExport(selectedFormat, options)
                    }
                },
                secondary: .init(label: "Back") {
                    navigate(to: .format, direction: .backward)
                },
                embedded: true
            )
        }
        .frame(width: contentWidth, height: pageHeight)
    }

    private func toggleRow(_ label: LocalizedStringKey, binding: Binding<Bool>) -> some View {
        HStack {
            Text(label, bundle: .module)
                .textStyle(.bodySmall)
                .foregroundColor(hasTimingData ? theme.text.primary : theme.text.tertiary)
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .settingsSwitch()
                .disabled(!hasTimingData)
        }
    }
}
