//
//  ImageCatalogSource.swift
//  osaurus
//
//  Image models: installed mflux bundles plus the OsaurusAI image catalog.
//  Installed bundles open the generate / edit / upscale panel.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class ImageCatalogSource: LocalModelCatalogSource {
    private let downloads = ImageModelDownloadService.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var didActivate = false

    /// Installed bundle paired with its source repo, captured once per scan
    /// so building rows does no filesystem reads.
    private struct Installed {
        let info: ImageModelInfo
        let repoId: String?
    }

    private var installed: [Installed] = []
    private var didScanInstalled = false
    /// Download sizes for catalog rows, resolved lazily off the HF tree API.
    private var sizes: [String: Int64] = [:]
    private var sizeTask: Task<Void, Never>?

    init() {
        super.init(kind: .image)
    }

    override var supportsImport: Bool { true }
    override var landingAnchorId: String? { "imageGeneration.upscale" }
    override var refreshHelp: String? { "Refresh image models from Hugging Face" }
    override var isRefreshing: Bool { downloads.isLoadingCatalog }
    override func refresh() {
        Task { await downloads.refreshCatalog() }
    }

    override func activate() {
        guard !didActivate else { return }
        didActivate = true
        isLoading = true
        downloads.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .localModelsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.scanInstalled() } }
            .store(in: &subscriptions)
        Task {
            async let scan: Void = scanInstalled()
            async let catalog: Void = downloads.refreshCatalog()
            _ = await (scan, catalog)
            rebuild()
        }
    }

    private func scanInstalled() async {
        let models = (try? await ImageGenerationService.shared.availableModels()) ?? []
        installed = models.map { Installed(info: $0, repoId: downloads.sourceRepoId(for: $0.id)) }
        didScanInstalled = true
        rebuild()
    }

    private func rebuild() {
        let installedIds = Set(installed.map(\.info.id))
        let available = downloads.fetchedCatalog.filter { !installedIds.contains($0.id) }
        items = installed.map(item(for:)) + available.map(item(for:))
        isLoading = items.isEmpty && (downloads.isLoadingCatalog || !didScanInstalled)
        resolveSizes(for: available)
    }

    private func resolveSizes(for entries: [ImageModelDownload]) {
        let missing = entries.filter { sizes[$0.repoId] == nil }
        guard !missing.isEmpty, sizeTask == nil else { return }
        sizeTask = Task { [weak self] in
            for entry in missing {
                guard let self, !Task.isCancelled else { return }
                if let bytes = await self.downloads.estimateDownloadSize(repoId: entry.repoId), bytes > 0 {
                    self.sizes[entry.repoId] = bytes
                    self.rebuild()
                } else {
                    self.sizes[entry.repoId] = 0
                }
            }
            self?.sizeTask = nil
            self?.rebuild()
        }
    }

    // MARK: Rows

    private func status(_ id: String, installed: Bool) -> LocalModelCatalogItem.Status {
        switch downloads.states[id] ?? .notStarted {
        case .downloading(let progress), .paused(let progress):
            return .inProgress(progress: progress, detail: downloads.metrics[id]?.formattedLine, isPaused: false)
        case .failed(let error):
            return installed ? .installed : .failed(error)
        case .completed, .notStarted:
            return installed ? .installed : .available
        }
    }

    private func item(for model: Installed) -> LocalModelCatalogItem {
        let info = model.info
        let license = ImageModelRequestPolicy.licenseLabel(canonical: info.canonicalName)
        let quant = Self.quantization(bits: info.quantizationBits, id: info.id)
        let size = info.totalBytes > 0 ? Int64(info.totalBytes) : nil

        var item = LocalModelCatalogItem(
            id: info.id,
            name: info.displayName,
            subtitle: [Self.kindLabel(info), quant].compactMap { $0 }.joined(separator: " · "),
            description: info.ready ? "" : info.blockedReasons.joined(separator: "\n"),
            icon: info.capabilities.upscale ? "arrow.up.left.and.arrow.down.right" : "photo",
            sizeText: size.map(LocalModelCatalogFormat.bytes),
            sizeBytes: size,
            status: status(info.id, installed: true),
            huggingFaceRepo: model.repoId,
            facts: Self.facts(kind: Self.kindLabel(info), quant: quant, license: license, size: size, repo: model.repoId),
            searchHaystack: LocalModelCatalogFormat.haystack([info.displayName, info.id, model.repoId, license])
        )
        if !info.ready {
            item.badges.append(.init(text: L("Not ready"), tone: .warning, help: info.blockedReasons.first))
        }
        if let license {
            item.badges.append(.init(text: license, tone: .neutral))
        }

        let downloads = downloads
        let isEdit = !info.capabilities.textToImage && info.capabilities.imageEdit
        if info.ready, info.capabilities.textToImage || info.capabilities.imageEdit || info.capabilities.upscale {
            item.primaryAction = .init(
                title: info.capabilities.upscale ? "Upscale" : (isEdit ? "Edit" : "Generate"),
                icon: isEdit ? "wand.and.stars" : "sparkles"
            ) { [weak self] in self?.openPanel(info, isEdit: isEdit) }
            if info.capabilities.textToImage, info.capabilities.imageEdit {
                item.menuActions.append(.init(title: "Edit", icon: "wand.and.stars") { [weak self] in
                    self?.openPanel(info, isEdit: true)
                })
            }
        }
        if let repo = model.repoId {
            let redownload = LocalModelCatalogItem.Action(title: "Re-download", icon: "arrow.clockwise") {
                downloads.download(repoId: repo, displayName: info.displayName)
            }
            if info.ready { item.menuActions.append(redownload) } else { item.primaryAction = redownload }
        }
        item.menuActions.append(.init(
            title: "Delete", icon: "trash", role: .destructive,
            confirmation: L("This removes \(info.displayName) from this Mac. You can download it again later.")
        ) { downloads.delete(info.id) })
        item.onCancel = { downloads.cancel(info.id) }
        return item
    }

    private func item(for entry: ImageModelDownload) -> LocalModelCatalogItem {
        let license = ImageModelRequestPolicy.licenseLabel(
            canonical: ImageModelRequestPolicy.catalogCanonical(entry.id))
        let quant = Self.quantization(bits: nil, id: entry.repoId)
        let size = sizes[entry.repoId].flatMap { $0 > 0 ? $0 : nil }
        let status = status(entry.id, installed: false)

        var item = LocalModelCatalogItem(
            id: entry.id,
            name: entry.displayName,
            subtitle: [entry.note, quant].compactMap { $0 }.joined(separator: " · "),
            icon: "photo",
            sizeText: size.map(LocalModelCatalogFormat.bytes),
            sizeBytes: size,
            status: status,
            huggingFaceRepo: entry.repoId,
            facts: Self.facts(kind: nil, quant: quant, license: license, size: size, repo: entry.repoId),
            searchHaystack: LocalModelCatalogFormat.haystack([entry.displayName, entry.repoId, entry.note, license])
        )
        if let license {
            item.badges.append(.init(text: license, tone: .neutral))
        }
        let downloads = downloads
        item.primaryAction = .init(
            title: status == .available ? "Download" : "Retry",
            icon: "arrow.down.circle",
            role: .primary
        ) { downloads.download(entry) }
        item.onCancel = { downloads.cancel(entry.id) }
        return item
    }

    private func openPanel(_ info: ImageModelInfo, isEdit: Bool) {
        sheetRequest = SheetRequest(id: info.id) {
            AnyView(
                ImageGenerationPanelView(
                    modelId: info.id,
                    displayName: info.displayName,
                    isEdit: isEdit,
                    modelInfo: info
                )
            )
        }
    }

    // MARK: Labels

    private static func facts(
        kind: String?,
        quant: String?,
        license: String?,
        size: Int64?,
        repo: String?
    ) -> [LocalModelCatalogItem.Fact] {
        var facts: [LocalModelCatalogItem.Fact] = []
        if let kind { facts.append(.init(label: "Type", value: kind)) }
        if let quant { facts.append(.init(label: "Quantization", value: quant)) }
        if let size { facts.append(.init(label: "Size", value: LocalModelCatalogFormat.bytes(size))) }
        if let license { facts.append(.init(label: "License", value: license)) }
        if let repo { facts.append(.init(label: "Repository", value: repo)) }
        return facts
    }

    private static func kindLabel(_ info: ImageModelInfo) -> String? {
        switch info.kind {
        case "imageEdit": return L("Edit")
        case "imageUpscale": return L("Upscale")
        case "videoGen": return L("Video")
        default: return info.capabilities.textToImage ? L("Text to image") : nil
        }
    }

    /// Explicit bit width when known, else parsed from the repo or bundle name.
    private static func quantization(bits: Int?, id: String) -> String? {
        if let bits { return "\(bits)-bit" }
        let lower = id.lowercased()
        if lower.contains("fp8") { return "FP8" }
        if lower.contains("nf4") { return "NF4" }
        if lower.contains("8bit") || lower.contains("8-bit") { return "8-bit" }
        if lower.contains("6bit") || lower.contains("6-bit") { return "6-bit" }
        if lower.contains("4bit") || lower.contains("4-bit") { return "4-bit" }
        return nil
    }
}
