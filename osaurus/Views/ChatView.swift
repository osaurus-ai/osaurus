//
//  ChatView.swift
//  osaurus
//
//  Created by Assistant on 10/26/25.
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class ChatSession: ObservableObject {
  @Published var turns: [(role: MessageRole, content: String)] = []
  @Published var isStreaming: Bool = false
  @Published var input: String = ""
  @Published var selectedModel: String? = nil
  @Published var modelOptions: [String] = []
  @Published var scrollTick: Int = 0
  private var currentTask: Task<Void, Never>?

  init() {
    // Build options list (foundation first if available)
    var opts: [String] = []
    if FoundationModelService.isDefaultModelAvailable() {
      opts.append("foundation")
    }
    let mlx = MLXService.getAvailableModels()
    opts.append(contentsOf: mlx)
    modelOptions = opts
    // Leave selectedModel nil to let router pick foundation or first MLX
  }

  func sendCurrent() {
    guard !isStreaming else { return }
    let text = input
    input = ""
    send(text)
  }

  func stop() {
    currentTask?.cancel()
    currentTask = nil
  }

  func reset() {
    stop()
    turns.removeAll()
    input = ""
  }

  func send(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    turns.append((.user, trimmed))

    let messages = turns.map { Message(role: $0.role, content: $0.content) }
    let prompt = PromptBuilder.buildPrompt(from: messages)

    currentTask = Task { @MainActor in
      isStreaming = true
      ServerController.signalGenerationStart()
      defer {
        isStreaming = false
        ServerController.signalGenerationEnd()
      }

      let services: [ModelService] = [FoundationModelService(), MLXService.shared]
      let installed = MLXService.getAvailableModels()
      switch ModelServiceRouter.resolve(
        requestedModel: selectedModel,
        installedModels: installed,
        services: services
      ) {
      case .none:
        turns.append((.assistant, "No model available. Open Model Manager to download one."))
        return
      case .service(let svc, _):
        turns.append((.assistant, ""))
        let idx = turns.count - 1
        let params = GenerationParameters(temperature: 0.7, maxTokens: 1024)
        do {
          let stream = try await svc.streamDeltas(prompt: prompt, parameters: params)
          for await delta in stream {
            if Task.isCancelled { break }
            if !delta.isEmpty {
              turns[idx].content += delta
              // Signal UI to autoscroll while streaming
              scrollTick &+= 1
            }
          }
        } catch {
          turns[idx].content = "Error: \(error.localizedDescription)"
        }
      }
    }
  }
}

struct ChatView: View {
  @EnvironmentObject var server: ServerController
  @Environment(\.theme) private var theme
  @StateObject private var session = ChatSession()
  // Using AppKit-backed text view to handle Enter vs Shift+Enter
  @State private var focusTrigger: Int = 0

