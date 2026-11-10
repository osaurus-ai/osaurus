//
//  SpeechCatalogSource.swift
//  osaurus
//
//  Speech-to-text models (Parakeet) for voice input and transcription.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class SpeechCatalogSource: LocalModelCatalogSource {
    private let manager = SpeechModelManager.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var didActivate = false

    init() {
        super.init(kind: .speech)
    }

    override func activate() {
        guard !didActivate else { return }
        didActivate = true
        manager.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &subscriptions)
        rebuild()
    }

    override func banner(scope: LocalModelCatalogScope) -> AnyView? {
        AnyView(LegacyWhisperBanner())
    }

    private func rebuild() {
        let ordered = manager.availableModels.filter(\.isRecommended)
            + manager.availableModels.filter { !$0.isRecommended }
        items = ordered.map(item(for:))
    }

    private func item(for model: SpeechModel) -> LocalModelCatalogItem {
        let manager = manager
        let state = manager.effectiveDownloadState(for: model)
        let isDefault = manager.selectedModelId == model.id
        let status: LocalModelCatalogItem.Status
        switch state {
        case .notStarted: status = .available
        case .downloading(let progress): status = .inProgress(progress: progress, detail: nil, isPaused: false)
        case .completed: status = .installed
        case .failed(let error): status = .failed(error)
        }

        var item = LocalModelCatalogItem(
            id: model.id,
            name: model.name,
            subtitle: model.isEnglishOnly ? L("English only") : L("Multilingual"),
            description: model.description,
            icon: "waveform",
            isTopPick: model.isRecommended,
            isDefault: isDefault && status == .installed,
            sizeText: model.size,
            sizeBytes: Self.approximateBytes(model.size),
            status: status,
            facts: [
                .init(label: "Languages", value: model.isEnglishOnly ? L("English") : L("25 European languages")),
                .init(label: "Size", value: model.size),
                .init(label: "Engine", value: "FluidAudio Parakeet (Core ML)"),
            ],
            searchHaystack: LocalModelCatalogFormat.haystack([model.name, model.description, model.id])
        )

        switch status {
        case .available, .failed:
            item.primaryAction = .init(
                title: status == .available ? "Download" : "Retry",
                icon: "arrow.down.circle",
                role: .primary
            ) { manager.downloadModel(model) }
        case .inProgress:
            item.onCancel = { manager.cancelDownload(model.id) }
        case .installed:
            if !isDefault {
                item.primaryAction = .init(title: "Set as Default", icon: "checkmark.circle") {
                    manager.setDefaultModel(model.id)
                }
            }
            item.menuActions.append(.init(
                title: "Delete", icon: "trash", role: .destructive,
                confirmation: L("This removes \(model.name) from this Mac. You can download it again later.")
            ) { manager.deleteModel(model) })
        }
        return item
    }

    /// "~600 MB" → bytes, so Size sorts with the other kinds.
    static func approximateBytes(_ text: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: "~", with: "").trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        let multiplier: Double
        switch parts[1].uppercased() {
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        default: return nil
        }
        return Int64(value * multiplier)
    }
}

/// Legacy WhisperKit models left on disk after the move to Parakeet.
private struct LegacyWhisperBanner: View {
    @ObservedObject private var manager = SpeechModelManager.shared

    var body: some View {
        if manager.legacyWhisperModelsExist {
            SettingsCallout(
                icon: "exclamationmark.triangle.fill",
                title: "Legacy WhisperKit models found",
                message: L(
                    "These models are no longer used. Delete to free up \(manager.legacyWhisperModelsSizeString ?? "disk space")."
                ),
                tone: .warning
            ) {
                SettingsButton(.destructive, "Delete", size: .compact) {
                    manager.deleteLegacyWhisperModels()
                }
            }
        }
    }
}
