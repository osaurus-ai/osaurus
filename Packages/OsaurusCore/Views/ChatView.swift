//
//  ChatView.swift
//  osaurus
//
//  Created by Terence on 10/26/25.
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class ChatSession: ObservableObject {
    @Published var turns: [ChatTurn] = []
    @Published var isStreaming: Bool = false
    @Published var input: String = ""
    @Published var pendingImages: [Data] = []
    @Published var selectedModel: String? = nil
    @Published var modelOptions: [String] = []
    @Published var scrollTick: Int = 0
    @Published var hasAnyModel: Bool = false
    private var currentTask: Task<Void, Never>?
    private var remoteModelsObserver: NSObjectProtocol?

    init() {
        // Build initial options list
        var opts: [String] = []
        if FoundationModelService.isDefaultModelAvailable() {
            opts.append("foundation")
        }
        opts.append(contentsOf: MLXService.getAvailableModels())
        // Add remote provider models
        let remoteModels = RemoteProviderManager.shared.cachedAvailableModels()
        for providerModels in remoteModels {
            opts.append(contentsOf: providerModels.models)
        }
        modelOptions = opts
        selectedModel = opts.first
        hasAnyModel = !opts.isEmpty

        // Listen for remote provider model changes
        remoteModelsObserver = NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshModelOptions()
            }
        }
    }

    func refreshModelOptions() {
        var opts: [String] = []

        // Add foundation model first if available
        if FoundationModelService.isDefaultModelAvailable() {
            opts.append("foundation")
        }

        // Add local MLX models
        let mlx = MLXService.getAvailableModels()
        opts.append(contentsOf: mlx)

        // Add remote provider models
        let remoteModels = RemoteProviderManager.shared.cachedAvailableModels()
        for providerModels in remoteModels {
            opts.append(contentsOf: providerModels.models)
        }

        let prev = selectedModel
        let newSelected = (prev != nil && opts.contains(prev!)) ? prev : opts.first
        let newHasAnyModel = !opts.isEmpty
        if modelOptions == opts && selectedModel == newSelected && hasAnyModel == newHasAnyModel { return }
        modelOptions = opts
        selectedModel = newSelected
        hasAnyModel = newHasAnyModel
    }

    /// Check if the currently selected model supports images (VLM)
    var selectedModelSupportsImages: Bool {
        guard let model = selectedModel else { return false }
        // Foundation models don't support images yet
        if model.lowercased() == "foundation" { return false }
        return ModelManager.isVisionModel(named: model)
    }

    /// Filtered turns excluding tool messages (cached computation)
    var visibleTurns: [ChatTurn] {
        turns.filter { $0.role != .tool }
    }

    func sendCurrent() {
        guard !isStreaming else { return }
        let text = input
        let images = pendingImages
        input = ""
        pendingImages = []
        send(text, images: images)
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
    }

    func reset() {
        stop()
        turns.removeAll()
        input = ""
        pendingImages = []
    }

    func send(_ text: String, images: [Data] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow sending with just images
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        turns.append(ChatTurn(role: .user, content: trimmed, images: images))

        currentTask = Task { @MainActor in
            isStreaming = true
            ServerController.signalGenerationStart()
            defer {
                isStreaming = false
                ServerController.signalGenerationEnd()
            }

            let assistantTurn = ChatTurn(role: .assistant, content: "")
            turns.append(assistantTurn)
            do {
                let engine = ChatEngine(source: .chatUI)
                let chatCfg = ChatConfigurationStore.load()
                let sys = chatCfg.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                let toolSpecs = ToolRegistry.shared.specs()

                @MainActor
                func buildMessages() -> [ChatMessage] {
                    var msgs: [ChatMessage] = []
                    if !sys.isEmpty { msgs.append(ChatMessage(role: "system", content: sys)) }
                    for (index, t) in turns.enumerated() {
                        switch t.role {
                        case .assistant:
                            // Skip the last assistant turn if it's empty (it's the streaming placeholder)
                            let isLastTurn = index == turns.count - 1
                            if isLastTurn && t.content.isEmpty && t.toolCalls == nil {
                                continue
                            }
                            // For assistant messages with tool_calls but no content, use empty string
                            // OpenAI API rejects null content
                            let content = t.content.isEmpty ? (t.toolCalls != nil ? "" : nil) : t.content
                            msgs.append(
                                ChatMessage(
                                    role: "assistant",
                                    content: content,
                                    tool_calls: t.toolCalls,
                                    tool_call_id: nil
                                )
                            )
                        case .tool:
                            msgs.append(
                                ChatMessage(
                                    role: "tool",
                                    content: t.content,
                                    tool_calls: nil,
                                    tool_call_id: t.toolCallId
                                )
                            )
                        case .user:
                            // Include images if present
                            if t.hasImages {
                                msgs.append(ChatMessage(role: "user", text: t.content, imageData: t.attachedImages))
                            } else {
                                msgs.append(ChatMessage(role: t.role.rawValue, content: t.content))
                            }
                        default:
                            msgs.append(ChatMessage(role: t.role.rawValue, content: t.content))
                        }
                    }
                    return msgs
                }

                let maxAttempts = max(chatCfg.maxToolAttempts ?? 3, 1)
                var attempts = 0
                outer: while attempts < maxAttempts {
                    attempts += 1
                    let req = ChatCompletionRequest(
                        model: selectedModel ?? "default",
                        messages: buildMessages(),
                        temperature: chatCfg.temperature ?? 0.7,
                        max_tokens: chatCfg.maxTokens ?? 1024,
                        stream: true,
                        top_p: chatCfg.topPOverride,
                        frequency_penalty: nil,
                        presence_penalty: nil,
                        stop: nil,
                        n: nil,
                        tools: toolSpecs,
                        tool_choice: .auto,
                        session_id: nil
                    )
                    do {
                        let stream = try await engine.streamChat(request: req)
                        for try await delta in stream {
                            if Task.isCancelled { break outer }
                            if !delta.isEmpty {
                                assistantTurn.content += delta
                                scrollTick &+= 1
                            }
                        }
                        break  // finished normally
                    } catch let inv as ServiceToolInvocation {
                        // Create OpenAI-style tool call id
                        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        let callId = "call_" + String(raw.prefix(24))
                        let call = ToolCall(
                            id: callId,
                            type: "function",
                            function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments)
                        )
                        if assistantTurn.toolCalls == nil { assistantTurn.toolCalls = [] }
                        assistantTurn.toolCalls!.append(call)

                        // Execute tool and append hidden tool result turn
                        let resultText: String
                        do {
                            resultText = try await ToolRegistry.shared.execute(
                                name: inv.toolName,
                                argumentsJSON: inv.jsonArguments
                            )
                        } catch {
                            // Store rejection/error as the result so UI shows "Rejected" instead of hanging
                            let rejectionMessage = "[REJECTED] \(error.localizedDescription)"
                            assistantTurn.toolResults[callId] = rejectionMessage
                            let toolTurn = ChatTurn(role: .tool, content: rejectionMessage)
                            toolTurn.toolCallId = callId
                            turns.append(toolTurn)
                            break  // Stop tool loop on rejection
                        }
                        assistantTurn.toolResults[callId] = resultText
                        let toolTurn = ChatTurn(role: .tool, content: resultText)
                        toolTurn.toolCallId = callId
                        turns.append(toolTurn)
                        // Continue loop with new history
                        continue
                    }
                }
            } catch {
                assistantTurn.content = "Error: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - ChatView

struct ChatView: View {
    @EnvironmentObject var server: ServerController
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var session = ChatSession()
    @Environment(\.colorScheme) private var colorScheme

    @State private var focusTrigger: Int = 0
    @State private var isPinnedToBottom: Bool = true
    @State private var hostWindow: NSWindow?
    @State private var keyMonitor: Any?
    @State private var isHeaderHovered: Bool = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        GeometryReader { proxy in
            let containerWidth = proxy.size.width

            ZStack {
                // Background
                chatBackground

                // Main content
                VStack(spacing: 0) {
                    // Header
                    chatHeader

                    // Content area
                    if session.hasAnyModel {
                        if session.turns.isEmpty {
                            // Empty state
                            ChatEmptyState(
                                hasModels: true,
                                selectedModel: session.selectedModel,
                                onOpenModelManager: {
                                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                                },
                                onUseFoundation: FoundationModelService.isDefaultModelAvailable()
                                    ? {
                                        session.selectedModel = "foundation"
                                    } : nil,
                                onQuickAction: { prompt in
                                    session.input = prompt
                                }
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        } else {
                            // Message thread
                            messageThread(containerWidth)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        // Floating input card
                        FloatingInputCard(
                            text: $session.input,
                            selectedModel: $session.selectedModel,
                            pendingImages: $session.pendingImages,
                            modelOptions: session.modelOptions,
                            isStreaming: session.isStreaming,
                            supportsImages: session.selectedModelSupportsImages,
                            onSend: { session.sendCurrent() },
                            onStop: { session.stop() }
                        )
                    } else {
                        // No models empty state
                        ChatEmptyState(
                            hasModels: false,
                            selectedModel: nil,
                            onOpenModelManager: {
                                AppDelegate.shared?.showManagementWindow(initialTab: .models)
                            },
                            onUseFoundation: FoundationModelService.isDefaultModelAvailable()
                                ? {
                                    session.selectedModel = "foundation"
                                } : nil,
                            onQuickAction: { _ in }
                        )
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.turns.isEmpty)
            }
        }
        .frame(
            minWidth: 700,
            idealWidth: 900,
            maxWidth: .infinity,
            minHeight: session.turns.isEmpty ? 490 : 550,
            idealHeight: session.turns.isEmpty ? 550 : 700,
            maxHeight: .infinity
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            closeButton
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: session.turns.isEmpty)
        .background(WindowAccessor(window: $hostWindow))
        .onExitCommand { AppDelegate.shared?.closeChatOverlay() }
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            focusTrigger &+= 1
            isPinnedToBottom = true
            session.refreshModelOptions()
        }
        .onAppear {
            setupKeyMonitor()
            session.refreshModelOptions()
        }
        .onDisappear {
            cleanupKeyMonitor()
        }
        .onChange(of: session.turns.isEmpty) { _, newValue in
            resizeWindowForContent(isEmpty: newValue)
        }
        .environment(\.theme, themeManager.currentTheme)
    }

    // MARK: - Background

    private var chatBackground: some View {
        ZStack {
            // Base glass surface
            GlassSurface(cornerRadius: 24)
                .allowsHitTesting(false)

            // Gradient overlay for depth - stronger in light mode for text contrast
            LinearGradient(
                colors: [
                    theme.primaryBackground.opacity(colorScheme == .dark ? 0.3 : 0.6),
                    theme.primaryBackground.opacity(colorScheme == .dark ? 0.1 : 0.4),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 12) {
            // Model indicator
            if let model = session.selectedModel, session.modelOptions.count <= 1 {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(displayModelName(model))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(theme.secondaryBackground.opacity(0.6))
                )
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                if !session.turns.isEmpty {
                    // New chat button
                    HeaderActionButton(
                        icon: "plus",
                        help: "New chat",
                        action: { session.reset() }
                    )
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 56)  // Leave room for close button
        .padding(.top, 16)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHeaderHovered = hovering
        }
    }

    private var closeButton: some View {
        CloseButton(action: { AppDelegate.shared?.closeChatOverlay() })
            .padding(16)
    }

    // MARK: - Message Thread

    private func messageThread(_ width: CGFloat) -> some View {
        let visible = session.visibleTurns
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, turn in
                        let isLatest = index == visible.count - 1

                        MessageRow(
                            turn: turn,
                            width: width,
                            isStreaming: session.isStreaming,
                            isLatest: isLatest,
                            onCopy: copyToPasteboard
                        )
                        .padding(.horizontal, 16)
                    }

                    // Bottom anchor
                    Color.clear
                        .frame(height: 1)
                        .id("BOTTOM")
                        .onAppear { isPinnedToBottom = true }
                        .onDisappear { isPinnedToBottom = false }
                }
                .padding(.vertical, 8)
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottomTrailing) {
                scrollToBottomButton(proxy: proxy)
            }
            .onChange(of: session.turns.count) { _, _ in
                if isPinnedToBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
            }
            .onChange(of: session.scrollTick) { _, _ in
                if isPinnedToBottom {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
                proxy.scrollTo("BOTTOM", anchor: .bottom)
                isPinnedToBottom = true
            }
        }
    }

    @ViewBuilder
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        if !isPinnedToBottom && !session.turns.isEmpty {
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
                isPinnedToBottom = true
            }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(theme.secondaryBackground)
                            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 2)
                    )
            }
            .buttonStyle(.plain)
            .padding(20)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private func displayModelName(_ raw: String?) -> String {
        guard let raw else { return "Model" }
        if raw.lowercased() == "foundation" { return "Foundation" }
        if let last = raw.split(separator: "/").last { return String(last) }
        return raw
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func resizeWindowForContent(isEmpty: Bool) {
        guard let window = hostWindow else { return }

        let targetHeight: CGFloat = isEmpty ? 500 : 700
        let currentFrame = window.frame

        let currentCenterY = currentFrame.origin.y + (currentFrame.height / 2)
        let currentCenterX = currentFrame.origin.x + (currentFrame.width / 2)

        let newFrame = NSRect(
            x: currentCenterX - (currentFrame.width / 2),
            y: currentCenterY - (targetHeight / 2),
            width: currentFrame.width,
            height: targetHeight
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        })
    }

    // Key monitor for Enter to send is now handled by FloatingInputCard
    private func setupKeyMonitor() {
        // No-op: key handling moved to FloatingInputCard for proper local state sync
    }

    private func cleanupKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

// MARK: - Header Action Button

private struct HeaderActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .help(help)
    }
}

// MARK: - Close Button

private struct CloseButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .help("Close")
    }
}

// MARK: - Window Accessor Helper

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in
            self.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil {
            Task { @MainActor in
                self.window = nsView.window
            }
        }
    }
}
