//
//  EmbeddingCatalogSource.swift
//  osaurus
//
//  Embedding models for memory, knowledge and capability search: the
//  built-in Potion model, curated popular embedders, OsaurusAI embedding
//  repos from the Hub, and embedding bundles already on this Mac. Which one
//  runs is chosen in Model Defaults → Embedding Model and applies on the
//  next launch.
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class EmbeddingCatalogSource: LocalModelCatalogSource {
    private let downloads = ModelDownloadService.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var didActivate = false
    private var discovered: [MLXModel] = []
    private var osaurusAI: [MLXModel] = []
    private var fetchTask: Task<Void, Never>?

    init() {
        super.init(kind: .embedding)
    }

    override var columns: [LocalModelColumn] { [.model, .size, .status] }

    override var landingAnchorId: String? { "models.embedding" }

    override var refreshHelp: String? { "Check Hugging Face for new OsaurusAI embedding models" }
    override var isRefreshing: Bool { fetchTask != nil }
    override func refresh() { fetchOsaurusAI() }

    override var footnote: String? {
        "A new embedding model takes effect after Osaurus restarts. Search indexes are rebuilt with it in the background."
    }

    override func banner(scope: LocalModelCatalogScope) -> AnyView? {
        AnyView(EmbeddingRestartBanner())
    }

    override func activate() {
        guard !didActivate else { return }
        didActivate = true
        downloads.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .localModelsChanged)
            .merge(with: NotificationCenter.default.publisher(for: .embeddingSettingsChanged))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scanInstalled() }
            .store(in: &subscriptions)
        scanInstalled()
        fetchOsaurusAI()
    }

    private func scanInstalled() {
        discovered = EmbeddingModelCatalog.discoveredModels()
        rebuild()
    }

    private func fetchOsaurusAI() {
        guard fetchTask == nil else { return }
        isLoading = items.isEmpty
        fetchTask = Task { [weak self] in
            let fetched = await EmbeddingModelCatalog.fetchOsaurusAIModels()
            guard let self else { return }
            self.osaurusAI = fetched
            self.fetchTask = nil
            self.isLoading = false
            self.rebuild()
        }
    }

    private func rebuild() {
        let selectedId = EmbeddingSettingsStore.snapshot().effectiveModelId
        let curated = EmbeddingModelCatalog.curated.map { entry in
            item(
                id: entry.id,
                model: entry.mlxModel,
                entry: entry,
                directory: entry.isBuiltIn ? nil : EmbeddingModelCatalog.installedDirectory(for: entry),
                isManaged: true,
                selectedId: selectedId
            )
        }
        let discoveredIds = Set(discovered.map { $0.id.lowercased() })
        let published = osaurusAI.filter { !discoveredIds.contains($0.id.lowercased()) }.map { model in
            item(
                id: model.id,
                model: model,
                entry: nil,
                directory: model.isDownloaded ? model.localDirectory : nil,
                isManaged: true,
                selectedId: selectedId
            )
        }
        let local = discovered.map { model in
            item(
                id: model.id,
                model: model,
                entry: nil,
                directory: model.localDirectory,
                isManaged: model.bundleDirectory == nil && model.externalSource == nil,
                selectedId: selectedId
            )
        }
        items = curated + published + local
    }

    private func item(
        id: String,
        model: MLXModel,
        entry: EmbeddingModelCatalog.Entry?,
        directory: URL?,
        isManaged: Bool,
        selectedId: String
    ) -> LocalModelCatalogItem {
        let isBuiltIn = entry?.isBuiltIn == true
        let isInstalled = isBuiltIn || directory != nil
        let status: LocalModelCatalogItem.Status
        switch downloads.downloadStates[id] ?? .notStarted {
        case .downloading(let progress):
            status = .inProgress(progress: progress, detail: downloads.downloadMetrics[id]?.formattedLine, isPaused: false)
        case .paused(let progress):
            status = .inProgress(progress: progress, detail: nil, isPaused: true)
        case .failed(let error):
            status = isInstalled ? .installed : .failed(error)
        case .completed, .notStarted:
            status = isInstalled ? .installed : .available
        }

        let support: EmbeddingDetection.RuntimeSupport? =
            isBuiltIn ? .model2vec : directory.map(EmbeddingDetection.runtimeSupport(at:))
        let isSelected = selectedId.caseInsensitiveCompare(id) == .orderedSame
        let isRunning = EmbeddingService.modelId.caseInsensitiveCompare(id) == .orderedSame

        var subtitle: [String] = []
        if let entry {
            subtitle.append(entry.family)
            subtitle.append(L("\(entry.dimension) dimensions"))
            subtitle.append(entry.languages == "English" ? L("English") : L("Multilingual"))
        } else {
            subtitle.append(id)
            if let source = model.externalSource { subtitle.append(source) }
        }

        var badges: [LocalModelCatalogItem.Badge] = []
        if isBuiltIn { badges.append(.init(text: L("Built-in"))) }
        if isRunning, EmbeddingService.vectorIndexesAvailable {
            badges.append(.init(text: L("In Use"), tone: .success))
        }
        if case .unsupported(let reason) = support {
            badges.append(.init(text: L("Not Supported"), tone: .warning, help: reason))
        }

        var facts: [LocalModelCatalogItem.Fact] = []
        if let entry {
            facts.append(.init(label: "Dimensions", value: "\(entry.dimension)"))
            facts.append(.init(label: "Family", value: entry.family))
            facts.append(.init(label: "Languages", value: entry.languages == "English" ? L("English") : L("Multilingual")))
        }
        facts.append(.init(label: "Engine", value: Self.engineName(support: support, family: entry?.family)))
        if let directory {
            facts.append(.init(label: "Location", value: directory.path))
        }

        let sizeBytes = entry?.downloadSizeBytes ?? model.totalSizeEstimateBytes
        var item = LocalModelCatalogItem(
            id: id,
            name: entry?.name ?? model.name,
            subtitle: subtitle.joined(separator: " · "),
            description: entry?.summary ?? model.description,
            icon: "text.magnifyingglass",
            badges: badges,
            isTopPick: entry?.isTopPick == true,
            isDefault: isSelected && status == .installed,
            sizeText: sizeBytes.map(LocalModelCatalogFormat.bytes),
            sizeBytes: sizeBytes,
            status: status,
            huggingFaceRepo: id,
            facts: facts,
            searchHaystack: LocalModelCatalogFormat.haystack([
                entry?.name ?? model.name, id, entry?.summary ?? model.description, entry?.family, entry?.languages,
            ]),
            isUnsupported: support.map { !$0.isSupported } ?? false
        )

        let downloadService = downloads
        switch status {
        case .available, .failed:
            item.primaryAction = .init(
                title: status == .available ? "Download" : "Retry",
                icon: "arrow.down.circle",
                role: .primary
            ) { downloadService.download(model) }
        case .inProgress(_, _, let isPaused):
            if isPaused {
                item.onResume = { downloadService.resume(model) }
            } else {
                item.onPause = { downloadService.pause(id) }
            }
            item.onCancel = { downloadService.cancel(id) }
        case .installed:
            if !isSelected, support?.isSupported == true {
                item.primaryAction = .init(title: "Set as Default", icon: "checkmark.circle") {
                    EmbeddingSettingsStore.save(
                        EmbeddingSettings(selectedModelId: id, selectedModelPath: directory?.path))
                }
            }
            if isBuiltIn {
                break
            } else if isManaged, !isRunning {
                item.menuActions.append(.init(
                    title: "Delete Model", icon: "trash", role: .destructive,
                    confirmation: L("This removes \(item.name) from this Mac. You can download it again later.")
                ) {
                    Task {
                        await downloadService.delete(model)
                        if isSelected { EmbeddingSettingsStore.save(.default) }
                    }
                })
            } else if let directory {
                item.menuActions.append(.init(title: "Reveal in Finder", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                })
            }
        }
        return item
    }

    private static func engineName(support: EmbeddingDetection.RuntimeSupport?, family: String?) -> String {
        switch support {
        case .model2vec: return "Model2Vec (MLX)"
        case .transformer(let type): return "MLX Embedders (\(type))"
        case .unsupported: return L("Not supported")
        case nil: return family == "Model2Vec" ? "Model2Vec (MLX)" : "MLX Embedders"
        }
    }
}

