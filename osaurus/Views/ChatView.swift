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
    // Set default selectedModel to first available
    selectedModel = opts.first
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
    turns.append(ChatTurn(role: .user, content: trimmed))

    var messages = turns.map { Message(role: $0.role, content: $0.content) }
    let chatCfg = ChatConfigurationStore.load()
    let sys = chatCfg.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !sys.isEmpty {
      messages.insert(Message(role: .system, content: sys), at: 0)
    }
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
        turns.append(
          ChatTurn(
            role: .assistant, content: "No model available. Open Model Manager to download one."))
        return
      case .service(let svc, _):
        let assistantTurn = ChatTurn(role: .assistant, content: "")
        turns.append(assistantTurn)
        let params = GenerationParameters(temperature: 0.7, maxTokens: 1024)
        do {
          let stream = try await svc.streamDeltas(prompt: prompt, parameters: params)
          for await delta in stream {
            if Task.isCancelled { break }
            if !delta.isEmpty {
              assistantTurn.content += delta
              // Signal UI to autoscroll while streaming
              scrollTick &+= 1
            }
          }
        } catch {
          assistantTurn.content = "Error: \(error.localizedDescription)"
        }
      }
    }
  }
}

struct ChatView: View {
  @EnvironmentObject var server: ServerController
  @StateObject private var themeManager = ThemeManager.shared

  private var theme: ThemeProtocol {
    themeManager.currentTheme
  }
  @StateObject private var session = ChatSession()
  // Using AppKit-backed text view to handle Enter vs Shift+Enter
  @State private var focusTrigger: Int = 0
  @State private var isPinnedToBottom: Bool = true
  @State private var inputIsFocused: Bool = false
  @State private var hostWindow: NSWindow?
  @State private var keyMonitor: Any?

