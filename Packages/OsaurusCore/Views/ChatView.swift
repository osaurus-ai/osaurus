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
    @Published var modelOptions: [ModelOption] = []
    @Published var scrollTick: Int = 0
    @Published var hasAnyModel: Bool = false

    // MARK: - Persistence Properties
    @Published var sessionId: UUID?
    @Published var title: String = "New Chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Tracks if session has unsaved content changes
    private var isDirty: Bool = false

    /// Callback when session needs to be saved (called after streaming completes)
    var onSessionChanged: (() -> Void)?

    private var currentTask: Task<Void, Never>?
    private var remoteModelsObserver: NSObjectProtocol?

    init() {
        // Build initial options list
        modelOptions = Self.buildModelOptions()
        hasAnyModel = !modelOptions.isEmpty

        // Use configured default model if available, otherwise use first available
        let chatConfig = ChatConfigurationStore.load()
        if let defaultModel = chatConfig.defaultModel,
            modelOptions.contains(where: { $0.id == defaultModel })
        {
            selectedModel = defaultModel
        } else {
            selectedModel = modelOptions.first?.id
        }

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

    /// Build rich model options from all sources
    private static func buildModelOptions() -> [ModelOption] {
        var options: [ModelOption] = []

        // Add foundation model first if available
        if FoundationModelService.isDefaultModelAvailable() {
            options.append(.foundation())
        }

        // Add local MLX models with rich metadata
        let localModels = ModelManager.discoverLocalModels()
        for model in localModels {
            options.append(.fromMLXModel(model))
        }

        // Add remote provider models
        let remoteModels = RemoteProviderManager.shared.cachedAvailableModels()
        for providerInfo in remoteModels {
            for modelId in providerInfo.models {
                options.append(
                    .fromRemoteModel(
                        modelId: modelId,
                        providerName: providerInfo.providerName,
                        providerId: providerInfo.providerId
                    )
                )
            }
        }

        return options
    }

    func refreshModelOptions() {
        let newOptions = Self.buildModelOptions()

        let prev = selectedModel
        let newSelected: String?
        if let prev = prev, newOptions.contains(where: { $0.id == prev }) {
            newSelected = prev
        } else {
            newSelected = newOptions.first?.id
        }
        let newHasAnyModel = !newOptions.isEmpty

        // Check if anything changed
        let optionIds = modelOptions.map { $0.id }
        let newOptionIds = newOptions.map { $0.id }
        if optionIds == newOptionIds && selectedModel == newSelected && hasAnyModel == newHasAnyModel {
            return
        }

        modelOptions = newOptions
        selectedModel = newSelected
        hasAnyModel = newHasAnyModel
    }

    /// Check if the currently selected model supports images (VLM)
    var selectedModelSupportsImages: Bool {
        guard let model = selectedModel else { return false }
        // Foundation models don't support images yet
        if model.lowercased() == "foundation" { return false }

        // Check ModelOption first
        if let option = modelOptions.first(where: { $0.id == model }) {
            // Remote models: assume they support images (many do, and we can't detect)
            if case .remote = option.source {
                return true
            }
            // Local models: check VLM status
            if option.isVLM {
                return true
            }
        }

        // Fall back to ModelManager detection for downloaded models
        return ModelManager.isVisionModel(named: model)
    }

    /// Get the currently selected ModelOption
    var selectedModelOption: ModelOption? {
        guard let model = selectedModel else { return nil }
        return modelOptions.first { $0.id == model }
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
        // Clear session identity for new chat
        sessionId = nil
        title = "New Chat"
        createdAt = Date()
        updatedAt = Date()
        isDirty = false

        // Apply configured default model for new chat
        let chatConfig = ChatConfigurationStore.load()
        if let defaultModel = chatConfig.defaultModel,
            modelOptions.contains(where: { $0.id == defaultModel })
        {
            selectedModel = defaultModel
        } else {
            selectedModel = modelOptions.first?.id
        }
    }

    // MARK: - Persistence Methods

    /// Convert current state to persistable data
    func toSessionData() -> ChatSessionData {
        let turnData = turns.map { ChatTurnData(from: $0) }
        return ChatSessionData(
            id: sessionId ?? UUID(),
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            selectedModel: selectedModel,
            turns: turnData
        )
    }

    /// Save current session state
    func save() {
        // Only save if there are turns
        guard !turns.isEmpty else { return }

        // Create session ID if this is a new session
        if sessionId == nil {
            sessionId = UUID()
            createdAt = Date()
            isDirty = true
        }

        // Only update timestamp if content actually changed
        if isDirty {
            updatedAt = Date()
            isDirty = false
        }

        // Auto-generate title from first user message if still default
        if title == "New Chat" {
            let turnData = turns.map { ChatTurnData(from: $0) }
            title = ChatSessionData.generateTitle(from: turnData)
        }

        let data = toSessionData()
        ChatSessionStore.save(data)
        onSessionChanged?()
    }

    /// Load session from persisted data
    func load(from data: ChatSessionData) {
        stop()
        sessionId = data.id
        title = data.title
        createdAt = data.createdAt
        updatedAt = data.updatedAt

        // Restore saved model if available, otherwise use configured default
        if let savedModel = data.selectedModel,
            modelOptions.contains(where: { $0.id == savedModel })
        {
            selectedModel = savedModel
        } else {
            // Fall back to configured default model or first available
            let chatConfig = ChatConfigurationStore.load()
            if let defaultModel = chatConfig.defaultModel,
                modelOptions.contains(where: { $0.id == defaultModel })
            {
                selectedModel = defaultModel
            } else {
                selectedModel = modelOptions.first?.id
            }
        }

        turns = data.turns.map { ChatTurn(from: $0) }
        input = ""
        pendingImages = []
        isDirty = false  // Fresh load, not dirty
    }

    /// Edit a user message and regenerate from that point
    func editAndRegenerate(turnId: UUID, newContent: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnId }) else { return }
        guard turns[index].role == .user else { return }

        // Update the content
        turns[index].content = newContent

        // Remove all turns after this one
        turns = Array(turns.prefix(index + 1))

        // Mark as dirty and save
        isDirty = true
        save()
        send("")  // Empty send to trigger regeneration with existing history
    }

    /// Delete a turn and all subsequent turns
    func deleteTurn(id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns = Array(turns.prefix(index))
        isDirty = true
        save()
    }

    /// Regenerate an assistant response (removes it and regenerates)
    func regenerate(turnId: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnId }) else { return }
        guard turns[index].role == .assistant else { return }

        // Remove this turn and all subsequent turns
        turns = Array(turns.prefix(index))
        isDirty = true

        // Regenerate
        send("")
    }

    func send(_ text: String, images: [Data] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow sending with just images, or regenerating from existing history
        let isRegeneration = trimmed.isEmpty && images.isEmpty && !turns.isEmpty
        guard !trimmed.isEmpty || !images.isEmpty || isRegeneration else { return }

        // Only append user turn if there's actual content
        if !trimmed.isEmpty || !images.isEmpty {
            turns.append(ChatTurn(role: .user, content: trimmed, images: images))
            isDirty = true

            // Immediately save new session so it appears in sidebar
            if sessionId == nil {
                sessionId = UUID()
                createdAt = Date()
                updatedAt = Date()
                isDirty = false  // Already set updatedAt
                // Auto-generate title from first user message
                let turnData = turns.map { ChatTurnData(from: $0) }
                title = ChatSessionData.generateTitle(from: turnData)
                let data = toSessionData()
                ChatSessionStore.save(data)
                onSessionChanged?()
            }
        }

        currentTask = Task { @MainActor in
            isStreaming = true
            ServerController.signalGenerationStart()
            defer {
                isStreaming = false
                ServerController.signalGenerationEnd()
                // Auto-save after streaming completes
                save()
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

                let maxAttempts = max(chatCfg.maxToolAttempts ?? 15, 1)
                var attempts = 0
                outer: while attempts < maxAttempts {
                    attempts += 1
                    let req = ChatCompletionRequest(
                        model: selectedModel ?? "default",
                        messages: buildMessages(),
                        temperature: chatCfg.temperature,
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
                        // Use preserved tool call ID from stream if available, otherwise generate one
                        let callId: String
                        if let preservedId = inv.toolCallId, !preservedId.isEmpty {
                            callId = preservedId
                        } else {
                            let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                            callId = "call_" + String(raw.prefix(24))
                        }
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
    @StateObject private var sessionsManager = ChatSessionsManager.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var focusTrigger: Int = 0
    @State private var isPinnedToBottom: Bool = true
    @State private var hostWindow: NSWindow?
    @State private var keyMonitor: Any?
    @State private var isHeaderHovered: Bool = false
    @State private var showSidebar: Bool = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        GeometryReader { proxy in
            let sidebarWidth: CGFloat = showSidebar ? 240 : 0
            let chatWidth = proxy.size.width - sidebarWidth

            HStack(spacing: 0) {
                // Sidebar
                if showSidebar {
                    ChatSessionSidebar(
                        manager: sessionsManager,
                        currentSessionId: session.sessionId,
                        onSelect: { data in
                            // Don't reload if already on this session
                            guard data.id != session.sessionId else { return }
                            // Save current session before switching
                            if !session.turns.isEmpty {
                                session.save()
                            }
                            // Load fresh data from store
                            if let freshData = ChatSessionStore.load(id: data.id) {
                                session.load(from: freshData)
                            } else {
                                session.load(from: data)
                            }
                            isPinnedToBottom = true
                        },
                        onNewChat: {
                            // Save current and create new
                            if !session.turns.isEmpty {
                                session.save()
                            }
                            session.reset()
                        },
                        onDelete: { id in
                            sessionsManager.delete(id: id)
                            // If we deleted the current session, reset
                            if session.sessionId == id {
                                session.reset()
                            }
                        },
                        onRename: { id, title in
                            sessionsManager.rename(id: id, title: title)
                        }
                    )
                    .transition(.move(edge: .leading))
                }

                // Main chat area
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
                                messageThread(chatWidth)
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
                    .animation(theme.springAnimation(), value: session.turns.isEmpty)
                }
            }
        }
        .frame(
            minWidth: 800,
            idealWidth: 950,
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
        .animation(theme.animationMedium(), value: session.turns.isEmpty)
        .animation(theme.animationQuick(), value: showSidebar)
        .background(WindowAccessor(window: $hostWindow))
        .onExitCommand { AppDelegate.shared?.closeChatOverlay() }
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            focusTrigger &+= 1
            isPinnedToBottom = true
            session.refreshModelOptions()
            sessionsManager.refresh()
        }
        .onAppear {
            setupKeyMonitor()
            session.refreshModelOptions()
            sessionsManager.refresh()
            // Set up callback for session changes
            session.onSessionChanged = { [weak sessionsManager] in
                sessionsManager?.refresh()
            }
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
            // Use custom theme's background settings
            switch customTheme.background.type {
            case .solid:
                let color = Color(themeHex: customTheme.background.solidColor ?? customTheme.colors.primaryBackground)
                color

            case .gradient:
                let colors = (customTheme.background.gradientColors ?? ["#000000", "#333333"])
                    .map { Color(themeHex: $0) }
                LinearGradient(
                    colors: colors,
                    startPoint: .top,
                    endPoint: .bottom
                )

            case .image:
                if let image = customTheme.background.decodedImage() {
                    ZStack {
                        backgroundImageView(
                            image: image,
                            fit: customTheme.background.imageFit ?? .fill,
                            opacity: customTheme.background.imageOpacity ?? 1.0
                        )

                        // Overlay if configured
                        if let overlayHex = customTheme.background.overlayColor {
                            Color(themeHex: overlayHex)
                                .opacity(customTheme.background.overlayOpacity ?? 0.5)
                        }
                    }
                } else {
                    // Fallback to primary background if image fails to load
                    Color(themeHex: customTheme.colors.primaryBackground)
                }
            }
        } else {
            // Default theme - use primary background with transparency for glass
            theme.primaryBackground
        }
    }

    @ViewBuilder
    private func backgroundImageView(image: NSImage, fit: ThemeBackground.ImageFit, opacity: Double) -> some View {
        GeometryReader { geo in
            switch fit {
            case .fill:
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .opacity(opacity)
            case .fit:
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(opacity)
            case .stretch:
                Image(nsImage: image)
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(opacity)
            case .tile:
                // Tile the image
                tiledImage(image: image, size: geo.size)
                    .opacity(opacity)
            }
        }
    }

    private func tiledImage(image: NSImage, size: CGSize) -> some View {
        let imageSize = image.size
        let cols = Int(ceil(size.width / imageSize.width))
        let rows = Int(ceil(size.height / imageSize.height))

        return VStack(spacing: 0) {
            ForEach(0 ..< rows, id: \.self) { _ in
                HStack(spacing: 0) {
                    ForEach(0 ..< cols, id: \.self) { _ in
                        Image(nsImage: image)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 12) {
            // Sidebar toggle
            HeaderActionButton(
                icon: showSidebar ? "sidebar.left" : "sidebar.left",
                help: showSidebar ? "Hide sidebar" : "Show sidebar",
                action: {
                    withAnimation(theme.animationQuick()) {
                        showSidebar.toggle()
                    }
                }
            )

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
                        action: {
                            // Save current session before creating new
                            session.save()
                            session.reset()
                        }
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
                            onCopy: copyToPasteboard,
                            onEdit: { turnId, newContent in
                                session.editAndRegenerate(turnId: turnId, newContent: newContent)
                            },
                            onRegenerate: { turnId in
                                session.regenerate(turnId: turnId)
                            }
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
                    withAnimation(theme.animationQuick()) {
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
            }
            .onChange(of: session.scrollTick) { _, _ in
                if isPinnedToBottom {
                    withAnimation(theme.animationQuick()) {
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
                withAnimation(theme.springAnimation()) {
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
            withAnimation(theme.animationQuick()) {
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
            withAnimation(theme.animationQuick()) {
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