/// Shown when the saved embedding model differs from the one this launch is
/// running, or when the selected model failed to load at launch.
struct EmbeddingRestartBanner: View {
    @State private var settings = EmbeddingSettingsStore.snapshot()

    var body: some View {
        Group {
            if let error = EmbeddingService.launchError,
                settings.effectiveModelId.caseInsensitiveCompare(error.modelId) == .orderedSame
            {
                SettingsCallout(
                    icon: "exclamationmark.triangle.fill",
                    title: "Embedding model unavailable",
                    message: error.localizedDescription,
                    tone: .warning
                ) {
                    SettingsButton(.secondary, "Use Built-In Model", size: .compact) {
                        EmbeddingSettingsStore.save(.default)
                    }
                }
            } else if settings.effectiveModelId.caseInsensitiveCompare(EmbeddingService.launchState.requestedModelId)
                != .orderedSame
            {
                SettingsCallout(
                    icon: "arrow.clockwise.circle.fill",
                    title: "Restart to use the new embedding model",
                    message: restartMessage,
                    tone: .info
                ) {
                    SettingsButton(.primary, "Restart Now", size: .compact) {
                        SpaceActions.relaunch()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .embeddingSettingsChanged)) { _ in
            settings = EmbeddingSettingsStore.snapshot()
        }
    }

    private var restartMessage: String {
        let next = EmbeddingModelCatalog.displayName(for: settings.effectiveModelId)
        if EmbeddingService.vectorIndexesAvailable {
            return L("Osaurus is still using \(EmbeddingService.modelName). Restart to switch to \(next).")
        }
        return L("Semantic search stays off until Osaurus restarts with \(next).")
    }
}
