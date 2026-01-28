//
//  AgentView.swift
//  osaurus
//
//  Main view for agent mode - displays task execution with issue tracking.
//

import CoreText
import SwiftUI
import UniformTypeIdentifiers

struct AgentView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: AgentSession

    @State private var showSidebar: Bool = false
    @State private var isPinnedToBottom: Bool = true

    // Progress sidebar state (right side)
    @State private var progressSidebarWidth: CGFloat = 280
    @State private var isProgressSidebarCollapsed: Bool = false
    private let minProgressSidebarWidth: CGFloat = 200
    private let maxProgressSidebarWidth: CGFloat = 400

    // Artifact viewer state
    @State private var showArtifactViewer: Bool = false
    @State private var selectedArtifact: Artifact?

    private var theme: ThemeProtocol { windowState.theme }

    var body: some View {
        GeometryReader { proxy in
            let sidebarWidth: CGFloat = showSidebar ? 240 : 0
            let mainWidth = proxy.size.width - sidebarWidth

            HStack(alignment: .top, spacing: 0) {
                // Sidebar - Task list
                if showSidebar {
                    AgentTaskSidebar(
                        tasks: windowState.agentTasks,
                        currentTaskId: session.currentTask?.id,
                        onSelect: { task in
                            Task {
                                await session.loadTask(task)
                            }
                        },
                        onDelete: { taskId in
                            Task {
                                try? await IssueManager.shared.deleteTask(taskId)
                                windowState.refreshAgentTasks()
                                if session.currentTask?.id == taskId {
                                    session.currentTask = nil
                                    session.issues = []
                                }
                            }
                        }
                    )
                    .transition(.move(edge: .leading))
                }

                // Main content
                ZStack {
                    // Background
                    agentBackground

                    VStack(spacing: 0) {
                        // Header
                        agentHeader

                        // Content
                        if session.currentTask == nil {
                            // Empty state - no task selected
                            agentEmptyState
                        } else {
                            // Task execution view
                            taskExecutionView(width: mainWidth)
                        }

                        // Input card - reuse FloatingInputCard for consistency
                        FloatingInputCard(
                            text: $session.input,
                            selectedModel: $session.selectedModel,
                            pendingImages: .constant([]),
                            isContinuousVoiceMode: .constant(false),
                            voiceInputState: .constant(.idle),
                            showVoiceOverlay: .constant(false),
                            modelOptions: session.modelOptions,
                            isStreaming: session.isExecuting,
                            supportsImages: false,
                            estimatedContextTokens: session.estimatedContextTokens,
                            onSend: { Task { await session.handleUserInput() } },
                            onStop: { session.stopExecution() },
                            personaId: windowState.personaId,
                            windowId: windowState.windowId
                        )
                    }
                }
            }
        }
        .frame(minWidth: 800, idealWidth: 950)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            windowControls
        }
        .ignoresSafeArea()
        .animation(theme.animationQuick(), value: showSidebar)
        .environment(\.theme, windowState.theme)
        .tint(theme.accentColor)
        .sheet(isPresented: $showArtifactViewer) {
            if let artifact = selectedArtifact {
                ArtifactViewerSheet(
                    artifact: artifact,
                    onDownload: { downloadArtifact(artifact) },
                    onDismiss: { showArtifactViewer = false }
                )
                .environment(\.theme, windowState.theme)
            }
        }
    }

    // MARK: - Artifact Actions

    private func viewArtifact(_ artifact: Artifact) {
        selectedArtifact = artifact
        showArtifactViewer = true
    }

    private func downloadArtifact(_ artifact: Artifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.filename
        panel.allowedContentTypes =
            artifact.contentType == .markdown
            ? [UTType(filenameExtension: "md") ?? .plainText]
            : [.plainText]

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                try artifact.content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[AgentView] Failed to save artifact: \(error)")
            }
        }
    }

    // MARK: - Window Controls

    private var windowControls: some View {
        HStack(spacing: 8) {
            if session.currentTask == nil {
                SettingsButton(action: {
                    AppDelegate.shared?.showManagementWindow(initialTab: .settings)
                })
            } else {
                HeaderActionButton(
                    icon: "plus",
                    help: "New task",
                    action: {
                        session.currentTask = nil
                        session.issues = []
                        session.clearSelection()
                    }
                )
            }
            PinButton(windowId: windowState.windowId)
            CloseButton(action: closeWindow)
        }
        .padding(16)
    }

    /// Close this window via ChatWindowManager
    private func closeWindow() {
        ChatWindowManager.shared.closeWindow(id: windowState.windowId)
    }

    // MARK: - Background

    private var agentBackground: some View {
        ZStack {
            // Layer 1: Base background (solid, gradient, or image)
            baseBackgroundLayer
                .clipShape(backgroundShape)

            // Layer 2: Glass effect (if enabled)
            if theme.glassEnabled {
                ThemedGlassSurface(
                    cornerRadius: 24,
                    topLeadingRadius: showSidebar ? 0 : nil,
                    bottomLeadingRadius: showSidebar ? 0 : nil
                )
                .allowsHitTesting(false)

                // Solid backing layer for text contrast
                let baseBackingOpacity = theme.isDark ? 0.6 : 0.7
                let themeBoost = theme.glassOpacityPrimary * 0.8
                let backingOpacity = min(0.92, baseBackingOpacity + themeBoost)

                backgroundShape
                    .fill(theme.primaryBackground.opacity(backingOpacity))
                    .allowsHitTesting(false)

                // Gradient overlay for depth and polish
                LinearGradient(
                    colors: [
                        theme.primaryBackground.opacity(theme.glassOpacityPrimary * 1.5),
                        theme.primaryBackground.opacity(theme.glassOpacitySecondary),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(backgroundShape)
                .allowsHitTesting(false)
            }
        }
    }

    private var backgroundShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: showSidebar ? 0 : 24,
            bottomLeadingRadius: showSidebar ? 0 : 24,
            bottomTrailingRadius: 24,
            topTrailingRadius: 24,
            style: .continuous
        )
    }

    @ViewBuilder
    private var baseBackgroundLayer: some View {
        if let customTheme = theme.customThemeConfig {
            switch customTheme.background.type {
            case .solid:
                Color(themeHex: customTheme.background.solidColor ?? customTheme.colors.primaryBackground)

            case .gradient:
                let colors = (customTheme.background.gradientColors ?? ["#000000", "#333333"])
                    .map { Color(themeHex: $0) }
                LinearGradient(
                    colors: colors,
                    startPoint: .top,
                    endPoint: .bottom
                )

            case .image:
                if let image = windowState.cachedBackgroundImage {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(customTheme.background.imageOpacity ?? 1.0)

                        // Overlay tint for contrast
                        theme.primaryBackground.opacity(0.7)
                    }
                } else {
                    theme.primaryBackground
                }
            }
        } else {
            theme.primaryBackground
        }
    }

    // MARK: - Header

    private var agentHeader: some View {
        ZStack {
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                // Sidebar toggle - far left
                HeaderActionButton(
                    icon: "sidebar.left",
                    help: showSidebar ? "Hide sidebar" : "Show sidebar",
                    action: {
                        withAnimation(theme.animationQuick()) {
                            showSidebar.toggle()
                        }
                    }
                )

                // Mode toggle - Chat mode (to the right of sidebar toggle)
                ModeToggleButton(currentMode: .agent) {
                    windowState.switchMode(to: .chat)
                }

                // Task title
                if let task = session.currentTask {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.leading, 20)
            .padding(.trailing, 56)
        }
        .frame(height: 72)
    }

    // MARK: - Empty State

    private var agentEmptyState: some View {
        AgentEmptyState(
            hasModels: session.modelOptions.count > 0,
            selectedModel: session.selectedModel,
            personas: windowState.personas,
            activePersonaId: windowState.personaId,
            onOpenModelManager: {
                AppDelegate.shared?.showManagementWindow(initialTab: .models)
            },
            onUseFoundation: windowState.foundationModelAvailable
                ? {
                    session.selectedModel = session.modelOptions.first?.id ?? "foundation"
                } : nil,
            onSelectPersona: { newPersonaId in
                windowState.switchPersona(to: newPersonaId)
            }
        )
    }

    // MARK: - Task Execution View

    private func taskExecutionView(width: CGFloat) -> some View {
        let collapsedWidth: CGFloat = 36
        let sidebarWidth = isProgressSidebarCollapsed ? collapsedWidth : progressSidebarWidth
        let chatWidth = width - sidebarWidth

        return HStack(spacing: 0) {
            // Main chat area
            VStack(spacing: 0) {
                // Issue detail view with MessageThreadView
                if session.selectedIssueId != nil && !session.issueBlocks.isEmpty {
                    issueDetailView(width: chatWidth)
                } else if session.selectedIssueId != nil {
                    // Selected issue but no blocks yet (loading or empty)
                    issueEmptyDetailView
                } else {
                    // No issue selected - show prompt
                    noIssueSelectedView
                }

                // Error message with retry button
                if let error = session.errorMessage {
                    errorView(error: error)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            // Resize handle + Progress sidebar (right side)
            if !isProgressSidebarCollapsed {
                // Resize handle
                ProgressSidebarResizeHandle(
                    width: $progressSidebarWidth,
                    minWidth: minProgressSidebarWidth,
                    maxWidth: maxProgressSidebarWidth
                )

                // Progress sidebar
                IssueTrackerPanel(
                    issues: session.issues,
                    activeIssueId: session.activeIssue?.id,
                    selectedIssueId: session.selectedIssueId,
                    finalArtifact: session.finalArtifact,
                    artifacts: session.artifacts,
                    isCollapsed: $isProgressSidebarCollapsed,
                    onIssueSelect: { issue in
                        session.selectIssue(issue)
                    },
                    onIssueRun: { issue in
                        Task {
                            await session.executeIssue(issue)
                        }
                    },
                    onIssueClose: { issueId in
                        Task {
                            await session.closeIssue(issueId, reason: "Manually closed")
                        }
                    },
                    onArtifactView: { artifact in
                        viewArtifact(artifact)
                    },
                    onArtifactDownload: { artifact in
                        downloadArtifact(artifact)
                    }
                )
                .frame(width: progressSidebarWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                // Collapsed state - thin expand button
                collapsedProgressSidebar
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(theme.animationQuick(), value: isProgressSidebarCollapsed)
        .onChange(of: isProgressSidebarCollapsed) { _, _ in
            // Clear height cache when sidebar state changes to prevent layout glitches
            MessageHeightCache.shared.clear()
        }
    }

    // MARK: - No Issue Selected View

    private var noIssueSelectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.point.right")
                .font(.system(size: 32))
                .foregroundColor(theme.tertiaryText)

            Text("Select an issue to view details")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Collapsed Progress Sidebar

    private var collapsedProgressSidebar: some View {
        VStack {
            Button {
                withAnimation(theme.animationQuick()) {
                    isProgressSidebarCollapsed = false
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show progress")
            .padding(.top, 10)

            Spacer()
        }
        .frame(width: 36)
        .background(theme.primaryBackground.opacity(0.5))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.primaryBorder.opacity(0.2))
                .frame(width: 1)
        }
    }

    // MARK: - Issue Detail View

    /// Maximum content width for chat readability
    private let maxChatContentWidth: CGFloat = 700

    private func issueDetailView(width: CGFloat) -> some View {
        let personaName = windowState.cachedPersonaDisplayName
        // Use available width minus padding, capped at max for readability
        let contentWidth = min(width - 40, maxChatContentWidth)

        return ZStack(alignment: .bottomTrailing) {
            MessageThreadView(
                blocks: session.issueBlocks,
                width: contentWidth,
                personaName: personaName,
                isStreaming: session.isExecuting && session.activeIssue?.id == session.selectedIssueId,
                turnsCount: session.issueBlocks.count,
                lastAssistantTurnId: session.issueBlocks.last?.turnId,
                onCopy: { _ in },
                onRegenerate: { _ in },
                onScrolledToBottom: { isPinnedToBottom = true },
                onScrolledAwayFromBottom: { isPinnedToBottom = false }
            )

            // Scroll to bottom button
            ScrollToBottomButton(
                isPinnedToBottom: isPinnedToBottom,
                hasTurns: !session.issueBlocks.isEmpty,
                onTap: { isPinnedToBottom = true }
            )
        }
        .frame(maxWidth: contentWidth)
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var issueEmptyDetailView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(theme.tertiaryText)

            Text("No execution history")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Text("Select an issue to view its details, or run it to see live execution.")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Error View

    private func errorView(error: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                Spacer()
            }

            if let failedIssue = session.failedIssue {
                HStack(spacing: 12) {
                    Button {
                        Task {
                            session.errorMessage = nil
                            await session.executeIssue(failedIssue, withRetry: true)
                        }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button {
                        session.errorMessage = nil
                        session.failedIssue = nil
                    } label: {
                        Text("Dismiss")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.1))
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Helpers

    private func statusIcon(for status: AgentTaskStatus) -> String {
        switch status {
        case .active: return "play.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private func statusColor(for status: AgentTaskStatus) -> Color {
        switch status {
        case .active: return .orange
        case .completed: return .green
        case .cancelled: return .gray
        }
    }
}

// MARK: - Progress Sidebar Resize Handle

private struct ProgressSidebarResizeHandle: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isHovered = false
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isHovered ? theme.accentColor.opacity(0.5) : theme.primaryBorder.opacity(0.3))
            .frame(width: isHovered ? 3 : 1)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.width
                    }
                    .onChanged { value in
                        // Dragging left increases width, dragging right decreases
                        let newWidth = width - value.translation.width
                        width = min(maxWidth, max(minWidth, newWidth))
                    }
            )
            .animation(theme.animationQuick(), value: isHovered)
    }
}

// MARK: - Shared Header Components
// HeaderActionButton, ModeToggleButton, ModeIndicatorBadge are now in SharedHeaderComponents.swift

// MARK: - Artifact Viewer Sheet

struct ArtifactViewerSheet: View {
    let artifact: Artifact
    let onDownload: () -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var isCopied = false
    @State private var showRawSource = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                // File icon and name
                HStack(spacing: 8) {
                    Image(systemName: artifact.contentType == .markdown ? "doc.richtext" : "doc.text")
                        .font(.system(size: 16))
                        .foregroundColor(theme.accentColor)

                    Text(artifact.filename)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                }

                Spacer()

                // View toggle (for markdown)
                if artifact.contentType == .markdown {
                    Picker("", selection: $showRawSource) {
                        Text("Rendered").tag(false)
                        Text("Source").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                // Action buttons
                HStack(spacing: 8) {
                    // Copy button
                    Button {
                        copyToClipboard()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                            Text(isCopied ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(isCopied ? theme.successColor : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground.opacity(0.5))
                        )
                    }
                    .buttonStyle(.plain)

                    // Download menu
                    Menu {
                        Button {
                            onDownload()
                        } label: {
                            Label("Download as Markdown", systemImage: "doc.text")
                        }

                        if artifact.contentType == .markdown {
                            Button {
                                exportAsPDF()
                            } label: {
                                Label("Download as PDF", systemImage: "doc.richtext")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11))
                            Text("Download")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.accentColor.opacity(0.1))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)

                    // Close button
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(theme.tertiaryBackground.opacity(0.5))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(theme.secondaryBackground.opacity(0.5))

            Divider()
                .background(theme.primaryBorder.opacity(0.2))

            // Content
            GeometryReader { geometry in
                ScrollView {
                    if artifact.contentType == .markdown && !showRawSource {
                        // Rendered markdown view
                        MarkdownMessageView(
                            text: artifact.content,
                            baseWidth: min(geometry.size.width - 80, 700)
                        )
                        .padding(40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Raw source view
                        Text(artifact.content)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 900, maxWidth: 1200)
        .frame(minHeight: 500, idealHeight: 700, maxHeight: 900)
        .background(theme.primaryBackground)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(artifact.content, forType: .string)
        isCopied = true

        // Reset after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }

    private func exportAsPDF() {
        // Create save panel
        let panel = NSSavePanel()
        let baseName = (artifact.filename as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(baseName).pdf"
        panel.allowedContentTypes = [.pdf]

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            // Generate PDF from markdown
            generatePDF(to: url)
        }
    }

    private func generatePDF(to url: URL) {
        // Use NSAttributedString for reliable PDF generation
        let pdfWidth: CGFloat = 612  // US Letter width
        let pdfHeight: CGFloat = 792  // US Letter height
        let margin: CGFloat = 72  // 1 inch margins
        let contentWidth = pdfWidth - (margin * 2)

        // Convert markdown to attributed string
        let attributedString = markdownToAttributedString(artifact.content)

        // Create PDF context
        var mediaBox = CGRect(x: 0, y: 0, width: pdfWidth, height: pdfHeight)

        guard let consumer = CGDataConsumer(url: url as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            print("[ArtifactViewerSheet] Failed to create PDF context")
            return
        }

        // Calculate text layout
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        var currentPosition = 0
        let pageContentHeight = pdfHeight - (margin * 2)

        while currentPosition < attributedString.length {
            context.beginPDFPage(nil)

            // Create frame for this page (CoreText uses bottom-left origin)
            let framePath = CGPath(
                rect: CGRect(x: margin, y: margin, width: contentWidth, height: pageContentHeight),
                transform: nil
            )

            let frameRange = CFRangeMake(currentPosition, 0)
            let frame = CTFramesetterCreateFrame(framesetter, frameRange, framePath, nil)

            // Draw the frame
            CTFrameDraw(frame, context)

            // Get the visible range to advance position
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            currentPosition += max(visibleRange.length, 1)

            context.endPDFPage()

            // Safety: prevent infinite loop
            if visibleRange.length == 0 {
                break
            }
        }

        context.closePDF()
        print("[ArtifactViewerSheet] PDF saved to \(url.path)")
    }

    private func markdownToAttributedString(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Default paragraph style
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 12

        let defaultFont = NSFont.systemFont(ofSize: 12)
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: defaultFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle,
        ]

        let headingFont = NSFont.boldSystemFont(ofSize: 18)
        let subheadingFont = NSFont.boldSystemFont(ofSize: 14)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockContent: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Handle code blocks
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    // End code block
                    let codeText = codeBlockContent.joined(separator: "\n")
                    result.append(
                        NSAttributedString(
                            string: codeText + "\n\n",
                            attributes: [
                                .font: codeFont,
                                .foregroundColor: NSColor.darkGray,
                                .paragraphStyle: paragraphStyle,
                            ]
                        )
                    )
                    codeBlockContent = []
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBlockContent.append(line)
                continue
            }

            // Headings
            if trimmed.hasPrefix("# ") {
                let text = String(trimmed.dropFirst(2))
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: [
                            .font: headingFont,
                            .foregroundColor: NSColor.black,
                            .paragraphStyle: paragraphStyle,
                        ]
                    )
                )
            } else if trimmed.hasPrefix("## ") {
                let text = String(trimmed.dropFirst(3))
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: [
                            .font: subheadingFont,
                            .foregroundColor: NSColor.black,
                            .paragraphStyle: paragraphStyle,
                        ]
                    )
                )
            } else if trimmed.hasPrefix("### ") || trimmed.hasPrefix("#### ") {
                let dropCount = trimmed.hasPrefix("### ") ? 4 : 5
                let text = String(trimmed.dropFirst(dropCount))
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: [
                            .font: NSFont.boldSystemFont(ofSize: 12),
                            .foregroundColor: NSColor.black,
                            .paragraphStyle: paragraphStyle,
                        ]
                    )
                )
            }
            // List items
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let text = String(trimmed.dropFirst(2))
                result.append(NSAttributedString(string: "• " + text + "\n", attributes: defaultAttrs))
            }
            // Numbered lists
            else if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let text = String(trimmed[match.upperBound...])
                let number = String(trimmed[..<match.upperBound])
                result.append(NSAttributedString(string: number + text + "\n", attributes: defaultAttrs))
            }
            // Empty line
            else if trimmed.isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: defaultAttrs))
            }
            // Regular text - strip markdown formatting
            else {
                var text = trimmed
                // Remove bold/italic markers for PDF
                text = text.replacingOccurrences(of: "**", with: "")
                text = text.replacingOccurrences(of: "__", with: "")
                text = text.replacingOccurrences(of: "*", with: "")
                text = text.replacingOccurrences(of: "_", with: "")
                result.append(NSAttributedString(string: text + "\n", attributes: defaultAttrs))
            }
        }

        return result
    }
}
