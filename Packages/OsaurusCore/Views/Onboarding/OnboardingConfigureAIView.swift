//
//  OnboardingConfigureAIView.swift
//  osaurus
//
//  Onboarding step 3 — pick where the model brain lives (Apple Intelligence,
//  a local MLX model, or any cloud provider) and configure it inline.
//
//  Split into:
//   - `ConfigureAIState`: ObservableObject holding path/substate selection,
//     connection-test progress, and the substate slide direction (lives at
//     OnboardingView level).
//   - `ConfigureAIBody`: the body slot — sticky segmented path picker plus a
//     per-path substate body that slides direction-aware between picker
//     and drilled-in forms.
//   - `ConfigureAICTA`: the footer primary action, dispatched per substate.
//   - `ConfigureAISecondary`: the footer secondary text-link slot.
//

import SwiftUI

// MARK: - Path

enum ConfigurePath: String, CaseIterable {
    case appleFoundation
    case local
    case apiProvider

    var title: LocalizedStringKey {
        switch self {
        case .appleFoundation: return "Apple"
        case .local: return "Local"
        case .apiProvider: return "Cloud"
        }
    }

    var icon: String {
        switch self {
        case .appleFoundation: return "apple.logo"
        case .local: return "internaldrive"
        case .apiProvider: return "network"
        }
    }
}

// MARK: - Local / API substates

enum LocalSubstate: Equatable {
    case picker
    case downloading
}

enum APISubstate: Equatable {
    case picker
    case keyForm(ProviderPreset)
    case customForm
}

enum APITestResult: Equatable {
    case success
    case failure(String)
}

// MARK: - Resolved provider config

struct ResolvedProviderConfig {
    let name: String
    let host: String
    let port: Int?
    let basePath: String
    let providerType: RemoteProviderType
    let providerProtocol: RemoteProviderProtocol
}

struct CustomProviderForm {
    var name: String = ""
    var host: String = ""
    var protocolKind: RemoteProviderProtocol = .https
    var port: String = ""
    var basePath: String = "/v1"

    mutating func reset() { self = CustomProviderForm() }

    var endpointPreview: String {
        var url = (protocolKind == .https ? "https://" : "http://") + host
        if !port.isEmpty { url += ":\(port)" }
        url += basePath.isEmpty ? "/v1" : basePath
        return url
    }

    func resolved(displayName: String) -> ResolvedProviderConfig {
        ResolvedProviderConfig(
            name: name.isEmpty ? displayName : name,
            host: host,
            port: port.isEmpty ? nil : Int(port),
            basePath: basePath.isEmpty ? "/v1" : basePath,
            providerType: .openaiLegacy,
            providerProtocol: protocolKind
        )
    }
}

// MARK: - State

@MainActor
final class ConfigureAIState: ObservableObject {
    static let onboardingPresets: [ProviderPreset] = [
        .anthropic, .deepseek, .google, .openai, .venice, .xai, .custom,
    ]

    let foundationAvailable: Bool

    @Published var selectedPath: ConfigurePath
    @Published var localSubstate: LocalSubstate = .picker
    @Published var apiSubstate: APISubstate = .picker

    /// Direction the next substate transition should travel. Mirrors the
    /// global step `OnboardingDirection` so the substate slide reads as a
    /// natural continuation of the outer navigation language.
    @Published var substateDirection: OnboardingDirection = .forward

    // Local
    @Published var selectedModel: MLXModel? = nil

    // API
    @Published var apiKey: String = ""
    @Published var openAIAuthMode: OpenAIProviderCredentialMode = .chatGPTSubscription
    @Published var oauthTokens: RemoteProviderOAuthTokens? = nil
    @Published var customForm = CustomProviderForm()
    @Published var isTesting = false
    @Published var isSaving = false
    @Published var testResult: APITestResult? = nil

    init() {
        let foundation = FoundationModelService.isDefaultModelAvailable()
        self.foundationAvailable = foundation
        self.selectedPath = foundation ? .appleFoundation : .local
    }

    var availablePaths: [ConfigurePath] {
        if foundationAvailable {
            return [.appleFoundation, .local, .apiProvider]
        } else {
            return [.local, .apiProvider]
        }
    }

    var footerCaption: LocalizedStringKey {
        switch selectedPath {
        case .appleFoundation: return "Private, instant, no setup."
        case .local: return "No account, no cloud, no data sent anywhere."
        case .apiProvider: return "API keys are stored securely in Keychain."
        }
    }

