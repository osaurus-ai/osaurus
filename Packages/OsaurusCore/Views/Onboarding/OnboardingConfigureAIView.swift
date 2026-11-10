//
//  OnboardingConfigureAIView.swift
//  osaurus
//
//  Onboarding step 3 — Figma screen 3 ("A private brain that runs on your
//  Mac"). Left column: title, subtitle, and the step CTA ("Set
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

/// The top-level screen within the Configure AI step. `home` offers the
/// three peer paths (Raptor on this Mac, your own key, Osaurus Cloud);
/// `local` is the recommended-model card; `keys` is the provider chips;
/// `byok` is the per-provider connect drill-in under `keys`.
enum ConfigureScreen: Hashable {
    case home
    case local
    case keys
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

    /// Where this step is shown, for `brain_source_selected`: `onboarding`
    /// (the onboarding window) or `chat_sheet` (Choose a Brain over the
    /// first-run chat).
    var telemetrySurface = "onboarding"

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
        let downloaded = ModelManager.shared.installedModels()
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

    /// Preferred first-run local model. Named explicitly because v0.5 parses
    /// as 8B and would otherwise beat 0.6's 4B under the largest-parameter
    /// rule, and Gemma E4B is also a 4B Top Pick that could steal 8 GB.
    static let preferredOnboardingModelId = "OsaurusAI/Raptor-0.6-4B-JANG_6M"

    /// The bundled local brain the full distribution can commit without
    /// showing the Configure AI step, or `nil` when that step must run.
    ///
    /// All four gates must hold; any miss falls back to the normal step so
    /// the light build, a seed that has not landed yet (cross-volume models
    /// directory still copying), a user who deleted the seeded model, and a
    /// Mac where Raptor 0.6 only fits in the `.tight` band all get the full
    /// chooser:
    ///
    ///   1. `isFullDistribution` — the app shipped with `BundledModels`.
    ///   2. The preferred onboarding model is a curated Top Pick (so it is
    ///      what the chooser would have offered).
    ///   3. It is on disk (`isDownloaded`, i.e. `BundledModelSeeder` finished).
    ///   4. It fits **comfortably** (`.compatible`) — the same rule
    ///      `recommendedLocalPick` uses for the auto-default.
    static func bundledLocalBrainReady(
        from candidates: [MLXModel],
        totalMemoryGB: Double,
        isFullDistribution: Bool = BundledModelSeeder.isFullDistribution
    ) -> MLXModel? {
        guard isFullDistribution else { return nil }
        guard
            let bundled = candidates.first(where: {
                $0.isTopSuggestion && $0.id == preferredOnboardingModelId
            })
        else { return nil }
        guard bundled.isDownloaded else { return nil }
        guard bundled.compatibility(totalMemoryGB: totalMemoryGB) == .compatible else { return nil }
        return bundled
    }

    /// App-facing wrapper over `bundledLocalBrainReady(from:totalMemoryGB:)`
    /// that reads the live catalog (curated entries merged with the on-disk
    /// scan, so `isDownloaded` reflects the seeded bundle).
    func bundledLocalBrainReady(totalMemoryGB: Double) -> MLXModel? {
        Self.bundledLocalBrainReady(
            from: ModelManager.shared.deduplicatedModels(),
            totalMemoryGB: totalMemoryGB
        )
    }

    /// Commit the bundled brain exactly as `chooseLocalAndContinue` would for
    /// an on-disk model — no download, no disk preflight — so
    /// `finishOnboarding` pins it through `localDefaultModelIdToPin`.
    func commitBundledLocalBrain(_ model: MLXModel) {
        selectedModel = model
        diskSpaceWarning = nil
        selectedBrainSource = .local
        OnboardingTelemetry.brainSourceSelected(.local, downloadStarted: false, surface: telemetrySurface)
    }

    /// Parameter-count floor that marks the large-RAM upgrade lane (Gemma 12B,
    /// Ornith 35B). Comfortable models at or above this beat the preferred
    /// Raptor 0.6 default.
    static let largeRAMOnboardingParameterFloor = 12.0

    /// Pure, testable core of the onboarding default pick. Given the curated
    /// top-pick `candidates` and the machine RAM, returns the model onboarding
    /// should pre-select (or `nil` when there are no candidates).
    ///
    /// Rule: auto-default to Raptor 0.6 when it **comfortably** fits
    /// (`.compatible`, never the `.tight` band) and no larger-RAM Top Pick
    /// (Gemma 12B / Ornith 35B) is also comfortable. Otherwise pick the
    /// curated Top Pick with the **largest base parameter count** that
    /// comfortably fits; equal-size variants prefer the larger resident
    /// footprint. Top Picks are the maintained onboarding recommendation
    /// set. Raptor v0.5 8B-A1B is retired from the catalog entirely.
    /// Dense Bonsai 27B, LFM2.5 8B, and dense Ornith 1.5 9B remain catalog
    /// choices rather than first-run defaults. When nothing is comfortable
    /// (very low RAM), fall back to the smallest candidate overall so
    /// onboarding never dead-ends.
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

