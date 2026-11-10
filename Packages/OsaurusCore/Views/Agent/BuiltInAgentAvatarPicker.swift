//
//  BuiltInAgentAvatarPicker.swift
//  osaurus
//
//  Avatar picker for the Orchestrator and the Architect: upload an image
//  or pick a dino. Their identity lives in config stores, so it saves
//  through `AgentManager.setBuiltIn*` instead of the custom-agent editor.
//

import AppKit
import SwiftUI

/// Picks an image file and returns it as a PNG at most 256px on its long
/// edge, the size avatars are stored at.
enum AvatarImageImport {
    @MainActor
    static func choosePNG() async -> Data? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .image]
        panel.prompt = L("Choose")
        guard await panel.beginModal() == .OK, let url = panel.url,
            let original = NSImage(contentsOf: url)
        else { return nil }
        return pngData(from: downscaled(original, maxDimension: 256))
    }

    /// Keeps disk, memory, and decode time bounded; sources are usually
    /// far larger than any avatar surface.
    static func downscaled(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else { return image }
        let scale = min(1.0, maxDimension / max(srcSize.width, srcSize.height))
        guard scale < 1.0 else { return image }
        let target = NSSize(width: floor(srcSize.width * scale), height: floor(srcSize.height * scale))
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .copy,
            fraction: 1.0
        )
        result.unlockFocus()
        return result
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Identity for the Orchestrator and the Architect: an optional display
/// name over the built-in one, and the avatar. Each is its own row.
struct BuiltInAgentIdentitySection: View {
    let agentId: UUID
    /// The built-in name, shown as the placeholder and used while blank.
    let defaultName: String
    @Binding var name: String
    /// Catalog key for the name hint.
    let nameHelp: String
    let nameAnchorId: String
    let avatarAnchorId: String

    private var previewName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    var body: some View {
        SettingsSection(title: "Identity") {
            SettingsTextFieldRow(
                label: "Name",
                text: $name,
                placeholder: defaultName,
                help: nameHelp,
                anchorId: nameAnchorId
            )
            SettingsFieldRow(
                label: "Avatar",
                hint: "Upload your own image or pick a dino.",
                anchorId: avatarAnchorId
            ) {
                BuiltInAgentAvatarPicker(agentId: agentId, previewName: previewName)
            }
        }
    }
}

struct BuiltInAgentAvatarPicker: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let agentId: UUID
    /// Name the monogram and tint follow, so the preview matches the
    /// name being typed next to it.
    let previewName: String

    private var agent: Agent {
        agentManager.agent(for: agentId) ?? (agentId == Agent.architectId ? .architect : .default)
    }

    var body: some View {
        HStack(spacing: theme.space.s8) {
            if agent.customAvatarURL != nil {
                customPreview
            }
            uploadButton
            ForEach(AgentMascot.allCases) { mascot in
                mascotOption(mascot)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, theme.space.s4)
    }

    private var customPreview: some View {
        Button {
            agentManager.clearBuiltInCustomAvatar(for: agentId)
        } label: {
            AgentAvatarView(
                mascotId: nil,
                name: previewName,
                tint: agentColorFor(previewName),
                diameter: 36,
                customImageURL: agent.customAvatarURL,
                monogramFontSize: 14,
                borderWidth: 1.5
            )
            .overlay(Circle().strokeBorder(theme.action.primary.default.background, lineWidth: theme.stroke.focus).padding(-3))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "xmark.circle.fill")
                    .glyphSize(13, weight: .semibold)
                    .foregroundColor(theme.text.secondary)
                    .background(Circle().fill(theme.surface.canvas))
                    .offset(x: 4, y: -4)
            }
        }
        .buttonStyle(.plain)
        .localizedHelp("Remove custom avatar")
    }

    private var uploadButton: some View {
        Button {
            Task { @MainActor in
                guard let data = await AvatarImageImport.choosePNG() else { return }
                agentManager.setBuiltInCustomAvatar(data, ext: "png", for: agentId)
            }
        } label: {
            ZStack {
                Circle().fill(theme.surface.subtle)
                Circle().strokeBorder(theme.border.strong, style: StrokeStyle(lineWidth: theme.stroke.default, dash: [3, 3]))
                Image(systemName: "photo.badge.plus")
                    .glyphSize(13, weight: .semibold)
                    .foregroundColor(theme.text.secondary)
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .localizedHelp("Upload custom image")
    }

    private func mascotOption(_ mascot: AgentMascot) -> some View {
        let isSelected = agent.customAvatarURL == nil && agent.avatar == mascot.id
        return Button {
            agentManager.setBuiltInMascot(mascot.id, for: agentId)
        } label: {
            AgentAvatarView(
                mascotId: mascot.id,
                name: previewName,
                tint: mascot.color,
                diameter: 36,
                monogramFontSize: 14,
                borderWidth: 1.5
            )
            .overlay(
                Circle()
                    .strokeBorder(isSelected ? theme.action.primary.default.background : Color.clear, lineWidth: theme.stroke.focus)
                    .padding(-3)
            )
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: mascot.displayName))
    }
}
