import SwiftUI

private struct WorkflowSharedGridKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Workflows owns one canvas behind its screens; standalone Settings
    /// keeps the same views' normal opaque page backgrounds.
    var workflowSharedGrid: Bool {
        get { self[WorkflowSharedGridKey.self] }
        set { self[WorkflowSharedGridKey.self] = newValue }
    }
}

/// The Paper empty state lives in the existing main Workflows destination.
/// Installed workflows and unfinished drafts share the Paper homepage.
struct WorkflowMainDestination: View {
    let windowState: ChatWindowState
    var body: some View { WorkflowsView(windowState: windowState) }
}

/// New Workflow: describe a task to the Architect, or add a ready-made
/// workflow. Pushed over the Workflows home (`onBack`), or the whole
/// screen while there are no workflows and no drafts.
struct WorkflowCreationLanding<StarterCard: View>: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var draft: ChatSession
    /// Already localized.
    let title: String
    /// Ready-made workflows not set up yet.
    let starters: [Template]
    @ViewBuilder var starterCard: (Template) -> StarterCard
    /// Esc; nil when this page is the home.
    var onBack: (() -> Void)? = nil
    var onImport: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: theme.space.s24) {
                    VStack(spacing: theme.space.s40) {
                        VStack(spacing: theme.space.s12) {
                            Text(verbatim: title)
                                .textStyle(.title)
                                .foregroundStyle(theme.text.primary)
                                .multilineTextAlignment(.center)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.bottom, theme.space.s12)
                            WorkflowArchitectComposer(windowState: windowState, draft: draft, focusesOnAppear: true)
                                // The existing composer owns 12pt outer side insets.
                                .frame(maxWidth: 504)
                                .padding(.bottom, -theme.space.s12)
                            Text("The Architect drafts the steps, tests them with you, and saves the workflow to your library.", bundle: .module)
                                .textStyle(.caption)
                                .foregroundStyle(theme.text.tertiary)
                                .multilineTextAlignment(.center)
                            WorkflowAccessStrip()
                        }
                        if !starters.isEmpty {
                            suggestions
                                .frame(maxWidth: 480)
                        }
                    }
                    if let onImport {
                        SettingsButton(.tertiary, "Import a Workflow", icon: "square.and.arrow.down", size: .extraSmall, action: onImport)
                    }
                }
                .padding(theme.space.s12)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text("Or add a ready-made workflow", bundle: .module)
                .textStyle(.caption)
                .foregroundStyle(theme.text.tertiary)
            WorkflowStarterGrid(items: starters, card: starterCard)
        }
    }
}

/// Describe a task to the Architect: sending starts a new workflow draft
/// in this window with the brief as its first message.
struct WorkflowArchitectComposer: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var draft: ChatSession
    var focusesOnAppear = false
    @State private var focusTrigger = 0

    static let ideas = [
        "Organize my Downloads folder by file type…",
        "Turn a folder of invoices into a monthly expense report with totals by category…",
        "Research a company, summarize recent news, and draft a tailored outreach email…",
        "Check a CSV for missing data…",
        "Compare two versions of a contract and flag changes that need a closer look…",
        "Read project documents, extract decisions and risks, then prepare a team update…"
    ]

    var body: some View {
        composer
            .task {
                if draft.selectedModel == nil { draft.selectedModel = windowState.session.selectedModel }
                await draft.refreshPickerItems()
            }
            .onAppear {
                let requested = windowState.consumeNewWorkflowComposerFocus()
                if requested || focusesOnAppear { requestFocus() }
            }
            .onChange(of: windowState.newWorkflowComposerWantsFocus) { _, _ in
                if windowState.consumeNewWorkflowComposerFocus() { requestFocus() }
            }
    }

    private func requestFocus() {
        // Wait out the page transition so the field exists to take focus.
        DispatchQueue.main.async { focusTrigger += 1 }
    }

    private var composer: some View {
        FloatingInputCard(
            text: $draft.input, selectedModel: $draft.selectedModel,
            pendingAttachments: $draft.pendingAttachments,
            isContinuousVoiceMode: $draft.isContinuousVoiceMode,
            voiceInputState: $draft.voiceInputState, showVoiceOverlay: $draft.showVoiceOverlay,
            pickerItems: draft.pickerItems, activeModelOptions: $draft.activeModelOptions,
            isStreaming: false, supportsImages: draft.selectedModelSupportsImages,
            estimatedContextTokens: draft.estimatedContextTokens,
            imageComposerSettings: $draft.imageComposerSettings,
            onSend: submit, onStop: {}, focusTrigger: focusTrigger,
            agentId: Agent.architectId, windowId: windowState.windowId, isCompact: true,
            onDraftChange: { draft.input = $0 },
            folderState: draft.folderState,
            placeholderIdeas: Self.ideas, minimumEditorHeight: 48, minimumCardHeight: 104
        )
        .environment(\.composerAllowsWorkflowSelection, false)
    }

    /// Reuse authoring and send behavior; a card click itself never runs a model.
    private func submit(_ text: String?) {
        let brief = (text ?? draft.input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return }
        let model = draft.selectedModel
        let options = draft.activeModelOptions
        let attachments = draft.pendingAttachments
        ArchitectLauncher.newWorkflow(in: windowState)
        windowState.leaveNewWorkflowPage()
        windowState.session.selectedModel = model
        windowState.session.activeModelOptions = options
        windowState.session.pendingAttachments = attachments
        draft.input = ""
        draft.pendingAttachments = []
        windowState.session.send(brief)
    }
}