    func selectPath(_ path: ConfigurePath) {
        // Path changes are lateral, but we treat them as forward motion so
        // the substate body slides in from the trailing edge consistently.
        substateDirection = .forward
        selectedPath = path
        if path != .local { localSubstate = .picker }
        if path != .apiProvider { resetAPIState(direction: .forward) }
        testResult = nil
    }

    // MARK: Back handling

    /// The global header back button always exits the Configure AI step.
    /// Sub-substates (key form, custom form, local downloading) have their
    /// own in-section back rows, so the header back button doesn't double
    /// as both global-step nav AND substate nav — that ambiguity used to
    /// confuse users.
    func handleBack(parentBack: () -> Void) {
        parentBack()
    }

    // MARK: Local

    var localDownloadState: DownloadState {
        guard let model = selectedModel else { return .notStarted }
        return ModelManager.shared.downloadStates[model.id] ?? .notStarted
    }

    var isLocalDownloading: Bool {
        if case .downloading = localDownloadState { return true }
        return false
    }

    var isLocalPaused: Bool {
        if case .paused = localDownloadState { return true }
        return false
    }

    var isLocalCompleted: Bool {
        if case .completed = localDownloadState { return true }
        return false
    }

    var isLocalFailed: Bool {
        if case .failed = localDownloadState { return true }
        return false
    }

    var localFailedError: String? {
        if case .failed(let e) = localDownloadState { return e }
        return nil
    }

    /// Progress fraction (0…1) of the latest download attempt regardless
    /// of whether it's currently in flight or paused. Used by the shimmer
    /// bar so the rendering site doesn't have to branch on the state case.
    var localBarProgress: Double {
        switch localDownloadState {
        case .downloading(let p), .paused(let p): return p
        case .completed: return 1
        case .notStarted, .failed: return 0
        }
    }

    func ensureLocalSelection() {
        if selectedModel == nil {
            let topModels = ModelManager.shared.suggestedModels.filter { $0.isTopSuggestion }
            selectedModel = topModels.first
        }
    }

    func startLocalDownloadOrContinue(onComplete: () -> Void) {
        if selectedModel?.isDownloaded == true {
            onComplete()
            return
        }
        substateDirection = .forward
        localSubstate = .downloading
        startLocalDownload()
    }

    func startLocalDownload() {
        guard let model = selectedModel else { return }
        ModelManager.shared.downloadModel(model)
    }

    func pauseLocalDownload() {
        guard let model = selectedModel else { return }
        ModelManager.shared.pauseDownload(model.id)
    }

    func resumeLocalDownload() {
        guard let model = selectedModel else { return }
        ModelManager.shared.resumeDownload(model.id)
    }

    /// Cancels an in-flight or paused download and returns the user to the
    /// model picker. Used by the inline Cancel control on the downloading
    /// screen so the user has a clear escape route — the previous version
    /// only had the small back chevron at the top of the section.
    func cancelLocalDownload() {
        if let model = selectedModel {
            ModelManager.shared.cancelDownload(model.id)
        }
        popLocalToPicker()
    }

    // MARK: API

    var currentAPIProvider: ProviderPreset? {
        switch apiSubstate {
        case .keyForm(let p): return p
        case .customForm: return .custom
        case .picker: return nil
        }
    }

    var canTestAPI: Bool {
        guard let provider = currentAPIProvider else { return false }
        if provider == .custom {
            return !customForm.host.isEmpty && apiKey.count > 5
        }
        if provider == .openai && openAIAuthMode == .chatGPTSubscription {
            return true
        }
        return apiKey.count > 10
    }

    var isAPISuccess: Bool {
        if case .success = testResult { return true }
        return false
    }

    var apiButtonState: OnboardingButtonState {
        if isTesting || isSaving { return .loading }
        switch testResult {
        case .success: return .success
        case .failure(let m): return .error(m)
        case nil: return .idle
        }
    }

    /// Resets the API substate back to the picker. Direction defaults to
    /// `.backward` so the substate slide reads as "popping out", but
    /// callers can pass `.forward` when this is invoked as a side-effect
    /// of a forward path switch.
    func resetAPIState(direction: OnboardingDirection = .backward) {
        substateDirection = direction
        apiSubstate = .picker
        apiKey = ""
        openAIAuthMode = .chatGPTSubscription
        oauthTokens = nil
        customForm.reset()
        testResult = nil
    }

    /// Picker → form drill-in. Tapping a provider card immediately advances
    /// to its key form (or the custom-provider form), no "Continue" press
    /// required.
    func selectAPIPreset(_ preset: ProviderPreset) {
        substateDirection = .forward
        if preset == .custom {
            apiSubstate = .customForm
        } else {
            apiSubstate = .keyForm(preset)
        }
    }

