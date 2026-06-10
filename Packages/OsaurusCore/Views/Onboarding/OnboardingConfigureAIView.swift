//
//  OnboardingConfigureAIView.swift
//  osaurus
//
//  Onboarding step 3 — pick where the model brain lives (a curated local
//  MLX model, or any cloud / locally-hosted provider) and configure it
//  inline.
//
//  Apple Intelligence was removed from this step: it's too limited (no
//  tools, no web, no agent work) to be a first-class first-run option.
//  Users with `FoundationModelService` available can still configure it
//  post-onboarding from Settings.
//
//  Split into:
//   - `ConfigureAIState`: ObservableObject holding path/substate selection,
//     connection-test progress, and the substate slide direction (lives at
//     OnboardingView level).
//   - `ConfigureAIBody`: the body slot — sticky segmented path picker plus a
//     per-path substate body that slides direction-aware between picker
//     and drilled-in forms.
//   - `ConfigureAICTA`: the footer primary action, dispatched per substate.
//

import SwiftUI

// MARK: - Path

enum ConfigurePath: String, CaseIterable {
    case local
    case apiProvider

    var title: LocalizedStringKey {
        switch self {
        case .local: return "Local"
        case .apiProvider: return "Cloud"
        }
    }

    var icon: String {
        switch self {
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
    /// "Use an API key" drill-in: grouped list of API-key vendors, the local
    /// Ollama option, and the custom OpenAI-compatible escape hatch.
    case apiKeyPicker
    case keyForm(ProviderPreset)
    case customForm
}

enum APITestResult: Equatable {
    case success
    case failure(String)
}

// MARK: - Auth choice protocol

// MARK: - Resolved provider config

struct ResolvedProviderConfig {
    let name: String
    let host: String
    let port: Int?
    let basePath: String
    let providerType: RemoteProviderType
    let providerProtocol: RemoteProviderProtocol
    let authType: RemoteProviderAuthType
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

    /// Treat localhost-style hosts as "no auth required" — covers Ollama, LM
    /// Studio, llama.cpp server, vLLM, etc. when the user wires them up via
    /// the custom form.
    var isLocalhost: Bool {
        let h = host.lowercased().trimmingCharacters(in: .whitespaces)
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "0.0.0.0"
    }

    func resolved(displayName: String, apiKey: String) -> ResolvedProviderConfig {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let authType: RemoteProviderAuthType = (isLocalhost && trimmedKey.isEmpty) ? .none : .apiKey
        return ResolvedProviderConfig(
            name: name.isEmpty ? displayName : name,
            host: host,
            port: port.isEmpty ? nil : Int(port),
            basePath: basePath.isEmpty ? "/v1" : basePath,
            providerType: .openaiLegacy,
            providerProtocol: protocolKind,
            authType: authType
        )
    }
}

// MARK: - State

@MainActor
final class ConfigureAIState: ObservableObject {
    @Published var selectedPath: ConfigurePath = .local
    @Published var localSubstate: LocalSubstate = .picker
    @Published var apiSubstate: APISubstate = .picker

    /// Guards `applyDefaultPathIfNeeded(totalMemoryGB:)` so the RAM-based
    /// default path is only ever applied once. Without it a user who manually
    /// switched back to Local would be bounced to Cloud again on the next
    /// `onAppear`.
    private var didApplyDefaultPath = false

    /// Direction the next substate transition should travel. Mirrors the
    /// global step `OnboardingDirection` so the substate slide reads as a
    /// natural continuation of the outer navigation language.
    @Published var substateDirection: OnboardingDirection = .forward

    // Local
    @Published var selectedModel: MLXModel? = nil
    /// Whether the local picker has expanded past the single opinionated
    /// default to reveal the remaining eligible models. Lives on the state
    /// (not the body view) so the choice survives step slide transitions.
    @Published var showAllLocalModels = false

    // API
    @Published var apiKey: String = ""
    /// The connection method pinned for the selected provider, set from the
    /// catalog at selection time (OAuth for top-level rows, `.apiKey` for the
    /// "Use an API key" sub-list). There is no in-form fork; this drives the
    /// CTA, key field, save/test branches, and back-routing.
    @Published var selectedAuthMethod: ProviderPickerAuthMethod = .apiKey
    @Published var oauthTokens: RemoteProviderOAuthTokens? = nil

    /// The OAuth flavor of the current selection, if any.
    var selectedOAuthKind: ProviderOAuthKind? {
        if case .oauth(let kind) = selectedAuthMethod { return kind }
        return nil
    }
    @Published var customForm = CustomProviderForm()
    @Published var isTesting = false
    @Published var isSaving = false
    @Published var testResult: APITestResult? = nil
    /// One-shot latch so the auto-advance-on-green and a manual CTA press can't
    /// both finalize. Reset whenever credentials are cleared (back / reselect).
    var hasFinalizedAPI = false

    /// Whether the Local tab should be offered at all on this Mac. RAM is an
    /// advisory fit signal only; users can still choose local models on small
    /// machines because mmap-backed runtimes may succeed under macOS memory
    /// compression/paging even when a static estimate looks tight.
    static func isLocalTabAvailable(totalMemoryGB: Double) -> Bool {
        true
    }

    /// Paths offered on this Mac.
    func availablePaths(totalMemoryGB: Double) -> [ConfigurePath] {
        [.local, .apiProvider]
    }

    // No footer caption on either tab. The reassurance copy crowded the footer,
    // and — more importantly — a caption on one tab but not the other makes the
    // footer (and thus the centered left-column dino) jump in height when the
    // user switches tabs. Keeping both captionless holds the layout steady.
    var footerCaption: LocalizedStringKey? { nil }

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

    /// Picks the lowest-friction default tab for this Mac on first appearance.
    /// Local remains available even on low-RAM Macs; compatibility only affects
    /// the recommended model and warning badges.
    func applyDefaultPathIfNeeded(totalMemoryGB: Double) {
        guard !didApplyDefaultPath else { return }
        // `totalMemoryGB == 0` means the monitor hasn't reported yet; wait for
        // a real value before committing to a default.
        guard totalMemoryGB > 0 else { return }
        didApplyDefaultPath = true
    }

    /// Auto-selects the recommended local pick — the best model this Mac can
    /// run — so the picker lands on a sensible default the user can just
    /// accept. The rule is deliberately simple and hardware-deterministic:
    ///
    ///   1. If a curated top pick is already on disk, keep it. The user
    ///      downloaded (and presumably ran) it before, so the compat
    ///      heuristic shouldn't lock them out.
    ///   2. Otherwise pick the *largest* top pick this Mac can comfortably
    ///      run (`.compatible`), falling back to the largest that merely fits
    ///      when nothing lands in the comfortable band. Bigger ≈ higher
    ///      quality, so "the best the machine can handle" is the best
    ///      first-run experience.
    ///
    /// Falls back to the smallest curated top pick when every option is tight
    /// or too large, so onboarding never dead-ends on RAM estimates alone.
    /// `.unknown` (no param info / monitor not yet populated) fails open.
    func ensureLocalSelection(totalMemoryGB: Double) {
        guard selectedModel == nil else { return }

        // 1. A curated top pick already on disk wins. Onboarding only shows
        // top picks, so we don't fall back to ad-hoc downloaded models that
        // wouldn't appear in the list anyway.
        let downloaded = ModelManager.shared.deduplicatedModels().filter(\.isDownloaded)
        if let topDownloaded = downloaded.first(where: \.isTopSuggestion) {
            selectedModel = topDownloaded
            return
        }

        // 2. The largest top pick the Mac can comfortably run.
        let candidates = ModelManager.shared.suggestedModels.filter(\.isTopSuggestion)
        let comfortable = candidates.filter {
            $0.compatibility(totalMemoryGB: totalMemoryGB) == .compatible
        }
        let tight = candidates.filter {
            $0.compatibility(totalMemoryGB: totalMemoryGB) == .tight
        }
        let pool = !comfortable.isEmpty ? comfortable : (!tight.isEmpty ? tight : candidates)
        selectedModel =
            pool.max(by: { ($0.estimatedMemoryGB ?? 0) < ($1.estimatedMemoryGB ?? 0) })
            ?? candidates.first
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
        case .picker, .apiKeyPicker: return nil
        }
    }

    var canTestAPI: Bool {
        guard let provider = currentAPIProvider else { return false }
        if provider == .custom {
            guard !customForm.host.isEmpty else { return false }
            // Localhost endpoints typically don't authenticate — let users
            // press Connect with an empty key (Ollama, LM Studio, etc.).
            return customForm.isLocalhost || apiKey.count > 5
        }
        // A browser sign-in is connectable as soon as the provider is picked —
        // the OAuth flow itself collects the credential.
        if selectedAuthMethod.isOAuth {
            return true
        }
        // Presets that don't require auth (e.g. Ollama) are connectable as soon
        // as they're selected.
        if provider.configuration.authType == .none {
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
        clearAPICredentials()
    }

    /// Clear entered credentials, auth-mode selections, and the last test
    /// result. Shared by every "back out of a form" path so stale secrets
    /// never leak across provider selections.
    private func clearAPICredentials() {
        apiKey = ""
        selectedAuthMethod = .apiKey
        oauthTokens = nil
        customForm.reset()
        testResult = nil
        hasFinalizedAPI = false
    }

    /// Top-level "Use an API key" drill-in (OAuth-first picker → grouped
    /// API-key sub-list).
    func showAPIKeyPicker() {
        substateDirection = .forward
        apiSubstate = .apiKeyPicker
    }

    /// Back out of the API-key sub-list to the OAuth-first top level.
    func popAPIKeyPickerToTop() {
        substateDirection = .backward
        apiSubstate = .picker
    }

    /// Back out of a provider form. A form entered via the OAuth-first top level
    /// returns there; everything reached through the "Use an API key" sub-list
    /// (key vendors including the dual-mode OAuth presets, Ollama, Custom)
    /// returns to that sub-list. Routing is read from the pinned auth mode
    /// *before* `clearAPICredentials()` resets it to the OAuth defaults.
    func popFormToPicker(for preset: ProviderPreset) {
        substateDirection = .backward
        // A form reached via OAuth lives at the top level; everything else
        // (pasted-key vendors, dual-mode presets in api-key mode, Ollama,
        // Custom) was reached through the "Use an API key" sub-list. Read the
        // pinned method before `clearAPICredentials()` resets it.
        let returnToTop = selectedAuthMethod.isOAuth
        clearAPICredentials()
        apiSubstate = returnToTop ? .picker : .apiKeyPicker
    }

    /// Picker → form drill-in. Tapping a provider card immediately advances
    /// to its key form (or the custom-provider form), no "Continue" press
    /// required.
    ///
    /// The connection method for dual-mode providers (OpenAI, OpenRouter, xAI)
    /// is decided by where the card lives: the OAuth-first top level uses OAuth,
    /// the "Use an API key" sub-list (`preferAPIKey`) uses the pasted key. There
    /// is no in-form fork, so we pin the auth mode here at selection time.
    func selectAPIPreset(_ preset: ProviderPreset, preferAPIKey: Bool = false) {
        substateDirection = .forward
        if let entry = ProviderCatalog.entry(for: preset) {
            selectedAuthMethod = preferAPIKey ? .apiKey : (entry.authMethods.first ?? .apiKey)
        }
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
            return customForm.resolved(displayName: L("Custom Provider"), apiKey: apiKey)
        }
        let cfg = provider.configuration
        return ResolvedProviderConfig(
            name: cfg.name,
            host: cfg.host,
            port: cfg.port,
            basePath: cfg.basePath,
            providerType: cfg.providerType,
            providerProtocol: cfg.providerProtocol,
            authType: cfg.authType
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
                switch self.selectedAuthMethod {
                case .oauth(.openAICodex):
                    let tokens = try await OpenAICodexOAuthService.signIn()
                    self.oauthTokens = tokens
                case .oauth(.openRouter):
                    // The browser sign-in IS the test: it returns a freshly minted
                    // OpenRouter API key, which we stash in `apiKey` for the save
                    // step to persist via the standard apiKey path.
                    let key = try await OpenRouterOAuthService.signIn()
                    self.apiKey = key
                case .oauth(.xai):
                    // Grok sign-in returns access/refresh tokens stashed for the
                    // save step to persist via the `.xaiOAuth` path.
                    let tokens = try await XAIOAuthService.signIn()
                    self.oauthTokens = tokens
                case .apiKey, .none:
                    _ = try await RemoteProviderManager.shared.testConnection(
                        host: config.host,
                        providerProtocol: config.providerProtocol,
                        port: config.port,
                        basePath: config.basePath,
                        authType: config.authType,
                        providerType: config.providerType,
                        apiKey: config.authType == .apiKey ? self.apiKey : nil,
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
        // One-shot: a successful test auto-advances, but the CTA is also still
        // tappable during the brief green window, so both routes funnel through
        // this latch to avoid adding the provider (and advancing) twice.
        guard !hasFinalizedAPI else { return }
        guard let config = resolvedAPIConfig() else { return }
        hasFinalizedAPI = true
        isSaving = true

        // OpenAI Codex and xAI persist OAuth tokens via a service-provided
        // provider config; OpenRouter's OAuth mints a plain key handled by the
        // standard apiKey path below.
        if selectedOAuthKind == .openAICodex {
            let provider = OpenAICodexOAuthService.makeProvider()
            RemoteProviderManager.shared.addProvider(provider, apiKey: nil, oauthTokens: oauthTokens)
            isSaving = false
            onComplete()
            return
        }

        if selectedOAuthKind == .xai {
            let provider = XAIOAuthService.makeProvider()
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
            authType: config.authType,
            providerType: config.providerType,
            enabled: true,
            autoConnect: true,
            timeout: 60
        )
        RemoteProviderManager.shared.addProvider(
            provider,
            apiKey: config.authType == .apiKey ? apiKey : nil
        )
        isSaving = false
        onComplete()
    }
}

// MARK: - Body

struct ConfigureAIBody: View {
    @ObservedObject var state: ConfigureAIState

    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = ModelManager.shared
    /// Drives the capability filter on the local picker. `totalMemoryGB`
    /// is populated synchronously in `SystemMonitorService.init`, so the
    /// first onboarding frame already has a real value to classify
    /// curated top suggestions against.
    @ObservedObject private var systemMonitor = SystemMonitorService.shared

    var body: some View {
        OnboardingTwoColumnBody(
            illustrationAsset: "osaurus-brain",
            leftHeadline: "Pick a brain",
            leftBody:
                "Run a brain on your Mac, or plug in one you already pay for. You can swap brains any time, and your chats come along.",
            subtitle: pathSubtitle,
            // We manage our own inner scroll: the segmented control stays
            // pinned at the top while the substate body scrolls beneath it.
            useScrollView: false
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if showsModeToggle {
                    pathSegmentedControl
                }

                // Substate envelope. Clipped horizontally so the slide
                // transition never bleeds into the left column, but
                // vertically scaled (`y: 4`) so card hover shadows can
                // escape the substate region without being trimmed at
                // the scroll-area edges.
                ZStack(alignment: .topLeading) {
                    substateContainer
                        .id(substateID)
                        .transition(substateTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(Rectangle().scale(x: 1, y: 4))
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: substateID)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            state.applyDefaultPathIfNeeded(totalMemoryGB: systemMonitor.totalMemoryGB)
            state.ensureLocalSelection(totalMemoryGB: systemMonitor.totalMemoryGB)
        }
    }

    // MARK: - Path subtitle

    private var pathSubtitle: LocalizedStringKey {
        switch state.selectedPath {
        case .local: return "Runs right on your Mac. Private, and works offline."
        case .apiProvider:
            return "Already have a favorite AI? Connect it in a tap."
        }
    }

    // MARK: - Path Segmented Control

    /// Binding that drives the shared `OnboardingSegmentedControl` while
    /// preserving the side effects on `state.selectPath(_:)` (substate
    /// reset, slide direction). A direct `$state.selectedPath` binding
    /// would skip those.
    private var pathBinding: Binding<ConfigurePath> {
        Binding(
            get: { state.selectedPath },
            set: { state.selectPath($0) }
        )
    }

    /// Paths offered on this Mac, gated by available memory (Cloud-only on
    /// sub-24GB machines). Computed from the live monitor reading rather than
    /// `state` so the first frame is already correct — no Local-tab flash.
    private var availablePaths: [ConfigurePath] {
        state.availablePaths(totalMemoryGB: systemMonitor.totalMemoryGB)
    }

    /// The mode toggle is the single top-level nav: show it only on the two
    /// top-level pickers, and only when there's actually a choice to make.
    /// Once the user drills into the API-key hub / a form / a download, the
    /// in-section "Back" row owns navigation instead.
    private var showsModeToggle: Bool {
        guard availablePaths.count > 1 else { return false }
        switch state.selectedPath {
        case .local: return state.localSubstate == .picker
        case .apiProvider: return state.apiSubstate == .picker
        }
    }

    private var pathSegmentedControl: some View {
        OnboardingSegmentedControl(
            selection: pathBinding,
            items: availablePaths.map {
                OnboardingSegmentItem(tag: $0, title: $0.title, icon: $0.icon)
            }
        )
    }

    // MARK: - Substate dispatch

    private var substateID: String {
        switch state.selectedPath {
        case .local:
            switch state.localSubstate {
            case .picker: return "local-picker"
            case .downloading: return "local-downloading"
            }
        case .apiProvider:
            switch state.apiSubstate {
            case .picker: return "api-picker"
            case .apiKeyPicker: return "api-key-picker"
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
        case .local: localSubstateContainer
        case .apiProvider: apiSubstateContainer
        }
    }

    @ViewBuilder
    private var localSubstateContainer: some View {
        switch state.localSubstate {
        case .picker:
            OnboardingScrollContainer { localPickerView }
        case .downloading:
            substateWithBackBar(onBack: { state.popLocalToPicker() }) {
                localDownloadingView
            }
        }
    }

    @ViewBuilder
    private var apiSubstateContainer: some View {
        switch state.apiSubstate {
        case .picker:
            OnboardingScrollContainer { apiPickerView }
        case .apiKeyPicker:
            substateWithBackBar(onBack: { state.popAPIKeyPickerToTop() }) {
                apiKeyPickerView
            }
        case .keyForm(let provider):
            substateWithBackBar(onBack: { state.popFormToPicker(for: provider) }) {
                apiKeyFormView
            }
        case .customForm:
            substateWithBackBar(onBack: { state.popFormToPicker(for: .custom) }) {
                apiCustomFormView
            }
        }
    }

    /// Sub-substate frame: an in-context back row (drills out to the
    /// picker) followed by the substate body wrapped in the shared
    /// scroll container for any overflow (key forms, custom-provider
    /// form, etc.).
    private func substateWithBackBar<C: View>(
        onBack: @escaping () -> Void,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            substateBackRow(onBack: onBack)
            OnboardingScrollContainer { content() }
        }
    }

    private func substateBackRow(onBack: @escaping () -> Void) -> some View {
        // Always a plain "Back" — the section title was redundant breadcrumb
        // noise (and truncated awkwardly, e.g. "Use an API k…").
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back", bundle: .module)
                    .font(theme.font(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.secondaryText)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedHelp("Back")
    }

    // MARK: - Local picker

    /// Top-suggestion curated models paired with their compatibility
    /// verdict against the current `totalMemoryGB`. `.unknown` is treated
    /// as "let through" — same fail-open behavior as
    /// `ModelFilterState.PerformanceFilter.hideTooLarge`, so the list
    /// isn't blank during startup before the system monitor reports.
    private var topSuggestionsWithCompatibility: [(model: MLXModel, compatibility: ModelCompatibility)] {
        let totalMemoryGB = systemMonitor.totalMemoryGB
        return modelManager.suggestedModels
            .filter(\.isTopSuggestion)
            .map { ($0, $0.compatibility(totalMemoryGB: totalMemoryGB)) }
    }

    /// What the local picker renders: the curated top suggestions only.
    ///
    /// Onboarding is intentionally opinionated — it surfaces only our curated
    /// top picks (downloaded ones still appear, badged "Downloaded"), so the
    /// first-run list never balloons with ad-hoc / auto-fetched models the
    /// user happens to have on disk. The full catalog lives in the Models tab.
    private var localPickerModels: [(model: MLXModel, compatibility: ModelCompatibility)] {
        topSuggestionsWithCompatibility
    }

    @ViewBuilder
    private var localPickerView: some View {
        let pairs = localPickerModels
        if !pairs.isEmpty {
            // Be opinionated: surface a single recommended pick (the model
            // `ensureLocalSelection` chose) and tuck everything else behind a
            // disclosure, so first-run isn't a wall of model choices.
            let featuredId = state.selectedModel?.id
            let featured = pairs.first(where: { $0.model.id == featuredId }) ?? pairs.first
            let rest = pairs.filter { $0.model.id != featured?.model.id }

            VStack(spacing: OnboardingMetrics.cardSpacing) {
                computeIntensiveCallout
                if let featured {
                    localModelCard(for: featured)
                }
                if !rest.isEmpty {
                    localMoreOptionsDisclosure(count: rest.count)
                    if state.showAllLocalModels {
                        ForEach(rest, id: \.model.id) { pair in
                            localModelCard(for: pair)
                        }
                    }
                }
            }
        }
    }

    /// One selectable local-model row. Shared by the featured default and the
    /// disclosure-revealed remainder so both read identically.
    private func localModelCard(
        for pair: (model: MLXModel, compatibility: ModelCompatibility)
    ) -> some View {
        let model = pair.model
        return OnboardingRowCard(
            icon: .symbol(model.isVLM ? "eye" : "cpu"),
            title: model.name,
            subtitle: model.description,
            secondaryLine: model.formattedReleaseMonth.map { L("Released \($0)") },
            badges: localBadges(for: model, compatibility: pair.compatibility),
            // Local model rows ship up to four badges
            // (use case · size · modality · compat verdict);
            // inline next to the title they truncated the
            // model name to "Gemm…". Bump them to their own
            // row so the full name is always readable.
            badgesBelowTitle: true,
            accessory: .radio(isSelected: state.selectedModel?.id == model.id),
            isSelected: state.selectedModel?.id == model.id,
            isDisabled: false
        ) {
            // No `withAnimation` — selecting a model otherwise
            // morphs the CTA between "Continue" and
            // "Download & Install" as a side-effect of the
            // shared transaction.
            state.selectedModel = model
        }
    }

    /// Expand / collapse control for the non-featured local models.
    private func localMoreOptionsDisclosure(count: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                state.showAllLocalModels.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(state.showAllLocalModels ? 180 : 0))
                Text(
                    state.showAllLocalModels
                        ? L("Hide other options")
                        : L("See other options (\(count))")
                )
                .font(theme.font(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.accentColor)
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedHelp("See other options")
    }

    /// Inline explainer rendered above the curated list — first-time
    /// users don't realize local models actually run on their Mac, so
    /// we set the RAM / latency / offline expectation up front rather
    /// than burying it in the model detail view.
    private var computeIntensiveCallout: some View {
        OnboardingGlassCard {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(0.14))
                        .frame(width: 28, height: 28)
                    Image(systemName: "cpu")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                Text(
                    "Local brains live on your Mac. They use a chunk of memory while running, and they keep working offline.",
                    bundle: .module
                )
                .font(theme.font(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// Order: use-case category (leading scannable signal) → status /
    /// size → modality → capability verdict (trailing, near the
    /// accessory where the eye lands to evaluate the row).
    private func localBadges(
        for model: MLXModel,
        compatibility: ModelCompatibility
    ) -> [OnboardingRowBadge] {
        var result: [OnboardingRowBadge] = []
        if let useCase = model.useCase {
            result.append(.useCase(useCase))
        }
        if model.isDownloaded {
            result.append(OnboardingRowBadge(L("Downloaded"), style: .success))
        } else if let size = model.formattedDownloadSize {
            result.append(OnboardingRowBadge(size))
        }
        result.append(OnboardingRowBadge(model.isVLM ? "VLM" : "LLM"))
        switch compatibility {
        case .tight:
            result.append(OnboardingRowBadge(L("Tight fit"), style: .warning))
        case .tooLarge:
            result.append(OnboardingRowBadge(L("Too large for this Mac"), style: .error))
        case .compatible, .unknown:
            break
        }
        return result
    }

    // MARK: - Local downloading

    /// State-driven downloading view. Renders one of two layouts
    /// depending on the live `localDownloadState`:
    /// - `.downloading` / `.paused` (or initial): progress card with
    ///   inline Pause / Resume / Cancel controls.
    /// - `.failed`: inline error card with Retry and
    ///   Choose-another-model actions, so the user always has a path
    ///   forward without a disabled Continue button.
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

    /// Inline failure card with Try again / Choose another model
    /// actions, so the user always has a clear path forward without
    /// the chrome dead-ending into a disabled Continue button.
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
                    OnboardingCompactButton(
                        title: "Choose another model",
                        style: .ghost,
                        action: { state.popLocalToPicker() }
                    )
                    OnboardingCompactButton(
                        title: "Try again",
                        icon: "arrow.clockwise",
                        style: .accent,
                        action: { state.startLocalDownload() }
                    )
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

    /// OAuth-first top level: one-click sign-in providers as first-class rows,
    /// then a single "Use an API key" drill-in that holds every paste-a-key
    /// vendor, the local Ollama option, and the custom escape hatch.
    private var apiPickerView: some View {
        VStack(spacing: OnboardingMetrics.cardSpacing) {
            ForEach(ProviderPreset.oauthProviders, id: \.id) { preset in
                apiPresetCard(preset)
            }
            useAPIKeyCard
        }
    }

    /// Drill-in entry to the grouped API-key sub-list. Titled "Use an API key"
    /// even though it also houses Ollama (local) and Custom, because API-key
    /// vendors are the dominant case; the sub-list section headers disambiguate.
    private var useAPIKeyCard: some View {
        OnboardingRowCard(
            icon: .symbol("key.fill"),
            title: L("Use an API key"),
            subtitle: L("Anthropic, Google, Ollama, and more — paste a key to connect"),
            accessory: .chevron
        ) {
            state.showAPIKeyPicker()
        }
    }

    /// Grouped API-key sub-list (key vendors / Local / Custom). Azure OpenAI is
    /// omitted in onboarding (it needs extra endpoint + deployment fields).
    private var apiKeyPickerView: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(ProviderPreset.apiKeyPickerGroups(includeAzure: false)) { section in
                VStack(alignment: .leading, spacing: OnboardingMetrics.cardSpacing) {
                    Text(LocalizedStringKey(section.title), bundle: .module)
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .textCase(.uppercase)
                    ForEach(section.presets, id: \.id) { preset in
                        apiPresetCard(preset, preferAPIKey: true)
                    }
                }
            }
        }
    }

    /// `preferAPIKey` distinguishes the "Use an API key" sub-list rows (pasted
    /// key) from the OAuth-first top-level rows for the dual-mode presets.
    private func apiPresetCard(_ preset: ProviderPreset, preferAPIKey: Bool = false) -> some View {
        OnboardingRowCard(
            icon: .custom {
                ProviderIcon(preset: preset, size: 18, color: theme.secondaryText)
            },
            title: presetTitle(for: preset),
            subtitle: presetSubtitle(for: preset, preferAPIKey: preferAPIKey),
            badges: presetBadges(for: preset),
            accessory: .chevron
        ) {
            // Drill-in: tapping a card commits the choice and advances
            // straight to the matching key form. No "Continue" press needed.
            state.selectAPIPreset(preset, preferAPIKey: preferAPIKey)
        }
    }

    private func presetTitle(for preset: ProviderPreset) -> String {
        preset == .custom ? L("Custom / OpenAI-compatible") : preset.name
    }

    /// Onboarding-specific subtitle. Diverges from the generic
    /// `preset.description` for the custom card (concrete example providers) and
    /// for the dual-mode presets, whose subtitle reflects the entry point: the
    /// OAuth-first top level describes the browser sign-in, the "Use an API key"
    /// sub-list (`preferAPIKey`) describes the pasted key.
    private func presetSubtitle(for preset: ProviderPreset, preferAPIKey: Bool = false) -> String {
        // Returns localization *keys*; the row card localizes via
        // `LocalizedStringKey(subtitle)`, so don't pre-localize here.
        ProviderCatalog.entry(for: preset)?.pickerSubtitle(preferAPIKey: preferAPIKey)
            ?? preset.description
    }

    /// Lift selected provider badges to a richer style so the cloud
    /// picker stays scannable. Ollama's "Local" label specifically gets
    /// the success-green chip — it lives in the Cloud tab for routing
    /// reasons (same HTTP code path), but the row needs to read as "this
    /// is the local-server option" at a glance.
    private func presetBadges(for preset: ProviderPreset) -> [OnboardingRowBadge] {
        guard let label = preset.badge else { return [] }
        let style: OnboardingRowBadge.Style = (preset == .ollama) ? .success : .neutral
        return [OnboardingRowBadge(label, style: style)]
    }

    // MARK: - API key form

    @ViewBuilder
    private var apiKeyFormView: some View {
        if case .keyForm(let provider) = state.apiSubstate {
            apiKeyForm(provider: provider)
        }
    }

    private func apiKeyForm(provider: ProviderPreset) -> some View {
        // Compute once — both the key field and the help section condition
        // depend on the same answer.
        let showsKeyField = shouldShowKeyField(for: provider)
        let isNoAuth = provider.configuration.authType == .none

        return VStack(spacing: 14) {
            if isNoAuth {
                noAuthEndpointBanner(for: provider)
            } else if let kind = state.selectedOAuthKind {
                // Dual-mode preset reached via the OAuth-first top level: the
                // browser sign-in IS the action (footer CTA), so the body just
                // explains what's about to happen.
                oauthInfoBanner(for: kind)
            }
            if showsKeyField {
                apiKeyField(provider: provider)
            }
            if showsKeyField || isNoAuth {
                helpSection(for: provider)
            }
        }
    }

    /// Body shown for the OAuth-first entry of a dual-mode preset. There's no
    /// key field — the footer button starts the browser flow — so this banner
    /// carries the short "here's how this works" context the auth-choice card
    /// used to provide.
    private func oauthInfoBanner(for kind: ProviderOAuthKind) -> some View {
        OnboardingGlassCard {
            HStack(spacing: 10) {
                Image(systemName: kind.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(LocalizedStringKey(kind.subtitle), bundle: .module)
                    .font(theme.font(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    /// Replaces the API key field for presets that authenticate locally (no
    /// key required — Ollama, etc.). Shows the resolved endpoint so the user
    /// can confirm where Osaurus will look.
    private func noAuthEndpointBanner(for preset: ProviderPreset) -> some View {
        let cfg = preset.configuration
        var url = cfg.providerProtocol.rawValue + "://" + cfg.host
        if let port = cfg.port { url += ":\(port)" }
        url += cfg.basePath
        return OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.successColor)
                    Text("No API key required", bundle: .module)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundColor(theme.accentColor)
                    Text(url)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    /// Whether the key form should expose the raw API key field + help
    /// section. Both OpenAI and OpenRouter offer an OAuth alternative, and
    /// the field is only relevant when the user picks the paste-key mode.
    private func shouldShowKeyField(for provider: ProviderPreset) -> Bool {
        // Dual-mode providers only show the raw key field in api-key mode;
        // everything else falls back to whether the preset uses an API key.
        if let entry = ProviderCatalog.entry(for: provider), entry.primaryOAuthKind != nil {
            return state.selectedAuthMethod == .apiKey
        }
        return provider.configuration.authType == .apiKey
    }

    private var apiCustomFormView: some View {
        VStack(spacing: 14) {
            OnboardingGlassCard {
                customProviderForm.padding(14)
            }
            apiKeyField(provider: .custom)
            if state.customForm.isLocalhost {
                customFormLocalhostHint
            }
        }
    }

    private var customFormLocalhostHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text(
                "Local endpoints don't usually need a key — leave blank to skip auth.",
                bundle: .module
            )
            .font(theme.font(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 4)
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
                    Text("Protocol", bundle: .module)
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                    OnboardingSegmentedControl(
                        selection: $state.customForm.protocolKind,
                        items: [
                            OnboardingSegmentItem(tag: .https, title: "HTTPS"),
                            OnboardingSegmentItem(tag: .http, title: "HTTP"),
                        ],
                        style: .compact
                    )
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

    private var endpointPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundColor(theme.accentColor)
            Text(state.customForm.endpointPreview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, OnboardingMetrics.bannerPaddingH)
        .padding(.vertical, OnboardingMetrics.bannerPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OnboardingMetrics.bannerCornerRadius)
                .fill(theme.accentColor.opacity(0.1))
        )
    }

    private func helpSection(for preset: ProviderPreset) -> some View {
        let heading: LocalizedStringKey =
            preset.configuration.authType == .none
            ? "Don't have it set up yet?"
            : "Don't have a key?"
        return OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(heading, bundle: .module)
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

/// Primary CTA for the Configure AI step, dispatched per substate:
///   - Local picker: Download/Continue, enabled once a model is selected.
///   - Local downloading: a single adaptive "Continue in Background" →
///     "Continue" button (plus "Try Again" on failure).
///   - Cloud picker / API-key hub: cards drill in on tap, so a quiet hint
///     stands in for the (absent) Continue button.
///   - Cloud forms: the stateful Connect/Test/Continue button.
struct ConfigureAICTA: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    @Environment(\.theme) private var theme

    /// Observed-but-not-read: the CTA's `isLocalCompleted` / `isLocalFailed`
    /// reads bounce through `ConfigureAIState`, but those computed
    /// properties pull live values out of `ModelManager.shared` rather
    /// than out of any `@Published` on `state`. Without this observer the
    /// CTA wouldn't refresh from "Continue (disabled)" → "Continue
    /// (enabled)" when the download finishes.
    @ObservedObject private var modelManager = ModelManager.shared

    var body: some View {
        primaryButton
            .onChange(of: state.isLocalCompleted) { _, completed in
                if completed && state.localSubstate == .downloading {
                    onComplete()
                }
            }
            .onChange(of: state.isAPISuccess) { _, success in
                // Auto-advance once connected (green): a successful test/sign-in
                // is the confirmation, so move to the next onboarding step
                // without a second "Continue" press. The brief pause lets the
                // green success state register first.
                guard success else { return }
                switch state.apiSubstate {
                case .keyForm, .customForm:
                    Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        await MainActor.run {
                            state.saveProviderAndContinue(onComplete: onComplete)
                        }
                    }
                case .picker, .apiKeyPicker:
                    break
                }
            }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch state.selectedPath {
        case .local:
            switch state.localSubstate {
            case .picker:
                OnboardingBrandButton(
                    title: state.selectedModel?.isDownloaded == true ? "Continue" : "Download & Install",
                    action: { state.startLocalDownloadOrContinue(onComplete: onComplete) },
                    isEnabled: state.selectedModel != nil
                )
                .fixedSize(horizontal: true, vertical: false)
            case .downloading:
                localDownloadingCTA
            }

        case .apiProvider:
            switch state.apiSubstate {
            case .picker, .apiKeyPicker:
                // Provider cards drill in on tap — no Continue press
                // required. A subtle hint replaces the dead disabled button so
                // the footer reads as guidance, not a broken control.
                providerPickerHint
            case .keyForm, .customForm:
                apiActionButton
            }
        }
    }

    /// Footer text shown on the Cloud provider list / API-key hub, where the
    /// cards themselves are the action. A quiet hint reads better than a dead
    /// disabled "Continue".
    private var providerPickerHint: some View {
        Text("Pick a provider to continue", bundle: .module)
            .font(theme.font(size: OnboardingMetrics.captionSize))
            .foregroundColor(theme.tertiaryText)
            .frame(height: OnboardingMetrics.buttonHeight)
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
            .fixedSize(horizontal: true, vertical: false)
        } else {
            // Single CTA: the user can always proceed. While the download is
            // still running it reads "Continue in Background" (onboarding moves
            // on, the download keeps going); once finished it becomes a plain
            // "Continue". This replaces the old disabled-CTA + separate
            // text-link pairing.
            OnboardingBrandButton(
                title: state.isLocalCompleted ? "Continue" : "Continue in Background",
                action: onComplete
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var apiActionButton: some View {
        let oauthKind = state.selectedOAuthKind
        let isBrowserSignIn = oauthKind != nil
        let idleTitle: LocalizedStringKey =
            oauthKind.map { LocalizedStringKey($0.ctaTitle) } ?? "Connect"
        return OnboardingStatefulButton(
            state: state.apiButtonState,
            idleTitle: idleTitle,
            loadingTitle: isBrowserSignIn ? "Signing in..." : (state.isSaving ? "Connecting..." : "Testing..."),
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
        .fixedSize(horizontal: true, vertical: false)
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
                    Spacer()
                    ConfigureAICTA(state: state, onComplete: {})
                }
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 660)
        }
    }
#endif
