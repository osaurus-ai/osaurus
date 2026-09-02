//
//  OnboardingConfigureAIView.swift
//  osaurus
//
//  Onboarding step 3 — Figma screen 3 ("A private brain that runs on your
//  Mac"). Left column: brain dino, title, subtitle, and the step CTA ("Set
//  up later" until a brain is committed, then "Continue to Osaurus"). Right
//  panel: the recommended-model card ("Picked for your Mac" badge, meta
//  chips, Download + Change model) with an in-card downloading state, then
//  the provider chips (OpenAI, Anthropic, xAI, OpenRouter, Gemini, + More)
//  that drill into a per-provider connect screen whose option rows open the
//  connect dialog (browser sign-in or pasted API key).
//
//  Split into:
//   - `ConfigureAIState`: ObservableObject holding the committed brain
//     source, the provider drill-in, connection-test progress, and dialog
//     state (lives at the OnboardingView level so it survives step
//     transitions).
//   - `ConfigureAIStepView`: the full-window step layout.
//   - `ProviderConnectDialog` / `ConfigureModelChooserModal`: window-root
//     dialogs hosted by `OnboardingView`.
//
//  Apple Intelligence was removed from this step: it's too limited (no tools,
//  no web, no agent work) to be a first-class first-run option. Users with
//  `FoundationModelService` available can still configure it post-onboarding
//  from Settings.
//

import SwiftUI

// MARK: - Screen / substates

/// The top-level screen within the Configure AI step. `home` recommends a
/// local model with the provider chips below; `byok` is the per-provider
/// connect drill-in.
enum ConfigureScreen: Equatable {
    case home
    case byok
    case claudeCode
}

/// Bring-your-own-key drill-in depth (inside `ConfigureScreen.byok`).
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

/// Which connect dialog is open over the provider drill-in: the browser
/// sign-in confirmation or the paste-an-API-key form.
enum ConnectDialogKind: Equatable {
    case oauth
    case apiKey
}

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

struct CustomProviderForm: Equatable {
    var name: String = ""
    var host: String = ""
    var protocolKind: RemoteProviderProtocol = .https
    var port: String = ""
    var basePath: String = "/v1"

    mutating func reset() { self = CustomProviderForm() }