        if let preferred = comfortable.first(where: { $0.id == preferredOnboardingModelId }) {
            let hasLargerRAMTier = comfortable.contains {
                ($0.parameterCountBillions ?? 0) >= largeRAMOnboardingParameterFloor
            }
            if !hasLargerRAMTier {
                return preferred
            }
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

    /// Why a chooser row is disabled: "Needs about 24 GB; this Mac has 16 GB."
    /// Nil when either number is unknown.
    nonisolated static func tooLargeReason(estimatedMemoryGB: Double?, totalMemoryGB: Double) -> String? {
        guard let needed = estimatedMemoryGB, needed > 0, totalMemoryGB > 0 else { return nil }
        return L("Needs about \(Int(needed.rounded(.up))) GB; this Mac has \(Int(totalMemoryGB.rounded())) GB.")
    }

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

    /// What a model means for this Mac, in plain words. `nil` when the fit
    /// is unknown.
    static func fitLabel(_ compatibility: ModelCompatibility) -> String? {
        switch compatibility {
        case .compatible: return L("Runs smoothly here")
        case .tight: return L("May slow your other apps")
        case .tooLarge: return L("Too big for this Mac")
        case .unknown: return nil
        }
    }

    /// Why the app picked `model`, in terms of this Mac. `nil` when the
    /// person chose it themselves or the Mac's memory is unknown.
    static func pickReason(for model: MLXModel, recommendedId: String?, totalMemoryGB: Double) -> String? {
        if model.isDownloaded { return L("It's already on this Mac, so there's nothing to download.") }
        guard model.id == recommendedId, totalMemoryGB > 0 else { return nil }
        let memoryGB = Int(totalMemoryGB.rounded())
        if model.compatibility(totalMemoryGB: totalMemoryGB) == .compatible {
            return L("It runs smoothly with your Mac's \(memoryGB) GB of memory and leaves room for your other apps.")
        }
        return L("It's the lightest option, the best fit for your Mac's \(memoryGB) GB of memory.")
    }

    /// The chooser's two signposts among the models that run smoothly here:
    /// the lightest one, and the largest (the smartest that fits). `nil`s
    /// when fewer than two run smoothly, since one model is both.
    static func standouts(
        in models: [MLXModel],
        totalMemoryGB: Double
    ) -> (lightestId: String?, smartestId: String?) {
        let smooth = models.filter { $0.compatibility(totalMemoryGB: totalMemoryGB) == .compatible }
        guard smooth.count > 1 else { return (nil, nil) }
        let lightest = smooth.min {
            ($0.estimatedMemoryGB ?? .greatestFiniteMagnitude) < ($1.estimatedMemoryGB ?? .greatestFiniteMagnitude)
        }
        let smartest = smooth.max { lhs, rhs in
            let (lp, rp) = (lhs.parameterCountBillions ?? 0, rhs.parameterCountBillions ?? 0)
            if lp != rp { return lp < rp }
            return (lhs.estimatedMemoryGB ?? 0) < (rhs.estimatedMemoryGB ?? 0)
        }
        guard lightest?.id != smartest?.id else { return (nil, nil) }
        return (lightest?.id, smartest?.id)
    }

    /// The model onboarding would pick for this Mac from the live Top Picks.
    func recommendedModelId(totalMemoryGB: Double) -> String? {
        Self.recommendedLocalPick(
            from: ModelManager.shared.suggestedModels.filter(\.isTopSuggestion),
            totalMemoryGB: totalMemoryGB
        )?.id
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

    /// The Osaurus Cloud card (and Skip setup with nothing chosen): start on
    /// Osaurus Cloud (with the free welcome credit)
    /// instead of downloading anything. There is nothing to download or
    /// connect here — identity + router connect are prepared in the
    /// background by `OnboardingView` and finalized at finish.
    func chooseOsaurusAndContinue(onComplete: () -> Void) {
        selectedBrainSource = .osaurus
        OnboardingTelemetry.brainSourceSelected(.osaurus, surface: telemetrySurface)
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
        OnboardingTelemetry.brainSourceSelected(.local, downloadStarted: needsDownload, surface: telemetrySurface)
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

    /// Home → the recommended local model (forward slide).
    func showLocal() {
        substateDirection = .forward
        screen = .local
    }

    /// Home → the provider chips (forward slide).
    func showKeys() {
        substateDirection = .forward
        screen = .keys
    }

    /// Back to the three paths. Clears any entered credentials so a stale
    /// secret never leaks across selections.
    func popToHome() {
        resetAPIState(direction: .backward)
        screen = .home
    }

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
        OnboardingTelemetry.brainSourceSelected(.claudeCode, surface: telemetrySurface)
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
            // The custom dialog opens straight over the provider chips with
            // no drill-in behind it; an abandoned attempt pops the substate
            // too so no half-filled form lingers under the next chip tap.
            if screen == .keys, apiSubstate == .customForm {
                apiSubstate = .picker
                customEndpointURL = ""
                customForm.reset()
            }
        }
    }

    /// Provider drill-in → the provider chips (backward slide). Clears any
    /// entered credentials so a stale secret never leaks across selections.
    func popBYOKToProviders() {
        resetAPIState(direction: .backward)
        screen = .keys
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
            OnboardingTelemetry.brainSourceSelected(.providerKey(preset), surface: telemetrySurface)
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

/// The Brain chapter: a text column on the left (the stage dino stands
/// below it, outside this view) and the setup surface on glass at the right.
struct ConfigureAIStepView: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled, authoritative: true) }

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
        Group {

        HStack(alignment: .top, spacing: OnboardingLayout.columnGap) {
            ConfigureAILeftColumn(state: state, onComplete: onComplete)
                .frame(width: OnboardingLayout.brainColumnWidth, alignment: .topLeading)
            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onboardingEntrance(1, scaleFrom: 0.98)
        }
        .padding(.horizontal, OnboardingLayout.contentPadding)
        .padding(.top, OnboardingLayout.stageTopInset)
        .padding(.bottom, OnboardingLayout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            state.ensureLocalSelection(totalMemoryGB: systemMonitor.totalMemoryGB)
            state.refreshFreeDiskSpace()
        }

        }.environment(\.theme, theme)
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
                RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.panelRadius, theme), style: .continuous)
            )
            .animation(OnboardingMotion.gentle, value: substateID)
        }
    }

    private var substateID: String {
        switch state.screen {
        case .home: return "home"
        case .local: return "local"
        case .keys: return "keys"
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
            ConfigureAIPathsPanel(state: state, onComplete: onComplete)
        case .local:
            ConfigureAILocalPanel(state: state, onComplete: onComplete)
        case .keys:
            ConfigureAIKeysPanel(state: state)
        case .byok:
            ConfigureAIProviderPanel(state: state)
        case .claudeCode:
            ClaudeCodeSetupStep(
                onBack: {
                    state.substateDirection = .backward
                    state.screen = .keys
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

/// Title, subtitle, and, once a download is running or a provider is
/// verified, the "Continue to Osaurus" CTA.
private struct ConfigureAILeftColumn: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled, authoritative: true) }

    var body: some View {
        Group {

        VStack(alignment: .leading, spacing: 0) {
            Text(title, bundle: .module)
                .catalogTypography(.heading, theme: theme, fallback: OnboardingTypography.heroTitle)
                .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
                .fixedSize(horizontal: false, vertical: true)
                .id(state.screen)
                .transition(.opacity)

            Spacer().frame(height: theme.space.s16)

            Text(subtitle)
            .catalogTypography(.body, theme: theme, fallback: OnboardingTypography.subtitle)
            .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
            #if !OSAURUS_DESIGN_SYSTEM
            .lineSpacing(1.5)
            #endif
            .fixedSize(horizontal: false, vertical: true)
            .id(state.screen)
            .transition(.opacity)

            if hasCTA {
                Spacer().frame(height: theme.space.s32)
                cta
            }
        }
        .animation(theme.motion.standard, value: state.screen)
        .onboardingEntrance(0)

        }.environment(\.theme, theme)
}

    private var title: LocalizedStringKey {
        switch state.screen {
        case .home: return "What matters most to you?"
        case .local: return "A private model that runs on your Mac"
        case .keys, .byok: return "Use an AI account you already have"
        case .claudeCode: return "Use your Claude Code account"
        }
    }

    private var subtitle: String {
        switch state.screen {
        case .home:
            return L("Pick one to get started. You can change it any time in Settings.")
        case .local:
            let memoryGB = Int(SystemMonitorService.shared.totalMemoryGB.rounded())
            guard memoryGB > 0 else {
                return L("Picked to run smoothly on your Mac, so Osaurus can work privately, even offline.")
            }
            return L("Picked for your Mac's \(memoryGB) GB of memory, so Osaurus can work privately, even offline.")
        case .keys, .byok:
            return L("Connect the AI provider you already use. Your key is stored on this Mac.")
        case .claudeCode:
            return L("Osaurus delegates sign-in and requests to Anthropic's Claude Code CLI. Credentials stay with the CLI; model requests run in the cloud.")
        }
    }

    /// The left column only carries a CTA once there is something to
    /// continue with; each path's own card holds the way in.
    private var hasCTA: Bool { state.isAPISuccess || state.hasCommittedLocal }

    @ViewBuilder
    private var cta: some View {
        if state.isAPISuccess {
            OnboardingPillButton(
                title: "Continue to Osaurus",
                style: .primary,
                size: .large,
                trailingSymbol: "arrow.right",
                isEnabled: !state.isSaving,
                action: { state.saveProviderAndContinue(onComplete: onComplete) }
            )
        } else if state.hasCommittedLocal {
            OnboardingPillButton(
                title: "Continue to Osaurus",
                style: .primary,
                size: .large,
                trailingSymbol: "arrow.right",
                action: onComplete
            )
        }
    }
}

// MARK: - Paths panel

/// The right panel's home screen: three peer places for Osaurus to run.
private struct ConfigureAIPathsPanel: View {
    @Environment(\.theme) private var theme
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    @ObservedObject private var modelManager = ModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            OnboardingPathCard(
                symbol: "lock.laptopcomputer",
                title: "Keep it private, on this Mac",
                caption: "Free, works offline, and nothing you type leaves your Mac.",
                detail: localDetail,
                badge: "Recommended",
                isRecommended: true,
                status: localStatus
            ) {
                state.showLocal()
            }
            .onboardingEntrance(2)

            OnboardingPathCard(
                symbol: "bolt.fill",
                title: "Start chatting right away",
                caption: "Osaurus Cloud. Nothing to download, with free credit to start.",
                status: nil
            ) {
                state.chooseOsaurusAndContinue(onComplete: onComplete)
            }
            .onboardingEntrance(3)

            OnboardingPathCard(
                symbol: "person.crop.circle.badge.checkmark",
                title: "Use an AI account you already have",
                caption: "Sign in with ChatGPT, Grok, or OpenRouter, or use Claude Code or a key from OpenAI, Anthropic, Gemini, and more.",
                status: state.isAPISuccess ? L("Connected") : nil
            ) {
                state.showKeys()
            }
            .onboardingEntrance(4)

            Spacer(minLength: 0)
        }
        .padding(theme.space.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The pick and why, in terms of this Mac: "Picked for your 32 GB Mac:
    /// Gemma 4 12B, a one-time 8 GB download."
    private var localDetail: String? {
        guard let model = state.selectedModel else { return nil }
        let memoryGB = Int(SystemMonitorService.shared.totalMemoryGB.rounded())
        let name = model.simplifiedName
        if model.isDownloaded {
            return L("\(name) is already on this Mac, ready to go.")
        }
        switch (memoryGB > 0, model.formattedDownloadSize) {
        case (true, let size?):
            return L("Picked for your \(memoryGB) GB Mac: \(name), a one-time \(size) download.")
        case (true, nil):
            return L("Picked for your \(memoryGB) GB Mac: \(name).")
        case (false, let size?):
            return L("Picked for your Mac: \(name), a one-time \(size) download.")
        case (false, nil):
            return L("Picked for your Mac: \(name).")
        }
    }

    private var localStatus: String? {
        guard let model = state.selectedModel else { return nil }
        if model.isDownloaded { return state.hasCommittedLocal ? L("Ready") : nil }
        switch modelManager.downloadStates[model.id] {
        case .downloading(let progress):
            return String(format: L("Downloading %lld%%"), Int((progress * 100).rounded()))
        case .paused: return L("Paused")
        case .completed: return L("Ready")
        default: return nil
        }
    }
}

/// One of the three paths: icon, title, caption, an optional detail line,
/// badge, and live status, and a chevron. The recommended path wears the
/// dino-green glow so the default needs no deliberation.
private struct OnboardingPathCard: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    var detail: String? = nil
    var badge: LocalizedStringKey? = nil
    var isRecommended = false
    let status: String?
    let action: () -> Void

    @State private var isHovered = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: theme.space.s16) {
                ZStack {
                    Circle().fill(iconFill)
                    Image(systemName: symbol)
                        .glyphSize(17, weight: .semibold)
                        .foregroundColor(
                            isHovered || isRecommended ? OnboardingPalette.dinoGreen : OnboardingPalette.labelPrimary)
                }
                .frame(width: theme.space.s48, height: theme.space.s48)

                VStack(alignment: .leading, spacing: theme.space.s4) {
                    HStack(spacing: theme.space.s8) {
                        Text(title, bundle: .module)
                            .font(OnboardingTypography.cardTitle)
                            .foregroundColor(OnboardingPalette.labelPrimary)
                        if let badge {
                            OnboardingPickedBadge(text: badge, tint: isRecommended ? OnboardingPalette.dinoGreen : nil)
                        }
                    }
                    Text(caption, bundle: .module)
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(OnboardingTypography.cardCaption)
                            .foregroundColor(OnboardingPalette.labelPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let status {
                        Text(status)
                            .font(OnboardingTypography.badge)
                            .foregroundColor(OnboardingPalette.dinoGreen)
                            .contentTransition(.numericText())
                            .animation(theme.motion.standard, value: status)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .glyphSize(12, weight: .semibold)
                    .foregroundColor(OnboardingPalette.labelSecondary)
                    .offset(x: isHovered ? theme.space.s2 : 0)
            }
            .padding(theme.space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(isHovered ? OnboardingPalette.fill8 : OnboardingPalette.fill3)
                    if isRecommended {
                        shape.fill(
                            LinearGradient(
                                colors: [OnboardingPalette.createGradientGreen, .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    }
                }
            }
            .overlay {
                if isRecommended {
                    ZStack {
                        shape.strokeBorder(OnboardingPalette.dinoGreen, lineWidth: theme.stroke.focus)
                            .blur(radius: theme.space.s8)
                            .opacity(isHovered ? 0.9 : 0.6)
                        shape.strokeBorder(OnboardingPalette.dinoGreen, lineWidth: theme.stroke.focus)
                    }
                } else {
                    shape.strokeBorder(
                        isHovered ? OnboardingPalette.fill10 : OnboardingPalette.fill5, lineWidth: theme.stroke.default)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(OnboardingPressableButtonStyle())
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovered = hovering }
        }
    }

    private var iconFill: Color {
        if isRecommended { return OnboardingPalette.dinoGreen.opacity(isHovered ? 0.24 : 0.16) }
        return isHovered ? OnboardingPalette.fill10 : OnboardingPalette.fill5
    }
}

// MARK: - Shared back row

private struct ConfigureAIBackRow: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s4) {
                Image(systemName: "arrow.left")
                    .glyphSize(10, weight: .semibold)
                Text("Back", bundle: .module)
                    .font(OnboardingTypography.cardCaption)
            }
            .foregroundColor(OnboardingPalette.labelSecondary)
            .padding(.vertical, theme.space.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedHelp("Back")
    }
}

// MARK: - Local panel

/// Raptor on this Mac: the recommended-model card and its download.
private struct ConfigureAILocalPanel: View {
    @Environment(\.theme) private var theme
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConfigureAIBackRow { state.popToHome() }

            Spacer().frame(height: theme.space.s16)

            RecommendedModelCard(state: state, onComplete: onComplete)

            if let warning = state.diskSpaceWarning {
                Spacer().frame(height: theme.space.s12)
                Text(warning)
                    .font(OnboardingTypography.cardCaption)
                    .foregroundColor(OnboardingPalette.warningLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(theme.space.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Keys panel

/// Your own key: the provider chips, Claude Code, and a custom endpoint.
private struct ConfigureAIKeysPanel: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled, authoritative: true) }

    @ObservedObject var state: ConfigureAIState

    var body: some View {
        Group {

        VStack(alignment: .leading, spacing: 0) {
            ConfigureAIBackRow { state.popToHome() }

            Spacer().frame(height: theme.space.s16)

            Text("Choose your provider", bundle: .module)
                .componentInspectionText(55, role: .caption, fallback: .caption, weight: 600, theme: theme)
                .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))

            Spacer().frame(height: theme.space.s12)

            providerChips

            Spacer(minLength: 0)
        }
        .padding(theme.space.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        }.environment(\.theme, theme)
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

    /// Featured chips cascade in; the chips revealed by "+ More" instead
    /// pop in with the expansion animation itself.
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
                    chip.onboardingEntrance(1 + index)
                } else {
                    chip.transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }

            OnboardingProviderChip(
                logo: {
                    Image(systemName: "terminal.fill")
                        .glyphSize(11, weight: .semibold)
                        .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
                },
                label: "Claude Code"
            ) {
                state.enterClaudeCode()
            }
            .onboardingEntrance(1 + Self.featuredPresets.count)

            OnboardingProviderChip(
                logo: { OnboardingProviderLogo(preset: .custom, size: 16) },
                label: L("Custom")
            ) {
                state.enterCustomProvider()
            }
            .onboardingEntrance(2 + Self.featuredPresets.count)

            if !state.showAllProviders {
                OnboardingProviderChip(
                    logo: {
                        Image(systemName: "plus")
                            .glyphSize(11, weight: .semibold)
                            .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
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
                .onboardingEntrance(3 + Self.featuredPresets.count)
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
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled, authoritative: true) }
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void

    @ObservedObject private var modelManager = ModelManager.shared

    var body: some View {
        Group {

        if let model = state.selectedModel {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingPickedBadge(text: "Picked for your Mac")

                Spacer().frame(height: 12)

                titleRow(model)

                Spacer().frame(height: 6)

                if let subtitle = ConfigureAIState.chooserSubtitle(for: model) {
                    Text(subtitle)
                        .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                        .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let reason = pickReason(model) {
                    Spacer().frame(height: theme.space.s8)
                    (Text("Why this one: ", bundle: .module).bold() + Text(reason))
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer().frame(height: 14)

                statusBlock(model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 20, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 20, theme))).catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.body.padding.horizontal").catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.body.padding.vertical")
            .background(
                RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.cardRadius, theme), style: .continuous)
                    .fill(theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.cardRadius, theme), style: .continuous)
                    .strokeBorder(theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.fill8), lineWidth: theme.stroke.default)
            )
        }
    
        }.environment(\.theme, theme)
}

    /// Effective download state for the featured model. A bundle already on
    /// disk renders as `.completed` regardless of any stale service entry.
    private func downloadState(for model: MLXModel) -> DownloadState {
        if model.isDownloaded { return .completed }
        return modelManager.downloadStates[model.id] ?? .notStarted
    }

    private func titleRow(_ model: MLXModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.titleRow.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 10, theme))) {
            Text(model.simplifiedName)
                .catalogTypography(.heading, theme: theme, fallback: OnboardingTypography.modelTitle)
                .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelWhite))
                .fixedSize(horizontal: false, vertical: true)

            // The size moves inline next to the name once the meta chips are
            // replaced by the progress block (per the downloading frame).
            if isInProgress(model), let size = model.formattedDownloadSize {
                Text(size)
                    .componentInspectionText(55, role: .body, fallback: .body, theme: theme)
                    .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
            }
        }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.titleRow.horizontalGap")
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
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.statusBlock.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 16, theme))) {
                metaChips(model)
                HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.statusBlock.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 12, theme))) {
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
                }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.statusBlock.horizontalGap")
            }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.statusBlock.verticalGap")

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.statusBlock.verticalGap2", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 8, theme))) {
                Text("Downloading. You can continue while it finishes in the background.", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                    .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                OnboardingProgressBar(progress: progress)
                HStack(spacing: 0) {
                    let metrics = metricsText(for: model) ?? L("Starting download…")
                    Text(metrics)
                        .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                        .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                        .contentTransition(.numericText())
                        .animation(theme.motion.standard, value: metrics)
                    Spacer(minLength: 8)
                    if let remaining = remainingText(for: model, progress: progress) {
                        Text(remaining)
                            .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                            .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                            .contentTransition(.numericText())
                            .animation(theme.motion.standard, value: remaining)
                    }
                }
            }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.statusBlock.verticalGap2")

        case .paused(let progress):
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.statusBlock.verticalGap3", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 10, theme))) {
                OnboardingProgressBar(progress: progress)
                HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.statusBlock.horizontalGap2", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 12, theme))) {
                    Text("Download paused", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                        .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                    OnboardingPillButton(
                        title: "Resume download",
                        style: .primary,
                        size: .compact,
                        action: { modelManager.resumeDownload(model.id) }
                    )
                }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.statusBlock.horizontalGap2")
            }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.statusBlock.verticalGap3")

        case .failed(let error):
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.statusBlock.verticalGap4", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 10, theme))) {
                Text(L("Download hit a snag — \(error)"))
                    .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                    .foregroundColor(theme.assignedColor("component.library.55.error", fallback: OnboardingPalette.warningLabel))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.statusBlock.horizontalGap3", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 12, theme))) {
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
                }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.statusBlock.horizontalGap3")
            }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.statusBlock.verticalGap4")

        case .completed:
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.statusBlock.verticalGap5", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 16, theme))) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.statusBlock.horizontalGap4", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 6, theme))) {
                    Image(systemName: "checkmark.circle")
                        .glyphSize(12, weight: .semibold)
                        .foregroundColor(theme.assignedColor("component.library.55.accent", fallback: OnboardingPalette.dinoGreen))
                    Text("Already on your Mac — ready to go", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                        .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.statusBlock.horizontalGap4")
                HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.statusBlock.horizontalGap5", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 12, theme))) {
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
                }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.statusBlock.horizontalGap5")
            }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.statusBlock.verticalGap5")
        }
    }

    private func metaChips(_ model: MLXModel) -> some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.recommendedModelCard.metaChips.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 8, theme))) {
            if let size = model.formattedDownloadSize {
                OnboardingMetaChip(text: L("One-time \(size) download"))
            }
            if let fit = ConfigureAIState.fitLabel(model.compatibility(totalMemoryGB: totalMemoryGB)) {
                OnboardingMetaChip(text: fit)
            }
        }.catalogLayoutTarget("component.library.55.elements.layout.recommendedModelCard.metaChips.horizontalGap")
    }

    private var totalMemoryGB: Double { SystemMonitorService.shared.totalMemoryGB }

    private func pickReason(_ model: MLXModel) -> String? {
        ConfigureAIState.pickReason(
            for: model,
            recommendedId: state.recommendedModelId(totalMemoryGB: totalMemoryGB),
            totalMemoryGB: totalMemoryGB
        )
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
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled, authoritative: true) }

    @ObservedObject var state: ConfigureAIState

    private var preset: ProviderPreset? { state.currentAPIProvider }

    private var oauthKind: ProviderOAuthKind? {
        guard let preset else { return nil }
        return ProviderCatalog.entry(for: preset)?.primaryOAuthKind
    }

    var body: some View {
        Group {

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
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.configureAIProviderPanel.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 24, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.configureAIProviderPanel.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 24, theme))).catalogLayoutTarget("component.library.55.elements.layout.configureAIProviderPanel.body.padding.horizontal").catalogLayoutTarget("component.library.55.elements.layout.configureAIProviderPanel.body.padding.vertical")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    
        }.environment(\.theme, theme)
}

    private var backRow: some View {
        Button {
            state.popBYOKToProviders()
        } label: {
            HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.configureAIProviderPanel.backRow.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 5, theme))) {
                Image(systemName: "arrow.left")
                    .glyphSize(10, weight: .semibold)
                Text("Back", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
            }.catalogLayoutTarget("component.library.55.elements.layout.configureAIProviderPanel.backRow.horizontalGap")
            .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
            .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.configureAIProviderPanel.backRow.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 4, theme))).catalogLayoutTarget("component.library.55.elements.layout.configureAIProviderPanel.backRow.paddingY")
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
        VStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.configureAIProviderPanel.optionRows.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 12, theme))) {
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
        }.catalogLayoutTarget("component.library.55.elements.layout.configureAIProviderPanel.optionRows.verticalGap")
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
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled, authoritative: true) }
    @ObservedObject var state: ConfigureAIState

    private var preset: ProviderPreset? { state.currentAPIProvider }
    private var isOAuth: Bool { state.connectDialog == .oauth }

    var body: some View {
        Group {

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
                        .catalogTypography(.heading, theme: theme, fallback: OnboardingTypography.cardTitle)
                        .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelWhite))
                        .multilineTextAlignment(.center)

                    Spacer().frame(height: 8)

                    Text(caption(preset))
                        .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                        .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
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
                            .componentInspectionText(55, role: .caption, fallback: .footnote, theme: theme)
                            .foregroundColor(theme.assignedColor("component.library.55.error", fallback: OnboardingPalette.warningLabel))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320)
                    }

                    Spacer().frame(height: 24)

                    actionButton(preset)
                }
            }
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 40, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.body.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 36, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.body.paddingY")
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
    
        }.environment(\.theme, theme)
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
        #if OSAURUS_DESIGN_SYSTEM
        SettingsTextField(placeholder: L("sk-..."), text: $state.apiKey, monospaced: true, isSecure: true)
            .frame(maxWidth: 300).onChange(of: state.apiKey) { _, _ in state.testResult = nil }
        #else

        SecureField(L("sk-..."), text: $state.apiKey)
            .textFieldStyle(.plain)
            .componentInspectionText(55, role: .body, fallback: .code, theme: theme)
            .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.keyField.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 12, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.keyField.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.keyField.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 9, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.keyField.paddingY")
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .strokeBorder(theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.fill10), lineWidth: theme.stroke.default)
            )
            .frame(maxWidth: 300)
            .onChange(of: state.apiKey) { _, _ in state.testResult = nil }
    
        #endif
}

    /// Single paste-the-URL form for the custom OpenAI-compatible endpoint.
    /// The URL is parsed into scheme/host/port/path behind the scenes
    /// (`CustomProviderForm.parse`); a resolved preview confirms how the
    /// paste was understood. Optional key below for authenticated servers.
    private var customEndpointForm: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.customEndpointForm.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 10, theme))) {
            formField("http://localhost:11434/v1", text: $state.customEndpointURL)

            Group {
                #if OSAURUS_DESIGN_SYSTEM
                SettingsTextField(placeholder: L("API key (optional for local servers)"), text: $state.apiKey, monospaced: true, isSecure: true)
                #else
            SecureField(L("API key (optional for local servers)"), text: $state.apiKey)
                .textFieldStyle(.plain)
                .componentInspectionText(55, role: .body, fallback: .code, theme: theme)
                .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.customEndpointForm.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 12, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.customEndpointForm.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.customEndpointForm.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 9, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.customEndpointForm.paddingY")
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .fill(theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .strokeBorder(theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.fill10), lineWidth: theme.stroke.default)
                )


                #endif
            }

            // Confirm how the paste was understood, but only when parsing
            // actually added something (scheme, default /v1) beyond the
            // literal input — echoing an identical URL back is noise.
            if !state.customForm.host.isEmpty,
                state.customForm.endpointPreview
                    != state.customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
            {
                Text(state.customForm.endpointPreview)
                    .componentInspectionText(55, role: .code, fallback: .footnote, family: .code, theme: theme)
                    .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }.catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.customEndpointForm.verticalGap")
        .frame(maxWidth: 320)
        .onChange(of: state.customForm) { _, _ in state.testResult = nil }
        .onChange(of: state.apiKey) { _, _ in state.testResult = nil }
    }

    private func formField(_ placeholder: String, text: Binding<String>) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        SettingsTextField(placeholder: placeholder, text: text, monospaced: true)
        #else

        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .componentInspectionText(55, role: .body, fallback: .code, theme: theme)
            .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
            .autocorrectionDisabled()
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.formField.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 12, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.formField.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.formField.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 9, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.formField.paddingY")
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .strokeBorder(theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.fill10), lineWidth: theme.stroke.default)
            )
    
        #endif
}

    @ViewBuilder
    private func actionButton(_ preset: ProviderPreset) -> some View {
        if state.isTesting {
            HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.actionButton.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 8, theme))) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    isOAuth
                        ? LocalizedStringKey("Authenticating...")
                        : LocalizedStringKey("Connecting..."),
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: OnboardingTypography.chip)
                .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
            }.catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.actionButton.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.actionButton.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 16, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.actionButton.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.actionButton.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 8, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.actionButton.paddingY")
            .background(Capsule().fill(theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill8)))
        } else if state.isAPISuccess {
            HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.actionButton.horizontalGap2", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 6, theme))) {
                Image(systemName: "checkmark.circle")
                    .glyphSize(12, weight: .semibold)
                Text("Connected", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: OnboardingTypography.chip)
            }.catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.actionButton.horizontalGap2")
            .foregroundColor(theme.assignedColor("component.library.55.accent", fallback: OnboardingPalette.dinoGreen))
            .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.providerConnectDialog.actionButton.paddingY2", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 8, theme))).catalogLayoutTarget("component.library.55.elements.layout.providerConnectDialog.actionButton.paddingY2")
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
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled, authoritative: true) }
    @ObservedObject var state: ConfigureAIState

    @ObservedObject private var modelManager = ModelManager.shared

    /// See `ConfigureAIStepView.systemMonitor`: a plain reference (not an
    /// `@ObservedObject`) so the dialog doesn't re-render on every 2s
    /// CPU/memory publish — `totalMemoryGB` is constant for the session.
    private let systemMonitor = SystemMonitorService.shared

    var body: some View {
        Group {

        OnboardingDialog(width: 520, onClose: { state.cancelModelChooser() }) {
            VStack(spacing: 0) {
                header
                modelList
                footer
            }
        }
    
        }.environment(\.theme, theme)
}

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.header.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 6, theme))) {
            Text("Choose your model", bundle: .module)
                .catalogTypography(.heading, theme: theme, fallback: OnboardingTypography.cardTitle)
                .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelWhite))
            Text(
                "Bigger models give smarter answers but need more memory and a longer download. Lighter ones reply faster and leave room for your other apps. Not sure? Keep the one picked for your Mac.",
                bundle: .module
            )
            .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
            .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
            .fixedSize(horizontal: false, vertical: true)
        }.catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.header.verticalGap")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.header.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 24, theme))).catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.header.paddingX")
        .padding(.top, 24)
        .padding(.trailing, 44)
        .padding(.bottom, 16)
    }

    // MARK: List

    private var modelList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.modelList.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 8, theme))) {
                ForEach(pickerModels, id: \.model.id) { pair in
                    modelRow(pair.model, compatibility: pair.compatibility)
                }
            }.catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.modelList.verticalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.modelList.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 24, theme))).catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.modelList.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.modelList.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 4, theme))).catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.modelList.paddingY")
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
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.modelRow.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 4, theme))) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.modelRow.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 8, theme))) {
                    Text(model.simplifiedName)
                        .catalogTypography(.body, theme: theme, fallback: OnboardingTypography.optionTitle)
                        .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
                    if model.id == recommendedRowId {
                        OnboardingPickedBadge(text: "Picked for your Mac", tint: OnboardingPalette.dinoGreen)
                    } else if model.id == standouts.smartestId {
                        OnboardingPickedBadge(text: "Smartest that fits")
                    } else if model.id == standouts.lightestId {
                        OnboardingPickedBadge(text: "Lightest")
                    }
                    if model.isDownloaded {
                        OnboardingMetaChip(text: L("Downloaded"))
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle")
                            .glyphSize(13, weight: .semibold)
                            .foregroundColor(theme.assignedColor("component.library.55.accent", fallback: OnboardingPalette.dinoGreen))
                    }
                }.catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.modelRow.horizontalGap")
                if let subtitle = ConfigureAIState.chooserSubtitle(for: model) {
                    Text(subtitle)
                        .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                        .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                }
                fitLine(model, compatibility: compatibility)
                if isDisabled,
                    let reason = ConfigureAIState.tooLargeReason(
                        estimatedMemoryGB: model.estimatedMemoryGB, totalMemoryGB: systemMonitor.totalMemoryGB)
                {
                    Text(reason)
                        .componentInspectionText(55, role: .caption, fallback: .footnote, theme: theme)
                        .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
                }
            }.catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.modelRow.verticalGap")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.modelRow.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 14, theme))).catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.modelRow.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.modelRow.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 10, theme))).catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.modelRow.paddingY")
            .background(
                RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.cardRadius, theme), style: .continuous)
                    .fill(isSelected ? theme.assignedColor("component.library.55.selected", fallback: OnboardingPalette.fill5) : theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.cardRadius, theme), style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.dinoGreen) : theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.fill8),
                        lineWidth: theme.stroke.default
                    )
            )
            .contentShape(
                RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.cardRadius, theme), style: .continuous)
            )
        }
        .buttonStyle(OnboardingPressableButtonStyle(pressedScale: 0.985))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }

    /// "● Runs smoothly here · Download: 8 GB · …": the fit for this Mac
    /// first, in its color, then the cost.
    @ViewBuilder
    private func fitLine(_ model: MLXModel, compatibility: ModelCompatibility) -> some View {
        let stats = ConfigureAIState.chooserStatsLine(for: model)
        if let fit = ConfigureAIState.fitLabel(compatibility) {
            HStack(spacing: theme.space.s6) {
                Circle()
                    .fill(fitColor(compatibility))
                    .frame(width: theme.space.s6, height: theme.space.s6)
                Text(fit)
                    .font(OnboardingTypography.badge)
                    .foregroundColor(fitColor(compatibility))
                if let stats {
                    Text(verbatim: "· \(stats)")
                        .componentInspectionText(55, role: .caption, fallback: .footnote, theme: theme)
                        .foregroundColor(OnboardingPalette.labelSecondary)
                        .lineLimit(1)
                }
            }
        } else if let stats {
            Text(stats)
                .componentInspectionText(55, role: .caption, fallback: .footnote, theme: theme)
                .foregroundColor(OnboardingPalette.labelSecondary)
        }
    }

    private func fitColor(_ compatibility: ModelCompatibility) -> Color {
        switch compatibility {
        case .compatible: return OnboardingPalette.dinoGreen
        case .tight: return OnboardingPalette.fitTight
        case .tooLarge, .unknown: return OnboardingPalette.labelSecondary
        }
    }

    private var standouts: (lightestId: String?, smartestId: String?) {
        ConfigureAIState.standouts(in: dedupedTopPicks, totalMemoryGB: systemMonitor.totalMemoryGB)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.footer.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 12, theme))) {
            Text(footerHint)
                .componentInspectionText(55, role: .caption, fallback: .footnote, theme: theme)
                .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.footer.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 10, theme))) {
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
            }.catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.footer.horizontalGap")
        }.catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.footer.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.configureModelChooserModal.footer.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", 24, theme))).catalogLayoutTarget("component.library.55.elements.layout.configureModelChooserModal.footer.paddingX")
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
        if let free = state.freeDiskBytes {
            let freeText = free.formatted(.byteCount(style: .file, allowedUnits: [.gb, .mb]))
            return L(
                "Your Mac has \(memoryGB) GB of memory and \(freeText) of free storage. Models that run smoothly here leave room for your other apps."
            )
        }
        return L(
            "Your Mac has \(memoryGB) GB of memory. Models that run smoothly here leave room for your other apps."
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
