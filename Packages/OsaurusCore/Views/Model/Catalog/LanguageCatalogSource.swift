//
//  LanguageCatalogSource.swift
//  osaurus
//
//  Language models: the OsaurusAI catalog (one row per model family), the
//  models installed on this Mac (one row per bundle), and Hugging Face
//  search results.
//

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Catalog pipeline

/// Pure search / filter / family grouping over a snapshot of the model
/// manager, so it can run off the main thread.
enum LanguageModelCatalog {
    struct Lists {
        /// Top Pick families, newest first.
        let suggested: [MLXModel]
        /// The rest of the catalog, one representative per family, newest first.
        let others: [MLXModel]
        /// Installed bundles and downloads in flight, one per bundle.
        let downloaded: [MLXModel]
        /// Family keys of everything installed or downloading, unfiltered, so
        /// a searched-out bundle never resurfaces as an available family.
        var ownedFamilies: Set<String> = []
        /// Every catalog build keyed by `ModelMetadataParser.familyKey`, built
        /// from the unfiltered merged catalog so the detail view's version
        /// picker always shows the full family while the table is filtered.
        var variantsByFamily: [String: [MLXModel]] = [:]

        var catalog: [MLXModel] { suggested + others }

        static let empty = Lists(suggested: [], others: [], downloaded: [])
    }

    /// Value snapshot of everything `makeLists` reads, captured on the main
    /// actor.
    struct Input: Sendable {
        let availableModels: [MLXModel]
        let suggestedModels: [MLXModel]
        let deduplicatedModels: [MLXModel]
        let downloadStates: [String: DownloadState]
        let searchText: String
        let filterState: ModelManager.ModelFilterState
        let totalMemoryGB: Double
    }

    /// One row per model family: precision/quant variants of the same model
    /// (MXFP4 vs MXFP8 vs QAT vs JANGTQ…) collapse into a single
    /// representative. Each family keeps the position of its first-listed
    /// variant.
    nonisolated static func groupIntoFamilies(
        _ models: [MLXModel],
        totalMemoryGB: Double,
        downloadStates: [String: DownloadState]
    ) -> [MLXModel] {
        var order: [String] = []
        var buckets: [String: [MLXModel]] = [:]
        for model in models {
            let key = ModelMetadataParser.familyKey(from: model.id)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(model)
        }
        return order.compactMap { key in
            buckets[key].map {
                defaultFamilyVariant(among: $0, totalMemoryGB: totalMemoryGB, downloadStates: downloadStates)
            }
        }
    }

