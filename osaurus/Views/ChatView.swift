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
  @State private var isPinnedToBottom: Bool = true
  @State private var inputIsFocused: Bool = false

  var body: some View {
    GeometryReader { proxy in
      let containerWidth = proxy.size.width
      ZStack(alignment: .bottomTrailing) {
        // HUD-style glass background
        GlassBackground(cornerRadius: 16)
          .allowsHitTesting(false)
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(theme.glassTintOverlay)
          .allowsHitTesting(false)

        VStack(spacing: 10) {
          header(containerWidth)
          if hasAnyModel {
            conversation(containerWidth)
            inputBar(containerWidth)
          } else {
            emptyState
          }
        }
        .padding(14)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
    }
    .frame(
      minWidth: 560, idealWidth: 720, maxWidth: .infinity, minHeight: 420, idealHeight: 560,
      maxHeight: .infinity
    )
    .onExitCommand { AppDelegate.shared?.closeChatOverlay() }
    .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
      focusTrigger &+= 1
      isPinnedToBottom = true
    }
  }

  private func header(_ width: CGFloat) -> some View {
    HStack(spacing: 8) {
      Text("Chat")
        .font(Typography.title(width))
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

  private func conversation(_ width: CGFloat) -> some View {
    ScrollViewReader { proxy in
      @State var hasInitialScroll = false
      ZStack(alignment: .bottomTrailing) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(session.turns.enumerated()), id: \.offset) { item in
              let turn = item.element
              VStack(alignment: .leading, spacing: 6) {
                Text(turn.role == .user ? "You" : "Assistant")
                  .font(Typography.small(width))
                  .foregroundColor(theme.tertiaryText)

                ZStack(alignment: .topTrailing) {
                  MarkdownMessageView(text: turn.content, baseWidth: width)
                    .font(Typography.body(width))
                    .foregroundColor(theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                  if turn.role == .assistant {
                    Button(action: { copyToPasteboard(turn.content) }) {
                      Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .opacity(0.0)
                    .help("Copy message")
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
              .background(
                (turn.role == .user
                  ? theme.secondaryBackground.opacity(0.28)
                  : theme.secondaryBackground.opacity(0.35))
              )
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay(alignment: .topTrailing) {
                if turn.role == .assistant {
                  Button(action: { copyToPasteboard(turn.content) }) {
                    Image(systemName: "doc.on.doc")
                  }
                  .buttonStyle(.borderless)
                  .padding(6)
                  .background(Color.black.opacity(0.25))
                  .clipShape(Capsule())
                  .opacity(0)
                  .accessibilityLabel("Copy message")
                  .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                      // Fade in/out on hover via layer-backed opacity
                    }
                  }
                }
              }
            }
            Color.clear
              .frame(height: 1)
              .id("BOTTOM")
              .onAppear { isPinnedToBottom = true }
              .onDisappear { isPinnedToBottom = false }
          }
          .padding(2)
        }

        if !isPinnedToBottom && !session.turns.isEmpty {
          Button(action: {
            withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            isPinnedToBottom = true
          }) {
            HStack(spacing: 6) {
              Image(systemName: "arrow.down")
              Text("Jump to latest")
            }
            .font(Typography.small(width))
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.black.opacity(0.3))
            .clipShape(Capsule())
          }
          .buttonStyle(.plain)
          .padding(8)
        }
      }
      .onChange(of: session.turns.count) {
        if hasInitialScroll {
          if isPinnedToBottom { withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) } }
        } else {
          proxy.scrollTo("BOTTOM", anchor: .bottom)
          hasInitialScroll = true
        }
      }
      .onChange(of: session.scrollTick) {
        if isPinnedToBottom { withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) } }
      }
      .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
        proxy.scrollTo("BOTTOM", anchor: .bottom)
        hasInitialScroll = true
        isPinnedToBottom = true
      }
    }
  }

  private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func inputBar(_ width: CGFloat) -> some View {
    VStack(spacing: 6) {
      ZStack(alignment: .topLeading) {
        MultilineTextView(
          text: $session.input,
          focusTrigger: $focusTrigger,
          onCommit: { session.sendCurrent() },
          onFocusChange: { focused in inputIsFocused = focused }
        )
        .frame(minHeight: 60, maxHeight: 120)
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(
              inputIsFocused ? theme.accentColor.opacity(0.6) : theme.tertiaryText.opacity(0.2),
              lineWidth: inputIsFocused ? 1.5 : 1)
        )
        .background(theme.primaryBackground.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        if session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("Message…")
            .font(Typography.body(width))
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
      }

      HStack(spacing: 8) {
        Spacer()
        Button(action: { session.sendCurrent() }) {
          HStack(spacing: 6) {
            Image(systemName: "paperplane.fill")
            Text("Send")
          }
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
  var onFocusChange: ((Bool) -> Void)? = nil

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
      tv.focusHandler = onFocusChange
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

    func textDidBeginEditing(_ notification: Notification) {
      parent.onFocusChange?(true)
    }

    func textDidEndEditing(_ notification: Notification) {
      parent.onFocusChange?(false)
    }
  }

  final class CommitInterceptTextView: NSTextView {
    var commitHandler: (() -> Void)?
    var focusHandler: ((Bool) -> Void)?
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

    override func becomeFirstResponder() -> Bool {
      let r = super.becomeFirstResponder()
      if r { focusHandler?(true) }
      return r
    }

    override func resignFirstResponder() -> Bool {
      let r = super.resignFirstResponder()
      if r { focusHandler?(false) }
      return r
    }
  }
}
