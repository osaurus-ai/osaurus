//
//  OnboardingConfigureAIView.swift
//  osaurus
//
//  Onboarding step 3 — "Give your dino a brain". Local-first: a single home
//  screen leads with "Run on your Mac" (the recommended default — a curated
//  MLX model that runs locally) and tucks bring-your-own-key behind a quiet
//  drill-in row.
//
//  Apple Intelligence was removed from this step: it's too limited (no tools,
//  no web, no agent work) to be a first-class first-run option. Users with
//  `FoundationModelService` available can still configure it post-onboarding
//  from Settings.
//
//  Split into:
//   - `ConfigureAIState`: ObservableObject holding the committed brain source,
//     the drilled-in screen (download / bring-your-own-key), connection-test
//     progress, and the slide direction (lives at the OnboardingView level so
//     it survives step transitions).
//   - `ConfigureAIBody`: the body slot — a two-column shell whose right column
//     is the home screen, sliding direction-aware into the download and
//     bring-your-own-key sub-screens.
//   - `ConfigureAICTA`: the footer primary action, dispatched per screen.
//

import SwiftUI

// MARK: - Screen / substates

/// The top-level screen within the Configure AI step. `home` shows the local
/// "Run on your Mac" card and the bring-your-own-key entry row; the other two
/// are drilled-in sub-screens reached from home.
enum ConfigureScreen: Equatable {
    case home
    case downloading
    case byok
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
    /// The screen currently shown. Starts at `home` (the recommended local card
    /// plus the bring-your-own-key entry row).
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

    // Local
    @Published var selectedModel: MLXModel? = nil

    /// Free bytes on the volume that will host the model download, refreshed
    /// one-shot (`refreshFreeDiskSpace`) on appear / chooser open / CTA press.
    /// Deliberately not `SystemMonitorService.availableStorageGB`: subscribing
    /// this deep onboarding tree to the monitor's 2s publishes forced a full
    /// re-render every tick (see the note on `ConfigureAIBody.systemMonitor`),
    /// and the stat lines only need a point-in-time value. `nil` means the
    /// query failed — render stats without the free-space context.
    @Published var freeDiskBytes: Int64? = nil

    /// Inline "not enough disk space" warning shown under the local card when
    /// the CTA-press preflight refuses. Cleared on model change and on a
    /// passing preflight, so it never sticks to a different selection.
    @Published var diskSpaceWarning: String? = nil

    // API
    @Published var apiKey: String = ""
    /// The connection method pinned for the selected provider, set from the
    /// catalog at selection time (OAuth for top-level rows, `.apiKey` for the
    /// "Use an API key" sub-list). There is no in-form fork; this drives the
    /// CTA, key field, save/test branches, and back-routing.
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
    @Published var isTesting = false
    @Published var isSaving = false
    @Published var testResult: APITestResult? = nil
    /// One-shot latch so the auto-advance-on-green and a manual CTA press can't
    /// both finalize. Reset whenever credentials are cleared (back / reselect).
    var hasFinalizedAPI = false

    // No footer caption. The reassurance copy crowded the footer, and a caption
    // present on one screen but not another makes the footer (and thus the
    // centered left-column dino) jump in height.
    var footerCaption: LocalizedStringKey? { nil }

    // MARK: Back handling

    /// The global header back button always exits the Configure AI step.
    /// Sub-screens (download, bring-your-own-key forms) have their own
    /// in-section back rows, so the header back button doesn't double as both
    /// global-step nav AND sub-screen nav — that ambiguity used to confuse
    /// users.
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