    /// The build a family row represents (and the one its Download button
    /// installs by default). Anything the user already owns or is actively
    /// downloading wins; otherwise the best build for this Mac: better RAM
    /// fit first, then curated over auto-fetched, Top Pick over plain, then
    /// highest precision (largest download) among equals, newest as the
    /// final tiebreak.
    nonisolated static func defaultFamilyVariant(
        among variants: [MLXModel],
        totalMemoryGB: Double,
        downloadStates: [String: DownloadState]
    ) -> MLXModel {
        func isActive(_ m: MLXModel) -> Bool {
            switch downloadStates[m.id] ?? .notStarted {
            case .downloading, .paused: return true
            default: return false
            }
        }
        func compatRank(_ m: MLXModel) -> Int {
            switch m.compatibility(totalMemoryGB: totalMemoryGB) {
            case .compatible: return 0
            case .tight: return 1
            case .tooLarge: return 2
            case .unknown: return 3
            }
        }
        let curatedIds = ModelManager.curatedSuggestedIds
        let best = variants.min { lhs, rhs in
            if isActive(lhs) != isActive(rhs) { return isActive(lhs) }
            if lhs.isDownloaded != rhs.isDownloaded { return lhs.isDownloaded }
            let lc = compatRank(lhs)
            let rc = compatRank(rhs)
            if lc != rc { return lc < rc }
            let lCurated = curatedIds.contains(lhs.id.lowercased())
            let rCurated = curatedIds.contains(rhs.id.lowercased())
            if lCurated != rCurated { return lCurated }
            if lhs.isTopSuggestion != rhs.isTopSuggestion { return lhs.isTopSuggestion }
            let ls = lhs.totalSizeEstimateBytes ?? 0
            let rs = rhs.totalSizeEstimateBytes ?? 0
            if ls != rs { return ls > rs }
            switch (lhs.releasedAt, rhs.releasedAt) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return best ?? variants[0]
    }

    nonisolated static func makeLists(_ input: Input) -> Lists {
        let mem = input.totalMemoryGB
        let filterState = input.filterState
        let searchText = input.searchText
        let downloadStates = input.downloadStates

        func isActive(_ m: MLXModel) -> Bool {
            switch downloadStates[m.id] ?? .notStarted {
            case .downloading, .paused: return true
            default: return false
            }
        }
        // On disk or downloading/paused: keeps imported/non-curated models
        // in the catalog.
        func isUserModel(_ m: MLXModel) -> Bool {
            m.isDownloaded || isActive(m)
        }
        // Newest first by release date (nil dates last), name as the stable
        // tiebreak.
        func newestFirst(_ lhs: MLXModel, _ rhs: MLXModel) -> Bool {
            switch (lhs.releasedAt, rhs.releasedAt) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        func byName(_ models: [MLXModel]) -> [MLXModel] {
            models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        func curatedFirst(_ models: [MLXModel]) -> [MLXModel] {
            let curatedIds = ModelManager.curatedSuggestedIds
            return models.sorted { lhs, rhs in
                let lhsCurated = curatedIds.contains(lhs.id.lowercased())
                let rhsCurated = curatedIds.contains(rhs.id.lowercased())
                if lhsCurated != rhsCurated { return lhsCurated }
                if lhsCurated && lhs.isTopSuggestion != rhs.isTopSuggestion {
                    return lhs.isTopSuggestion
                }
                return newestFirst(lhs, rhs)
            }
        }

        // Installed inventory: the same set the header counts and the
        // sidebar badge shows, plus downloads in flight.
        let all = input.deduplicatedModels
        var seen: Set<String> = []
        var owned: [MLXModel] = []
        for m in all.filter(isActive) + ModelManager.installedModels(among: all)
        where seen.insert(m.id.lowercased()).inserted {
            owned.append(m)
        }
        let ownedFamilies = Set(owned.map { ModelMetadataParser.familyKey(from: $0.id) })
        let ownedFiltered = filterState.apply(
            to: SearchService.filterModels(owned, with: searchText),
            totalMemoryGB: mem
        )
        let downloaded = byName(ownedFiltered.filter(isActive)) + byName(ownedFiltered.filter { !isActive($0) })

        // Catalog = OsaurusAI models + models the user owns or is downloading
        // + (when searching) anything matching the query, so imported or
        // pasted repos inserted into `availableModels` still appear.
        //
        // AppleScript bundles only ever emit AppleScript, so they never
        // surface in the language catalog (same rule as the chat model
        // picker); they live under the AppleScript kind. Embedding bundles
        // found on disk can't chat and aren't in the installed inventory.
        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // A catalog row for an installed id must be the installed entry: a
        // curated suggestion listed first would otherwise probe the managed
        // models directory and offer Download for a bundle already on disk.
        // Swap in the inventory representative only when it carries
        // installation evidence.
        var inventoryByLowerId: [String: MLXModel] = [:]
        for model in input.deduplicatedModels where model.hasLocalInstallationEvidence {
            inventoryByLowerId[model.id.lowercased()] = model
        }
        func installedRepresentative(_ model: MLXModel) -> MLXModel {
            inventoryByLowerId[model.id.lowercased()] ?? model
        }

        let catalogBase = input.availableModels.filter { model in
            guard !AppleScriptModelCatalog.isAppleScriptModel(id: model.id) else { return false }
            if model.isDownloaded, model.isEmbedding { return false }
            return isOsaurusAI(model) || isUserModel(model) || hasQuery
        }.map(installedRepresentative)
        let osaurusSuggested = input.suggestedModels.filter {
            isOsaurusAI($0) && !AppleScriptModelCatalog.isAppleScriptModel(id: $0.id)
        }.map(installedRepresentative)

        let catalogFiltered = filterState.apply(
            to: SearchService.filterModels(catalogBase, with: searchText),
            totalMemoryGB: mem
        ).sorted(by: newestFirst)
        let recommended = curatedFirst(
            filterState.apply(
                to: SearchService.filterModels(osaurusSuggested, with: searchText),
                totalMemoryGB: mem
            )
        )

        let topPicks = groupIntoFamilies(
            recommended.filter(\.isTopSuggestion).sorted(by: newestFirst),
            totalMemoryGB: mem,
            downloadStates: downloadStates
        )
        // Exclude by family, not id, so precision siblings of a Top Pick
        // don't reappear as separate rows.
        let topPickFamilies = Set(topPicks.map { ModelMetadataParser.familyKey(from: $0.id) })

        var seenCatalog: Set<String> = []
        var catalogRest: [MLXModel] = []
        for model in recommended + catalogFiltered {
            if topPickFamilies.contains(ModelMetadataParser.familyKey(from: model.id)) { continue }
            if seenCatalog.insert(model.id.lowercased()).inserted {
                catalogRest.append(model)
            }
        }
        let others = groupIntoFamilies(
            catalogRest.sorted(by: newestFirst),
            totalMemoryGB: mem,
            downloadStates: downloadStates
        )

        var variantsByFamily: [String: [MLXModel]] = [:]
        var seenVariantIds: Set<String> = []
        for model in input.suggestedModels + input.availableModels {
            guard seenVariantIds.insert(model.id.lowercased()).inserted else { continue }
            variantsByFamily[ModelMetadataParser.familyKey(from: model.id), default: []].append(model)
        }

        // Warm disk-backed verdicts while still off the main actor: rows read
        // `isVLM`, `isMLXFormat` and `isDownloaded` on the main thread, and a
        // cold cache would fault config / safetensors-header reads per row
        // there (the app-hang path).
        for model in topPicks + others + downloaded {
            _ = model.isVLM
            _ = model.isMLXFormat
            _ = model.isDownloaded
        }

        return Lists(
            suggested: topPicks,
            others: others,
            downloaded: downloaded,
            ownedFamilies: ownedFamilies,
            variantsByFamily: variantsByFamily
        )
    }

    nonisolated static func isOsaurusAI(_ model: MLXModel) -> Bool {
        model.id.lowercased().hasPrefix("osaurusai/")
    }
}

// MARK: - Source

@MainActor
final class LanguageCatalogSource: LocalModelCatalogSource {
    private let modelManager = ModelManager.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var remoteSearchTask: Task<Void, Never>?
    private var didActivate = false
    private var query = ""

    @Published var filterState = ModelManager.ModelFilterState() {
        didSet { if filterState != oldValue { refreshNow() } }
    }
    @Published private(set) var lists = LanguageModelCatalog.Lists.empty

    init() {
        super.init(kind: .language)
    }

    override var columns: [LocalModelColumn] { LocalModelColumn.allCases }
    override var supportsFilters: Bool { true }
    override var searchesItself: Bool { true }

    override var headerSummary: String? {
        let count = modelManager.totalDownloadedModelCount
        guard count > 0 else { return nil }
        return L("\(count) on this Mac • \(modelManager.totalDownloadedSizeString)")
    }

    override var supportsImport: Bool { true }

    override var refreshHelp: String? { "Refresh OsaurusAI models from Hugging Face" }

    /// An image repo pasted into the search (image bundles live under Image).
    @Published private(set) var imageSearchRepoId: String?

    override func banner(scope: LocalModelCatalogScope) -> AnyView? {
        if let repoId = imageSearchRepoId {
            return AnyView(
                SettingsCallout(
                    icon: "photo.on.rectangle.angled",
                    title: "This is an image model",
                    message: "Image generation and editing models are under Image."
                ) {
                    SettingsButton(.secondary, "Show Image Models", size: .compact) {
                        ImageModelDownloadService.shared.offer(repoId: repoId)
                        ManagementStateManager.shared.openLocalModels(kind: .image)
                    }
                }
            )
        }
        guard scope != .onThisMac else { return nil }
        return AnyView(HuggingFaceTokenBanner())
    }
    override var isRefreshing: Bool { modelManager.isLoadingSuggested }
    override func refresh() {
        Task { await modelManager.refreshSuggestedModels() }
    }

    /// Model families available for the filter popover.
    var families: [String] {
        Array(Set(modelManager.availableModels.map(\.family))).sorted()
    }

    func variants(for model: MLXModel) -> [MLXModel] {
        lists.variantsByFamily[ModelMetadataParser.familyKey(from: model.id)] ?? []
    }

    override func activate() {
        guard !didActivate else {
            refreshNow()
            return
        }
        didActivate = true
        isLoading = true
        modelManager.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &subscriptions)
        refreshNow()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.modelManager.fetchRemoteMLXModels(searchText: self.query)
        }
        Task { await modelManager.refreshAutomaticModelUpdates() }
    }

    override func setQuery(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        refreshNow()
        remoteSearchTask?.cancel()
        remoteSearchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.modelManager.fetchRemoteMLXModels(searchText: query)
        }
    }

