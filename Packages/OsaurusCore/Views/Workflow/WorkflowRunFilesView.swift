//
//  WorkflowRunFilesView.swift
//  osaurus
//
//  The files a run handed the person, under its result: each with its
//  Finder icon (a thumbnail for images), size, and Open / Show in Finder.
//  A file that is missing or outside the run's folders says so instead.
//

import AppKit
import SwiftUI

struct WorkflowRunFiles: View {
    let files: [WorkflowArtifact]

    @Environment(\.theme) private var theme

    var body: some View {
        let media = WorkflowMediaGalleryModel.items(files)
        let others = files.filter { file in !media.contains { $0.id == file.id } }
        VStack(alignment: .leading, spacing: 12) {
            if !media.isEmpty {
                WorkflowMediaGallery(files: media)
            }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Files", bundle: .module)
                        .textStyle(.caption, weight: 600)
                        .foregroundColor(theme.text.secondary)
                    ForEach(others) { file in
                        WorkflowRunFileRow(file: file)
                    }
                }
            }
        }
    }
}

private struct WorkflowRunFileRow: View {
    let file: WorkflowArtifact

    @Environment(\.theme) private var theme
    @State private var thumbnail: NSImage?

    private var url: URL { URL(fileURLWithPath: file.path) }

    var body: some View {
        HStack(spacing: 10) {
            preview
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.filename)
                    .textStyle(.body, weight: 500)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: subtitle)
                    .textStyle(.caption)
                    .foregroundColor(file.problem == nil ? theme.text.tertiary : theme.status.warning.foreground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if file.isAvailable {
                Button {
                    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    Text("Open", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.text.tertiary)
                .localizedHelp("Show in Finder")
            }
        }
        .padding(theme.space.s8)
        .settingsChrome(.inset)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard file.isAvailable else { return }
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        }
        .task(id: file.path) { await loadThumbnail() }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
        } else if file.isAvailable {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "exclamationmark.triangle")
                .glyphSize(16)
                .foregroundColor(theme.status.warning.foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surface.subtle)
        }
    }

    private var subtitle: String {
        if let problem = file.problem { return problem }
        var parts = [file.shared.categoryLabel]
        if file.fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(file.fileSize), countStyle: .file))
        }
        if let description = file.description, !description.isEmpty { parts.append(description) }
        return parts.joined(separator: " · ")
    }

    private func loadThumbnail() async {
        guard file.isAvailable, file.shared.isImage else { return }
        let path = file.path
        let image = await Task.detached(priority: .utility) { NSImage(contentsOfFile: path) }.value
        thumbnail = image
    }
}