/// The existing starter card's interaction states, using library surfaces.
/// State washes composite over canvas so the card remains opaque.
/// The existing starter card, shared by the empty and populated pages.
struct WorkflowStarterCard: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: String
    let detail: String
    var isSelected = false
    var minimumHeight: CGFloat? = nil
    let action: () -> Void

    static func detail(for template: Template) -> String {
        switch template.id.uuidString.lowercased() {
        case "0f5c1a4e-6b7d-4c1a-9a01-000000000103": return "Paste an email and get a reply in your tone."
        case "0f5c1a4e-6b7d-4c1a-9a01-000000000102": return "Paste meeting notes, receive deliverables and follow-up email"
        case "0f5c1a4e-6b7d-4c1a-9a01-000000000101": return "Turns a topic into a post for any platform you pick, with hashtags."
        default: return template.summary ?? ""
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: icon)
                        .glyphSize(10)
                        .foregroundStyle(theme.text.inverse)
                        .frame(width: theme.space.s16 + theme.space.s4, height: theme.space.s16 + theme.space.s4)
                        .background(WorkflowCanvasGrid.primitive("sky/300", theme: theme, fallback: theme.status.info.foreground), in: Circle())
                    Text(verbatim: title).textStyle(.body).foregroundStyle(theme.text.primary)
                }.frame(minHeight: CGFloat(theme.typography.styles.body.lineHeight) * theme.fontScale)
                Text(verbatim: detail).textStyle(.caption).foregroundStyle(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(theme.space.s16)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, maxHeight: minimumHeight == nil ? nil : .infinity, alignment: .topLeading)
        }
        .buttonStyle(WorkflowStarterCardStyle(isSelected: isSelected))
        .accessibilityHint("Preview this workflow and add it to your workflows.")
    }
}

private struct WorkflowStarterCardStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium)
        let selected = isSelected || configuration.isPressed
        configuration.label
            .background {
                shape.fill(theme.surface.canvas)
                shape.fill(selected ? theme.surface.selected : (isHovered ? theme.surface.hover : .clear))
            }
            .overlay { shape.strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default) }
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(theme.motion.quick, value: isHovered)
            .animation(theme.motion.quick, value: selected)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The half of the workflow-creation split on screen when the window is too
/// narrow for both side by side.
enum WorkflowCreationPane: Hashable {
    case chat
    case workflow

    /// The half an Architect chat opens on: its draft when only the draft
    /// has something to show (a saved workflow opened for changes).
    static func opening(hasChat: Bool, hasSteps: Bool) -> Self {
        hasSteps && !hasChat ? .workflow : .chat
    }
}

/// Layout-only frame from Paper; the content remains the shared Chat UI.
/// `width` is the panel's outer width beside the draft, or nil when the
/// panel takes the whole content area (stacked layout).
struct WorkflowCreationChatFrame: ViewModifier {
    let isActive: Bool
    var width: CGFloat? = nil
    @Environment(\.theme) private var theme

    @ViewBuilder func body(content: Content) -> some View {
        if isActive {
            content
                .padding(theme.space.s16)
                .frame(width: width)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .frame(maxHeight: .infinity)
                .background(theme.surface.canvas, in: RoundedRectangle(cornerRadius: theme.radius.xlarge))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radius.xlarge)
                        .strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default)
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        } else { content }
    }
}

/// Compensate only for the shared composer's external placement insets;
/// its internal spacing, buttons and styles remain library-owned.
struct WorkflowCreationComposerFrame: ViewModifier {
    let isActive: Bool
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, isActive ? -theme.space.s12 : 0)
            .padding(.bottom, isActive ? -theme.space.s12 : 0)
    }
}

/// Two-point squares separated by twenty clear points, on the workflow canvas only.
struct WorkflowCanvasGrid: View {
    @Environment(\.theme) private var theme
    static func primitive(_ name: String, theme: any ThemeProtocol, fallback: Color) -> Color {
        #if OSAURUS_DESIGN_SYSTEM
        if let color = DesignThemeOverlay.shared.current()?.document.primitives?[name] {
            return Color(themeHex: theme.isDark ? color.dark : color.light)
        }
        #endif
        return fallback
    }
    var body: some View {
        Canvas { context, size in
            var squares = Path()
            for y in stride(from: CGFloat(8), to: size.height, by: 22) {
                for x in stride(from: CGFloat(8), to: size.width, by: 22) {
                    squares.addRect(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
            context.fill(squares, with: .color(Self.primitive("neutral/100", theme: theme, fallback: theme.surface.raised)))
        }
        .background(theme.surface.canvas)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
