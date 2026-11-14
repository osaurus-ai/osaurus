//
//  PrivacyDetectionCatalogSource.swift
//  osaurus
//
//  On-device models that find personal data before it leaves the Mac:
//  Rampart and the OpenAI Privacy Filter. Writes only
//  `aiDetectionBackend` (and turns AI detection off when the last model is
//  removed).
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class PrivacyDetectionCatalogSource: LocalModelCatalogSource {
    private let downloader = PrivacyFilterModelDownloader.shared
    private let rampart = RampartModelManager.shared
    private var configuration = PrivacyFilterStore.snapshot()
    private var subscriptions: Set<AnyCancellable> = []
    private var didActivate = false

    /// Rampart first (the lightweight default suggestion), then OpenAI.
    private let backends: [PrivacyAIBackend] = [.rampart, .openai]

    init() {
        super.init(kind: .detection)
    }

    override var landingAnchorId: String? { "privacy.models" }
    override var footnote: String? {
        "Optional. Pattern rules in Privacy & Security → Detection Rules work without any model."
    }

    override func activate() {
        guard !didActivate else { return }
        didActivate = true
        downloader.objectWillChange
            .merge(with: rampart.objectWillChange)
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .privacyFilterConfigurationChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configuration = PrivacyFilterStore.snapshot()
                self?.rebuild()
            }
            .store(in: &subscriptions)
        rebuild()
    }

    private func rebuild() {
        items = backends.map(item(for:))
    }

    private func isInstalled(_ backend: PrivacyAIBackend) -> Bool {
        switch backend {
        case .openai:
            return downloader.state == .ready
        case .rampart:
            if rampart.state == .ready { return true }
            return RampartModelManager.bundleExists()
        }
    }

    /// The backend detection actually runs with: the user's default if
    /// installed, else the only installed one.
    private var activeBackend: PrivacyAIBackend? {
        configuration.resolvedAIBackend(isInstalled: isInstalled)
    }

    private func status(_ backend: PrivacyAIBackend) -> LocalModelCatalogItem.Status {
        switch backend {
        case .openai:
            switch downloader.state {
            case .idle: return .available
            case .enumerating: return .inProgress(progress: nil, detail: L("Preparing…"), isPaused: false)
            case let .downloading(_, _, _, done, total):
                return .inProgress(
                    progress: total > 0 ? Double(done) / Double(total) : nil, detail: nil, isPaused: false)
            case .verifying: return .inProgress(progress: nil, detail: L("Verifying…"), isPaused: false)
            case .ready: return .installed
            case .failed(let message): return .failed(message)
            }
        case .rampart:
            switch rampart.state {
            case .idle: return RampartModelManager.bundleExists() ? .installed : .available
            case .downloading(let progress): return .inProgress(progress: progress, detail: nil, isPaused: false)
            case .ready: return .installed
            case .failed(let message): return .failed(message)
            }
        }
    }

    private func item(for backend: PrivacyAIBackend) -> LocalModelCatalogItem {
        let meta = Self.meta(backend)
        let status = status(backend)
        let isActive = activeBackend == backend

        var item = LocalModelCatalogItem(
            id: backend.rawValue,
            name: meta.name,
            subtitle: meta.detects,
            description: meta.summary,
            icon: "eye.slash",
            isTopPick: backend == .rampart,
            isDefault: isActive && status == .installed,
            sizeText: meta.size,
            sizeBytes: meta.bytes,
            status: status,
            huggingFaceRepo: backend == .openai ? PrivacyFilterModelDownloader.repoId : RampartModelManager.repoId,
            facts: [
                .init(label: "Detects", value: meta.detects),
                .init(label: "Size", value: meta.size),
                .init(
                    label: "Repository",
                    value: backend == .openai ? PrivacyFilterModelDownloader.repoId : RampartModelManager.repoId),
            ],
            searchHaystack: LocalModelCatalogFormat.haystack([meta.name, meta.summary, meta.detects])
        )

        switch status {
        case .available, .failed:
            item.primaryAction = .init(
                title: status == .available ? "Install" : "Retry",
                icon: "arrow.down.circle",
                role: .primary
            ) { [weak self] in self?.startDownload(backend) }
        case .inProgress:
            item.onCancel = { [weak self] in self?.cancel(backend) }
        case .installed:
            if !isActive {
                item.primaryAction = .init(title: "Set as Default", icon: "checkmark.circle") { [weak self] in
                    self?.setDefault(backend)
                }
            }
            if backend == .openai {
                item.menuActions.append(.init(title: "Re-verify", icon: "arrow.clockwise") { [weak self] in
                    self?.downloader.reverify()
                })
            }
            item.menuActions.append(.init(
                title: "Remove Model", icon: "trash", role: .destructive,
                confirmation: L("This deletes the on-disk model. Detection for it stops until you re-download.")
            ) { [weak self] in self?.remove(backend) })
        }
        return item
    }

    private func startDownload(_ backend: PrivacyAIBackend) {
        switch backend {
        case .openai: downloader.startDownload()
        case .rampart: rampart.startDownload()
        }
    }

    private func cancel(_ backend: PrivacyAIBackend) {
        switch backend {
        case .openai: downloader.cancel()
        case .rampart: rampart.cancel()
        }
    }

    private func setDefault(_ backend: PrivacyAIBackend) {
        configuration = PrivacyFilterStore.snapshot()
        configuration.aiDetectionBackend = backend
        PrivacyFilterStore.save(configuration)
        rebuild()
    }

    private func remove(_ backend: PrivacyAIBackend) {
        // Detection falls back to any other installed model; only turn the
        // AI layer off when this was the last one, so an AI-on + no-model
        // config can't fail-close every cloud send.
        configuration = PrivacyFilterStore.snapshot()
        let othersInstalled = backends.contains { $0 != backend && isInstalled($0) }
        if !othersInstalled && configuration.aiDetectionEnabled {
            configuration.aiDetectionEnabled = false
            PrivacyFilterStore.save(configuration)
        }
        switch backend {
        case .openai: downloader.remove()
        case .rampart: rampart.remove()
        }
    }

    private static func meta(
        _ backend: PrivacyAIBackend
    ) -> (name: String, size: String, bytes: Int64, detects: String, summary: String) {
        switch backend {
        case .rampart:
            return (
                "Rampart", "~37 MB", 37_000_000,
                L("Names, addresses, IDs and secrets"),
                L("Tiny and fast. Catches names, addresses, and IDs/secrets. No date detection.")
            )
        case .openai:
            return (
                "OpenAI Privacy Filter", "~2.8 GB", 2_800_000_000,
                L("Names, addresses, dates and free-form secrets"),
                L("Highest coverage. Adds names, addresses, dates, and free-form secrets beyond pattern rules.")
            )
        }
    }
}