    /// Local downloading → picker (backward).
    func popLocalToPicker() {
        substateDirection = .backward
        localSubstate = .picker
    }

    func resolvedAPIConfig() -> ResolvedProviderConfig? {
        guard let provider = currentAPIProvider else { return nil }
        if provider == .custom {
            return customForm.resolved(displayName: L("Custom Provider"))
        }
        let cfg = provider.configuration
        return ResolvedProviderConfig(
            name: cfg.name,
            host: cfg.host,
            port: cfg.port,
            basePath: cfg.basePath,
            providerType: cfg.providerType,
            providerProtocol: cfg.providerProtocol
        )
    }

    func testAPIConnection() {
        guard let config = resolvedAPIConfig() else { return }
        isTesting = true
        testResult = nil

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let result: APITestResult
            do {
                if self.currentAPIProvider == .openai && self.openAIAuthMode == .chatGPTSubscription {
                    let tokens = try await OpenAICodexOAuthService.signIn()
                    self.oauthTokens = tokens
                } else {
                    _ = try await RemoteProviderManager.shared.testConnection(
                        host: config.host,
                        providerProtocol: config.providerProtocol,
                        port: config.port,
                        basePath: config.basePath,
                        authType: .apiKey,
                        providerType: config.providerType,
                        apiKey: self.apiKey,
                        headers: [:]
                    )
                }
                result = .success
            } catch {
                result = .failure(error.localizedDescription)
            }
            self.testResult = result
            self.isTesting = false
        }
    }

    func saveProviderAndContinue(onComplete: () -> Void) {
        guard let config = resolvedAPIConfig() else { return }
        isSaving = true

        if currentAPIProvider == .openai && openAIAuthMode == .chatGPTSubscription {
            let provider = OpenAICodexOAuthService.makeProvider()
            RemoteProviderManager.shared.addProvider(provider, apiKey: nil, oauthTokens: oauthTokens)
            isSaving = false
            onComplete()
            return
        }

        let provider = RemoteProvider(
            name: config.name,
            host: config.host,
            providerProtocol: config.providerProtocol,
            port: config.port,
            basePath: config.basePath,
            customHeaders: [:],
            authType: .apiKey,
            providerType: config.providerType,
            enabled: true,
            autoConnect: true,
            timeout: 60
        )
        RemoteProviderManager.shared.addProvider(provider, apiKey: apiKey)
        isSaving = false
        onComplete()
    }
}

// MARK: - Body

struct ConfigureAIBody: View {
    @ObservedObject var state: ConfigureAIState

    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = ModelManager.shared

