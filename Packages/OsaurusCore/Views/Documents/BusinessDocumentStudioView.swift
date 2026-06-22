//
//  BusinessDocumentStudioView.swift
//  osaurus
//
//  UI for inspecting BusinessDocumentStudioService previews and export
//  availability without routing the document through chat.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BusinessDocumentStudioView: View {
    @StateObject private var presenter: BusinessDocumentStudioPresenter
    private let sourceURL: URL?
    @State private var currentSourceURL: URL?

    init(
        sourceURL: URL? = nil,
        presenter: BusinessDocumentStudioPresenter = BusinessDocumentStudioPresenter()
    ) {
        _presenter = StateObject(wrappedValue: presenter)
        self.sourceURL = sourceURL
        _currentSourceURL = State(initialValue: sourceURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .task(id: currentSourceURL) {
            guard let currentSourceURL else { return }
            await presenter.load(url: currentSourceURL)
        }
        .onChange(of: sourceURL) { _, newValue in
            currentSourceURL = newValue
        }
    }

    private var chrome: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Business Document Studio")
                    .font(.system(size: 15, weight: .semibold))
                Text(verbatim: "Preview and export availability")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button {
                beginImport()
            } label: {
                Label {
                    Text(verbatim: "Import")
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch presenter.loadState {
        case .idle:
            emptyState(
                systemImage: "doc.badge.plus",
                title: "No document loaded",
                message: "Open a supported business document to inspect preview, security, and export availability."
            )

        case .loading(let url):
            VStack(spacing: 12) {
                ProgressView()
                Text(verbatim: url?.lastPathComponent ?? "Loading document")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let failure):
            emptyState(
                systemImage: failure.kind == .unsupportedFormat ? "doc.badge.questionmark" : "exclamationmark.triangle",
                title: failure.title,
                message: failure.message
            )

        case .loaded(let presentation):
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    documentHeader(presentation)
                    StudioSection(title: "Import Summary") {
                        infoGrid(presentation.importRows)
                    }
                    StudioSection(title: "Metadata") {
                        infoGrid(presentation.summaryRows)
                    }
                    StudioSection(title: "Structure") {
                        infoGrid(presentation.structureRows)
                    }
                    StudioSection(title: "Security and Extraction") {
                        VStack(alignment: .leading, spacing: 12) {
                            infoGrid(presentation.securityRows)
                            warningsView(presentation.warnings)
                        }
                    }
                    StudioSection(title: "Structured Extraction Preview") {
                        VStack(alignment: .leading, spacing: 14) {
                            infoGrid(presentation.previewRows)
                            previewSections(presentation.previewSections)
                        }
                    }
                    StudioSection(title: "Export Options") {
                        VStack(alignment: .leading, spacing: 10) {
                            exportStateView
                            ForEach(presentation.exportOptions) { option in
                                exportOptionRow(option, presentation: presentation)
                            }
                        }
                    }
                    if !presenter.artifactStatuses.isEmpty {
                        StudioSection(title: "Artifact Status") {
                            artifactStatusesView(presenter.artifactStatuses)
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private func documentHeader(_ presentation: BusinessDocumentStudioPresentation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.iconSystemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: presentation.title)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(verbatim: presentation.subtitle)
                    if !presentation.registryRoleLabels.isEmpty {
                        Text(verbatim: presentation.registryRoleLabels.joined(separator: " / "))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 16)
        }
    }

    private func infoGrid(_ rows: [BusinessDocumentStudioInfoRow]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            ForEach(rows) { row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(verbatim: row.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    Text(verbatim: row.value)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private func warningsView(_ warnings: [BusinessDocumentStudioWarning]) -> some View {
        if warnings.isEmpty {
            Label {
                Text(verbatim: "No extraction or export warnings")
            } icon: {
                Image(systemName: "checkmark.circle")
            }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(warnings) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: iconName(for: warning.severity))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(color(for: warning.severity))
                            .frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: warning.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(verbatim: warning.message)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func previewSections(_ sections: [BusinessDocumentStudioPreviewSection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 7) {
                    Text(verbatim: section.title)
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(section.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(verbatim: row.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            Text(verbatim: row.value)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    @ViewBuilder
    private var exportStateView: some View {
        switch presenter.exportState {
        case .idle:
            EmptyView()

        case .exporting(let optionID):
            Label {
                Text(verbatim: "Exporting \(optionID.uppercased())")
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

        case .awaitingOverwriteConsent(let request):
            HStack(alignment: .center, spacing: 10) {
                Label {
                    Text(verbatim: request.message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(2)

                Spacer(minLength: 12)

                Button {
                    presenter.cancelPendingOverwrite()
                } label: {
                    Text(verbatim: "Cancel")
                }
                .controlSize(.small)

                Button {
                    Task { @MainActor in
                        await presenter.confirmPendingOverwrite()
                    }
                } label: {
                    Text(verbatim: "Replace")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .help(request.destination.path)

        case .succeeded(let receipt):
            Label {
                Text(verbatim: receipt.message)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .help(receipt.url.path)

        case .blocked(let block):
            Label {
                Text(verbatim: block.message)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .help(block.path ?? block.optionID)

        case .failed(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "xmark.octagon")
            }
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
    }

    private func artifactStatusesView(_ statuses: [BusinessDocumentStudioArtifactStatus]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(statuses) { status in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: artifactIconName(for: status.state))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(artifactColor(for: status.state))
                        .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(verbatim: status.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(verbatim: status.safetyLabel)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: status.message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let path = status.path {
                            Text(verbatim: path)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        if let bytesWritten = status.bytesWritten {
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: 12)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private func exportOptionRow(
        _ option: BusinessDocumentStudioExportOptionPresentation,
        presentation: BusinessDocumentStudioPresentation
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: option.canExport ? "square.and.arrow.up" : "nosign")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(option.canExport ? Color.secondary : Color.orange)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: option.label)
                        .font(.system(size: 12, weight: .semibold))
                    Text(verbatim: option.statusLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(option.canExport ? Color.secondary : Color.orange)
                    Text(verbatim: option.reasonLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text(verbatim: option.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button {
                beginExport(option, presentation: presentation)
            } label: {
                Label {
                    Text(verbatim: "Export")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!option.canExport)
            .help(option.canExport ? "Export \(option.label)" : option.message)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func beginExport(
        _ option: BusinessDocumentStudioExportOptionPresentation,
        presentation: BusinessDocumentStudioPresentation
    ) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = L("Export")
        panel.message = option.label
        panel.nameFieldStringValue = defaultExportName(for: option, presentation: presentation)
        if let contentType = UTType(filenameExtension: option.fileExtension) {
            panel.allowedContentTypes = [contentType]
        }

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            await presenter.export(
                optionID: option.id,
                to: url,
                allowedDirectory: url.deletingLastPathComponent(),
                allowOverwrite: false
            )
        }
    }

    private func beginImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.title = L("Open Business Document")
        panel.message = L("Choose a business document to inspect or export.")
        panel.allowedContentTypes = BusinessDocumentStudioDocumentTypes.supportedContentTypes

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            currentSourceURL = url.standardizedFileURL
        }
    }

    private func defaultExportName(
        for option: BusinessDocumentStudioExportOptionPresentation,
        presentation: BusinessDocumentStudioPresentation
    ) -> String {
        let stem = (presentation.title as NSString).deletingPathExtension
        let basename = stem.isEmpty ? "document" : stem
        return "\(basename).\(option.fileExtension)"
    }

    private func emptyState(
        systemImage: String,
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text(verbatim: title)
                .font(.system(size: 14, weight: .semibold))
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func iconName(for severity: BusinessDocumentStudioWarning.Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .caution: return "exclamationmark.triangle"
        case .blocked: return "xmark.octagon"
        }
    }

    private func color(for severity: BusinessDocumentStudioWarning.Severity) -> Color {
        switch severity {
        case .info: return .secondary
        case .caution: return .orange
        case .blocked: return .red
        }
    }

    private func artifactIconName(for state: BusinessDocumentStudioArtifactStatus.State) -> String {
        switch state {
        case .created: return "checkmark.circle"
        case .needsConsent: return "exclamationmark.triangle"
        case .blocked: return "nosign"
        case .failed: return "xmark.octagon"
        }
    }

    private func artifactColor(for state: BusinessDocumentStudioArtifactStatus.State) -> Color {
        switch state {
        case .created: return .green
        case .needsConsent: return .orange
        case .blocked: return .orange
        case .failed: return .red
        }
    }
}

private struct StudioSection<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