    /// Parses a pasted endpoint URL into the form's fields. Delegates the
    /// decomposition to the Settings sheet's `parsePastedEndpoint` so both
    /// surfaces share one parser (query/fragment stripping, IPv6 literals,
    /// operation-suffix normalization like /v1/chat/completions -> /v1),
    /// then layers onboarding's forgiving defaults on top: the scheme is
    /// optional (local machine and LAN hosts default to http, everything
    /// else https) and a missing path defaults to /v1. Returns an empty
    /// form (host == "") when no host can be extracted, which keeps
    /// `canTestAPI` false.
    static func parse(_ urlString: String) -> CustomProviderForm {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return CustomProviderForm() }
        var form = CustomProviderForm()
        if let components = parsePastedEndpoint(trimmed) {
            form.host = components.host
            form.port = components.port.map(String.init) ?? ""
            form.basePath = components.basePath ?? "/v1"
            form.protocolKind = components.providerProtocol ?? form.inferredScheme
        } else if !trimmed.contains("://"), !trimmed.contains("/") {
            // A bare host ("localhost", "myserver.internal") has no pieces
            // to split, so the shared parser declines it; take it verbatim.
            form.host = trimmed
            form.basePath = "/v1"
            form.protocolKind = form.inferredScheme
        }
        return form
    }

    /// Best-guess scheme for input pasted without one: the local machine
    /// and LAN addresses virtually never serve TLS; domains and public IPs
    /// default to https.
    private var inferredScheme: RemoteProviderProtocol {
        let h = host.lowercased()
        let isPrivateLAN =
            h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasSuffix(".local")
        return (isLocalhost || isPrivateLAN) ? .http : .https
    }

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
        // `parsePastedEndpoint` keeps IPv6 literals bracketed ("[::1]").
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " []"))
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
    /// The screen currently shown. Starts at `home` with the recommended local
    /// model and the provider chips.
    @Published var screen: ConfigureScreen = .home

    /// Bring-your-own-key drill-in depth. Only meaningful while
    /// `screen == .byok`.
    @Published var apiSubstate: APISubstate = .picker

    /// The brain the user committed to on this step. Recorded at the proceed
    /// moment for each path (with no payment side effect) and read by
    /// `finishOnboarding` to pin routing and persist the analytics dimension for
    /// the first `message_sent`.
    @Published var selectedBrainSource: BrainSource? = nil

    /// The local model id to record as the active agent's default when the user
    /// finishes onboarding on the Local path. `nil` for the bring-your-own-key
    /// source (or none committed), so `finishOnboarding` only pins the model the
    /// user actually committed to locally. The bundle may still be downloading;
    /// the id is durable and `ChatView.refreshPickerItems` re-resolves it once
    /// the download lands.
    var localDefaultModelIdToPin: String? {
        guard case .local = selectedBrainSource else { return nil }
        return selectedModel?.id
    }

    /// The remote provider whose first chat-capable model should become the
    /// active agent's default when the user finished onboarding on the
    /// bring-your-own-key / OAuth path. `nil` for non-provider brain sources.
    /// The provider's catalog populates asynchronously after connect, so
    /// `finishOnboarding` polls `RemoteProviderManager.firstChatCapableModelId`
    /// before pinning.
    var providerModelPinTarget: UUID? {
        guard case .providerKey = selectedBrainSource else { return nil }
        return addedProviderId
    }

    /// Direction the next screen transition should travel. Mirrors the global
    /// step `OnboardingDirection` so the sub-screen slide reads as a natural
    /// continuation of the outer navigation language.
    @Published var substateDirection: OnboardingDirection = .forward

    // MARK: Connect dialog / provider chips

    /// The connect dialog open over the provider drill-in, if any. Hosted at
    /// the OnboardingView window root so it dims the whole window.
    @Published var connectDialog: ConnectDialogKind? = nil

    /// Whether the "+ More" chip has expanded the provider grid with the
    /// remaining API-key presets.
    @Published var showAllProviders = false

    /// Whether the user committed the Local path this run (download started
    /// or already-on-disk model chosen) — drives the left CTA swap to
    /// "Continue to Osaurus".
    var hasCommittedLocal: Bool {
        if case .local = selectedBrainSource { return true }
        return false
    }

    // MARK: Local

    @Published var selectedModel: MLXModel? = nil

    /// Free bytes on the volume that will host the model download, refreshed
    /// one-shot (`refreshFreeDiskSpace`) on appear / chooser open / CTA press.
    /// Deliberately not `SystemMonitorService.availableStorageGB`: subscribing
    /// this deep onboarding tree to the monitor's 2s publishes forced a full
    /// re-render every tick, and the stat lines only need a point-in-time
    /// value. `nil` means the query failed — render stats without the
    /// free-space context.
    @Published var freeDiskBytes: Int64? = nil

    /// Inline "not enough disk space" warning shown under the local card when
    /// the CTA-press preflight refuses. Cleared on model change and on a
    /// passing preflight, so it never sticks to a different selection.
    @Published var diskSpaceWarning: String? = nil

    /// Set the moment the Download button starts the background download.
    /// This durable latch keeps the card safe if the user navigates around:
    /// no model swap, duplicate download, or Cloud-only recommit while bytes
    /// are already moving.
    @Published var hasStartedLocalDownload = false

    // API
    @Published var apiKey: String = ""
    /// The connection method pinned for the selected provider, set at
    /// option-row tap time (OAuth for the browser sign-in row, `.apiKey` for
    /// the paste-a-key row). Drives the dialog CTA, key field, and
    /// save/test branches.
    @Published var selectedAuthMethod: ProviderPickerAuthMethod = .apiKey
    @Published var oauthTokens: RemoteProviderOAuthTokens? = nil
    /// The id of the provider added by `saveProviderAndContinue`. Read by
    /// `finishOnboarding` (via `providerModelPinTarget`) to pin the new agent's
    /// default model to the just-connected provider's first chat-capable model.
    /// Cleared by `clearAPICredentials()` so an abandoned selection never pins.
    @Published var addedProviderId: UUID? = nil

    /// The OAuth flavor of the current selection, if any.
    var selectedOAuthKind: ProviderOAuthKind? {
        if case .oauth(let kind) = selectedAuthMethod { return kind }
        return nil
    }
    @Published var customForm = CustomProviderForm()
    /// The raw pasted endpoint URL backing the custom connect dialog's single
    /// field; `customForm` is derived from it on every edit.
    @Published var customEndpointURL = "" {
        didSet { customForm = CustomProviderForm.parse(customEndpointURL) }
    }
    @Published var isTesting = false
    @Published var isSaving = false
    @Published var testResult: APITestResult? = nil
    /// One-shot latch so the Continue CTA can't finalize twice. Reset whenever
    /// credentials are cleared (back / reselect).
    var hasFinalizedAPI = false

    // MARK: Local

    /// Auto-selects the recommended local pick — the best model this Mac can
    /// run — so the home screen lands on a sensible default the user can just
    /// accept. The rule is hardware-deterministic:
    ///
    ///   1. If a curated top pick is already on disk, keep it. The user
    ///      downloaded (and presumably ran) it before, so the compat
    ///      heuristic shouldn't lock them out.
    ///   2. Otherwise defer to `recommendedLocalPick`: the largest proven
    ///      base model that *comfortably* fits, using resident footprint to
    ///      choose between equal-size variants. We never auto-default into
    ///      the `.tight` band.
    ///
    /// `.unknown` (no param info / monitor not yet populated) fails open via
    /// the final `candidates.first` fallback so onboarding never dead-ends.
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

        // 2. The data-backed default for this Mac's RAM.
        let candidates = ModelManager.shared.suggestedModels.filter(\.isTopSuggestion)
        selectedModel =
            Self.recommendedLocalPick(from: candidates, totalMemoryGB: totalMemoryGB)
            ?? candidates.first
    }

    /// Pure, testable core of the onboarding default pick. Given the curated
    /// top-pick `candidates` and the machine RAM, returns the model onboarding
    /// should pre-select (or `nil` when there are no candidates).
    ///
    /// Rule: auto-default to the curated Top Pick with the **largest base
    /// parameter count** that **comfortably** fits (`.compatible`, so never
    /// into the `.tight` band). For variants of the same base model, prefer
    /// the larger resident footprint as the higher-quality precision.
    /// Top Picks are the maintained onboarding recommendation set. Raptor v0.5
    /// 8B-A1B is the mainstream-RAM text default; dense Bonsai 27B, LFM2.5 8B,
    /// and dense Ornith 1.5 9B remain catalog choices rather than first-run
    /// defaults. When nothing is comfortable (very low RAM), fall back to the
    /// smallest candidate overall so onboarding never dead-ends.
    ///
    /// This replaced the earlier Gemma-4-QAT auto-default spine: the Gemma 4
    /// `qat-MXFP4` builds are no longer curated Top Picks, so they are neither
    /// shown nor auto-selected in onboarding (a recommended Gemma build must be
    /// a non-QAT/non-MXFP4 precision, e.g. `12B-it-MXFP8` / `E4B-it-8bit`).
    static func recommendedLocalPick(
        from candidates: [MLXModel],
        totalMemoryGB: Double
    ) -> MLXModel? {
        let comfortable = candidates.filter {
            $0.compatibility(totalMemoryGB: totalMemoryGB) == .compatible
        }

        func strongest(_ pool: [MLXModel]) -> MLXModel? {
            pool.max { lhs, rhs in
                let lhsParameters = lhs.parameterCountBillions ?? 0
                let rhsParameters = rhs.parameterCountBillions ?? 0
                if lhsParameters != rhsParameters {
                    return lhsParameters < rhsParameters
                }
                return (lhs.estimatedMemoryGB ?? 0) < (rhs.estimatedMemoryGB ?? 0)
            }
        }
        func smallest(_ pool: [MLXModel]) -> MLXModel? {
            pool.min(by: {
                ($0.estimatedMemoryGB ?? .greatestFiniteMagnitude)
                    < ($1.estimatedMemoryGB ?? .greatestFiniteMagnitude)
            })
        }

        return strongest(comfortable) ?? smallest(candidates)
    }

    /// Collapses same-family quant variants — rows whose titles collapse to
    /// the same `simplifiedName`, e.g. the MXFP8 and QAT builds of one model —
    /// to a single pick per family, so the chooser never shows what reads as
    /// a duplicate. Group order follows the first occurrence in `candidates`
    /// (catalog order). Within a family the app chooses for the user:
    ///
    ///   1. The active selection (`selectedId`) — the committed model must
    ///      never vanish from the list.
    ///   2. A downloaded variant that can still run here — never steer the
    ///      user into re-downloading a near-duplicate of bits already on
    ///      disk. Largest wins if several are on disk.
    ///   3. The variant `recommendedLocalPick` chose — the tuned auto-default
    ///      must survive dedupe, or the "Picked for your Mac"
    ///      badge would point at a hidden row.
    ///   4. Quality first, comfort permitting: the largest (highest-
    ///      precision) build inside the best compatibility band a variant
    ///      reaches (comfortable beats tight).
    ///   5. If every variant is too large, the smallest one — the disabled
    ///      row then documents the family's floor.
    static func dedupedTopPicks(
        from candidates: [MLXModel],
        totalMemoryGB: Double,
        selectedId: String?
    ) -> [MLXModel] {
        let recommendedId = recommendedLocalPick(
            from: candidates,
            totalMemoryGB: totalMemoryGB
        )?.id
        var order: [String] = []
        var groups: [String: [MLXModel]] = [:]
        for model in candidates {
            let key = model.simplifiedName
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(model)
        }
        return order.compactMap { key in
            guard let variants = groups[key] else { return nil }
            return bestVariant(
                of: variants,
                totalMemoryGB: totalMemoryGB,
                selectedId: selectedId,
                recommendedId: recommendedId
            )
        }
    }

    /// Representative of one same-name variant group; see `dedupedTopPicks`
    /// for the preference order.
    private static func bestVariant(
        of variants: [MLXModel],
        totalMemoryGB: Double,
        selectedId: String?,
        recommendedId: String?
    ) -> MLXModel? {
        if let selected = variants.first(where: { $0.id == selectedId }) {
            return selected
        }

        func sizeBytes(_ model: MLXModel) -> Int64 { model.downloadSizeBytes ?? 0 }
        func comfortRank(_ model: MLXModel) -> Int {
            switch model.compatibility(totalMemoryGB: totalMemoryGB) {
            case .compatible, .unknown: return 0
            case .tight: return 1
            case .tooLarge: return 2
            }
        }

        let runnable = variants.filter { comfortRank($0) < 2 }
        if let downloaded = runnable.filter(\.isDownloaded)
            .max(by: { sizeBytes($0) < sizeBytes($1) })
        {
            return downloaded
        }
        if let recommended = variants.first(where: { $0.id == recommendedId }) {
            return recommended
        }
        if let best = runnable.min(by: { lhs, rhs in
            let (lhsRank, rhsRank) = (comfortRank(lhs), comfortRank(rhs))
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return sizeBytes(lhs) > sizeBytes(rhs)
        }) {
            return best
        }
        return variants.min(by: { sizeBytes($0) < sizeBytes($1) })
    }

    /// Tapping a local model row (in the chooser) makes it the active
    /// local brain. Kept side-effect-light (no `withAnimation`) so the CTA
    /// doesn't morph through the shared transaction. Clears any disk-space
    /// warning raised for the previous selection — the new model has its own
    /// footprint and gets its own preflight at the next CTA press.
    func selectLocalModel(_ model: MLXModel) {
        selectedModel = model
        diskSpaceWarning = nil
        // A new pick is a fresh download candidate. Clearing this latch
        // unsticks the "Change model" affordance after a failed download of
        // the previous selection (the latch otherwise hid it forever).
        hasStartedLocalDownload = false
    }

    // MARK: Machine specs (free storage)

    /// One-shot query of the free bytes on the volume that hosts the models
    /// directory. The same query path the downloader's preflight uses
    /// (`OsaurusPaths.volumeFreeBytes` via an existing ancestor), so the number
    /// the user sees matches the number the refusal logic compares against.
    func refreshFreeDiskSpace() {
        freeDiskBytes = Self.queryFreeDiskBytes()
    }

    /// Free bytes on the models volume, or `nil` when the query fails
    /// (callers render without the free-space context rather than showing 0).
    static func queryFreeDiskBytes() -> Int64? {
        let dir = DirectoryPickerService.effectiveModelsDirectory()
        guard let probe = ModelDownloadService.existingAncestor(of: dir) else { return nil }
        return OsaurusPaths.volumeFreeBytes(forPath: probe.path)
    }

    // MARK: Resource stat formatting

    /// Chooser-row stat line ("Download: 7.5 GB · Est. memory while running:
    /// 9.4 GB"). Explicit labels keep disk space and RAM from reading as one
    /// interchangeable size. `nil` when neither stat is known.
    static func chooserStatsLine(for model: MLXModel) -> String? {
        var parts: [String] = []
        if let size = model.formattedDownloadSize {
            parts.append(model.isDownloaded ? L("On disk: \(size)") : L("Download: \(size)"))
        }
        if let memory = model.formattedEstimatedMemory {
            parts.append(L("Est. memory while running: \(memory)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Plain-language one-liner for a model, derived from the curated
    /// use case instead of the catalog description. The raw descriptions are
    /// written for the Models tab and lean on exactly the vocabulary
    /// first-timers shouldn't have to parse (MoE, MXFP8, context windows);
    /// this keeps the row to "what is it for". `nil` when the model carries
    /// no use case — no subtitle beats a jargon leak.
    static func chooserSubtitle(for model: MLXModel) -> String? {
        guard let useCase = model.useCase else { return nil }
        switch useCase {
        case .general: return L("A great everyday model for chat and writing.")
        case .vision: return L("Chats, and understands images and video.")
        case .reasoning: return L("Takes extra time to think through hard problems.")
        case .coding: return L("Tuned for writing and fixing code.")
        case .smallest: return L("Light and fast — runs on any Mac.")
        case .bestQuality: return L("The most capable pick — for powerful Macs.")
        }
    }

    // MARK: Disk-space preflight

    /// Mirrors `ModelDownloadService.storageRefusalMessage` semantics
    /// (including its 256 MB safety margin): returns `true` when the download
    /// definitely won't fit. Unknown sizes on either side fail open — the
    /// downloader's own in-task preflight remains the authoritative check.
    static func downloadWontFit(neededBytes: Int64?, freeBytes: Int64?) -> Bool {
        guard let needed = neededBytes, needed > 0, let free = freeBytes else { return false }
        return ModelDownloadService.storageRefusalMessage(neededBytes: needed, freeBytes: free)
            != nil
    }

    /// Runs the disk preflight for the current selection, refreshing the
    /// cached free-space value. Returns the user-facing warning on refusal,
    /// `nil` when the download fits (or sizes are unknown — fail open).
    private func evaluateDiskShortfall() -> String? {
        refreshFreeDiskSpace()
        guard let model = selectedModel,
            Self.downloadWontFit(neededBytes: model.totalSizeEstimateBytes, freeBytes: freeDiskBytes),
            let needed = model.formattedDownloadSize,
            let freeBytes = freeDiskBytes
        else { return nil }
        let free = freeBytes.formatted(.byteCount(style: .file, allowedUnits: [.gb, .mb]))
        return L(
            "Not enough free disk space — this model needs \(needed) and this Mac has \(free) free. Free up space or choose a smaller model."
        )
    }

    // MARK: Model chooser state

    // Draft-then-confirm state for `ConfigureModelChooserModal`, opened by
    // the featured model card's "Change model" button (only before a download
    // has started — switching models mid-download would orphan the bytes in
    // flight).
    @Published var isChoosingModel: Bool = false
    @Published var draftModel: MLXModel? = nil

    func openModelChooser() {
        refreshFreeDiskSpace()
        draftModel = selectedModel
        isChoosingModel = true
    }

    func selectDraftModel(_ model: MLXModel) {
        draftModel = model
    }

    func commitModelChooser() {
        if let model = draftModel {
            selectLocalModel(model)
        }
        isChoosingModel = false
    }

    func cancelModelChooser() {
        isChoosingModel = false
    }

    /// "Set up later": start on Osaurus Cloud (with the free welcome credit)
    /// instead of downloading anything. There is nothing to download or
    /// connect here — identity + router connect are prepared in the
    /// background by `OnboardingView` and finalized at finish.
    func chooseOsaurusAndContinue(onComplete: () -> Void) {
        selectedBrainSource = .osaurus
        OnboardingTelemetry.brainSourceSelected(.osaurus)
        onComplete()
    }

    /// Commit the local brain. If the model is not on disk, start its
    /// background download first (the card shows in-place progress and the
    /// left CTA becomes "Continue to Osaurus"). The disk preflight is the
    /// only refusal and remains inline on this step.
    func chooseLocalAndContinue(onComplete: () -> Void) {
        if selectedModel?.isDownloaded != true, let warning = evaluateDiskShortfall() {
            diskSpaceWarning = warning
            return
        }
        diskSpaceWarning = nil

        // Committing to a local model — record the brain source for the funnel
        // (no payment, no network).
        selectedBrainSource = .local
        let needsDownload = selectedModel?.isDownloaded != true
        OnboardingTelemetry.brainSourceSelected(.local, downloadStarted: needsDownload)
        if needsDownload {
            startLocalDownload()
            hasStartedLocalDownload = true
        }
        onComplete()
    }

    func startLocalDownload() {
        guard let model = selectedModel else { return }
        // Consume any stale refusal for this model before retrying so a prior
        // alert can't re-present later in the Models tab. A repeat refusal
        // sets a new alert.
        clearDownloadAlertForSelectedModel()
        // Route through the onboarding-only Osaurus model download proxy: the user
        // has no HF token yet, and anonymous throttling here is a measured
        // onboarding drop-off driver. Any proxy failure silently falls back
        // to the plain anonymous HF path.
        ModelManager.shared.downloadModel(model, route: .onboardingProxy)
    }

    /// Drops a pending `downloadAlert` that belongs to the current selection.
    /// Onboarding presents these refusals inline (never as the Models tab's
    /// alert dialog), so once handled here the global alert must not linger
    /// and re-present later in the Models tab.
    private func clearDownloadAlertForSelectedModel() {
        guard let id = selectedModel?.id,
            ModelManager.shared.downloadAlert?.modelId == id
        else { return }
        ModelManager.shared.downloadAlert = nil
    }

    // MARK: Navigation

    /// Home → bring-your-own-provider flow (forward slide).
    func showBYOK() {
        substateDirection = .forward
        apiSubstate = .picker
        screen = .byok
    }

    /// Provider-chip tap: drill straight into the provider's connect screen
    /// (no intermediate picker — the chips on the home screen ARE the picker).
    func enterProvider(_ preset: ProviderPreset) {
        substateDirection = .forward
        clearAPICredentials()
        apiSubstate = .keyForm(preset)
        screen = .byok
    }

    /// "Custom" chip tap: open the endpoint-form connect dialog directly over
    /// the home screen. Unlike preset providers there is no drill-in — the
    /// chip has no logo/option rows worth a page, so one tap goes straight to
    /// the form.
    func enterCustomProvider() {
        clearAPICredentials()
        apiSubstate = .customForm
        connectDialog = .apiKey
    }

    func enterClaudeCode() {
        substateDirection = .forward
        screen = .claudeCode
    }

    func chooseClaudeCodeAndContinue(onComplete: () -> Void) {
        selectedBrainSource = .claudeCode
        OnboardingTelemetry.brainSourceSelected(.claudeCode)
        onComplete()
    }

    /// Open the connect dialog for the current provider, pinning the auth
    /// method the tapped option row represents.
    func openConnectDialog(_ kind: ConnectDialogKind) {
        guard let preset = currentAPIProvider else { return }
        testResult = nil
        if kind == .oauth,
            let entry = ProviderCatalog.entry(for: preset),
            let oauthKind = entry.primaryOAuthKind
        {
            selectedAuthMethod = .oauth(oauthKind)
        } else {
            selectedAuthMethod = .apiKey
        }
        connectDialog = kind
    }

    /// Close the connect dialog. A failed / abandoned attempt clears the
    /// stale result so re-opening starts fresh; a verified connection keeps
    /// its green state for the drill-in's check and the Continue CTA.
    func closeConnectDialog() {
        connectDialog = nil
        if !isAPISuccess {
            testResult = nil
            apiKey = ""
            // The custom dialog opens straight over the home grid with no
            // drill-in behind it; an abandoned attempt pops the substate too
            // so no half-filled form lingers under the next chip tap.
            if screen == .home, apiSubstate == .customForm {
                apiSubstate = .picker
                customEndpointURL = ""
                customForm.reset()
            }
        }
    }

    /// Provider drill-in → the recommended local setup (backward slide).
    /// Clears any entered credentials so a stale secret never leaks across
    /// selections.
    func popBYOKToHome() {
        resetAPIState(direction: .backward)
        screen = .home
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

    /// Resets the API substate back to the picker. Direction defaults to
    /// `.backward` so the slide reads as "popping out", but callers can pass
    /// `.forward` when this is invoked as a side-effect of a forward switch.
    func resetAPIState(direction: OnboardingDirection = .backward) {
        substateDirection = direction
        apiSubstate = .picker
        clearAPICredentials()
    }

    /// Clear entered credentials, auth-mode selections, and the last test
    /// result. Shared by every "back out" path so stale secrets never leak
    /// across provider selections.
    private func clearAPICredentials() {
        apiKey = ""
        selectedAuthMethod = .apiKey
        oauthTokens = nil
        addedProviderId = nil
        customEndpointURL = ""
        customForm.reset()
        testResult = nil
        hasFinalizedAPI = false
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
        // One-shot: the Continue CTA remains tappable briefly while saving, so
        // both routes funnel through this latch to avoid adding the provider
        // (and advancing) twice.
        guard !hasFinalizedAPI else { return }
        guard let config = resolvedAPIConfig() else { return }
        hasFinalizedAPI = true
        isSaving = true

        // Record the bring-your-own-key brain source for the funnel. The
        // provider type (closed enum) is the only identifying bit sent.
        if let preset = currentAPIProvider {
            selectedBrainSource = .providerKey(preset)
            OnboardingTelemetry.brainSourceSelected(.providerKey(preset))
        }

        // OpenAI Codex and xAI persist OAuth tokens via a service-provided
        // provider config; OpenRouter's OAuth mints a plain key handled by the
        // standard apiKey path below.
        if selectedOAuthKind == .openAICodex {
            let provider = OpenAICodexOAuthService.makeProvider()
            addedProviderId = provider.id
            RemoteProviderManager.shared.addProvider(provider, apiKey: nil, oauthTokens: oauthTokens)
            isSaving = false
            onComplete()
            return
        }

        if selectedOAuthKind == .xai {
            let provider = XAIOAuthService.makeProvider()
            addedProviderId = provider.id
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
        addedProviderId = provider.id
        RemoteProviderManager.shared.addProvider(
            provider,
            apiKey: config.authType == .apiKey ? apiKey : nil
        )
        isSaving = false
        onComplete()
    }
}

// MARK: - Step view

struct ConfigureAIStepView: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `totalMemoryGB` is populated synchronously in
    /// `SystemMonitorService.init`, so the first onboarding frame can select a
    /// hardware-appropriate local default.
    /// Non-observing on purpose. We only ever read `totalMemoryGB` — total
    /// physical RAM, a runtime constant. Observing via `@ObservedObject`
    /// subscribed this deep onboarding tree to the service's 2s CPU/memory
    /// publishes, forcing a full re-render every tick. A plain reference reads
    /// the same constant without subscribing to publishes that can never change
    /// our output.
    private let systemMonitor = SystemMonitorService.shared

    var body: some View {
        OnboardingStepLayout {
            ConfigureAILeftColumn(state: state, onComplete: onComplete)
        } right: {
            rightPanel
        }
        .onAppear {
            state.ensureLocalSelection(totalMemoryGB: systemMonitor.totalMemoryGB)
            state.refreshFreeDiskSpace()
        }
    }

    // MARK: Right panel

    private var rightPanel: some View {
        OnboardingRightPanel {
            ZStack {
                screenContainer
                    .id(substateID)
                    .transition(substateTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(
                RoundedRectangle(cornerRadius: OnboardingLayout.panelRadius, style: .continuous)
            )
            .animation(OnboardingMotion.gentle, value: substateID)
        }
    }

    private var substateID: String {
        switch state.screen {
        case .home: return "home"
        case .byok: return "provider-\(state.currentAPIProvider?.rawValue ?? "none")"
        case .claudeCode: return "claude-code"
        }
    }

    /// Direction-aware push-fade — the same motion language as the outer
    /// step transitions (crossfade under Reduce Motion).
    private var substateTransition: AnyTransition {
        OnboardingMotion.pushFade(
            direction: state.substateDirection,
            reduceMotion: reduceMotion
        )
    }

    @ViewBuilder
    private var screenContainer: some View {
        switch state.screen {
        case .home:
            ConfigureAIHomePanel(state: state, onComplete: onComplete)
        case .byok:
            ConfigureAIProviderPanel(state: state)
        case .claudeCode:
            ClaudeCodeSetupStep(
                onBack: {
                    state.substateDirection = .backward
                    state.screen = .home
                },
                onDone: {
                    state.chooseClaudeCodeAndContinue(onComplete: onComplete)
                },
                completionTitle: "Use Claude Code",
                requiresUsableCLI: true
            )
        }
    }
}

// MARK: - Left column

/// Brain dino + title + subtitle + the step CTA. The CTA swaps from "Set up
/// later" (nothing committed) to "Continue to Osaurus" once a download is
/// running or a provider is verified. While a download is in flight a comic
/// speech bubble floats above the dino reassuring the user that it continues
/// in the background (Figma node 42:4533).
private struct ConfigureAILeftColumn: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    @ObservedObject private var modelManager = ModelManager.shared

    /// Whether the featured model's download is currently in flight.
    private var isDownloading: Bool {
        guard let id = state.selectedModel?.id else { return false }
        if case .downloading = modelManager.downloadStates[id] { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("osaurus-brain", bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 106)
                // The bubble is a free-floating overlay (matching the design's
                // absolute placement) so its appearance never reflows the
                // column: anchored to the dino's top-right, tail pointing back
                // down at its head.
                .overlay(alignment: .topLeading) {
                    if isDownloading {
                        downloadBubble
                            .offset(x: 90, y: -100)
                            .transition(
                                .scale(scale: 0.8, anchor: .bottomLeading)
                                    .combined(with: .opacity)
                            )
                    }
                }
                .animation(OnboardingMotion.bouncy, value: isDownloading)
                .onboardingEntrance(0, scaleFrom: 0.96)

            Spacer().frame(height: 24)

            Text(title, bundle: .module)
                .font(OnboardingTypography.heroTitle)
                .tracking(0.4)
                .foregroundColor(OnboardingPalette.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingEntrance(1)

            Spacer().frame(height: 16)

            Text(subtitle, bundle: .module)
            .font(OnboardingTypography.subtitle)
            .foregroundColor(OnboardingPalette.labelSecondary)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .onboardingEntrance(2)

            Spacer().frame(height: 40)

            cta
                .onboardingEntrance(3)
        }
    }

    private var title: LocalizedStringKey {
        state.screen == .claudeCode
            ? "Use your Claude Code account"
            : "A private brain that runs on your Mac"
    }

    private var subtitle: LocalizedStringKey {
        state.screen == .claudeCode
            ? "Osaurus delegates sign-in and requests to Anthropic's Claude Code CLI. Credentials stay with the CLI; model requests run in the cloud."
            : "We've picked the best fit for your Mac and the specialty you chose, so your Dino can work locally — even offline."
    }

    /// The design's white comic speech bubble: 196×64 text box, 12pt
    /// semibold black copy, thin black outline, tail sweeping down-left
    /// toward the dino. The tail hangs 13pt below the text box via the
    /// top-aligned background shape, so it never affects the text layout.
    private var downloadBubble: some View {
        Text("You can continue while the model downloads in the background!", bundle: .module)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.black)
            .lineSpacing(1)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(width: 196, height: 64)
            .background(alignment: .top) {
                SpeechBubbleShape()
                    .fill(Color.white)
                    .overlay(SpeechBubbleShape().stroke(Color.black, lineWidth: 1))
                    .frame(width: 196, height: 77)
                    .shadow(color: Color.black.opacity(0.25), radius: 10, y: 5)
            }
    }

    @ViewBuilder
    private var cta: some View {
        if state.isAPISuccess {
            OnboardingPillButton(
                title: "Continue to Osaurus",
                style: .primary,
                size: .large,
                isEnabled: !state.isSaving,
                action: { state.saveProviderAndContinue(onComplete: onComplete) }
            )
        } else if state.hasCommittedLocal {
            OnboardingPillButton(
                title: "Continue to Osaurus",
                style: .primary,
                size: .large,
                action: onComplete
            )
        } else {
            OnboardingPillButton(
                title: "Set up later",
                style: .secondary,
                size: .large,
                action: { state.chooseOsaurusAndContinue(onComplete: onComplete) }
            )
        }
    }
}

/// The speech-bubble outline traced from the Figma vector (node 42:4534):
/// a 16pt-radius rounded rectangle over the top 64pt with a curved comic
/// tail sweeping down-left off the bottom edge. Reference canvas 196×77;
/// the path scales to whatever rect it's given.
private struct SpeechBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 196
        let sy = rect.height / 77
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        // Tail root on the bottom edge, up into the rounded rectangle…
        path.move(to: p(21.97, 67.95))
        path.addCurve(to: p(18.5, 64), control1: p(22.55, 65.82), control2: p(20.71, 64))
        path.addLine(to: p(16, 64))
        path.addCurve(to: p(0, 48), control1: p(7.16, 64), control2: p(0, 56.84))
        path.addLine(to: p(0, 16))
        path.addCurve(to: p(16, 0), control1: p(0, 7.16), control2: p(7.16, 0))
        path.addLine(to: p(180, 0))
        path.addCurve(to: p(196, 16), control1: p(188.84, 0), control2: p(196, 7.16))
        path.addLine(to: p(196, 48))
        path.addCurve(to: p(180, 64), control1: p(196, 56.84), control2: p(188.84, 64))
        path.addLine(to: p(38, 64))
        // …then the tail: bows out of the bottom edge and curls to a point.
        path.addCurve(to: p(33.39, 67.94), control1: p(35.79, 64), control2: p(34.06, 65.83))
        path.addCurve(to: p(21, 77), control1: p(31.72, 73.19), control2: p(26.81, 77))
        path.addLine(to: p(16.01, 77))
        path.addCurve(to: p(15.84, 76.44), control1: p(15.71, 77), control2: p(15.59, 76.61))
        path.addCurve(to: p(21.97, 67.95), control1: p(18.88, 74.42), control2: p(21.03, 71.38))
        path.closeSubpath()
        return path
    }
}

// MARK: - Home panel

/// The right panel's home screen: recommended model card + provider chips.
private struct ConfigureAIHomePanel: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecommendedModelCard(state: state, onComplete: onComplete)
                .onboardingEntrance(0, scaleFrom: 0.98)

            if let warning = state.diskSpaceWarning {
                Spacer().frame(height: 12)
                Text(warning)
                    .font(OnboardingTypography.cardCaption)
                    .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer().frame(height: 28)

            Text("Prefer to connect your AI Provider?", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(OnboardingPalette.labelPrimary)
                .onboardingEntrance(2)

            Spacer().frame(height: 12)

            providerChips

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The five Figma-featured providers, in frame order.
    private static let featuredPresets: [ProviderPreset] = [
        .openai, .anthropic, .xai, .openrouter, .google,
    ]

    /// Remaining connectable presets revealed by "+ More": every API-key
    /// picker preset not already featured. The custom OpenAI-compatible
    /// endpoint has its own always-visible chip next to Claude Code.
    private static var morePresets: [ProviderPreset] {
        ProviderPreset.apiKeyPickerGroups(includeAzure: false)
            .flatMap(\.presets)
            .filter { !featuredPresets.contains($0) && $0 != .custom }
    }

    private var visiblePresets: [ProviderPreset] {
        state.showAllProviders
            ? Self.featuredPresets + Self.morePresets
            : Self.featuredPresets
    }

    /// Featured chips cascade in with a tight stagger after the card and
    /// header; the chips revealed by "+ More" instead pop in with the
    /// expansion animation itself.
    private var providerChips: some View {
        ChipFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(Array(visiblePresets.enumerated()), id: \.element.id) { index, preset in
                let chip = OnboardingProviderChip(
                    logo: { OnboardingProviderLogo(preset: preset, size: 16) },
                    label: preset == .google ? "Gemini" : preset.name
                ) {
                    state.enterProvider(preset)
                }
                if index < Self.featuredPresets.count {
                    chip.onboardingEntrance(3 + index)
                } else {
                    chip.transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }

            OnboardingProviderChip(
                logo: {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(OnboardingPalette.labelPrimary)
                },
                label: "Claude Code"
            ) {
                state.enterClaudeCode()
            }
            .onboardingEntrance(3 + Self.featuredPresets.count)

            OnboardingProviderChip(
                logo: { OnboardingProviderLogo(preset: .custom, size: 16) },
                label: L("Custom")
            ) {
                state.enterCustomProvider()
            }
            .onboardingEntrance(4 + Self.featuredPresets.count)

            if !state.showAllProviders {
                OnboardingProviderChip(
                    logo: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(OnboardingPalette.labelPrimary)
                    },
                    label: L("More")
                ) {
                    // `smooth`: the chip grid reflows on expansion, and a
                    // wobbling layout reads as jank rather than character.
                    withAnimation(OnboardingMotion.smooth) {
                        state.showAllProviders = true
                    }
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .onboardingEntrance(5 + Self.featuredPresets.count)
            }
        }
    }
}

// MARK: - Recommended model card

/// The elevated recommended-model card: "Picked for your Mac" badge, model
/// name, plain-language description, then a per-download-state block —
/// meta chips + Download/Change buttons, in-card progress, pause/failure
/// recovery, or the already-on-disk state. Isolated so only the card
/// re-renders on `ModelManager`'s frequent progress publishes.
private struct RecommendedModelCard: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    @ObservedObject private var modelManager = ModelManager.shared

    var body: some View {
        if let model = state.selectedModel {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingPickedBadge(text: "Picked for your Mac")

                Spacer().frame(height: 12)

                titleRow(model)

                Spacer().frame(height: 6)

                if let subtitle = ConfigureAIState.chooserSubtitle(for: model) {
                    Text(subtitle)
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer().frame(height: 14)

                statusBlock(model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
                    .fill(OnboardingPalette.fill5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
                    .strokeBorder(OnboardingPalette.fill8, lineWidth: 1)
            )
        }
    }

    /// Effective download state for the featured model. A bundle already on
    /// disk renders as `.completed` regardless of any stale service entry.
    private func downloadState(for model: MLXModel) -> DownloadState {
        if model.isDownloaded { return .completed }
        return modelManager.downloadStates[model.id] ?? .notStarted
    }

    private func titleRow(_ model: MLXModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.simplifiedName)
                .font(OnboardingTypography.modelTitle)
                .foregroundColor(OnboardingPalette.labelWhite)
                .fixedSize(horizontal: false, vertical: true)

            // The size moves inline next to the name once the meta chips are
            // replaced by the progress block (per the downloading frame).
            if isInProgress(model), let size = model.formattedDownloadSize {
                Text(size)
                    .font(.system(size: 15))
                    .foregroundColor(OnboardingPalette.labelSecondary)
            }
        }
    }

    private func isInProgress(_ model: MLXModel) -> Bool {
        switch downloadState(for: model) {
        case .downloading, .paused: return true
        default: return false
        }
    }

    // MARK: Status block

    @ViewBuilder
    private func statusBlock(_ model: MLXModel) -> some View {
        switch downloadState(for: model) {
        case .notStarted:
            VStack(alignment: .leading, spacing: 16) {
                metaChips(model)
                HStack(spacing: 12) {
                    OnboardingPillButton(
                        title: "Download",
                        style: .primary,
                        size: .compact,
                        leadingSymbol: "arrow.down.circle",
                        action: { state.chooseLocalAndContinue(onComplete: {}) }
                    )
                    OnboardingPillButton(
                        title: "Change model",
                        style: .text,
                        size: .compact,
                        action: { state.openModelChooser() }
                    )
                }
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading..", bundle: .module)
                    .font(OnboardingTypography.cardCaption)
                    .foregroundColor(OnboardingPalette.labelSecondary)
                OnboardingProgressBar(progress: progress)
                HStack(spacing: 0) {
                    let metrics = metricsText(for: model) ?? L("Starting download…")
                    Text(metrics)
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelSecondary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.3), value: metrics)
                    Spacer(minLength: 8)
                    if let remaining = remainingText(for: model, progress: progress) {
                        Text(remaining)
                            .font(OnboardingTypography.cardCaption)
                            .foregroundColor(OnboardingPalette.labelSecondary)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.3), value: remaining)
                    }
                }
            }

        case .paused(let progress):
            VStack(alignment: .leading, spacing: 10) {
                OnboardingProgressBar(progress: progress)
                HStack(spacing: 12) {
                    Text("Download paused", bundle: .module)
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelSecondary)
                    OnboardingPillButton(
                        title: "Resume download",
                        style: .primary,
                        size: .compact,
                        action: { modelManager.resumeDownload(model.id) }
                    )
                }
            }

        case .failed(let error):
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Download hit a snag — \(error)"))
                    .font(OnboardingTypography.cardCaption)
                    .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    OnboardingPillButton(
                        title: "Try again",
                        style: .primary,
                        size: .compact,
                        action: { state.startLocalDownload() }
                    )
                    OnboardingPillButton(
                        title: "Change model",
                        style: .text,
                        size: .compact,
                        action: { state.openModelChooser() }
                    )
                }
            }

        case .completed:
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(OnboardingPalette.dinoGreen)
                    Text("Already on your Mac — ready to go", bundle: .module)
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelSecondary)
                }
                HStack(spacing: 12) {
                    OnboardingPillButton(
                        title: "Use this model",
                        style: .primary,
                        size: .compact,
                        action: { state.chooseLocalAndContinue(onComplete: onComplete) }
                    )
                    if !state.hasStartedLocalDownload {
                        OnboardingPillButton(
                            title: "Change model",
                            style: .text,
                            size: .compact,
                            action: { state.openModelChooser() }
                        )
                    }
                }
            }
        }
    }

    private func metaChips(_ model: MLXModel) -> some View {
        HStack(spacing: 8) {
            if let size = model.formattedDownloadSize {
                OnboardingMetaChip(text: L("Download : \(size)"))
            }
            if let memory = model.formattedEstimatedMemory {
                OnboardingMetaChip(text: L("Est memory usage : \(memory)"))
            }
        }
    }

    /// "341.3 MB of 13.39 GB · 38.5 MB/s" from the live download metrics, or
    /// `nil` before the first metrics tick.
    private func metricsText(for model: MLXModel) -> String? {
        guard let metrics = modelManager.downloadMetrics[model.id] else { return nil }
        var parts: [String] = []
        if let received = metrics.bytesReceived, let total = metrics.totalBytes {
            parts.append(
                L(
                    "\(received.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))"
                )
            )
        }
        if let speed = metrics.bytesPerSecond {
            parts.append("\(Int64(speed).formatted(.byteCount(style: .file)))/s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "~11min remaining" estimated from the live byte rate; `nil` until the
    /// rate settles.
    private func remainingText(for model: MLXModel, progress: Double) -> String? {
        guard let metrics = modelManager.downloadMetrics[model.id],
            let received = metrics.bytesReceived,
            let total = metrics.totalBytes,
            let speed = metrics.bytesPerSecond,
            speed > 1024, total > received
        else { return nil }
        let seconds = Double(total - received) / speed
        if seconds < 90 { return L("~1min remaining") }
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 90 {
            let hours = Int((seconds / 3600).rounded())
            return L("~\(hours)h remaining")
        }
        return L("~\(minutes)min remaining")
    }
}

// MARK: - Provider drill-in panel

/// Per-provider connect screen: back row, centered logo card, then the
/// connect option rows (browser sign-in and/or API key). A verified method
/// shows the green check; the left CTA (outside this panel) becomes
/// "Continue to Osaurus".
private struct ConfigureAIProviderPanel: View {
    @ObservedObject var state: ConfigureAIState

    private var preset: ProviderPreset? { state.currentAPIProvider }

    private var oauthKind: ProviderOAuthKind? {
        guard let preset else { return nil }
        return ProviderCatalog.entry(for: preset)?.primaryOAuthKind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backRow

            if let preset {
                Spacer().frame(height: 24)

                HStack {
                    Spacer(minLength: 0)
                    OnboardingLogoCard(
                        logo: { OnboardingProviderLogo(preset: preset, size: 28) },
                        caption: displayName(preset)
                    )
                    Spacer(minLength: 0)
                }

                Spacer().frame(height: 40)

                optionRows(preset)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var backRow: some View {
        Button {
            state.popBYOKToHome()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Back", bundle: .module)
                    .font(OnboardingTypography.cardCaption)
            }
            .foregroundColor(OnboardingPalette.labelSecondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedHelp("Back")
    }

    private func displayName(_ preset: ProviderPreset) -> String {
        preset == .google ? "Gemini" : preset.name
    }

    @ViewBuilder
    private func optionRows(_ preset: ProviderPreset) -> some View {
        VStack(spacing: 12) {
            if oauthKind != nil {
                OnboardingOptionRow(
                    title: oauthRowTitle(preset),
                    caption: oauthRowCaption(preset),
                    isVerified: state.isAPISuccess && state.selectedAuthMethod.isOAuth
                ) {
                    state.openConnectDialog(.oauth)
                }
            }

            if preset.configuration.authType == .none {
                // Local presets (Ollama) — no key, one connect action.
                OnboardingOptionRow(
                    title: LocalizedStringKey(L("Connect to \(displayName(preset))")),
                    caption: "No API key required — connects to your local server",
                    isVerified: state.isAPISuccess && !state.selectedAuthMethod.isOAuth
                ) {
                    state.openConnectDialog(.apiKey)
                }
            } else {
                OnboardingOptionRow(
                    title: LocalizedStringKey(L("Provide an \(displayName(preset)) API Key")),
                    caption: keyRowCaption(preset),
                    isVerified: state.isAPISuccess && !state.selectedAuthMethod.isOAuth
                ) {
                    state.openConnectDialog(.apiKey)
                }
            }
        }
    }

    private func oauthRowTitle(_ preset: ProviderPreset) -> LocalizedStringKey {
        switch oauthKind {
        case .openAICodex: return "Sign in with a ChatGPT account"
        case .openRouter: return "Sign in with your OpenRouter account"
        case .xai: return "Sign in with your Grok account"
        case nil: return ""
        }
    }

    private func oauthRowCaption(_ preset: ProviderPreset) -> LocalizedStringKey {
        switch oauthKind {
        case .openAICodex: return "This will use your ChatGPT Plus/Pro subscription"
        case .openRouter: return "This will use your OpenRouter account"
        case .xai: return "This will use your SuperGrok or X Premium+ subscription"
        case nil: return ""
        }
    }

    private func keyRowCaption(_ preset: ProviderPreset) -> LocalizedStringKey {
        switch preset {
        case .openai: return "Paste a key from platform.openai.com"
        case .anthropic: return "Paste a key from console.anthropic.com"
        case .google: return "Paste a key from aistudio.google.com"
        case .xai: return "Paste a key from console.x.ai"
        case .openrouter: return "Paste a key from openrouter.ai"
        default: return "Paste a key from your provider dashboard"
        }
    }
}

// MARK: - Connect dialog

/// Centered connect dialog over the whole window (Figma connect frames):
/// provider logo card, title, caption, then either the browser sign-in
/// button (idle → "Authenticating…" with spinner) or the API-key field +
/// Connect button. Success closes the dialog; the drill-in shows the green
/// check and the left CTA becomes "Continue to Osaurus".
struct ProviderConnectDialog: View {
    @ObservedObject var state: ConfigureAIState

    private var preset: ProviderPreset? { state.currentAPIProvider }
    private var isOAuth: Bool { state.connectDialog == .oauth }

    var body: some View {
        OnboardingDialog(
            isDismissable: !state.isTesting,
            onClose: { state.closeConnectDialog() }
        ) {
            VStack(spacing: 0) {
                if let preset {
                    OnboardingLogoCard(
                        logo: { OnboardingProviderLogo(preset: preset, size: 24) },
                        caption: displayName(preset),
                        logoSize: 24
                    )

                    Spacer().frame(height: 24)

                    Text(title(preset))
                        .font(OnboardingTypography.cardTitle)
                        .foregroundColor(OnboardingPalette.labelWhite)
                        .multilineTextAlignment(.center)

                    Spacer().frame(height: 8)

                    Text(caption(preset))
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isOAuth {
                        if preset == .custom {
                            Spacer().frame(height: 20)
                            customEndpointForm
                        } else if preset.configuration.authType == .apiKey {
                            Spacer().frame(height: 20)
                            keyField(preset)
                        }
                    }

                    if case .failure(let message) = state.testResult {
                        Spacer().frame(height: 12)
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.4))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320)
                    }

                    Spacer().frame(height: 24)

                    actionButton(preset)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
        .onChange(of: state.isAPISuccess) { _, success in
            // A verified connection closes the dialog after a beat so the
            // user sees the state settle; the drill-in's check + the left
            // "Continue to Osaurus" CTA carry it from there.
            guard success else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                state.closeConnectDialog()
            }
        }
    }

    private func displayName(_ preset: ProviderPreset) -> String {
        preset == .google ? "Gemini" : preset.name
    }

    private func title(_ preset: ProviderPreset) -> String {
        if isOAuth {
            // Authenticating shortens the title to the account brand, per the
            // Figma authenticating frame.
            if state.isTesting, state.selectedOAuthKind == .openAICodex {
                return "ChatGPT"
            }
            switch state.selectedOAuthKind {
            case .openAICodex: return L("Sign in with a ChatGPT account")
            case .openRouter: return L("Sign in with your OpenRouter account")
            case .xai: return L("Sign in with your Grok account")
            case nil: return ""
            }
        }
        if preset == .custom {
            return L("Connect a custom endpoint")
        }
        if preset.configuration.authType == .none {
            return L("Connect to \(displayName(preset))")
        }
        return L("Provide an \(displayName(preset)) API Key")
    }

    private func caption(_ preset: ProviderPreset) -> String {
        if isOAuth {
            switch state.selectedOAuthKind {
            case .openAICodex: return L("This will use your ChatGPT Plus/Pro subscription")
            case .openRouter: return L("This will use your OpenRouter account")
            case .xai: return L("This will use your SuperGrok or X Premium+ subscription")
            case nil: return ""
            }
        }
        if preset == .custom {
            return L("Paste the URL of any OpenAI-compatible server. Local endpoints don't need a key.")
        }
        if preset.configuration.authType == .none {
            return L("No API key required — connects to your local server")
        }
        return L("Your key is stored securely in the macOS Keychain")
    }

    private func keyField(_ preset: ProviderPreset) -> some View {
        SecureField(L("sk-..."), text: $state.apiKey)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(OnboardingPalette.labelPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OnboardingPalette.fill5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(OnboardingPalette.fill10, lineWidth: 1)
            )
            .frame(maxWidth: 300)
            .onChange(of: state.apiKey) { _, _ in state.testResult = nil }
    }

    /// Single paste-the-URL form for the custom OpenAI-compatible endpoint.
    /// The URL is parsed into scheme/host/port/path behind the scenes
    /// (`CustomProviderForm.parse`); a resolved preview confirms how the
    /// paste was understood. Optional key below for authenticated servers.
    private var customEndpointForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formField("http://localhost:11434/v1", text: $state.customEndpointURL)

            SecureField(L("API key (optional for local servers)"), text: $state.apiKey)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(OnboardingPalette.labelPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OnboardingPalette.fill5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(OnboardingPalette.fill10, lineWidth: 1)
                )

            // Confirm how the paste was understood, but only when parsing
            // actually added something (scheme, default /v1) beyond the
            // literal input — echoing an identical URL back is noise.
            if !state.customForm.host.isEmpty,
                state.customForm.endpointPreview
                    != state.customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
            {
                Text(state.customForm.endpointPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(OnboardingPalette.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 320)
        .onChange(of: state.customForm) { _, _ in state.testResult = nil }
        .onChange(of: state.apiKey) { _, _ in state.testResult = nil }
    }

    private func formField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(OnboardingPalette.labelPrimary)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OnboardingPalette.fill5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(OnboardingPalette.fill10, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func actionButton(_ preset: ProviderPreset) -> some View {
        if state.isTesting {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    isOAuth
                        ? LocalizedStringKey("Authenticating...")
                        : LocalizedStringKey("Connecting..."),
                    bundle: .module
                )
                .font(OnboardingTypography.chip)
                .foregroundColor(OnboardingPalette.labelPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(OnboardingPalette.fill8))
        } else if state.isAPISuccess {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text("Connected", bundle: .module)
                    .font(OnboardingTypography.chip)
            }
            .foregroundColor(OnboardingPalette.dinoGreen)
            .padding(.vertical, 8)
        } else {
            OnboardingPillButton(
                title: idleButtonTitle,
                style: .primary,
                size: .compact,
                isEnabled: state.canTestAPI,
                action: { state.testAPIConnection() }
            )
        }
    }

    private var idleButtonTitle: LocalizedStringKey {
        if isOAuth, let kind = state.selectedOAuthKind {
            return LocalizedStringKey(kind.ctaTitle)
        }
        if case .failure = state.testResult { return "Try again" }
        return "Connect"
    }
}

// MARK: - Model chooser modal

/// Centered "Choose your model" dialog, hosted at the OnboardingView window
/// root over the scrim. Forgiving draft-then-confirm so brand-new users can
/// browse without committing: tapping a row only highlights it
/// (`state.draftModel`); "Use this model" commits, while Cancel / X / Esc /
/// scrim-tap dismiss without touching the active selection. Copy and rows
/// are written for first-timers — no `LLM`/`VLM` jargon, one
/// hardware-chosen build per model family, a "Picked for your Mac" pill on
/// the safe default, and per-row cost stats read against this Mac's specs.
struct ConfigureModelChooserModal: View {
    @ObservedObject var state: ConfigureAIState

    @ObservedObject private var modelManager = ModelManager.shared

    /// See `ConfigureAIStepView.systemMonitor`: a plain reference (not an
    /// `@ObservedObject`) so the dialog doesn't re-render on every 2s
    /// CPU/memory publish — `totalMemoryGB` is constant for the session.
    private let systemMonitor = SystemMonitorService.shared

    var body: some View {
        OnboardingDialog(width: 520, onClose: { state.cancelModelChooser() }) {
            VStack(spacing: 0) {
                header
                modelList
                footer
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose your model", bundle: .module)
                .font(OnboardingTypography.cardTitle)
                .foregroundColor(OnboardingPalette.labelWhite)
            Text(
                "Every model here runs privately on your Mac. Not sure? Keep the one we picked for your Mac's specs — you can switch anytime.",
                bundle: .module
            )
            .font(OnboardingTypography.cardCaption)
            .foregroundColor(OnboardingPalette.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.trailing, 44)
        .padding(.bottom, 16)
    }

    // MARK: List

    private var modelList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(pickerModels, id: \.model.id) { pair in
                    modelRow(pair.model, compatibility: pair.compatibility)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 360)
    }

    /// One selectable model row. Too-large models stay visible so the tag can
    /// explain why, but can't be selected — committing to a model that won't
    /// run is the one unsafe choice this list can offer.
    private func modelRow(_ model: MLXModel, compatibility: ModelCompatibility) -> some View {
        let isSelected = state.draftModel?.id == model.id
        let isDisabled = compatibility == .tooLarge
        return Button {
            state.selectDraftModel(model)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.simplifiedName)
                        .font(OnboardingTypography.optionTitle)
                        .foregroundColor(OnboardingPalette.labelPrimary)
                    if model.id == recommendedRowId {
                        OnboardingPickedBadge(text: "Picked for your Mac")
                    }
                    if model.isDownloaded {
                        OnboardingMetaChip(text: L("Downloaded"))
                    }
                    if compatibility == .tooLarge {
                        OnboardingMetaChip(text: compatibility.displayName)
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(OnboardingPalette.dinoGreen)
                    }
                }
                if let subtitle = ConfigureAIState.chooserSubtitle(for: model) {
                    Text(subtitle)
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelSecondary)
                }
                if let stats = ConfigureAIState.chooserStatsLine(for: model) {
                    Text(stats)
                        .font(.system(size: 11))
                        .foregroundColor(OnboardingPalette.labelSecondary.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
                    .fill(isSelected ? OnboardingPalette.fill5 : OnboardingPalette.fill2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? OnboardingPalette.dinoGreen : OnboardingPalette.fill8,
                        lineWidth: 1
                    )
            )
            .contentShape(
                RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
            )
        }
        .buttonStyle(OnboardingPressableButtonStyle(pressedScale: 0.985))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            Text(footerHint)
                .font(.system(size: 11))
                .foregroundColor(OnboardingPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                OnboardingPillButton(
                    title: "Cancel",
                    style: .secondary,
                    size: .compact,
                    action: { state.cancelModelChooser() }
                )
                OnboardingPillButton(
                    title: "Use this model",
                    style: .primary,
                    size: .compact,
                    isEnabled: state.draftModel != nil,
                    action: { state.commitModelChooser() }
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    /// Footer hint carrying the Mac's actual specs, so every row's download /
    /// memory numbers above are readable against real capacity. Degrades to
    /// the generic wording when the monitor hasn't reported RAM yet.
    private var footerHint: String {
        let totalMemoryGB = systemMonitor.totalMemoryGB
        guard totalMemoryGB > 0 else {
            return L("Bigger models are smarter but use more memory.")
        }
        let memoryGB = Int(totalMemoryGB.rounded())
        let comfortableGB = GPUMemoryBudget.assessment(
            modelSizeBytes: nil,
            sizeSource: nil,
            physicalMemoryGB: totalMemoryGB
        ).comfortableModelBudgetGB
        let comfortableText = String(format: "%.0f GB", comfortableGB)
        if let free = state.freeDiskBytes {
            let freeText = free.formatted(.byteCount(style: .file, allowedUnits: [.gb, .mb]))
            return L(
                "Your Mac has \(memoryGB) GB unified memory; for smooth performance, choose models estimated below \(comfortableText) while running. \(freeText) storage is free."
            )
        }
        return L(
            "Your Mac has \(memoryGB) GB unified memory; for smooth performance, choose models estimated below \(comfortableText) while running."
        )
    }

    // MARK: Catalog (modal-local)

    /// The curated top picks with same-family quant variants collapsed to a
    /// single, hardware-chosen build (`ConfigureAIState.dedupedTopPicks`) —
    /// the raw catalog ships e.g. two "Qwen3.6 27B" builds that read as
    /// duplicates once titles are simplified. Keyed on the committed
    /// `selectedModel` (stable while the dialog is open, unlike the draft) so
    /// rows don't reshuffle as the user taps around.
    private var dedupedTopPicks: [MLXModel] {
        ConfigureAIState.dedupedTopPicks(
            from: modelManager.suggestedModels.filter(\.isTopSuggestion),
            totalMemoryGB: systemMonitor.totalMemoryGB,
            selectedId: state.selectedModel?.id
        )
    }

    /// Onboarding is intentionally opinionated — it surfaces only our curated
    /// top picks (downloaded ones still appear, tagged "Downloaded"), so the
    /// first-run list never balloons with ad-hoc / auto-fetched models on disk.
    /// The full catalog lives in the Models tab. Each row is paired with its
    /// compatibility verdict (`.unknown` fails open so the list isn't blank
    /// before the system monitor reports), and the hardware-aware
    /// recommendation is pinned first so the safe default is the first thing
    /// a first-timer sees; everything else keeps catalog order, except LFM
    /// rows, which always sink to the bottom (the recommendation pin wins
    /// when LFM itself is the hardware pick — the "Picked for your Mac"
    /// badge must stay on the first row).
    private var pickerModels: [(model: MLXModel, compatibility: ModelCompatibility)] {
        let totalMemoryGB = systemMonitor.totalMemoryGB
        var items = dedupedTopPicks.map {
            (model: $0, compatibility: $0.compatibility(totalMemoryGB: totalMemoryGB))
        }
        if let recommendedId = recommendedRowId {
            let recommended = items.filter { $0.model.id == recommendedId }
            let rest = items.filter { $0.model.id != recommendedId }
            items = recommended + rest
        }
        let lfm = items.filter { $0.model.id != recommendedRowId && isLFM($0.model) }
        return items.filter { $0.model.id == recommendedRowId || !isLFM($0.model) } + lfm
    }

    private func isLFM(_ model: MLXModel) -> Bool {
        model.id.lowercased().contains("lfm")
    }

    /// The row carrying the "Picked for your Mac" pill — the exact build
    /// `recommendedLocalPick` chose, and only when dedupe kept it visible
    /// (it always does unless a family sibling is selected or already on
    /// disk). No family-level fallback: badging a sibling the policy didn't
    /// pick would contradict the home card's "picked for your specs" line,
    /// which requires an exact id match.
    private var recommendedRowId: String? {
        guard
            let recommended = ConfigureAIState.recommendedLocalPick(
                from: modelManager.suggestedModels.filter(\.isTopSuggestion),
                totalMemoryGB: systemMonitor.totalMemoryGB
            )
        else { return nil }
        return dedupedTopPicks.contains(where: { $0.id == recommended.id })
            ? recommended.id : nil
    }
}

// The provider chip rows reuse `ChipFlowLayout` from
// Views/Chat/ClarifyPromptOverlay.swift (internal, same wrap semantics).

// MARK: - Preview

#if DEBUG
    struct OnboardingConfigureAIView_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                OnboardingPalette.windowBackground
                ConfigureAIStepView(state: ConfigureAIState(), onComplete: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight)
        }
    }
#endif
