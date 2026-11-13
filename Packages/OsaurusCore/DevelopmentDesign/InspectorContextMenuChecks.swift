#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI
import AppKit

/// Original menu-bearing production views, with local data and callbacks only.
struct InspectorContextMenuChecks: View {
    @State private var part = 1
    @State private var hostedHere = false
    @State private var disabled = false
    @State private var lastAction = "None"
    @State private var actions = 0
    private let names = ["Workspace agent", "Paired agent", "Discovered agent", "Project", "File change set", "Current file", "Clipboard chip", "Folder chip", "Markdown image", "Workflow media", "Architect input", "Sandbox chip (inactive)", "Agent workspace sharing", "Sidebar/history variants"]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Remaining context menus").font(.title2)
            Text("Original production views · local display data · no account, runtime or persistent document operations")
            Picker("Menu path", selection: $part) {
                ForEach(1...14, id: \.self) { n in Text("\(n). \(names[n - 1])").tag(n) }
            }.accessibilityLabel("Menu path")
            if part == 1 { Toggle("Hosted here", isOn: $hostedHere) }
            if part == 5 || part == 6 { Toggle("Disable file actions", isOn: $disabled) }
            Text("Local actions: \(actions) · \(lastAction)")
            Group {
                switch part {
                case 1...4: inspectorSidebarContextRow(part, hostedHere: hostedHere, action: action)
                case 5, 6: inspectorFileContextRow(part, disabled: disabled, action: action)
                case 7, 8: InspectorComposerContextMenuCheck(part: part)
                case 9: MarkdownImageView(urlString: InspectorContextMenuData.cachedURL, altText: "Local menu image", baseWidth: 300)
                case 10: inspectorWorkflowMediaContext(InspectorContextMenuData.imagePath, action: { action("Media open callback only") })
                case 11: ArchitectSidebarPanel(sessionId: nil, inspectorMenuVerification: true)
                case 13: inspectorSidebarSharingRow(action: action)
                case 14: InspectorSidebarRemainingVerification()
                default: Text("The current selector cluster never calls sandboxToggleChip. It has no reachable menu in this app version. Its visibility is not restored for this check.")
                }
            }.id(part).padding(16)
            Text("Right-click or use Show menu. File reveal/save, account and network actions are not needed for visual proof.").font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func action(_ name: String) { actions += 1; lastAction = name }
}

private struct InspectorComposerContextMenuCheck: View {
    let part: Int
    @State private var text = ""
    @State private var clipboardKind = "Text"
    @State private var attachments: [Attachment] = []
    @StateObject private var folder = ChatFolderState.inspectorMenuSample()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if part == 7 {
                Picker("Clipboard sample", selection: $clipboardKind) {
                    ForEach(["Text", "Image", "File"], id: \.self) { Text($0) }
                }
                Text("Local attachments: \(attachments.count)")
            }
            FloatingInputCard(text: $text, selectedModel: .constant(nil), pendingAttachments: $attachments, isContinuousVoiceMode: .constant(false), voiceInputState: .constant(.idle), showVoiceOverlay: .constant(false), pickerItems: [], activeModelOptions: .constant([:]), isStreaming: false, supportsImages: true, estimatedContextTokens: 0, onSend: { _ in }, onStop: {}, isModelPinned: true, pinnedModelLabel: "Local sample", isRemoteAgentRun: true, folderState: folder)
                .inspectorContextMenuOnly(part, clipboard: clipboardContent)
                .id(clipboardKind)
            if part == 8 { Text("Local draft: " + (text.isEmpty ? "empty" : text)) }
        }
    }
    private var clipboardContent: ClipboardService.ClipboardContent {
        switch clipboardKind {
        case "Image": return .image(InspectorContextMenuData.image.pngData()!)
        case "File": return .file(URL(fileURLWithPath: "/private/tmp/osaurus-inspector-artifacts-oct23/clipboard.txt"))
        default: return .text("Local menu verification text")
        }
    }
}

@MainActor enum InspectorContextMenuData {
    static let image = NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
        NSColor.systemBlue.setFill(); rect.fill()
        NSColor.systemYellow.setFill(); NSRect(x: 20, y: 20, width: 60, height: 60).fill()
        return true
    }
    static var cachedURL: String {
        let url = "inspector://local-context-menu-image"
        ThreadCache.shared.setImage(image, for: url)
        return url
    }
    static let imagePath: String = {
        let directory = OsaurusPaths.root().appendingPathComponent("MenuVerification", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("menu-image.png")
        if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: file) }
        return file.path
    }()
}
#endif