    /// A download refusal that never flipped the state machine: the service's
    /// upfront preflight (e.g. not enough disk space) sets only
    /// `downloadAlert` and returns while the state is still `.notStarted`.
    /// Attributed by model id so an alert for some other download can't
    /// hijack this step. Read by both the downloading screen (renders the
    /// failed card inline) and the CTA (flips to "Try Again") so the two
    /// surfaces can't disagree.
    var localDownloadRefusal: ModelDownloadService.DownloadAlertInfo? {
        guard let alert = ModelManager.shared.downloadAlert,
            alert.modelId == selectedModel?.id,
            case .notStarted = localDownloadState
        else { return nil }
        return alert
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

    /// Auto-selects the recommended local pick — the best model this Mac can
    /// run — so the home screen lands on a sensible default the user can just
    /// accept. The rule is hardware-deterministic:
    ///
    ///   1. If a curated top pick is already on disk, keep it. The user
    ///      downloaded (and presumably ran) it before, so the compat
    ///      heuristic shouldn't lock them out.
    ///   2. Otherwise defer to `recommendedLocalPick`: the largest dense
    ///      Gemma 4 QAT model that *comfortably* fits, with the E-series
    ///      8-bit retention builds as the gated small-tier fallback. We no
    ///      longer auto-default into the `.tight` band or onto the largest
    ///      MoE/flagship — that pushed users onto models they couldn't really
    ///      run (the 26B-A4B 36%-bounce case).
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
    /// Preference order, all restricted to the **comfortable** (`.compatible`)
    /// band so we never auto-default into `.tight`:
    ///   1. The largest dense Gemma 4 QAT build (12B/31B `qat-MXFP4`) — the
    ///      auto-default spine.
    ///   2. The largest Gemma 4 E-series 8-bit retention build — the gated
    ///      small-tier fallback (until the QAT-4bit-vs-8bit A/B clears).
    ///   3. The smallest comfortable top pick; or, if nothing is comfortable,
    ///      the smallest candidate overall (never the largest).
    ///
    /// The 26B-A4B QAT MoE and the larger Qwen/Nemotron flagships are
    /// intentionally excluded from (1)/(2): they stay selectable Top Picks but
    /// are never auto-selected.
    static func recommendedLocalPick(
        from candidates: [MLXModel],
        totalMemoryGB: Double
    ) -> MLXModel? {
        let comfortable = candidates.filter {
            $0.compatibility(totalMemoryGB: totalMemoryGB) == .compatible
        }

        func largest(_ pool: [MLXModel]) -> MLXModel? {
            pool.max(by: { ($0.estimatedMemoryGB ?? 0) < ($1.estimatedMemoryGB ?? 0) })
        }
        func smallest(_ pool: [MLXModel]) -> MLXModel? {
            pool.min(by: {
                ($0.estimatedMemoryGB ?? .greatestFiniteMagnitude)
                    < ($1.estimatedMemoryGB ?? .greatestFiniteMagnitude)
            })
        }

        if let denseQAT = largest(comfortable.filter(\.isDenseGemmaQATAutoDefault)) {
            return denseQAT
        }
        if let eSeries8bit = largest(comfortable.filter(\.isGemmaESeries8bitAutoDefault)) {
            return eSeries8bit
        }
        return smallest(comfortable) ?? smallest(candidates)
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
    ///      (QAT spine) must survive dedupe, or the "Picked for your Mac"
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

    /// Tapping a local model row (in the "Change" popover) makes it the active
    /// local brain. Kept side-effect-light (no `withAnimation`) so the footer
    /// CTA doesn't morph through the shared transaction. Clears any disk-space
    /// warning raised for the previous selection — the new model has its own
    /// footprint and gets its own preflight at the next CTA press.
    func selectLocalModel(_ model: MLXModel) {
        selectedModel = model
        diskSpaceWarning = nil
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

    /// Whether `selected` is exactly the model `recommendedLocalPick` would
    /// choose for this machine — the condition for the "picked for your Mac's
    /// specs" line on the home card. Pure so the render rule is unit-testable.
    static func isRecommendedSelection(
        _ selected: MLXModel?,
        candidates: [MLXModel],
        totalMemoryGB: Double
    ) -> Bool {
        guard let selected else { return false }
        return recommendedLocalPick(from: candidates, totalMemoryGB: totalMemoryGB)?.id
            == selected.id
    }

    // MARK: Resource stat formatting

    /// Home-card memory stat: the model's runtime RAM cost read against the
    /// Mac's own total, so cost and capacity land in one glance. `nil` when
    /// the model has no RAM estimate (hide the line rather than show "~—").
    static func memoryStatText(for model: MLXModel, totalMemoryGB: Double) -> String? {
        guard let memory = model.formattedEstimatedMemory else { return nil }
        guard totalMemoryGB > 0 else {
            return L("Uses \(memory) of memory while it runs")
        }
        return L(
            "Uses \(memory) of your \(Int(totalMemoryGB.rounded())) GB memory while it runs"
        )
    }

    /// Home-card disk stat: download cost against the Mac's free space, or
    /// the on-disk footprint once downloaded. `nil` when the size is unknown;
    /// an unknown free-space query drops the "you have N free" suffix rather
    /// than showing 0.
    static func diskStatText(for model: MLXModel, freeDiskBytes: Int64?) -> String? {
        guard let size = model.formattedDownloadSize else { return nil }
        if model.isDownloaded {
            return L("\(size) on disk")
        }
        guard let free = freeDiskBytes else {
            return L("\(size) download")
        }
        let freeText = free.formatted(.byteCount(style: .file, allowedUnits: [.gb, .mb]))
        return L("\(size) download — you have \(freeText) free")
    }

    /// Chooser-row stat line ("7.5 GB download · needs ~9.4 GB memory") —
    /// the size moved out of the badge cluster into a labeled, scannable
    /// line. `nil` when neither stat is known so the row omits it entirely.
    static func chooserStatsLine(for model: MLXModel) -> String? {
        var parts: [String] = []
        if let size = model.formattedDownloadSize {
            parts.append(model.isDownloaded ? L("\(size) on disk") : L("\(size) download"))
        }
        if let memory = model.formattedEstimatedMemory {
            parts.append(L("needs \(memory) memory"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Plain-language one-liner for a chooser row, derived from the curated
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

    // MARK: Model chooser (centered modal)

    /// Whether the centered "Choose your model" dialog is open. It's hosted at
    /// the OnboardingView window root so it can dim the whole step and center
    /// over it — a popover trapped in the small, clipped body region overflowed
    /// the window and covered the footer CTA.
    @Published var isChoosingModel: Bool = false

    /// The model highlighted inside the chooser before the user confirms. The
    /// draft lets brand-new users browse without committing: `commitModelChooser`
    /// applies it, Cancel discards it.
    @Published var draftModel: MLXModel? = nil

    /// Open the chooser, seeding the highlight from the current selection.
    /// Refreshes the free-storage snapshot so the footer's machine-spec line
    /// is current when the dialog appears.
    func openModelChooser() {
        refreshFreeDiskSpace()
        draftModel = selectedModel
        isChoosingModel = true
    }

    /// Highlight a model inside the chooser (no commit yet).
    func selectDraftModel(_ model: MLXModel) {
        draftModel = model
    }

    /// Apply the highlighted model as the active local brain and close.
    func commitModelChooser() {
        if let model = draftModel {
            selectLocalModel(model)
        }
        isChoosingModel = false
    }

    /// Close the chooser without changing the selection.
    func cancelModelChooser() {
        isChoosingModel = false
    }

    func startLocalDownloadOrContinue(onComplete: () -> Void) {
        // Disk preflight before committing anything: without it, the download
        // service's own refusal only sets `downloadAlert` (presented by the
        // Models tab, not onboarding) and the user would land on a permanent
        // "Preparing download..." screen. Refusing here keeps them on home
        // with an inline banner and a clear way forward.
        if selectedModel?.isDownloaded != true, let warning = evaluateDiskShortfall() {
            diskSpaceWarning = warning
            return
        }
        diskSpaceWarning = nil

        // Committing to a local model — record the brain source for the funnel
        // (no payment, no network).
        selectedBrainSource = .local
        OnboardingTelemetry.brainSourceSelected(.local)
        if selectedModel?.isDownloaded == true {
            onComplete()
            return
        }
        substateDirection = .forward
        screen = .downloading
        startLocalDownload()
    }

    func startLocalDownload() {
        guard let model = selectedModel else { return }
        // Consume any stale refusal for this model before retrying, so the
        // downloading screen's inline failed card doesn't resurrect it while
        // the fresh attempt is spinning up. A repeat refusal sets a new alert.
        clearDownloadAlertForSelectedModel()
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

    /// Cancels an in-flight or paused download and returns the user to the home
    /// screen. Used by the inline Cancel control on the downloading screen so
    /// the user has a clear escape route — the previous version only had the
    /// small back chevron at the top of the section.
    func cancelLocalDownload() {
        if let model = selectedModel {
            ModelManager.shared.cancelDownload(model.id)
        }
        popToHome()
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

    /// Any drilled-in sub-screen → home (backward slide). Consumes a pending
    /// refusal alert for the selection — it was already shown inline on the
    /// downloading screen.
    func popToHome() {
        clearDownloadAlertForSelectedModel()
        substateDirection = .backward
        screen = .home
        isChoosingModel = false
    }

    /// Home → bring-your-own-key flow (forward slide).
    func showBYOK() {
        substateDirection = .forward
        apiSubstate = .picker
        screen = .byok
        isChoosingModel = false
    }

    /// BYOK top-level picker → home (backward slide). Clears any entered
    /// credentials so a stale secret never leaks across selections.
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

    var apiButtonState: OnboardingButtonState {
        if isTesting || isSaving { return .loading }
        switch testResult {
        case .success: return .success
        case .failure(let m): return .error(m)
        case nil: return .idle
        }
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
    /// result. Shared by every "back out of a form" path so stale secrets
    /// never leak across provider selections.
    private func clearAPICredentials() {
        apiKey = ""
        selectedAuthMethod = .apiKey
        oauthTokens = nil
        addedProviderId = nil
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

// MARK: - Body

struct ConfigureAIBody: View {
    @ObservedObject var state: ConfigureAIState

    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = ModelManager.shared
    /// Drives the capability filter on the local model popover. `totalMemoryGB`
    /// is populated synchronously in `SystemMonitorService.init`, so the first
    /// onboarding frame already has a real value to classify curated top
    /// suggestions against.
    /// Non-observing on purpose. We only ever read `totalMemoryGB` — total
    /// physical RAM, a runtime constant. Observing via `@ObservedObject`
    /// subscribed this deep onboarding tree to the service's 2s CPU/memory
    /// publishes, forcing a full re-render every tick. A plain reference reads
    /// the same constant without subscribing to publishes that can never change
    /// our output.
    private let systemMonitor = SystemMonitorService.shared

    var body: some View {
        OnboardingTwoColumnBody(
            illustrationAsset: "osaurus-brain",
            leftHeadline: "Pick a brain",
            leftBody:
                "Run a brain on your Mac, or plug in one you already pay for. You can swap brains any time, and your chats come along.",
            subtitle: "Your dino runs on your Mac. Add more power whenever you want.",
            // We manage our own inner scroll: each screen owns its scrolling so
            // the slide transition stays crisp.
            useScrollView: false
        ) {
            // Screen envelope. Clipped horizontally so the slide transition
            // never bleeds into the left column, but vertically scaled (`y: 4`)
            // so card hover shadows can escape the screen region without being
            // trimmed at the scroll-area edges.
            ZStack(alignment: .topLeading) {
                screenContainer
                    .id(substateID)
                    .transition(substateTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(Rectangle().scale(x: 1, y: 4))
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: substateID)
        }
        .onAppear {
            state.ensureLocalSelection(totalMemoryGB: systemMonitor.totalMemoryGB)
            state.refreshFreeDiskSpace()
        }
    }

    // MARK: - Screen dispatch

    private var substateID: String {
        switch state.screen {
        case .home: return "home"
        case .downloading: return "downloading"
        case .byok:
            switch state.apiSubstate {
            case .picker: return "byok-picker"
            case .apiKeyPicker: return "byok-key-picker"
            case .keyForm(let p): return "byok-key-\(p.rawValue)"
            case .customForm: return "byok-custom"
            }
        }
    }

    /// Direction-aware horizontal slide that mirrors the global step
    /// transition's vocabulary: pure offset, no opacity. Sized to the screen
    /// region width so the body slides cleanly off one edge while the next
    /// slides in from the opposite edge.
    private var substateTransition: AnyTransition {
        let dx = OnboardingMetrics.substateSlideOffset
        let inOffset = state.substateDirection == .forward ? dx : -dx
        let outOffset = state.substateDirection == .forward ? -dx : dx
        return .asymmetric(
            insertion: .offset(x: inOffset),
            removal: .offset(x: outOffset)
        )
    }

    /// Screen container — owns its own scrolling and in-section back row when
    /// the user has drilled into a sub-screen (download, bring-your-own-key).
    @ViewBuilder
    private var screenContainer: some View {
        switch state.screen {
        case .home:
            OnboardingScrollContainer { homeView }
        case .downloading:
            substateWithBackBar(onBack: { state.popToHome() }) {
                localDownloadingView
            }
        case .byok:
            byokContainer
        }
    }

    @ViewBuilder
    private var byokContainer: some View {
        switch state.apiSubstate {
        case .picker:
            substateWithBackBar(onBack: { state.popBYOKToHome() }) {
                apiPickerView
            }
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

    /// Sub-screen frame: an in-context back row (drills out to home / one level
    /// up) followed by the body wrapped in the shared scroll container for any
    /// overflow (key forms, custom-provider form, etc.).
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
        // Always a plain "Back" — a section title was redundant breadcrumb
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

    // MARK: - Home screen

    private var homeView: some View {
        VStack(spacing: 12) {
            runOnYourMacCard
            if let warning = state.diskSpaceWarning {
                OnboardingCalloutBanner(tone: .error, rawMessage: warning)
            }
            useYourOwnKeyRow
        }
    }

    // MARK: Run on your Mac (recommended, local)

    /// The recommended local card. Tapping the upper region selects the local
    /// brain; the model inset's "Change" control opens the model popover.
    /// The subtitle dropped its vague "uses some memory" clause — the inset's
    /// stat lines now state the exact memory/disk cost against this Mac's
    /// specs, and the caption below says how to undo the download later.
    private var runOnYourMacCard: some View {
        OnboardingGlassCard(isSelected: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    localBrainIcon
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Run on your Mac", bundle: .module)
                                .font(theme.font(size: 14, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                                .layoutPriority(2)
                            recommendedBadge
                            Spacer(minLength: 8)
                        }
                        Text(
                            "Free, private, and works offline.",
                            bundle: .module
                        )
                        .font(theme.font(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    selectionRadio(true)
                }

                localModelInset

                deleteAnytimeCaption
            }
            .padding(.horizontal, OnboardingMetrics.cardPaddingH)
            .padding(.vertical, OnboardingMetrics.cardPaddingV)
        }
    }

    /// Quiet one-liner that answers "what am I committing to?" — the model is
    /// a single self-contained folder, removable later from the Models tab.
    private var deleteAnytimeCaption: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .padding(.top, 2)
            Text(
                "Kept in one folder on your Mac — delete it anytime from the Models tab to get the space back.",
                bundle: .module
            )
            .font(theme.font(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(theme.tertiaryText)
    }

    /// Leading accent badge for the local card, mirroring `OnboardingRowCard`'s
    /// selected-icon treatment (accent fill + glow when selected).
    private var localBrainIcon: some View {
        ZStack {
            Circle()
                .fill(theme.accentColor)
                .blur(radius: 8)
                .frame(
                    width: OnboardingMetrics.cardIcon - 8,
                    height: OnboardingMetrics.cardIcon - 8
                )
            Circle()
                .fill(theme.accentColor)
                .frame(width: OnboardingMetrics.cardIcon, height: OnboardingMetrics.cardIcon)
            Image(systemName: "cpu")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
        }
    }

    /// The selected-model summary under the local card body. Every number
    /// carries the machine context inline (cost *of* this Mac's capacity) so
    /// the user reads cost and headroom in one glance:
    ///   - name row: model name + Downloaded chip + "Change"
    ///   - stat rows: runtime memory vs total RAM, download size vs free disk
    ///   - fit row: "picked for your specs" when the auto-default is active,
    ///     else the plain compatibility verdict.
    private var localModelInset: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(state.selectedModel?.simplifiedName ?? L("Choose a model"))
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                localInsetBadge
                Spacer(minLength: 8)
                changeButton
            }
            localResourceStats
            localFitLine
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.tertiaryBackground)
        )
    }

    @ViewBuilder
    private var localInsetBadge: some View {
        if state.selectedModel?.isDownloaded == true {
            OnboardingBadgeChip(badge: OnboardingRowBadge(L("Downloaded"), style: .success))
        }
    }

    /// The explicit resource cost of the selected model, read against this
    /// Mac's own specs. Lines with unknown values disappear instead of
    /// rendering placeholders.
    @ViewBuilder
    private var localResourceStats: some View {
        if let model = state.selectedModel {
            VStack(alignment: .leading, spacing: 4) {
                if let memory = ConfigureAIState.memoryStatText(
                    for: model,
                    totalMemoryGB: systemMonitor.totalMemoryGB
                ) {
                    localStatLine(icon: "memorychip", text: memory)
                }
                if let disk = ConfigureAIState.diskStatText(
                    for: model,
                    freeDiskBytes: state.freeDiskBytes
                ) {
                    localStatLine(icon: "internaldrive", text: disk)
                }
            }
        }
    }

    private func localStatLine(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 13)
            Text(text)
                .font(theme.font(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// The trust line: when the selection is exactly the model the funnel
    /// recommends for this hardware, say so ("we chose this for you"). When
    /// the user picked something else in the chooser, fall back to the plain
    /// fit verdict so the claim stays honest.
    @ViewBuilder
    private var localFitLine: some View {
        if let model = state.selectedModel {
            if isRecommendedSelection(model) {
                localFitRow(
                    icon: "checkmark.seal.fill",
                    text: L("Picked for your Mac's specs — nothing to configure"),
                    color: theme.successColor
                )
            } else {
                switch model.compatibility(totalMemoryGB: systemMonitor.totalMemoryGB) {
                case .compatible:
                    localFitRow(
                        icon: "checkmark.shield.fill",
                        text: L("Runs well on this Mac"),
                        color: theme.successColor
                    )
                case .tight:
                    localFitRow(
                        icon: "exclamationmark.triangle.fill",
                        text: L("Tight fit on this Mac"),
                        color: theme.warningColor
                    )
                case .tooLarge:
                    localFitRow(
                        icon: "xmark.octagon.fill",
                        text: L("Too large for this Mac"),
                        color: theme.errorColor
                    )
                case .unknown:
                    EmptyView()
                }
            }
        }
    }

    private func localFitRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 13)
            Text(text)
                .font(theme.font(size: 11, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundColor(color)
    }

    private func isRecommendedSelection(_ model: MLXModel) -> Bool {
        ConfigureAIState.isRecommendedSelection(
            model,
            candidates: modelManager.suggestedModels.filter(\.isTopSuggestion),
            totalMemoryGB: systemMonitor.totalMemoryGB
        )
    }

    private var changeButton: some View {
        Button {
            state.openModelChooser()
        } label: {
            Text("Change", bundle: .module)
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedHelp("Change model")
    }

    // MARK: Use your own key (BYOK entry)

    /// Quiet single-line drill-in to the bring-your-own-key flow.
    private var useYourOwnKeyRow: some View {
        Button {
            state.showBYOK()
        } label: {
            OnboardingGlassCard {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(theme.cardBackground)
                            .frame(width: 32, height: 32)
                        Image(systemName: "key.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                    }
                    Text("Already pay for AI? Use your own key", bundle: .module)
                        .font(theme.font(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.horizontal, OnboardingMetrics.cardPaddingH)
                .padding(.vertical, 12)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Shared selection radio

    private func selectionRadio(_ isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? theme.accentColor : theme.primaryBorder,
                    lineWidth: isSelected ? 6 : 1.5
                )
                .frame(width: 20, height: 20)
            if isSelected {
                Circle().fill(Color.white).frame(width: 7, height: 7)
            }
        }
    }

    // MARK: "Recommended" badge

    /// "Recommended" pill shown beside the local card title.
    private var recommendedBadge: some View {
        Text("Recommended", bundle: .module)
            .font(theme.font(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.accentColor))
    }

    // MARK: - Local downloading

    /// State-driven downloading view. Renders one of three layouts depending
    /// on the live `localDownloadState`:
    /// - `.downloading` / `.paused` (or initial): progress card with inline
    ///   Pause / Resume / Cancel controls, plus the delete-anytime caption.
    /// - `.failed`: inline error card with Retry and Choose-another-model
    ///   actions, so the user always has a path forward without a disabled
    ///   Continue button.
    /// - a refusal that never started (`downloadAlert` with `.notStarted`):
    ///   rendered through the same failed card. The service's upfront disk
    ///   preflight refuses by setting only `downloadAlert` — presented by the
    ///   Models tab, not here — which used to strand onboarding on a permanent
    ///   "Preparing download..." screen.
    @ViewBuilder
    private var localDownloadingView: some View {
        if case .failed(let message) = state.localDownloadState {
            localDownloadFailedCard(message: message)
        } else if let refusal = state.localDownloadRefusal {
            localDownloadFailedCard(message: refusal.message)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                localDownloadProgressCard
                downloadReassuranceCaption
            }
        }
    }

    /// Deletion reassurance at the moment the user is watching gigabytes
    /// arrive — where the "what did I just commit to?" worry actually lives.
    private var downloadReassuranceCaption: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .padding(.top, 2)
            Text(
                "Saved to your Models folder as a single download — delete it anytime to get the space back.",
                bundle: .module
            )
            .font(theme.font(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 4)
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
    /// for "Continue when done", but give the user immediate, visible control
    /// over the in-flight download so they're never stuck (issue
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

    /// Inline failure card with Try again / Choose another model actions, so
    /// the user always has a clear path forward without the chrome dead-ending
    /// into a disabled Continue button.
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
                        action: { state.popToHome() }
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

    /// The bring-your-own-key body: OAuth-first sign-in rows plus the "Use an
    /// API key" drill-in.
    private var apiPickerView: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.cardSpacing) {
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
        switch preset {
        case .custom:
            return L("Custom / OpenAI-compatible")
        default:
            return preset.name
        }
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

    /// Lift selected provider badges to a richer style so the provider
    /// picker stays scannable. Ollama's "Local" label specifically gets
    /// the success-green chip — it lives in the bring-your-own-key tab for
    /// routing reasons (same HTTP code path), but the row needs to read as
    /// "this is the local-server option" at a glance.
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

// MARK: - Model chooser modal

/// Centered "Choose your model" dialog, hosted at the OnboardingView window
/// root over a dimmed scrim. It replaces the old floating "Change" popover,
/// which crammed a tall scrolling list into the small, clipped body region —
/// overflowing the window and covering the footer CTA.
///
/// Forgiving draft-then-confirm so brand-new users can browse without
/// committing: tapping a row only highlights it (`state.draftModel`); "Use this
/// model" commits, while Cancel / X / Esc / scrim-tap dismiss without touching
/// the active selection. Copy and rows are written for first-timers — no
/// `LLM`/`VLM` jargon, one hardware-chosen build per model family, a
/// "Picked for your Mac" pill on the safe default, and per-row cost stats
/// read against this Mac's specs in the footer.
struct ConfigureModelChooserModal: View {
    @ObservedObject var state: ConfigureAIState

    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = ModelManager.shared

    /// See `ConfigureAIBody.systemMonitor`: a plain reference (not an
    /// `@ObservedObject`) so the dialog doesn't re-render on every 2s
    /// CPU/memory publish — `totalMemoryGB` is constant for the session.
    private let systemMonitor = SystemMonitorService.shared

    private let dialogWidth: CGFloat = 520
    private let dialogCornerRadius: CGFloat = 20

    var body: some View {
        ZStack {
            scrim
            dialog
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Esc closes the dialog without changing the selection.
        .onExitCommand { state.cancelModelChooser() }
    }

    // MARK: Scrim

    /// Dims the whole step behind the dialog and acts as a tap-to-cancel
    /// target, so a background click reads as "never mind".
    private var scrim: some View {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { state.cancelModelChooser() }
    }

    // MARK: Dialog

    private var dialog: some View {
        VStack(spacing: 0) {
            header
            hairline
            modelList
            hairline
            footer
        }
        .frame(width: dialogWidth)
        .background(dialogSurface)
        .clipShape(RoundedRectangle(cornerRadius: dialogCornerRadius, style: .continuous))
        .overlay(dialogBorder)
        .shadow(color: theme.shadowColor.opacity(0.28), radius: 30, y: 14)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private var dialogSurface: some View {
        ZStack {
            if theme.glassEnabled {
                Rectangle().fill(.ultraThinMaterial)
            }
            theme.cardBackground.opacity(
                theme.glassEnabled
                    ? (theme.isDark
                        ? OnboardingStyle.glassOpacityDark
                        : OnboardingStyle.glassOpacityLight)
                    : 1.0
            )
        }
    }

    private var dialogBorder: some View {
        RoundedRectangle(cornerRadius: dialogCornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(theme.isDark ? 0.35 : 0.6),
                        theme.primaryBorder.opacity(theme.isDark ? 0.4 : 0.5),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.primaryBorder.opacity(0.18))
            .frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose your model", bundle: .module)
                    .font(theme.font(size: 18, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Every model here runs privately on your Mac. Not sure? Keep the one we picked for your Mac's specs — you can switch anytime.",
                    bundle: .module
                )
                .font(theme.font(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            }
            Spacer(minLength: 8)
            OnboardingCloseButton { state.cancelModelChooser() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: List

    private var modelList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: OnboardingMetrics.cardSpacing) {
                ForEach(pickerModels, id: \.model.id) { pair in
                    // Too-large models stay visible so the badge can explain
                    // why, but can't be selected — committing to a model that
                    // won't run is the one unsafe choice this list can offer.
                    OnboardingRowCard(
                        icon: .symbol(pair.model.isVLM ? "eye" : "cpu"),
                        title: pair.model.simplifiedName,
                        subtitle: ConfigureAIState.chooserSubtitle(for: pair.model),
                        secondaryLine: ConfigureAIState.chooserStatsLine(for: pair.model),
                        badges: badges(for: pair.model, compatibility: pair.compatibility),
                        badgesBelowTitle: true,
                        accessory: .radio(isSelected: isDraftSelected(pair.model)),
                        isSelected: isDraftSelected(pair.model),
                        isDisabled: pair.compatibility == .tooLarge
                    ) {
                        state.selectDraftModel(pair.model)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(maxHeight: 380)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .medium))
                Text(footerHint)
                    .font(theme.font(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(theme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                OnboardingCompactButton(title: "Cancel", style: .ghost) {
                    state.cancelModelChooser()
                }
                OnboardingBrandButton(
                    title: "Use this model",
                    action: { state.commitModelChooser() },
                    isEnabled: state.draftModel != nil
                )
                .frame(width: 190)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
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
        if let free = state.freeDiskBytes {
            let freeText = free.formatted(.byteCount(style: .file, allowedUnits: [.gb, .mb]))
            return L(
                "Bigger models are smarter but need more memory — your Mac has \(memoryGB) GB memory and \(freeText) free storage."
            )
        }
        return L("Bigger models are smarter but need more memory — your Mac has \(memoryGB) GB memory.")
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
    /// top picks (downloaded ones still appear, badged "Downloaded"), so the
    /// first-run list never balloons with ad-hoc / auto-fetched models on disk.
    /// The full catalog lives in the Models tab. Each row is paired with its
    /// compatibility verdict (`.unknown` fails open so the list isn't blank
    /// before the system monitor reports), and the hardware-aware
    /// recommendation is pinned first so the safe default is the first thing
    /// a first-timer sees; everything else keeps catalog order.
    private var pickerModels: [(model: MLXModel, compatibility: ModelCompatibility)] {
        let totalMemoryGB = systemMonitor.totalMemoryGB
        let items = dedupedTopPicks.map {
            (model: $0, compatibility: $0.compatibility(totalMemoryGB: totalMemoryGB))
        }
        guard let recommendedId = recommendedRowId else { return items }
        let recommended = items.filter { $0.model.id == recommendedId }
        let rest = items.filter { $0.model.id != recommendedId }
        return recommended + rest
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

    private func isDraftSelected(_ model: MLXModel) -> Bool {
        state.draftModel?.id == model.id
    }

    /// Friendlier than the inline card badges: leads with a hardware-aware
    /// "Picked for your Mac" pill for first-timers, keeps the use-case
    /// category and a Downloaded chip, and surfaces the capability warnings —
    /// but drops the `LLM`/`VLM` jargon (the eye/cpu icon already signals
    /// modality). Sizes moved out of the badges into each row's labeled stat
    /// line (`ConfigureAIState.chooserStatsLine`), and precision chips went
    /// away entirely: dedupe guarantees one build per family, so there is no
    /// same-title pair left to tell apart.
    private func badges(
        for model: MLXModel,
        compatibility: ModelCompatibility
    ) -> [OnboardingRowBadge] {
        var result: [OnboardingRowBadge] = []
        if model.id == recommendedRowId {
            result.append(OnboardingRowBadge(L("Picked for your Mac"), style: .accent))
        }
        if let useCase = model.useCase {
            result.append(.useCase(useCase))
        }
        if model.isDownloaded {
            result.append(OnboardingRowBadge(L("Downloaded"), style: .success))
        }
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
}

// MARK: - CTA

/// Primary CTA for the Configure AI step, dispatched per screen:
///   - Home (local): Download & Install / Continue, enabled once a model is
///     selected.
///   - Downloading: a single adaptive "Continue in Background" → "Continue"
///     button (plus "Try Again" on failure).
///   - BYOK picker / API-key hub: cards drill in on tap, so a quiet hint
///     stands in for the (absent) Continue button.
///   - BYOK forms: the stateful Connect/Test/Continue button.
struct ConfigureAICTA: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    @Environment(\.theme) private var theme

    /// Observed-but-not-read: the CTA's `isLocalCompleted` / `isLocalFailed`
    /// reads bounce through `ConfigureAIState`, but those computed properties
    /// pull live values out of `ModelManager.shared` rather than out of any
    /// `@Published` on `state`. Without this observer the CTA wouldn't refresh
    /// from "Continue (disabled)" → "Continue (enabled)" when the download
    /// finishes.
    @ObservedObject private var modelManager = ModelManager.shared

    var body: some View {
        primaryButton
            .onChange(of: state.isLocalCompleted) { _, completed in
                if completed && state.screen == .downloading {
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
        switch state.screen {
        case .home:
            OnboardingBrandButton(
                title: homeCTATitle,
                action: { state.startLocalDownloadOrContinue(onComplete: onComplete) },
                isEnabled: state.selectedModel != nil
            )
            .fixedSize(horizontal: true, vertical: false)

        case .downloading:
            localDownloadingCTA

        case .byok:
            switch state.apiSubstate {
            case .picker, .apiKeyPicker:
                // Provider cards drill in on tap — no Continue press required.
                // A subtle hint replaces the dead disabled button so the footer
                // reads as guidance, not a broken control.
                providerPickerHint
            case .keyForm, .customForm:
                apiActionButton
            }
        }
    }

    /// Home CTA title states the cost at the action itself: the download size
    /// rides along ("Download & Install (7.5 GB)") so pressing the button is
    /// never a surprise commitment. Falls back to the plain label when the
    /// size is unknown; already-downloaded models continue as before.
    private var homeCTATitle: String {
        if state.selectedModel?.isDownloaded == true { return L("Continue") }
        if let size = state.selectedModel?.formattedDownloadSize {
            return L("Download & Install (\(size))")
        }
        return L("Download & Install")
    }

    /// Footer text shown on the bring-your-own-key provider list / API-key hub,
    /// where the cards themselves are the action. A quiet hint reads better than
    /// a dead disabled "Continue".
    private var providerPickerHint: some View {
        Text("Pick a provider to continue", bundle: .module)
            .font(theme.font(size: OnboardingMetrics.captionSize))
            .foregroundColor(theme.tertiaryText)
            .frame(height: OnboardingMetrics.buttonHeight)
    }

    /// CTA for the local downloading screen. Mirrors the inline state-driven
    /// downloading view: while the download is in flight or paused, the CTA is
    /// disabled and the inline Pause/Resume/Cancel controls own the action
    /// surface. On failure — including a preflight refusal that never started
    /// the download (`localDownloadRefusal`) — the CTA flips to a "Try Again"
    /// button so the user always has a path forward — issue
    /// [#1071](https://github.com/osaurus-ai/osaurus/issues/1071).
    @ViewBuilder
    private var localDownloadingCTA: some View {
        if state.isLocalFailed || state.localDownloadRefusal != nil {
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
