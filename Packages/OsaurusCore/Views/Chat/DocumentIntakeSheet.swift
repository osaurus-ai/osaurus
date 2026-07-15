import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DocumentIntakePresenter: View {
    @ObservedObject var coordinator: DocumentIntakeCoordinator
    let onAttach: (Attachment) -> Void
    @State private var actionHandled = false

    var body: some View {
        Color.clear
            .sheet(item: previewBinding) { preview in
                DocumentIntakeSheet(
                    preview: preview,
                    onAttach: {
                        actionHandled = true
                        if let attachment = coordinator.attachCurrent() {
                            onAttach(attachment)
                            coordinator.confirmCurrentAttachment()
                        }
                    },
                    onCancel: {
                        actionHandled = true
                        coordinator.skipCurrent()
                    }
                )
            }
            .sheet(item: attachmentPreviewBinding) { preview in
                DocumentAttachmentIntakeSheet(
                    preview: preview,
                    onAttach: {
                        actionHandled = true
                        coordinator.confirmCurrentAttachments()
                    },
                    onCancel: {
                        actionHandled = true
                        coordinator.skipCurrent()
                    }
                )
            }
            .onChange(of: coordinator.errorMessage) { _, message in
                guard let message else { return }
                ToastManager.shared.error(L("Could not attach file"), message: message)
                coordinator.clearError()
            }
    }

    private var previewBinding: Binding<DocumentIntakePreview?> {
        Binding(
            get: { coordinator.preview },
            set: { value in
                if actionHandled {
                    actionHandled = false
                    return
                }
                if value == nil, coordinator.preview != nil {
                    coordinator.skipCurrent()
                }
            }
        )
    }

    private var attachmentPreviewBinding: Binding<DocumentAttachmentIntakePreview?> {
        Binding(
            get: { coordinator.attachmentPreview },
            set: { value in
                if actionHandled {
                    actionHandled = false
                    return
                }
                if value == nil, coordinator.attachmentPreview != nil {
                    coordinator.skipCurrent()
                }
            }
        )
    }
}

private struct DocumentAttachmentIntakeSheet: View {
    let preview: DocumentAttachmentIntakePreview
    let onAttach: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    private let pageImages: [NSImage]

