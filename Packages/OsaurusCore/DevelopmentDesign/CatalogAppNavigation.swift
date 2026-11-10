#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI
import AppKit
@MainActor enum CatalogAppNavigation {
    private static var galleryWindow: NSWindow?
    private static let galleryState = BaseGalleryState()
    private static var verificationChatWindowID: UUID?
    private static func showSample(_ sample: ChatSessionData) {
        let id = ChatWindowManager.shared.createWindow(sessionData: sample)
        verificationChatWindowID = id
        // The production chat hides its title. Give only these local sample
        // windows a stable system title so verification tools can target them.
        ChatWindowManager.shared.getNSWindow(id: id)?.title = "Osaurus · App verification"
    }
    static func arrangeVerificationChat(compact: Bool) {
        if verificationChatWindowID == nil { sampleConversation() }
        guard let id = verificationChatWindowID,
              let window = ChatWindowManager.shared.getNSWindow(id: id) else { return }
        window.setContentSize(NSSize(width: compact ? 760 : 1200, height: 700))
        window.center()
        ChatWindowManager.shared.showWindow(id: id)
    }
    static func showGallery(_ family: Int? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        galleryState.family = family
        if let galleryWindow { galleryWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings Kit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BaseGalleryHost(state: galleryState))
        window.contentMinSize = NSSize(width: 860, height: 680)
        window.setContentSize(NSSize(width: 960, height: 760))
        window.center(); galleryWindow = window; window.makeKeyAndOrderFront(nil)
    }
    static func sampleConversation(attachments: [Attachment] = [], artifacts: [SharedArtifact] = []) {
        let sample = ChatSessionData(
            id: UUID(uuidString: !artifacts.isEmpty ? (artifacts.count > 2 ? "9C6A2E10-1781-4B1D-BEF3-011CE4E42037" : "9C6A2E10-1781-4B1D-BEF3-011CE4E41937") : (attachments.isEmpty ? "9C6A2E10-1781-4B1D-BEF3-011CE4E41908" : "9C6A2E10-1781-4B1D-BEF3-011CE4E41924"))!,
            title: "Inspector verification · sample conversation",
            turns: [
                ChatTurnData(role: .user, content: "Can you show how our message components look together?", attachments: attachments),
                ChatTurnData(role: .assistant, content: "This is local sample content for checking the design inspector. No model request was made.\n\n## Shared components\n\nEdit **message emphasis**, typography or geometry in the component catalog while this conversation is open.\n\n- The sidebar and composer use the actual app views.\n- The message body and code block use the actual native renderers.\n\n```swift\nlet design = \"Connected to Osaurus\"\n```", sharedArtifacts: artifacts, completedAt: Date())
            ])
        showSample(sample)
    }
    static func sampleFileDiffConversation() {
        let callIDs = ["inspector-diff-swift", "inspector-diff-plain"]
        let paths = ["example.swift", "notes.unknown"]
        let calls = zip(callIDs, paths).map { callID, path in
            ToolCall(id: callID, type: "function", function: .init(name: "file_edit", arguments: "{\"path\":\"\(path)\"}"))
        }
        let results = Dictionary(uniqueKeysWithValues: zip(callIDs, paths).map { callID, path in
            (callID, ToolEnvelope.success(tool: "file_edit", result: [
                "path": path, "dry_run": true,
                "diff": "--- a/\(path)\n+++ b/\(path)\n@@ -1,2 +1,2 @@\n-let value = \"Before\"\n+let value = \"After\"\n // Local display data only."
            ]))
        })
        let sample = ChatSessionData(id: UUID(uuidString: "9C6A2E10-1781-4B1D-BEF3-011CE4E41938")!,
            title: "Inspector verification · file diffs",
            turns: [ChatTurnData(role: .user, content: "Review these local diff samples."),
                ChatTurnData(role: .assistant, content: "Display-only tool results. No file edit was performed.",
                    toolCalls: calls, toolResults: results, completedAt: Date())])
        showSample(sample)
    }
    static func sampleRichTextConversation() {
        let sample = ChatSessionData(id: UUID(uuidString: "9C6A2E10-1781-4B1D-BEF3-011CE4E41931")!,
            title: "Inspector verification · native rich text",
            turns: [ChatTurnData(role: .user, content: "Check these local rich-text blocks without sending a request."),
                ChatTurnData(role: .assistant, content: """
                ## Native structural blocks

                Local reference before the image. [Open the local reference PDF](file:///private/tmp/osaurus-inspector-artifacts-oct22/sample.pdf).

                ![Owned local sample](file:///private/tmp/osaurus-inspector-artifacts-oct22/sample.png)

                $$
                E = mc^2
                $$

                ---

                Local reference after the divider. **Body emphasis** and `inline code` remain part of the original renderer.
                """, completedAt: Date())])
        showSample(sample)
    }
    static func sampleTerminalChartConversation() {
        let spec = ChartSpec(chartType: "column", title: "Local chart sample", categories: ["One", "Two", "Three"],
            series: [ChartSeries(name: "Sample", data: [2, 4, 3]), ChartSeries(name: "Comparison", data: [3, 2, 5])], dataLabelsEnabled: true,
            note: "Local display data. No model request was made.")
        let json = (try? JSONEncoder().encode(spec)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var explicit = spec
        explicit.title = "Local explicit palette"
        explicit.colorsTheme = ["#0077CC", "#CC7700"]
        let explicitJSON = (try? JSONEncoder().encode(explicit)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let ids = ["inspector-terminal-ok", "inspector-terminal-error", "inspector-terminal-killed"]
        let calls = ids.map { ToolCall(id: $0, type: "function", function: .init(name: "shell_run", arguments: "{\"command\":\"local-display-sample\"}")) }
        let results = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, callID in
            (callID, ToolEnvelope.success(tool: "shell_run", result: ["stdout": "Local terminal output\nA second line for typography.\nNo command was executed.", "stderr": index == 1 ? "Sample error output" : "", "exit_code": index == 1 ? 1 : 0, "killed_by": index == 2 ? "user" : ""]))
        })
        let sample = ChatSessionData(id: UUID(uuidString: "9C6A2E10-1781-4B1D-BEF3-011CE4E41939")!,
            title: "Inspector verification · terminal and chart",
            turns: [ChatTurnData(role: .user, content: "Review these local display samples."),
                ChatTurnData(role: .assistant, content: "```chart\n\(json)\n```", completedAt: Date()),
                ChatTurnData(role: .user, content: "Compare the explicit local palette."),
                ChatTurnData(role: .assistant, content: "```chart\n\(explicitJSON)\n```", toolCalls: calls, toolResults: results, completedAt: Date())])
        showSample(sample)
    }
    static func sampleNoticeConversation() {
        let earlier = [ChatTurnData(role: .user, content: "Earlier local sample."),
            ChatTurnData(role: .assistant, content: "Earlier answer.", completedAt: Date())]
        let summary = ConversationSummary(summaryText: "## Local summary\n\nThis is **display-only** summary text.\n\n- Original conversation retained.\n- No compaction request was made.", coveredTurnIds: earlier.map(\.id), modelIdentifier: "local-display-sample", savedTokensEstimate: 2400)
        let empty = ChatTurnData(role: .assistant, content: "", completedAt: Date(),
            routerBilling: RouterBillingSummary(costMicro: "1234", status: "completed", tokenSource: "provider", inputTokens: 11, outputTokens: 3))
        let sample = ChatSessionData(id: UUID(uuidString: "9C6A2E10-1781-4B1D-BEF3-011CE4E41940")!,
            title: "Inspector verification · conversation notices",
            turns: earlier + [ChatTurnData(role: .user, content: "Local empty-response display sample. Do not retry."), empty],
            conversationSummary: summary)
        showSample(sample)
    }
    static func show(_ family: Int) {
        if (3...20).contains(family) { showGallery(family); return }
        if (33...36).contains(family) || family == 45 { showGallery(family); return }
        if family == 24 { sampleConversation(attachments: InspectorAttachmentSamples.items); return }
        if family == 37 {
            let base = URL(fileURLWithPath: "/private/tmp/osaurus-inspector-artifacts-oct22")
            let samples: [(String, String, Bool)] = [("sample.png", "image/png", false), ("sample.pdf", "application/pdf", false), ("sample.mp4", "video/mp4", false), ("sample.wav", "audio/wav", false), ("sample-directory", "inode/directory", true), ("missing-preview.png", "image/png", false)]
            let artifacts = samples.map { name, mime, directory in
                let path = base.appendingPathComponent(name).path
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                return SharedArtifact(id: "inspector-artifact-oct22-" + name, contextId: "inspector", contextType: .chat, filename: name, mimeType: mime, fileSize: size, hostPath: path, isDirectory: directory, description: "Local display sample; no external file or browser action is needed.")
            }
            sampleConversation(artifacts: artifacts)
            return
        }
        if family == 38 { sampleFileDiffConversation(); return }
        if family == 31 { sampleRichTextConversation(); return }
        if family == 39 { sampleTerminalChartConversation(); return }
        if family == 40 { sampleNoticeConversation(); return }
        let tabs: [Int: ManagementTab] = [8:.automations,9:.voice,11:.agents,20:.agents,46:.chat,47:.providers,48:.agents,49:.workspaces,50:.automations,51:.credits,52:.privacy,53:.knowledge,54:.imageGeneration]
        if [28,29,30,31,32,41,42,44].contains(family) { sampleConversation(); return }
        if let tab = tabs[family] { AppDelegate.shared?.showManagementWindow(initialTab: tab) }
        else if family < 21 { AppDelegate.shared?.showManagementWindow(initialTab: .chat) }
        else { _ = ChatWindowManager.shared.createWindow() }
    }
}
extension Notification.Name {
    static let designInspectorBaseComponent = Notification.Name("Osaurus.DesignInspector.BaseComponent")
}
@MainActor private final class BaseGalleryState: ObservableObject {
    @Published var family: Int?
}
private struct BaseGalleryHost: View {
    @ObservedObject var state: BaseGalleryState
    @ObservedObject private var themes = ThemeManager.shared
    var body: some View {
        SettingsKitGallery(inspectorFamily: state.family).id(state.family)
            .environment(\.theme, themes.currentTheme)
            .preferredColorScheme(themes.currentTheme.isDark ? .dark : .light)
            .frame(minWidth: 860, minHeight: 680)
    }
}
#endif