    var body: some View {
        OnboardingTwoColumnBody(
            illustrationAsset: "osaurus-brain",
            leftHeadline: "Pick a brain",
            leftBody:
                "Apple Intelligence on-device, a local MLX model, or any cloud provider. Models are interchangeable — switch any time without losing your history.",
            subtitle: pathSubtitle,
            // We manage our own inner scroll: the segmented control stays
            // pinned at the top while the substate body scrolls beneath it.
            useScrollView: false
        ) {
            VStack(alignment: .leading, spacing: 14) {
                pathSegmentedControl

                // Clipped container holds the substate during its slide
                // animation so the outgoing/incoming views never bleed
                // outside the right column (e.g. into the left column's
                // illustration).
                ZStack(alignment: .topLeading) {
                    substateContainer
                        .id(substateID)
                        .transition(substateTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: substateID)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { state.ensureLocalSelection() }
    }

    // MARK: - Path subtitle

    private var pathSubtitle: LocalizedStringKey {
        switch state.selectedPath {
        case .appleFoundation: return "Apple Intelligence — on-device and ready to go."
        case .local: return "Local MLX model — runs entirely on this Mac."
        case .apiProvider: return "Cloud provider — bring your own API key."
        }
    }

    // MARK: - Path Segmented Control

    private var pathSegmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(state.availablePaths, id: \.self) { path in
                pathSegment(path)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private func pathSegment(_ path: ConfigurePath) -> some View {
        let isSelected = state.selectedPath == path
        return Button {
            // No `withAnimation` wrapper: the body's own
            // `.animation(value: substateID)` modifier animates the substate
            // crossfade. Wrapping the state mutation in `withAnimation` would
            // also propagate to the footer CTA (which observes `selectedPath`)
            // and morph the button — visually distracting.
            state.selectPath(path)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: path.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(path.title, bundle: .module)
                    .font(theme.font(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .foregroundColor(isSelected ? .white : theme.secondaryText)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? theme.accentColor : Color.clear)
                    // Localized animation on the fill ONLY — keeps the
                    // segment selection smooth without leaking into the
                    // footer CTA via `selectedPath`.
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSelected)
            )
            // Make the entire segment hit-testable, not just the icon+text.
            // `Button { … } label: { … }` with `.plain` style only registers
            // hits on the label's drawn pixels by default.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Substate dispatch

    private var substateID: String {
        switch state.selectedPath {
        case .appleFoundation: return "apple"
        case .local:
            switch state.localSubstate {
            case .picker: return "local-picker"
            case .downloading: return "local-downloading"
            }
        case .apiProvider:
            switch state.apiSubstate {
            case .picker: return "api-picker"
            case .keyForm(let p): return "api-key-\(p.rawValue)"
            case .customForm: return "api-custom"
            }
        }
    }

    /// Direction-aware horizontal slide that mirrors the global step
    /// transition's vocabulary: pure offset, no opacity. Sized to the
    /// substate region width so the body slides cleanly off one edge
    /// while the next slides in from the opposite edge.
    private var substateTransition: AnyTransition {
        let dx = OnboardingMetrics.substateSlideOffset
        let inOffset = state.substateDirection == .forward ? dx : -dx
        let outOffset = state.substateDirection == .forward ? -dx : dx
        return .asymmetric(
            insertion: .offset(x: inOffset),
            removal: .offset(x: outOffset)
        )
    }

    /// Substate container — owns its own scrolling and in-section back row
    /// when the user has drilled into a sub-substate (key form, custom form,
    /// downloading). The segmented control above stays pinned in place.
    @ViewBuilder
    private var substateContainer: some View {
        switch state.selectedPath {
        case .appleFoundation:
            appleConfirmView

        case .local:
            switch state.localSubstate {
            case .picker:
                scrollableSubstate { localPickerView }
            case .downloading:
                substateWithBackBar(
                    title: state.selectedModel?.name ?? L("Downloading"),
                    onBack: { state.popLocalToPicker() }
                ) {
                    localDownloadingView
                }
            }

        case .apiProvider:
            switch state.apiSubstate {
            case .picker:
                scrollableSubstate { apiPickerView }
            case .keyForm(let provider):
                substateWithBackBar(
                    title: provider == .openai ? L("Connect OpenAI") : "Connect \(provider.name)",
                    onBack: { state.resetAPIState() }
                ) {
                    apiKeyFormView
                }
            case .customForm:
                substateWithBackBar(
                    title: L("Custom provider"),
                    onBack: { state.resetAPIState() }
                ) {
                    apiCustomFormView
                }
            }
        }
    }

    /// Wraps content in a vertical ScrollView so long lists don't overflow
    /// the body while keeping the segmented control above it pinned.
    /// `scrollContentBuffer` gives the first/last card's hover shadow +
    /// scale room to render without clipping at the scroll-area edges.
    private func scrollableSubstate<C: View>(@ViewBuilder content: () -> C) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(scrollContentBuffer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Sub-substate frame: an in-context back row (drills out to the picker)
    /// followed by the substate body wrapped in a ScrollView for any
    /// overflow (key forms, custom-provider form, etc.).
    private func substateWithBackBar<C: View>(
        title: String,
        onBack: @escaping () -> Void,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            substateBackRow(title: title, onBack: onBack)
            ScrollView(.vertical, showsIndicators: false) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(scrollContentBuffer)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Buffer (`EdgeInsets`) inside scroll regions so hover shadows + scale
    /// on row/glass cards don't clip against the scroll-area edges.
    private var scrollContentBuffer: EdgeInsets {
        EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
    }

    private func substateBackRow(title: String, onBack: @escaping () -> Void) -> some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(theme.font(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.secondaryText)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Back", bundle: .module))
    }

    // MARK: - Apple confirm

    private var appleConfirmView: some View {
        VStack(spacing: 12) {
            OnboardingGlassCard {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(theme.accentColor.opacity(0.14))
                            .frame(width: OnboardingMetrics.cardIcon, height: OnboardingMetrics.cardIcon)
                        Image(systemName: "apple.logo")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(theme.primaryText)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apple Intelligence is ready", bundle: .module)
                            .font(theme.font(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Private, on-device, and built into your Mac.", bundle: .module)
                            .font(theme.font(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, OnboardingMetrics.cardPaddingH)
                .padding(.vertical, OnboardingMetrics.cardPaddingV)
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.successColor)
                Text("No download. No setup. No keys.", bundle: .module)
                    .font(theme.font(size: 12))
                    .foregroundColor(theme.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Local picker

    private var localPickerView: some View {
        VStack(spacing: OnboardingMetrics.cardSpacing) {
            ForEach(modelManager.suggestedModels.filter(\.isTopSuggestion), id: \.id) { model in
                OnboardingRowCard(
                    icon: .symbol(model.isVLM ? "eye" : "cpu"),
                    title: model.name,
                    subtitle: model.description,
                    badges: localBadges(for: model),
                    accessory: .radio(isSelected: state.selectedModel?.id == model.id),
                    isSelected: state.selectedModel?.id == model.id
                ) {
                    // No `withAnimation` — selecting a model otherwise
                    // morphs the CTA between "Continue" and
                    // "Download & Install" as a side-effect of the
                    // shared transaction.
                    state.selectedModel = model
                }
            }
        }
    }

    private func localBadges(for model: MLXModel) -> [OnboardingRowBadge] {
        var result: [OnboardingRowBadge] = []
        if model.isDownloaded {
            result.append(OnboardingRowBadge(L("Downloaded"), style: .success))
        } else if let size = model.formattedDownloadSize {
            result.append(OnboardingRowBadge(size))
        }
        result.append(OnboardingRowBadge(model.isVLM ? "VLM" : "LLM"))
        return result
    }

    // MARK: - Local downloading

    /// State-driven downloading view. Renders one of three layouts depending
    /// on the live `localDownloadState`:
    /// - `.downloading` / `.paused` (or initial): progress card with inline
    ///   Pause / Resume / Cancel controls.
    /// - `.failed`: an inline error card with Retry and Choose-another-model
    ///   actions, replacing the disruptive alert that previously could leave
    ///   the user stuck on a dead screen with a disabled Continue button.
    @ViewBuilder
    private var localDownloadingView: some View {
        if case .failed(let message) = state.localDownloadState {
            localDownloadFailedCard(message: message)
        } else {
            localDownloadProgressCard
        }
    }

    private var localDownloadProgressCard: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(theme.accentColor.opacity(0.14))
                            .frame(width: OnboardingMetrics.cardIcon, height: OnboardingMetrics.cardIcon)
                        Image(systemName: state.selectedModel?.isVLM == true ? "eye" : "cpu")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(downloadHeadline)
                                .font(theme.font(size: 14, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                            if state.isLocalPaused {
                                pausedPill
                            }
                        }
                        Text(localProgressText)
                            .font(theme.font(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    inlineDownloadControls
                }

                OnboardingShimmerBar(
                    progress: state.localBarProgress,
                    color: state.isLocalPaused ? theme.tertiaryText : theme.accentColor,
                    height: 6
                )
            }
            .padding(.horizontal, OnboardingMetrics.cardPaddingH)
            .padding(.vertical, OnboardingMetrics.cardPaddingV)
        }
    }

    private var downloadHeadline: String {
        let modelName = state.selectedModel?.name ?? L("model")
        if state.isLocalPaused {
            return L("Paused — \(modelName)")
        }
        return L("Downloading \(modelName)")
    }

    private var pausedPill: some View {
        Text("Paused", bundle: .module)
            .font(theme.font(size: 10, weight: .bold))
            .foregroundColor(theme.warningColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(theme.warningColor.opacity(0.14))
            )
    }

    /// Pause / Resume + Cancel inline controls — keep the Continue CTA below
    /// for "Continue when done", but give the user immediate, visible
    /// control over the in-flight download so they're never stuck (issue
    /// [#1071](https://github.com/osaurus-ai/osaurus/issues/1071)).
    @ViewBuilder
    private var inlineDownloadControls: some View {
        HStack(spacing: 6) {
            switch state.localDownloadState {
            case .paused:
                inlineIconButton(
                    systemName: "play.fill",
                    help: L("Resume download"),
                    tint: theme.accentColor,
                    action: state.resumeLocalDownload
                )
            case .downloading:
                inlineIconButton(
                    systemName: "pause.fill",
                    help: L("Pause download"),
                    tint: theme.secondaryText,
                    action: state.pauseLocalDownload
                )
            case .notStarted, .completed, .failed:
                EmptyView()
            }
            inlineIconButton(
                systemName: "xmark",
                help: L("Cancel download"),
                tint: theme.tertiaryText,
                action: state.cancelLocalDownload
            )
        }
    }

    private func inlineIconButton(
        systemName: String,
        help: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(theme.tertiaryBackground)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
    }

    /// Inline failure card. Replaces the previous alert-based UX so the user
    /// always has a clear path forward (Try again / Choose another model)
    /// without the chrome dead-ending into a disabled Continue button.
    private func localDownloadFailedCard(message: String) -> some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(theme.errorColor.opacity(0.14))
                            .frame(width: OnboardingMetrics.cardIcon, height: OnboardingMetrics.cardIcon)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.errorColor)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Download failed", bundle: .module)
                            .font(theme.font(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(message)
                            .font(theme.font(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        state.popLocalToPicker()
                    } label: {
                        Text("Choose another model", bundle: .module)
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    Button {
                        state.startLocalDownload()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Try again", bundle: .module)
                                .font(theme.font(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(theme.accentColor)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, OnboardingMetrics.cardPaddingH)
            .padding(.vertical, OnboardingMetrics.cardPaddingV)
        }
    }

    /// Single-line status text shown beneath the model headline. Pause hides
    /// live speed/ETA (they're meaningless when paused, and the pill above
    /// already communicates the pause state); the active download adds them
    /// when available.
    private var localProgressText: String {
        guard let model = state.selectedModel,
              let metrics = modelManager.downloadMetrics[model.id]
        else {
            return state.isLocalPaused ? L("Paused") : L("Preparing download...")
        }

        var parts: [String] = []
        if let received = metrics.bytesReceived, let total = metrics.totalBytes {
            parts.append("\(formatBytes(received)) / \(formatBytes(total))")
        }

        if state.isLocalPaused {
            return parts.isEmpty ? L("Paused") : parts.joined(separator: " · ")
        }

        if let speed = metrics.bytesPerSecond {
            parts.append("\(formatBytes(Int64(speed)))/s")
        }
        if let etaText = formatETA(metrics.etaSeconds) {
            parts.append(etaText)
        }
        return parts.joined(separator: " · ")
    }

    private func formatETA(_ seconds: Double?) -> String? {
        guard let eta = seconds, eta > 0, eta < 3600 else { return nil }
        let m = Int(eta) / 60
        let s = Int(eta) % 60
        return m > 0 ? L("\(m)m \(s)s remaining") : L("\(s)s remaining")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB]
        f.includesUnit = true
        return f.string(fromByteCount: bytes)
    }

    // MARK: - API picker

    private var apiPickerView: some View {
        VStack(spacing: OnboardingMetrics.cardSpacing) {
            ForEach(ConfigureAIState.onboardingPresets, id: \.id) { preset in
                apiPresetCard(preset)
            }
        }
    }

    private func apiPresetCard(_ preset: ProviderPreset) -> some View {
        OnboardingRowCard(
            icon: .custom {
                ProviderIcon(preset: preset, size: 18, color: theme.secondaryText)
            },
            title: preset == .custom ? L("Custom / OpenAI-compatible") : preset.name,
            subtitle: preset == .custom
                ? L("OpenRouter, Together AI, LM Studio, and more")
                : (preset == .openai ? L("ChatGPT, Codex, or Platform API") : preset.description),
            badges: preset.badge.map { [OnboardingRowBadge($0)] } ?? [],
            accessory: .chevron
        ) {
            // Drill-in: tapping a card commits the choice and advances
            // straight to the matching key form. No "Continue" press needed.
            state.selectAPIPreset(preset)
        }
    }

    // MARK: - API key form

    private var apiKeyFormView: some View {
        Group {
            if case .keyForm(let provider) = state.apiSubstate {
                VStack(spacing: 14) {
                    if provider == .openai {
                        openAIAuthChoiceSection
                    }
                    if provider != .openai || state.openAIAuthMode == .platformAPIKey {
                        apiKeyField(provider: provider)
                    }
                    if provider != .openai || state.openAIAuthMode == .platformAPIKey {
                        helpSection(for: provider)
                    }
                }
            }
        }
    }

    private var apiCustomFormView: some View {
        VStack(spacing: 14) {
            OnboardingGlassCard {
                customProviderForm.padding(14)
            }
            apiKeyField(provider: .custom)
        }
    }

    private var customProviderForm: some View {
        VStack(spacing: 12) {
            OnboardingTextField(
                label: "Name",
                placeholder: "e.g. My Provider",
                text: $state.customForm.name
            )

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROTOCOL", bundle: .module)
                        .font(theme.font(size: 10, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.5)
                    OnboardingProtocolToggle(selection: $state.customForm.protocolKind)
                        .frame(height: 38)
                }
                .frame(width: 130)

                OnboardingTextField(
                    label: "Host",
                    placeholder: "api.example.com",
                    text: $state.customForm.host,
                    isMonospaced: true
                )
            }

            HStack(spacing: 12) {
                OnboardingTextField(
                    label: "Port",
                    placeholder: state.customForm.protocolKind == .https ? "443" : "80",
                    text: $state.customForm.port,
                    isMonospaced: true
                )
                .frame(width: 100)

                OnboardingTextField(
                    label: "Base Path",
                    placeholder: "/v1",
                    text: $state.customForm.basePath,
                    isMonospaced: true
                )
            }

            if !state.customForm.host.isEmpty {
                endpointPreview
            }
        }
    }

    private func apiKeyField(provider: ProviderPreset) -> some View {
        OnboardingSecureField(
            placeholder: "sk-...",
            text: $state.apiKey,
            label: provider == .openai ? "OpenAI Platform API Key" : "API Key"
        )
        .onChange(of: state.apiKey) { _, _ in state.testResult = nil }
    }

    private var openAIAuthChoiceSection: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose your OpenAI access", bundle: .module)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                openAIAuthChoiceCard(
                    mode: .chatGPTSubscription,
                    title: OpenAIProviderCredentialMode.chatGPTSubscription.title,
                    subtitle: OpenAIProviderCredentialMode.chatGPTSubscription.subtitle,
                    icon: OpenAIProviderCredentialMode.chatGPTSubscription.icon
                )
                openAIAuthChoiceCard(
                    mode: .platformAPIKey,
                    title: OpenAIProviderCredentialMode.platformAPIKey.title,
                    subtitle: OpenAIProviderCredentialMode.platformAPIKey.subtitle,
                    icon: OpenAIProviderCredentialMode.platformAPIKey.icon
                )
            }
            .padding(14)
        }
    }

    private func openAIAuthChoiceCard(
        mode: OpenAIProviderCredentialMode,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        let selected = state.openAIAuthMode == mode
        return Button {
            // No `withAnimation` wrapper — propagating to the CTA (which
            // observes `openAIAuthMode` to switch between "Sign in with
            // ChatGPT" and "Connect") morphs the button. Selection
            // crossfade is handled locally by the `.animation(value:)`
            // modifier on the background fill below.
            state.openAIAuthMode = mode
            state.oauthTokens = nil
            state.testResult = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(selected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(selected ? theme.accentColor.opacity(0.12) : theme.tertiaryBackground))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.font(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(subtitle)
                        .font(theme.font(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(selected ? theme.accentColor : theme.tertiaryText)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? theme.accentColor.opacity(0.08) : theme.cardBackground.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(selected ? theme.accentColor.opacity(0.55) : theme.cardBorder, lineWidth: 1)
                    )
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selected)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var endpointPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundColor(theme.accentColor)
            Text(state.customForm.endpointPreview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(theme.accentColor.opacity(0.1))
        )
    }

    private func helpSection(for preset: ProviderPreset) -> some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Don't have a key?", bundle: .module)
                    .font(theme.font(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(preset.helpSteps.enumerated()), id: \.offset) { index, text in
                        HelpStepRow(number: index + 1, text: text)
                    }
                }

                ProviderHelpLinks(
                    preset: preset,
                    accentColor: theme.accentColor,
                    secondaryTextColor: theme.secondaryText
                )
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}

// MARK: - CTA

/// Primary CTA for the Configure AI step. Always rendered (never hidden) —
/// disabled until the active substate has a valid action. The picker
/// substates use a `Continue` button that's disabled until a selection is
/// made; the form substates use the stateful Connect/Test/Continue button.
struct ConfigureAICTA: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    @ObservedObject private var modelManager = ModelManager.shared

    var body: some View {
        primaryButton
            .onChange(of: state.isLocalCompleted) { _, completed in
                if completed && state.localSubstate == .downloading {
                    onComplete()
                }
            }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch state.selectedPath {
        case .appleFoundation:
            OnboardingBrandButton(title: "Use Apple Intelligence", action: onComplete)
                .frame(width: OnboardingMetrics.ctaWidthCompact)

        case .local:
            switch state.localSubstate {
            case .picker:
                OnboardingBrandButton(
                    title: state.selectedModel?.isDownloaded == true ? "Continue" : "Download & Install",
                    action: { state.startLocalDownloadOrContinue(onComplete: onComplete) },
                    isEnabled: state.selectedModel != nil
                )
                .frame(width: OnboardingMetrics.ctaWidthCompact)
            case .downloading:
                localDownloadingCTA
            }

        case .apiProvider:
            switch state.apiSubstate {
            case .picker:
                // Provider cards drill in on tap — no Continue press
                // required. The button stays visible and disabled so the
                // footer chrome doesn't blank out, and the layout doesn't
                // reflow when the user navigates into a key form.
                OnboardingBrandButton(
                    title: "Continue",
                    action: {},
                    isEnabled: false
                )
                .frame(width: OnboardingMetrics.ctaWidthCompact)
            case .keyForm, .customForm:
                apiActionButton
            }
        }
    }

    /// CTA for the local downloading screen. Mirrors the inline state-driven
    /// downloading view: while the download is in flight or paused, the
    /// CTA is disabled and the inline Pause/Resume/Cancel controls own the
    /// action surface. On failure the CTA flips to a "Try Again" button so
    /// the user always has a path forward — issue [#1071](https://github.com/osaurus-ai/osaurus/issues/1071).
    @ViewBuilder
    private var localDownloadingCTA: some View {
        if state.isLocalFailed {
            OnboardingBrandButton(
                title: "Try Again",
                action: { state.startLocalDownload() }
            )
            .frame(width: OnboardingMetrics.ctaWidthCompact)
        } else {
            OnboardingBrandButton(
                title: "Continue",
                action: onComplete,
                isEnabled: state.isLocalCompleted
            )
            .frame(width: OnboardingMetrics.ctaWidthCompact)
        }
    }

    private var apiActionButton: some View {
        let provider = state.currentAPIProvider
        let isOpenAIChatGPT = provider == .openai && state.openAIAuthMode == .chatGPTSubscription
        return OnboardingStatefulButton(
            state: state.apiButtonState,
            idleTitle: isOpenAIChatGPT ? "Sign in with ChatGPT" : "Connect",
            loadingTitle: isOpenAIChatGPT ? "Signing in..." : (state.isSaving ? "Connecting..." : "Testing..."),
            successTitle: "Continue",
            errorTitle: "Try Again",
            action: {
                if state.isAPISuccess {
                    state.saveProviderAndContinue(onComplete: onComplete)
                } else {
                    state.testAPIConnection()
                }
            },
            isEnabled: state.canTestAPI
        )
        .frame(width: OnboardingMetrics.ctaWidthCompact)
    }
}

// MARK: - Secondary

/// Secondary action (text-link, leading edge of the footer) for Configure AI.
/// Only the local-downloading substate currently has one ("Download later").
struct ConfigureAISecondary: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    var body: some View {
        switch state.selectedPath {
        case .local:
            switch state.localSubstate {
            case .downloading:
                // Always offer a soft escape so the user can finish
                // onboarding even mid-download. The inline failure card
                // already exposes Retry + Choose-another-model, so when
                // failed we just show "Skip for now" rather than a
                // duplicate retry affordance.
                OnboardingTextButton(
                    title: secondaryDownloadingTitle,
                    action: onComplete
                )
            case .picker:
                EmptyView()
            }
        case .apiProvider, .appleFoundation:
            EmptyView()
        }
    }

    private var secondaryDownloadingTitle: String {
        switch state.localDownloadState {
        case .failed: return L("Skip for now")
        case .paused: return L("Finish later")
        case .downloading: return L("Continue in background")
        case .completed, .notStarted: return L("Download later")
        }
    }
}

// MARK: - Protocol Toggle

private struct OnboardingProtocolToggle: View {
    @Binding var selection: RemoteProviderProtocol

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            protocolButton("HTTPS", protocol: .https)
            protocolButton("HTTP", protocol: .http)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private func protocolButton(_ label: String, protocol proto: RemoteProviderProtocol) -> some View {
        Button {
            withAnimation(theme.animationQuick()) { selection = proto }
        } label: {
            Text(label)
                .font(theme.font(size: 11, weight: .semibold))
                .foregroundColor(selection == proto ? .white : theme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selection == proto ? theme.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Help Step Row

private struct HelpStepRow: View {
    let number: Int
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).", bundle: .module)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(theme.font(size: 11))
                .foregroundColor(theme.secondaryText)
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingConfigureAIView_Previews: PreviewProvider {
        static var previews: some View {
            let state = ConfigureAIState()
            return VStack {
                ConfigureAIBody(state: state).frame(height: 460)
                HStack {
                    ConfigureAISecondary(state: state, onComplete: {})
                    Spacer()
                    ConfigureAICTA(state: state, onComplete: {})
                }
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 660)
        }
    }
#endif