  var body: some View {
    ZStack {
      // Subtle material-like background using theme color
      theme.primaryBackground.opacity(0.95)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

      VStack(spacing: 8) {
        header
        if hasAnyModel {
          conversation
          inputBar
        } else {
          emptyState
        }
      }
      .padding(12)
    }
    .frame(width: 720, height: 560)
    .onExitCommand { AppDelegate.shared?.closeChatOverlay() }
    .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
      focusTrigger &+= 1
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("Chat")
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundColor(theme.primaryText)
      Spacer()
      if session.modelOptions.count > 1 {
        Picker("Model", selection: $session.selectedModel) {
          ForEach(session.modelOptions, id: \.self) { name in
            Text(name).tag(Optional(name))
          }
          Text("Auto").tag(Optional<String>.none)
        }
        .labelsHidden()
        .frame(width: 140)
        .help("Select model (Auto picks Foundation or first MLX)")
      }
      if session.isStreaming {
        Button(action: { session.stop() }) {
          Image(systemName: "stop.circle")
        }
        .buttonStyle(.plain)
        .help("Stop")
      }
      if !session.turns.isEmpty {
        Button(action: { session.reset() }) {
          Image(systemName: "trash")
        }
        .buttonStyle(.plain)
        .help("Reset chat")
      }
    }
  }

  private var conversation: some View {
    ScrollViewReader { proxy in
      @State var hasInitialScroll = false
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(Array(session.turns.enumerated()), id: \.offset) { item in
            let turn = item.element
            VStack(alignment: .leading, spacing: 4) {
              Text(turn.role == .user ? "You" : "Assistant")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
              Text(turn.content)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(theme.secondaryBackground.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
          Color.clear.frame(height: 1).id("BOTTOM")
        }
        .padding(2)
      }
      .onChange(of: session.turns.count) { _ in
        if hasInitialScroll {
          withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
        } else {
          proxy.scrollTo("BOTTOM", anchor: .bottom)
          hasInitialScroll = true
        }
      }
      .onChange(of: session.scrollTick) { _ in
        withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
      }
      .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
        proxy.scrollTo("BOTTOM", anchor: .bottom)
        hasInitialScroll = true
      }
    }
  }

  private var inputBar: some View {
    VStack(spacing: 6) {
      MultilineTextView(
        text: $session.input, focusTrigger: $focusTrigger, onCommit: { session.sendCurrent() }
      )
      .frame(minHeight: 60, maxHeight: 120)
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(theme.tertiaryText.opacity(0.2), lineWidth: 1)
      )
      .background(theme.primaryBackground)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      HStack(spacing: 8) {
        Spacer()
        Button(action: { session.sendCurrent() }) {
          Text("Send")
        }
        .keyboardShortcut(.return, modifiers: [.command])
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Text("No local models found")
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(theme.primaryText)
      Text("Download an MLX model or use the Foundation model if available.")
        .font(.system(size: 12))
        .foregroundColor(theme.secondaryText)
      HStack(spacing: 8) {
        Button("Open Model Manager") {
          AppDelegate.shared?.showModelManagerWindow()
        }
        if FoundationModelService.isDefaultModelAvailable() {
          Button("Use Foundation") {
            session.selectedModel = nil
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private var hasAnyModel: Bool {
    FoundationModelService.isDefaultModelAvailable() || !MLXService.getAvailableModels().isEmpty
  }
}

// MARK: - AppKit-backed Multiline Text View with Enter to send
struct MultilineTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var focusTrigger: Int
  var onCommit: () -> Void

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true

    let tv = CommitInterceptTextView()
    tv.delegate = context.coordinator
    tv.isRichText = false
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.font = NSFont.systemFont(ofSize: 13)
    tv.backgroundColor = .clear
    tv.textColor = NSColor.labelColor
    tv.string = text
    tv.commitHandler = onCommit
    tv.minSize = NSSize(width: 0, height: 60)
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 120)
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.textContainerInset = NSSize(width: 6, height: 6)
    tv.textContainer?.containerSize = NSSize(
      width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    tv.textContainer?.widthTracksTextView = true

    scroll.documentView = tv
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    if let tv = nsView.documentView as? CommitInterceptTextView {
      if tv.string != text { tv.string = text }
      tv.commitHandler = onCommit
      if context.coordinator.lastFocusTrigger != focusTrigger {
        context.coordinator.lastFocusTrigger = focusTrigger
        // Try focusing immediately, then again on the next runloop to handle first-show timing
        nsView.window?.makeFirstResponder(tv)
        DispatchQueue.main.async {
          nsView.window?.makeFirstResponder(tv)
        }
      }
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: MultilineTextView
    var lastFocusTrigger: Int = 0
    init(_ parent: MultilineTextView) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let tv = notification.object as? NSTextView else { return }
      parent.text = tv.string
    }
  }

  final class CommitInterceptTextView: NSTextView {
    var commitHandler: (() -> Void)?
    override func keyDown(with event: NSEvent) {
      let isReturn = (event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter)
      if isReturn {
        let hasShift = event.modifierFlags.contains(.shift)
        let hasCommand = event.modifierFlags.contains(.command)
        if hasShift {
          // Insert newline
          self.insertNewline(nil)
          return
        }
        if hasCommand || !hasCommand {
          // Command-Return or plain Return: commit
          commitHandler?()
          return
        }
      }
      super.keyDown(with: event)
    }
  }
}