    /// Ensures a linked repo is in the catalog and searched for, so its row
    /// can be selected once the lists refresh.
    func reveal(repoId: String) {
        _ = modelManager.resolveModel(byRepoId: repoId)
        modelManager.fetchRemoteMLXModels(searchText: query)
        refreshNow()
    }

    private func makeInput() -> LanguageModelCatalog.Input {
        LanguageModelCatalog.Input(
            availableModels: modelManager.availableModels,
            suggestedModels: modelManager.suggestedModels,
            deduplicatedModels: modelManager.deduplicatedModels(),
            downloadStates: modelManager.downloadStates,
            searchText: query,
            filterState: filterState,
            totalMemoryGB: SystemMonitorService.shared.totalMemoryGB
        )
    }

    /// Recompute now, superseding any pending pass. Used for user-driven
    /// changes (search, filters) that should feel immediate.
    private func refreshNow() {
        refreshTask?.cancel()
        refreshTask = nil
        startRefresh(after: nil)
    }

    /// Coalesces bursts of manager publishes (download progress) into at
    /// most one pass in flight.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        startRefresh(after: .milliseconds(50))
    }

    private func startRefresh(after delay: Duration?) {
        refreshTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard let self, !Task.isCancelled else { return }
            let input = self.makeInput()
            let lists = await Task.detached(priority: .userInitiated) {
                LanguageModelCatalog.makeLists(input)
            }.value
            guard !Task.isCancelled else { return }
            self.apply(lists)
            self.refreshTask = nil
        }
    }

    private func apply(_ lists: LanguageModelCatalog.Lists) {
        self.lists = lists
        let mem = SystemMonitorService.shared.totalMemoryGB
        var rows = lists.downloaded.map { item(for: $0, variants: variants(for: $0), isFamilyRow: false, mem: mem) }
        for model in lists.catalog
        where !lists.ownedFamilies.contains(ModelMetadataParser.familyKey(from: model.id)) {
            rows.append(item(for: model, variants: lists.variantsByFamily[
                ModelMetadataParser.familyKey(from: model.id)] ?? [], isFamilyRow: true, mem: mem))
        }
        items = rows
        isLoading = modelManager.isLoadingModels && rows.isEmpty
        if imageSearchRepoId != modelManager.imageSearchRepoId {
            imageSearchRepoId = modelManager.imageSearchRepoId
        }
    }

    private func item(
        for model: MLXModel,
        variants: [MLXModel],
        isFamilyRow: Bool,
        mem: Double
    ) -> LocalModelCatalogItem {
        let isFamily = isFamilyRow && variants.count > 1
        let state = modelManager.effectiveDownloadState(for: model)
        let check = modelManager.manifestChecks[model.id.lowercased()]
        let isUnsupported = model.isDownloaded && !model.isMLXFormat

        var subtitle: [String] = []
        if model.isDecision {
            subtitle.append(L("Decision"))
        } else {
            if let useCase = model.useCase, useCase != .smallest { subtitle.append(useCase.displayName) }
            if model.isVLM, model.useCase != .vision { subtitle.append(L("Vision")) }
            if let params = model.parameterCount { subtitle.append(params) }
        }
        if isFamily {
            subtitle.append(L("\(variants.count) versions"))
        } else if let quant = model.quantization {
            subtitle.append(quant)
        }

        var badges: [LocalModelCatalogItem.Badge] = []
        if isUnsupported {
            badges.append(.init(
                text: L("Not MLX"), tone: .warning,
                help: L("Not an MLX model — the local engine can't load this bundle")))
        }
        if state == .completed {
            if check?.updateAvailable == true {
                badges.append(.init(text: L("Update available"), tone: .info))
            } else if check?.verificationRequired == true {
                badges.append(.init(text: L("Verification needed"), tone: .warning))
            }
        }

        let status: LocalModelCatalogItem.Status
        switch state {
        case .notStarted: status = .available
        case .downloading(let progress):
            status = .inProgress(
                progress: progress, detail: modelManager.downloadMetrics[model.id]?.formattedLine, isPaused: false)
        case .paused(let progress):
            status = .inProgress(progress: progress, detail: nil, isPaused: true)
        case .completed: status = .installed
        case .failed(let error): status = .failed(error)
        }

        var item = LocalModelCatalogItem(
            id: model.id,
            name: isFamily ? ModelMetadataParser.familyDisplayName(from: model.id) : model.name,
            subtitle: subtitle.joined(separator: " · "),
            description: model.description,
            icon: model.isVLM ? "eye" : "text.bubble",
            badges: badges,
            isTopPick: model.isTopSuggestion,
            fit: model.compatibility(totalMemoryGB: mem),
            memoryText: model.formattedEstimatedMemory,
            memoryGB: model.estimatedMemoryGB,
            sizeText: model.formattedDownloadSize,
            sizeBytes: model.totalSizeEstimateBytes ?? model.downloadSizeBytes,
            releasedText: model.formattedReleaseMonth,
            releasedAt: model.releasedAt,
            status: status,
            huggingFaceRepo: model.id,
            model: model,
            variants: variants,
            isUnsupported: isUnsupported
        )

        let manager = modelManager
        let id = model.id
        switch status {
        case .available, .failed:
            if !isUnsupported {
                item.primaryAction = .init(
                    title: status == .available ? "Download" : "Retry",
                    icon: "arrow.down.circle",
                    role: .primary
                ) { manager.downloadModel(model) }
            }
        case .inProgress(_, _, let isPaused):
            if isPaused {
                item.onResume = { manager.resumeDownload(id) }
            } else {
                item.onPause = { manager.pauseDownload(id) }
            }
            item.onCancel = { manager.cancelDownload(id) }
        case .installed:
            let isExternal = model.externalSource != nil || model.bundleDirectory != nil
            if check?.updateAvailable == true, !isExternal {
                item.menuActions.append(.init(title: "Update Model", icon: "arrow.triangle.2.circlepath") {
                    manager.downloadService.repair(model)
                })
            }
            if isExternal {
                item.menuActions.append(.init(title: "Reveal in Finder", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.localDirectory])
                })
            } else {
                item.menuActions.append(.init(
                    title: "Delete Model", icon: "trash", role: .destructive,
                    confirmation: L("This removes \(model.name) from this Mac. You can download it again later.")
                ) {
                    Task { await manager.deleteModel(model) }
                })
            }
        }
        return item
    }
}