    init(
        preview: DocumentAttachmentIntakePreview,
        onAttach: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.preview = preview
        self.onAttach = onAttach
        self.onCancel = onCancel
        pageImages = preview.attachments.compactMap { attachment in
            attachment.loadImageData().flatMap { NSImage(data: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 20))
                    .foregroundColor(theme.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: Attachment.redactedFilename(from: preview.filename))
                        .font(theme.font(size: 15, weight: .semibold))
                    Text("Review rendered PDF pages before attaching", bundle: .module)
                        .font(theme.font(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "\(preview.attachments.count) rendered page image(s)",
                    systemImage: "photo.on.rectangle.angled"
                )
                .font(theme.font(size: 13, weight: .semibold))
                Text(
                    "This PDF has no extractable text. Osaurus will attach verified page images for a vision-capable model. Review the pages before continuing.",
                    bundle: .module
                )
                .font(theme.font(size: 12))
                .foregroundColor(theme.secondaryText)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(pageImages.enumerated()), id: \.offset) { index, image in
                            VStack(spacing: 4) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 128, height: 156)
                                    .background(Color.white)
                                    .overlay(Rectangle().stroke(theme.primaryBorder, lineWidth: 1))
                                Text(localized: "Page \(index + 1)")
                                    .font(theme.font(size: 10))
                                    .foregroundColor(theme.secondaryText)
                            }
                        }
                    }
                }
                Label(
                    localized: "Source captured and integrity checked",
                    systemImage: "checkmark.shield"
                )
                    .font(theme.font(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(18)
            Spacer()
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button(localized: "Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(localized: "Attach Pages", action: onAttach)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 480)
        .background(theme.primaryBackground)
    }
}

struct DocumentIntakeSheet: View {
    let preview: DocumentIntakePreview
    let onAttach: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var overwriteRequest: OverwriteRequest?
    @State private var isConverting = false
    @State private var conversionMessage: String?
    @State private var conversionTask: Task<Void, Never>?
    @State private var conversionGeneration = UUID()

    private let service = DocumentIntakeService()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sampleSection
                    securitySection
                    conversionSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(minWidth: 600, idealWidth: 720, minHeight: 560, idealHeight: 680)
        .background(theme.primaryBackground)
        .alert(item: $overwriteRequest) { request in
            Alert(
                title: Text("Replace existing file?", bundle: .module),
                message: Text("A file named \(request.url.lastPathComponent) already exists.", bundle: .module),
                primaryButton: .destructive(Text("Replace", bundle: .module)) {
                    performConversion(request.option, to: request.url, allowOverwrite: true)
                },
                secondaryButton: .cancel()
            )
        }
        .onDisappear(perform: cancelConversion)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 20))
                .foregroundColor(theme.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: Attachment.redactedFilename(from: preview.document.filename))
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text("Review parsed content before attaching", bundle: .module)
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Text(verbatim: preview.inspection.summary.kind.displayName)
                .font(theme.font(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(16)
    }

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Parsed sample", icon: "text.alignleft")
            Text(verbatim: sampleText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(theme.secondaryBackground.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if sampleIsTruncated {
                Label {
                    Text("Truncated", bundle: .module)
                } icon: {
                    Image(systemName: "scissors")
                }
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.warningColor)
            }
        }
    }

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Security and provenance", icon: "checkmark.shield")
            Label(
                "Inspection: \(preview.inspection.security.inspectionStatus.rawValue)",
                systemImage: preview.inspection.security.hasActiveContent ? "exclamationmark.triangle.fill" : "checkmark.circle"
            )
            .foregroundColor(preview.inspection.security.hasActiveContent ? theme.warningColor : theme.secondaryText)
            .font(theme.font(size: 12))

            if preview.inspection.security.hasActiveContent {
                Text("Active or external content was detected. Only the parsed text fallback is attached; active content is never executed.", bundle: .module)
                    .font(theme.font(size: 12))
                    .foregroundColor(theme.warningColor)
            }
            ForEach(Array(preview.inspection.security.findings.enumerated()), id: \.offset) { _, finding in
                Text(verbatim: "\(finding.severity.rawValue.capitalized): \(finding.message)")
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            Text("Source identity: \(preview.provenance.stableSourceID.prefix(12))", bundle: .module)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var conversionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Convert a copy", icon: "arrow.triangle.2.circlepath")
            ForEach(preview.inspection.exportOptions, id: \.targetFormatId) { option in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: option.label)
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text(verbatim: option.message)
                            .font(theme.font(size: 10))
                            .foregroundColor(option.canExport ? theme.secondaryText : theme.warningColor)
                    }
                    Spacer()
                    Button(localized: "Export") { chooseDestination(for: option) }
                        .disabled(!option.canExport || isConverting)
                }
            }
            if let conversionMessage {
                Text(verbatim: conversionMessage)
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(localized: "Cancel") {
                cancelConversion()
                onCancel()
            }
                .keyboardShortcut(.cancelAction)
            Button(localized: "Attach File", action: onAttach)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func sectionTitle(_ title: LocalizedStringKey, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(theme.font(size: 13, weight: .semibold))
            .foregroundColor(theme.primaryText)
    }

    private var sampleText: String {
        switch preview.inspection.preview {
        case .table(let table):
            return table.sampledRows.prefix(12).map { $0.values.joined(separator: " | ") }.joined(separator: "\n")
        case .workbook(let workbook):
            return workbook.sheets.prefix(3).flatMap { sheet in
                ["[\(sheet.name)]"] + sheet.sampleRows.prefix(8).map { row in
                    row.cells.map(\.text.text).joined(separator: " | ")
                }
            }.joined(separator: "\n")
        case .pdf(let pdf):
            return pdf.pages.prefix(4).map { "Page \($0.pageIndex + 1)\n\($0.text.text)" }.joined(separator: "\n\n")
        case .presentation(let presentation):
            return presentation.slides.prefix(6).map { "\($0.label)\n\($0.text.text)" }.joined(separator: "\n\n")
        case .richText(let rich):
            return rich.sampledBlocks.map(\.text.text).joined(separator: "\n\n")
        case .text(let text):
            return text.text
        }
    }

    private var sampleIsTruncated: Bool {
        switch preview.inspection.preview {
        case .table(let value):
            return value.truncatedByByteLimit || value.truncatedByRowLimit || value.truncatedByColumnLimit
        case .workbook(let value):
            return value.isSheetSampleTruncated || value.sheets.contains { $0.isRowSampleTruncated }
        case .pdf(let value): return value.isPageSampleTruncated || value.pages.contains { $0.text.isTruncated }
        case .presentation(let value):
            return value.isSlideSampleTruncated || value.slides.contains { $0.text.isTruncated }
        case .richText(let value): return value.isBlockSampleTruncated || value.text.isTruncated
        case .text(let value): return value.isTruncated
        }
    }

    private func chooseDestination(for option: BusinessDocumentStudioExportOption) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename(for: option)
        panel.allowedContentTypes = [UTType(filenameExtension: option.fileExtension) ?? .data]
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                overwriteRequest = OverwriteRequest(option: option, url: url)
            } else {
                performConversion(option, to: url, allowOverwrite: false)
            }
        }
    }

    private func performConversion(
        _ option: BusinessDocumentStudioExportOption,
        to url: URL,
        allowOverwrite: Bool
    ) {
        isConverting = true
        conversionMessage = nil
        conversionTask?.cancel()
        let request = UUID()
        conversionGeneration = request
        conversionTask = Task {
            do {
                let result = try await service.convert(
                    preview,
                    option: option,
                    to: url,
                    allowOverwrite: allowOverwrite
                )
                await MainActor.run {
                    guard conversionGeneration == request else { return }
                    conversionMessage = result.message
                    isConverting = false
                    conversionTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard conversionGeneration == request else { return }
                    isConverting = false
                    conversionTask = nil
                }
            } catch {
                await MainActor.run {
                    guard conversionGeneration == request else { return }
                    conversionMessage = DocumentIntakeError.conversionMessage(for: error)
                    isConverting = false
                    conversionTask = nil
                }
            }
        }
    }

    private func cancelConversion() {
        conversionGeneration = UUID()
        conversionTask?.cancel()
        conversionTask = nil
        isConverting = false
        conversionMessage = nil
    }

    private func suggestedFilename(for option: BusinessDocumentStudioExportOption) -> String {
        let basename = Attachment.redactedFilename(from: preview.document.filename)
        return (basename as NSString).deletingPathExtension + "." + option.fileExtension
    }

    private struct OverwriteRequest: Identifiable {
        let id = UUID()
        let option: BusinessDocumentStudioExportOption
        let url: URL
    }
}
