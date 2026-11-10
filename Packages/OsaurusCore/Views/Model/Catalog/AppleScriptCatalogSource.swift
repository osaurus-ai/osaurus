//
//  AppleScriptCatalogSource.swift
//  osaurus
//
//  The dedicated on-device models that power the `applescript` subagent.
//  They are ordinary MLX bundles, so they download through `ModelManager`
//  and open the same detail panel as language models. Which one runs is
//  chosen in Model Defaults → AppleScript.
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppleScriptCatalogSource: LocalModelCatalogSource {
    private let downloads = ModelDownloadService.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var didActivate = false
    /// Curated plus locally discovered AppleScript bundles on disk.
    private var installed: [MLXModel] = []

    init() {
        super.init(kind: .appleScript)
    }

    override var columns: [LocalModelColumn] { LocalModelColumn.allCases }

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
        scanInstalled()
    }

    private func scanInstalled() {
        installed = AppleScriptModelCatalog.installedModels()
        rebuild()
    }

    /// A finished download lands on disk before `.localModelsChanged`
    /// arrives; rescan then so the row flips to installed right away.
    private func downloadsChanged() {
        let installedIds = Set(installed.map(\.id))
        let finished = AppleScriptModelCatalog.models.contains {
            downloads.downloadStates[$0.id] == .completed && !installedIds.contains($0.id)
        }
        if finished { scanInstalled() } else { rebuild() }
    }

    private func rebuild() {
        let installedIds = Set(installed.map(\.id))
        let catalogIds = Set(AppleScriptModelCatalog.models.map(\.id))
        let defaultId = SubagentConfigurationStore.snapshot().defaultAppleScriptModelId
        let mem = SystemMonitorService.shared.totalMemoryGB
        let catalogRows = AppleScriptModelCatalog.models.map { model in
            item(
                for: installed.first { $0.id == model.id } ?? model,
                isInstalled: installedIds.contains(model.id),
                isCurated: true,
                defaultId: defaultId,
                mem: mem
            )
        }
        let discoveredRows = installed.filter { !catalogIds.contains($0.id) }.map {
            item(for: $0, isInstalled: true, isCurated: false, defaultId: defaultId, mem: mem)
        }
        items = catalogRows + discoveredRows
    }

    private func item(
        for model: MLXModel,
        isInstalled: Bool,
        isCurated: Bool,
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

        var subtitle: [String] = [L("AppleScript")]
        if let params = model.parameterCount { subtitle.append(params) }
        if let quant = model.quantization { subtitle.append(quant) }

        var item = LocalModelCatalogItem(
            id: model.id,
            name: model.name,
            subtitle: subtitle.joined(separator: " · "),
            description: model.description,
            icon: "applescript",
            isTopPick: model.isTopSuggestion,
            isDefault: defaultId == model.id,
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
            if isCurated {
                item.menuActions.append(.init(
                    title: "Delete Model", icon: "trash", role: .destructive,
                    confirmation: L("This removes \(model.name) from this Mac. You can download it again later.")
                ) { Task { await manager.deleteModel(model) } })
            } else {
                // A discovered bundle belongs to another source folder, so
                // it is revealed rather than deleted from here.
                item.menuActions.append(.init(title: "Reveal in Finder", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.localDirectory])
                })
            }
        }
        return item
    }
}
