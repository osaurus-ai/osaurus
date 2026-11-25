//
//  ComputerUseCatalogSource.swift
//  osaurus
//
//  The recommended on-device Computer Use models. They are ordinary MLX
//  bundles, so they download through `ModelManager` and open the same detail
//  panel as language models. Which one runs is chosen in Model Defaults →
//  Computer Use Model, or per agent.
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class ComputerUseCatalogSource: LocalModelCatalogSource {
    private let downloads = ModelDownloadService.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var didActivate = false
    private var installed: [MLXModel] = []

    init() {
        super.init(kind: .computerUse)
    }

    override var columns: [LocalModelColumn] { LocalModelColumn.allCases }

    override var footnote: String? {
        "Any installed chat model can run Computer Use. Choose one in Models → Model Defaults → Computer Use Model."
    }

    override func activate() {
        guard !didActivate else { return }
        didActivate = true
        downloads.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.downloadsChanged() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .localModelsChanged)
            .merge(with: NotificationCenter.default.publisher(for: .subagentConfigurationChanged))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scanInstalled() }
            .store(in: &subscriptions)
        observeNearby { [weak self] in self?.rebuild() }
        scanInstalled()
    }

    private func scanInstalled() {
        installed = ComputerUseModelCatalog.installedModels()
        rebuild()
    }

    /// A finished download lands on disk before `.localModelsChanged`
    /// arrives; rescan then so the row flips to installed right away.
    private func downloadsChanged() {
        let installedIds = Set(installed.map(\.id))
        let finished = ComputerUseModelCatalog.models.contains {
            downloads.downloadStates[$0.id] == .completed && !installedIds.contains($0.id)
        }
        if finished { scanInstalled() } else { rebuild() }
    }

    private func rebuild() {
        let installedIds = Set(installed.map(\.id))
        let defaultId = SubagentConfigurationStore.snapshot()
            .subagentModelOverrides[SubagentCapabilityRegistry.computerUse.id]
        let mem = SystemMonitorService.shared.totalMemoryGB
        let rows = ComputerUseModelCatalog.models.map { model in
            item(
                for: installed.first { $0.id == model.id } ?? model,
                isInstalled: installedIds.contains(model.id),
                defaultId: defaultId,
                mem: mem
            )
        }
        let manager = ModelManager.shared
        let downloadService = downloads
        items = mergingNearby(
            rows,
            localIds: { [$0.id] },
            addsUnlisted: false,
            download: { offer, row in
                guard let model = row?.model else { return }
                manager.downloadModel(model, fromNearbyHost: offer.source)
            },
            decorate: { row, offer in
                let id = offer.model.repoId ?? offer.localId
                guard let status = LocalModelCatalogItem.Status.nearbyProgress(downloadService.downloadStates[id])
                else { return }
                row.status = status
                if status.isActive {
                    row.primaryAction = nil
                    row.onCancel = { manager.cancelDownload(id) }
                }
            }
        )
    }

    private func item(
        for model: MLXModel,
        isInstalled: Bool,
        defaultId: String?,
        mem: Double
    ) -> LocalModelCatalogItem {
        let status: LocalModelCatalogItem.Status
        switch downloads.downloadStates[model.id] ?? .notStarted {
        case .downloading(let progress):
            status = .inProgress(progress: progress, detail: downloads.downloadMetrics[model.id]?.formattedLine, isPaused: false)
        case .paused(let progress):
            status = .inProgress(progress: progress, detail: nil, isPaused: true)
        case .failed(let error):
            status = isInstalled ? .installed : .failed(error)
        case .completed, .notStarted:
            status = isInstalled ? .installed : .available
        }

        var subtitle: [String] = [L("Computer Use")]
        if let params = model.parameterCount { subtitle.append(params) }
        if let quant = model.quantization { subtitle.append(quant) }

        var item = LocalModelCatalogItem(
            id: model.id,
            name: model.name,
            subtitle: subtitle.joined(separator: " · "),
            description: model.description,
            icon: "cursorarrow.rays",
            isTopPick: model.isTopSuggestion,
            isDefault: defaultId?.caseInsensitiveCompare(model.id) == .orderedSame,
            fit: model.compatibility(totalMemoryGB: mem),
            memoryText: model.formattedEstimatedMemory,
            memoryGB: model.estimatedMemoryGB,
            sizeText: model.formattedDownloadSize,
            sizeBytes: model.totalSizeEstimateBytes ?? model.downloadSizeBytes,
            releasedText: model.formattedReleaseMonth,
            releasedAt: model.releasedAt,
            status: status,
            huggingFaceRepo: model.id,
            searchHaystack: LocalModelCatalogFormat.haystack([model.name, model.id, model.description]),
            model: model
        )

        let manager = ModelManager.shared
        switch status {
        case .available, .failed:
            item.primaryAction = .init(
                title: status == .available ? "Download" : "Retry",
                icon: "arrow.down.circle",
                role: .primary
            ) { manager.downloadModel(model) }
        case .inProgress(_, _, let isPaused):
            if isPaused {
                item.onResume = { manager.resumeDownload(model.id) }
            } else {
                item.onPause = { manager.pauseDownload(model.id) }
            }
            item.onCancel = { manager.cancelDownload(model.id) }
        case .installed:
            if model.isExternallyOwned {
                item.menuActions.append(.init(title: "Reveal in Finder", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.localDirectory])
                })
            } else {
                item.menuActions.append(.init(
                    title: "Delete Model", icon: "trash", role: .destructive,
                    confirmation: L("This removes \(model.name) from this Mac. You can download it again later.")
                ) { Task { await manager.deleteModel(model) } })
            }
        }
        return item
    }
}