// MARK: - Filter popover

/// Model type, size, parameters, performance and family filters for the
/// language catalog.
struct LanguageModelFilterPopover: View {
    @ObservedObject var source: LanguageCatalogSource
    @Environment(\.theme) private var theme

    private static let width: CGFloat = 300
    private static let maxHeight: CGFloat = 480

    private var filter: Binding<ModelManager.ModelFilterState> {
        Binding(get: { source.filterState }, set: { source.filterState = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                HStack {
                    Text("Filters", bundle: .module)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.tertiary)
                    Spacer()
                    if source.filterState.isActive {
                        SettingsButton(.tertiary, "Reset", icon: "arrow.counterclockwise", size: .compact) {
                            source.filterState.reset()
                        }
                    }
                }

                section("Model Type") {
                    HStack(spacing: theme.settingsControlGap) {
                        FilterChip("LLM", isSelected: filter.wrappedValue.typeFilter.isLLM) {
                            filter.wrappedValue.typeFilter = filter.wrappedValue.typeFilter.isLLM ? .all : .llm
                        }
                        FilterChip("VLM", isSelected: filter.wrappedValue.typeFilter.isVLM) {
                            filter.wrappedValue.typeFilter = filter.wrappedValue.typeFilter.isVLM ? .all : .vlm
                        }
                    }
                }

                section("Model Size") {
                    FlowLayout(spacing: theme.settingsControlGap) {
                        ForEach(ModelManager.ModelFilterState.SizeCategory.allCases) { cat in
                            FilterChip(cat.displayName, isSelected: filter.wrappedValue.sizeCategory == cat) {
                                filter.wrappedValue.sizeCategory = filter.wrappedValue.sizeCategory == cat ? nil : cat
                            }
                        }
                    }
                }

                section("Parameters") {
                    HStack(spacing: theme.settingsControlGap) {
                        ForEach(ModelManager.ModelFilterState.ParamCategory.allCases) { cat in
                            FilterChip(cat.rawValue, isSelected: filter.wrappedValue.paramCategory == cat) {
                                filter.wrappedValue.paramCategory = filter.wrappedValue.paramCategory == cat ? nil : cat
                            }
                        }
                    }
                }

                section("Performance") {
                    FlowLayout(spacing: theme.settingsControlGap) {
                        ForEach(ModelManager.ModelFilterState.PerformanceFilter.allCases) { option in
                            FilterChip(option.displayName, isSelected: filter.wrappedValue.performance == option) {
                                filter.wrappedValue.performance =
                                    filter.wrappedValue.performance == option ? nil : option
                            }
                        }
                    }
                }

                section("Model Family") {
                    let families = source.families
                    if families.isEmpty {
                        Text("No families found", bundle: .module)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                    } else {
                        FlowLayout(spacing: theme.settingsControlGap) {
                            ForEach(families, id: \.self) { family in
                                FilterChip(family, isSelected: filter.wrappedValue.family == family) {
                                    filter.wrappedValue.family = filter.wrappedValue.family == family ? nil : family
                                }
                            }
                        }
                    }
                }
            }
            .padding(theme.space.s16)
        }
        .frame(width: Self.width)
        .frame(maxHeight: Self.maxHeight)
        .background(theme.surface.canvas)
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(title, bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)
            content()
        }
    }

    /// Short label for the filter chip; nil when no filter is set.
    static func summary(_ state: ModelManager.ModelFilterState) -> String? {
        var parts: [String] = []
        switch state.typeFilter {
        case .all: break
        case .llm: parts.append("LLM")
        case .vlm: parts.append("VLM")
        }
        if let size = state.sizeCategory { parts.append(size.displayName) }
        if let param = state.paramCategory { parts.append(param.rawValue) }
        if let performance = state.performance { parts.append(performance.displayName) }
        if let family = state.family { parts.append(family) }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return L("\(parts.count) active")
        }
    }
}