  var body: some View {
    GeometryReader { proxy in
      let containerWidth = proxy.size.width
      ZStack(alignment: .bottomTrailing) {
        // Unified glass surface background
        GlassSurface(cornerRadius: 28)
          .allowsHitTesting(false)

        VStack(spacing: 10) {
          header(containerWidth)
          if hasAnyModel {
            if !session.turns.isEmpty {
              conversation(containerWidth)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
              // Add minimal spacer when empty to keep window compact
              Spacer()
                .frame(height: 0)
            }
            inputBar(containerWidth)
            bottomControls(containerWidth)
          } else {
            emptyState
          }

          // Add flexible spacer only when there are messages
          if !session.turns.isEmpty && hasAnyModel {
            Spacer(minLength: 0)
          }
        }
        .animation(.easeInOut(duration: 0.25), value: session.turns.isEmpty)
        .padding(20)
        .frame(maxWidth: 1000)
        .frame(
          maxWidth: .infinity,
          maxHeight: session.turns.isEmpty ? .infinity : .infinity,
          alignment: .top
        )
      }
    }
    .frame(
      minWidth: 700,
      idealWidth: 900,
      maxWidth: .infinity,
      minHeight: session.turns.isEmpty ? 200 : 525,
      idealHeight: session.turns.isEmpty ? 250 : 700,
      maxHeight: .infinity
    )
    .animation(.easeInOut(duration: 0.3), value: session.turns.isEmpty)
    .background(WindowAccessor(window: $hostWindow))
    .overlay(alignment: .topTrailing) {
      HoveringIcon(systemName: "xmark", help: "Close") {
        AppDelegate.shared?.closeChatOverlay()
      }
      .padding(20)
    }
    .onExitCommand { AppDelegate.shared?.closeChatOverlay() }
    .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
      focusTrigger &+= 1
      isPinnedToBottom = true
      inputIsFocused = true
    }
    .onAppear {
      inputIsFocused = true
      if keyMonitor == nil {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          guard inputIsFocused else { return event }
          let isReturn = (event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter)
          if isReturn {
            let hasShift = event.modifierFlags.contains(.shift)
            if hasShift {
              return event  // allow newline
            } else {
              session.sendCurrent()
              return nil  // consume
            }
          }
          return event
        }
      }
    }
    .onDisappear {
      if let monitor = keyMonitor {
        NSEvent.removeMonitor(monitor)
        keyMonitor = nil
      }
    }
    .onChange(of: session.turns.isEmpty) { oldValue, newValue in
      // Resize window when chat is cleared or gets content
      resizeWindowForContent(isEmpty: newValue)
    }
  }

  private func resizeWindowForContent(isEmpty: Bool) {
    guard let window = hostWindow else { return }

    let targetHeight: CGFloat = isEmpty ? 250 : 700
    let currentFrame = window.frame

    // Calculate center point of current window
    let currentCenterY = currentFrame.origin.y + (currentFrame.height / 2)
    let currentCenterX = currentFrame.origin.x + (currentFrame.width / 2)

    // Keep window centered at the same point
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

  private func header(_ width: CGFloat) -> some View {
    HStack(spacing: 12) {
      Text("Chat with \(displayModelName(session.selectedModel))")
        .font(Typography.title(width))
        .foregroundColor(theme.primaryText)
        .fontWeight(.medium)
        .padding(.vertical, 4)
      if !session.turns.isEmpty {
        Button(action: { session.reset() }) {
          Image(systemName: "trash")
            .foregroundColor(theme.secondaryText)
        }
        .buttonStyle(.plain)
        .help("Reset chat")
      }
      Spacer()
    }
  }

  private func displayModelName(_ raw: String?) -> String {
    guard let raw else { return "Model" }
    if raw.lowercased() == "foundation" { return "Foundation" }
    if let last = raw.split(separator: "/").last { return String(last) }
    return raw
  }

  private func conversation(_ width: CGFloat) -> some View {
    ScrollViewReader { proxy in
      @State var hasInitialScroll = false
      ZStack(alignment: .bottomTrailing) {
        ScrollView {
          LazyVStack(spacing: 16) {
            ForEach(session.turns) { turn in
              MessageRowView(turn: turn, width: width, isStreaming: session.isStreaming) { text in
                copyToPasteboard(text)
              }
            }
            Color.clear
              .frame(height: 1)
              .id("BOTTOM")
              .onAppear { isPinnedToBottom = true }
              .onDisappear { isPinnedToBottom = false }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)

        if !isPinnedToBottom && !session.turns.isEmpty {
          Button(action: {
            withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            isPinnedToBottom = true
          }) {
            HStack(spacing: 4) {
              Image(systemName: "chevron.down.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(Color.accentColor)
                .background(
                  Circle()
                    .fill(theme.primaryBackground.opacity(0.9))
                    .frame(width: 20, height: 20)
                )
            }
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 2)
          }
          .buttonStyle(.plain)
          .transition(.opacity.combined(with: .scale))
          .padding(16)
        }
      }
      .onChange(of: session.turns.count) { _, _ in
        if hasInitialScroll {
          if isPinnedToBottom { withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) } }
        } else {
          proxy.scrollTo("BOTTOM", anchor: .bottom)
          hasInitialScroll = true
        }
      }
      .onChange(of: session.scrollTick) { _, _ in
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
    ZStack(alignment: .topLeading) {
      ChatTextEditor(
        text: $session.input,
        placeholder: "Type your message…",
        isFocused: $inputIsFocused,
        onSend: { session.sendCurrent() }
      )
      .frame(minHeight: 48, maxHeight: 120)
      .background(
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
              theme.glassOpacityTertiary == 0.05
                ? theme.secondaryBackground.opacity(0.4) : theme.primaryBackground.opacity(0.4)
            )
            .allowsHitTesting(false)
          Group {
            if #available(macOS 13.0, *) {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            } else {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.primaryBackground.opacity(0.85))
            }
          }
          .allowsHitTesting(false)
        }
      )
      .overlay(alignment: .center) {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(
            inputIsFocused
              ? LinearGradient(
                colors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
              : LinearGradient(
                colors: [theme.glassEdgeLight, theme.glassEdgeLight.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
            lineWidth: inputIsFocused ? 1.5 : 0.5
          )
          .allowsHitTesting(false)
      }
      .shadow(
        color: inputIsFocused ? Color.accentColor.opacity(0.2) : Color.clear,
        radius: inputIsFocused ? 20 : 0
      )
      .contentShape(RoundedRectangle(cornerRadius: 16))
      .onTapGesture { inputIsFocused = true }
      .animation(.easeInOut(duration: theme.animationDurationMedium), value: inputIsFocused)
    }
  }

  private var primaryActionButton: some View {
    Group {
      if session.isStreaming {
        Button(action: { session.stop() }) {
          HStack(spacing: 6) {
            Image(systemName: "stop.fill")
            Text("Stop")
          }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
          Capsule()
            .fill(Color.red.opacity(0.9))
        )
        .shadow(
          color: Color.red.opacity(0.3),
          radius: 8,
          x: 0,
          y: 2
        )
        .buttonStyle(.plain)
        .help("Stop response")
      } else {
        Button(action: { session.sendCurrent() }) {
          HStack(spacing: 6) {
            Image(systemName: "paperplane.fill")
            Text("Send")
          }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
          Capsule()
            .fill(Color.accentColor.opacity(0.9))
        )
        .shadow(
          color: Color.accentColor.opacity(0.3),
          radius: 8,
          x: 0,
          y: 2
        )
        .buttonStyle(.plain)
        .disabled(
          session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .opacity(
          session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1
        )
        .animation(.easeInOut(duration: theme.animationDurationQuick), value: session.input)
        .keyboardShortcut(.return)
      }
    }
  }

  private var sendButton: some View {
    Button(action: { session.sendCurrent() }) {
      HStack(spacing: 6) {
        Image(systemName: "paperplane.fill")
        Text("Send")
      }
      .font(.system(size: 14, weight: .medium))
      .foregroundColor(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(
        Capsule()
          .fill(Color.accentColor.opacity(0.9))
      )
      .shadow(
        color: Color.accentColor.opacity(0.3),
        radius: 8,
        x: 0,
        y: 2
      )
    }
    .buttonStyle(.plain)
    .disabled(
      session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || session.isStreaming
    )
    .opacity(
      session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || session.isStreaming ? 0.5 : 1
    )
    .animation(.easeInOut(duration: theme.animationDurationQuick), value: session.input)
    .keyboardShortcut(.return)
  }

  private func bottomControls(_ width: CGFloat) -> some View {
    HStack(spacing: 8) {
      if session.modelOptions.count > 1 {
        Picker("Model", selection: $session.selectedModel) {
          ForEach(session.modelOptions, id: \.self) { name in
            Text(name).tag(Optional(name))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 180)
        .help("Select model")
      } else if let selected = session.selectedModel {
        Text(selected)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(theme.secondaryText)
          .padding(.vertical, 6)
          .padding(.horizontal, 10)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(theme.secondaryBackground.opacity(0.6))
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .stroke(theme.glassEdgeLight.opacity(0.3), lineWidth: 1)
              )
          )
      }

      Spacer()

      primaryActionButton
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
            session.selectedModel = "foundation"
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

// MARK: - Message Row (observes individual turn)
private struct MessageRowView: View {
  @ObservedObject var turn: ChatTurn
  let width: CGFloat
  let isStreaming: Bool
  let onCopy: (String) -> Void
  @Environment(\.theme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      if turn.role == .user {
        Spacer()
      }

      VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 8) {
        Text(turn.role == .user ? "You" : "Assistant")
          .font(Typography.small(width))
          .fontWeight(.medium)
          .foregroundColor(turn.role == .user ? Color.accentColor : theme.secondaryText)

        ZStack(alignment: .topTrailing) {
          Group {
            if turn.content.isEmpty && turn.role == .assistant && isStreaming {
              HStack(spacing: 8) {
                ProgressView()
                  .scaleEffect(0.8)
                  .progressViewStyle(CircularProgressViewStyle(tint: Color.accentColor))
                Text("Thinking…")
                  .font(Typography.body(width))
                  .foregroundColor(theme.primaryText)
              }
              .padding(16)
              .background(
                GlassMessageBubble(role: turn.role, isStreaming: isStreaming)
              )
            } else {
              MarkdownMessageView(text: turn.content, baseWidth: width)
                .font(Typography.body(width))
                .foregroundColor(theme.primaryText)
                .padding(16)
                .background(
                  GlassMessageBubble(role: turn.role, isStreaming: isStreaming)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
          }
          .fixedSize(horizontal: false, vertical: true)

          if turn.role == .assistant && !turn.content.isEmpty {
            HoverButton(action: { onCopy(turn.content) }) {
              Image(systemName: "doc.on.doc")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
            }
            .padding(8)
            .offset(x: -8, y: 8)
          }
        }
      }
      .frame(
        maxWidth: min(width * 0.75, 600),
        alignment: turn.role == .user ? .trailing : .leading
      )

      if turn.role == .assistant {
        Spacer()
      }
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Hover Button Component
struct HoverButton<Content: View>: View {
  let action: () -> Void
  let content: () -> Content
  @State private var isHovered: Bool = false
  @Environment(\.theme) private var theme

  init(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
    self.action = action
    self.content = content
  }

  var body: some View {
    Button(action: action) {
      content()
        .padding(6)
        .background(
          Circle()
            .fill(theme.secondaryBackground.opacity(isHovered ? 0.9 : 0.7))
            .overlay(
              Circle()
                .strokeBorder(theme.glassEdgeLight, lineWidth: 0.5)
            )
        )
        .shadow(
          color: Color.black.opacity(0.1),
          radius: 4,
          x: 0,
          y: 2
        )
    }
    .buttonStyle(.plain)
    .opacity(isHovered ? 1 : 0)
    .animation(.easeInOut(duration: 0.15), value: isHovered)
    .onHover { hovering in
      isHovered = hovering
    }
    .help("Copy message")
  }
}

// MARK: - Hovering Icon Button
struct HoveringIcon: View {
  let systemName: String
  let help: String
  let action: () -> Void
  @State private var isHovered: Bool = false
  @Environment(\.theme) private var theme

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(theme.secondaryText)
        .padding(6)
    }
    .buttonStyle(.plain)
    .opacity(isHovered ? 1 : 0)
    .animation(.easeInOut(duration: 0.15), value: isHovered)
    .onHover { hovering in
      isHovered = hovering
    }
    .help(help)
  }
}

// MARK: - Window Accessor Helper
struct WindowAccessor: NSViewRepresentable {
  @Binding var window: NSWindow?

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      self.window = view.window
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if window == nil {
      DispatchQueue.main.async {
        self.window = nsView.window
      }
    }
  }
}
