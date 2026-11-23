//
//  MediaModelSourceResolver.swift
//  osaurus
//
//  Where a missing image or video model can be downloaded from. A media
//  step names a family (`qwen-image-2.1`), an exact bundle, or nothing; this
//  finds the bundles in the image catalog that could stand in for it, with
//  the same family rules `MediaModelResolver` uses once one is installed, so
//  the bundle setup downloads is the one the run then finds.
//

import Foundation

/// A downloadable bundle that would satisfy a media requirement.
struct MediaModelSource: Codable, Equatable, Sendable, Identifiable {
    /// The bundle directory name, which download state is keyed by.
    var id: String
    var repoId: String
    var displayName: String
    /// The engine family it loads as.
    var family: String?
    var sizeBytes: Int64?
}

enum MediaModelSourceResolver {

    /// One image catalog entry with what the engine says it is.
    struct CatalogEntry: Equatable, Sendable {
        var id: String
        var repoId: String
        var displayName: String
        /// Engine canonical family, nil when the engine does not know it.
        var family: String?
        /// Engine kind: `imageGen`, `imageEdit`, `imageUpscale`, `videoGen`.
        var kind: String?
        var sizeBytes: Int64?
    }

    enum Outcome: Equatable, Sendable {
        /// Download `choice`. `alternatives` are other versions of the same
        /// model, offered behind Details.
        case download(choice: MediaModelSource, alternatives: [MediaModelSource])
        /// The step names no model: the person picks one of `options`.
        case choose(options: [MediaModelSource])
        /// The step may only run on a connected provider.
        case connectProvider
        /// Nothing in the catalog can do it.
        case unavailable
    }

    static func resolve(_ requirement: MediaModelRequirement, catalog: [CatalogEntry]) -> Outcome {
        let selector = requirement.model
        guard selector.locality.allowsLocal else { return .connectProvider }
        let pool = catalog.filter { supports($0, requirement.action) }

        let hits: [CatalogEntry]
        if let id = selector.id {
            hits = pool.filter { matches($0, id: id) }
        } else if let family = selector.family {
            // An exact family beats a substring of a longer one
            // (`qwen-image-2.1` over `qwen-image-2.1-turbo`).
            let wanted = MediaModelResolver.normalized(family)
            let exact = pool.filter { $0.family.map(MediaModelResolver.normalized) == wanted }
            hits = exact.isEmpty ? pool.filter { matches($0, family: family) } : exact
        } else {
            let options = smallestFirst(pool)
            return options.isEmpty ? .unavailable : .choose(options: options.map(source))
        }
        let ordered = smallestFirst(hits)
        guard let first = ordered.first else {
            return selector.locality.allowsRemote ? .connectProvider : .unavailable
        }
        return .download(choice: source(first), alternatives: ordered.dropFirst().map(source))
    }

    /// The requirement a step's `image` or `video` tool stands for when it
    /// has no model to run on: any model that can do it.
    static func requirement(forTool name: String) -> MediaModelRequirement? {
        switch name {
        case "image": return MediaModelRequirement(action: .generate, model: MediaModelSelector(locality: .any))
        case "video": return MediaModelRequirement(action: .video, model: MediaModelSelector(locality: .any))
        default: return nil
        }
    }

    static func supports(_ entry: CatalogEntry, _ action: MediaAction) -> Bool {
        guard let kind = entry.kind else { return false }
        if action == .video { return kind == "videoGen" }
        let capabilities = ImageModelRequestPolicy.capabilities(kind: kind, canonical: entry.family)
        switch action {
        case .generate: return capabilities.textToImage
        case .edit: return capabilities.imageEdit
        case .upscale: return capabilities.upscale
        case .video: return false
        }
    }

    private static func matches(_ entry: CatalogEntry, id: String) -> Bool {
        let wanted = id.lowercased()
        return entry.id.lowercased() == wanted || entry.repoId.lowercased() == wanted
            || entry.family?.lowercased() == wanted
    }

    private static func matches(_ entry: CatalogEntry, family: String) -> Bool {
        let wanted = MediaModelResolver.normalized(family)
        guard !wanted.isEmpty else { return false }
        if let f = entry.family, MediaModelResolver.normalized(f) == wanted { return true }
        return MediaModelResolver.normalized(entry.id).contains(wanted)
            || MediaModelResolver.normalized(entry.displayName).contains(wanted)
    }

    /// Smallest known download first; unknown sizes keep catalog order
    /// after them.
    private static func smallestFirst(_ entries: [CatalogEntry]) -> [CatalogEntry] {
        entries.enumerated().sorted { a, b in
            switch (a.element.sizeBytes, b.element.sizeBytes) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    private static func source(_ entry: CatalogEntry) -> MediaModelSource {
        MediaModelSource(
            id: entry.id, repoId: entry.repoId, displayName: entry.displayName, family: entry.family,
            sizeBytes: entry.sizeBytes)
    }

    // MARK: - Live

    /// The image catalog as the engine reads it. `sizes` by repo id.
    @MainActor
    static func liveCatalog(sizes: [String: Int64] = [:]) -> [CatalogEntry] {
        ImageModelDownloadService.shared.fetchedCatalog.map { entry in
            let engine = ImageGenerationService.engineFamily(forBundleName: entry.id)
            return CatalogEntry(
                id: entry.id, repoId: entry.repoId, displayName: entry.displayName,
                family: engine?.canonical ?? ImageModelRequestPolicy.catalogCanonical(entry.id),
                kind: engine?.kind, sizeBytes: sizes[entry.repoId])
        }
    }

    /// `resolve` against the live catalog, loading the OsaurusAI listing
    /// first when only the built-in entries are known, with sizes for the
    /// bundles that match so the smallest can be chosen.
    @MainActor
    static func resolveLive(_ requirement: MediaModelRequirement) async -> Outcome {
        let downloads = ImageModelDownloadService.shared
        if downloads.fetchedCatalog.count <= ImageModelDownloadService.curatedCatalog.count {
            await downloads.refreshCatalog()
        }
        let unsized = resolve(requirement, catalog: liveCatalog())
        var sizes: [String: Int64] = [:]
        for source in unsized.sources {
            if let bytes = await downloads.estimateDownloadSize(repoId: source.repoId), bytes > 0 {
                sizes[source.repoId] = bytes
            }
        }
        return resolve(requirement, catalog: liveCatalog(sizes: sizes))
    }
}

extension SetupItem {
    /// The media requirement a `needsMediaModel` item stands for.
    func mediaRequirement(in template: Template) -> MediaModelRequirement? {
        guard needsMediaModel else { return nil }
        if kind == .mediaModel { return template.requirements.mediaModels.first { $0.id == value } }
        return MediaModelSourceResolver.requirement(forTool: value)
    }
}

extension MediaAction {
    /// What a person calls the model for this action.
    var modelTitle: String {
        switch self {
        case .generate: return L("Image model")
        case .edit: return L("Image editing model")
        case .upscale: return L("Upscaling model")
        case .video: return L("Video model")
        }
    }

    /// What the installer says while the model downloads.
    var downloadActivity: String {
        switch self {
        case .generate: return L("Downloading the image model")
        case .edit: return L("Downloading the image editing model")
        case .upscale: return L("Downloading the upscaling model")
        case .video: return L("Downloading the video model")
        }
    }
}

extension MediaModelSourceResolver.Outcome {
    /// Every bundle the outcome offers, the preselected one first.
    var sources: [MediaModelSource] {
        switch self {
        case .download(let choice, let alternatives): return [choice] + alternatives
        case .choose(let options): return options
        case .connectProvider, .unavailable: return []
        }
    }
}
