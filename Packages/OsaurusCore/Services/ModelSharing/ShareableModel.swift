//
//  ShareableModel.swift
//  osaurus
//
//  What this Mac could offer to nearby Macs: every installed model of every
//  kind, with the files that make it up. One provider per kind reads the
//  places that kind is installed; `ShareableModelInventory.scan` merges them.
//  Scans touch the disk, so they run off the main actor.
//

@preconcurrency import FluidAudio
import Foundation

/// The `kind` an item is published under. Values are listed in
/// osaurus-sync's `docs/model-sharing.md`.
enum ModelShareKind: String, CaseIterable, Sendable {
    case language, embedding, applescript, image, speech, privacy

    var format: String {
        switch self {
        case .image: return "mflux"
        case .speech: return "coreml"
        case .language, .embedding, .applescript, .privacy: return "mlx"
        }
    }

    var localModelKind: LocalModelKind {
        switch self {
        case .language: return .language
        case .embedding: return .embedding
        case .applescript: return .appleScript
        case .image: return .image
        case .speech: return .speech
        case .privacy: return .detection
        }
    }

    init(_ kind: LocalModelKind) {
        switch kind {
        case .language: self = .language
        case .embedding: self = .embedding
        case .appleScript: self = .applescript
        case .image: self = .image
        case .speech: self = .speech
        case .detection: self = .privacy
        }
    }
}

struct ShareableFile: Sendable, Equatable {
    /// Relative to the model's directory, with `/`.
    let path: String
    /// The file to read, symbolic links resolved.
    let url: URL
    let size: Int64
    let modified: Date
}

struct ShareableModel: Identifiable, Sendable, Equatable {
    let kind: ModelShareKind
    /// The id the kind's catalog uses: a repo id, an image bundle directory,
    /// a speech model version, or the privacy bundle version.
    let localId: String
    let name: String
    let repoId: String?
    let revision: String?
    let files: [ShareableFile]

    var id: String { Self.id(kind: kind, localId: localId) }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    static func id(kind: ModelShareKind, localId: String) -> String { "\(kind.rawValue):\(localId)" }
}

protocol ShareableModelProvider {
    static func shareableModels() -> [ShareableModel]
}

enum ShareableModelInventory {
    static var providers: [any ShareableModelProvider.Type] {
        [
            MLXBundleShareProvider.self,
            ImageBundleShareProvider.self,
            SpeechModelShareProvider.self,
            PrivacyFilterShareProvider.self,
        ]
    }

    /// Every model this Mac could share, minus ids in `busy` (downloads in
    /// progress), sorted by kind then name.
    static func scan(busy: Set<String> = []) -> [ShareableModel] {
        let kinds = ModelShareKind.allCases
        return providers.flatMap { $0.shareableModels() }
            .filter { !busy.contains($0.id) }
            .sorted {
                let (a, b) = (kinds.firstIndex(of: $0.kind)!, kinds.firstIndex(of: $1.kind)!)
                if a != b { return a < b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}

// MARK: - Files

enum ShareableFiles {
    private static let leftoverSuffixes = [".part", ".download", ".incomplete", ".part.json", ".tmp"]
    private static let maxDepth = 8

    /// Regular files under `root`, skipping hidden files and download
    /// leftovers. Symbolic links are followed only to regular files inside
    /// `confinement`; `nil` when one points elsewhere, so a bundle is shared
    /// whole or not at all.
    static func list(root: URL, confinement: URL? = nil) -> [ShareableFile]? {
        let fm = FileManager.default
        let confinement = confinement ?? root
        var files: [ShareableFile] = []

        func walk(_ directory: URL, prefix: String, depth: Int) -> Bool {
            guard depth <= maxDepth,
                let entries = try? fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else { return false }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                if leftoverSuffixes.contains(where: { name.hasSuffix($0) }) { continue }
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                var target = entry
                if values?.isSymbolicLink == true {
                    target = entry.resolvingSymlinksInPath()
                    guard ExternalModelLocator.isContained(target, in: confinement) else { return false }
                }
                guard let attrs = try? fm.attributesOfItem(atPath: target.path),
                    let type = attrs[.type] as? FileAttributeType
                else { return false }
                if type == .typeDirectory {
                    guard walk(target, prefix: path, depth: depth + 1) else { return false }
                } else if type == .typeRegular {
                    files.append(
                        ShareableFile(
                            path: path,
                            url: target,
                            size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                            modified: attrs[.modificationDate] as? Date ?? .distantPast
                        )
                    )
                }
            }
            return true
        }

        guard walk(root, prefix: "", depth: 0), !files.isEmpty else { return nil }
        return files
    }
}

// MARK: - Providers

/// Language, embedding and AppleScript bundles in the models folder, plus
/// MLX bundles found in the Hugging Face cache, LM Studio and custom folders.
enum MLXBundleShareProvider: ShareableModelProvider {
    static func shareableModels() -> [ShareableModel] {
        let fm = FileManager.default
        var seen = Set<String>()
        return ModelManager.localModelsSnapshotNonBlocking().compactMap { model in
            guard model.id.contains("/"), seen.insert(model.id.lowercased()).inserted, model.isDownloaded else {
                return nil
            }
            let directory = model.localDirectory
            if fm.fileExists(atPath: directory.appendingPathComponent(ModelManifest.pendingUpdateFilename).path) {
                return nil
            }
            let external = model.isExternallyOwned ? ExternalModelLocator.entry(forId: model.id) : nil
            let confinement = external?.scanRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            guard let files = ShareableFiles.list(root: directory, confinement: confinement ?? directory),
                files.contains(where: { $0.path == "config.json" }),
                files.contains(where: { $0.path.hasSuffix(".safetensors") })
            else { return nil }
            return ShareableModel(
                kind: kind(of: model),
                localId: model.id,
                name: model.name,
                repoId: model.id,
                revision: external?.revision,
                files: files
            )
        }
    }

    static func kind(of model: MLXModel) -> ModelShareKind {
        if AppleScriptModelCatalog.isAppleScriptModel(id: model.id) { return .applescript }
        if EmbeddingDetection.isEmbedding(at: model.localDirectory) { return .embedding }
        return .language
    }
}

/// mflux bundles in the image models folder.
enum ImageBundleShareProvider: ShareableModelProvider {
    static func shareableModels() -> [ShareableModel] {
        shareableModels(in: ImageGenerationService.imageModelsRoot())
    }

    static func shareableModels(in root: URL) -> [ShareableModel] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return entries.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let files = ShareableFiles.list(root: directory),
                ImageModelDownloadService.isImageBundle(paths: files.map(\.path))
            else { return nil }
            let id = directory.lastPathComponent
            return ShareableModel(
                kind: .image,
                localId: id,
                name: id,
                repoId: ImageModelDownloadService.markedSourceRepoId(in: directory),
                revision: nil,
                files: files
            )
        }
    }
}

/// FluidAudio Parakeet models in FluidAudio's cache.
enum SpeechModelShareProvider: ShareableModelProvider {
    static func shareableModels() -> [ShareableModel] {
        SpeechModelVersion.allCases.compactMap { version in
            let directory = cacheDirectory(for: version)
            guard AsrModels.modelsExist(at: directory, version: asrVersion(version)),
                let files = ShareableFiles.list(root: directory)
            else { return nil }
            return ShareableModel(
                kind: .speech,
                localId: version.rawValue,
                name: version.displayName,
                repoId: nil,
                revision: nil,
                files: files
            )
        }
    }

    static func asrVersion(_ version: SpeechModelVersion) -> AsrModelVersion {
        version == .v2 ? .v2 : .v3
    }

    static func cacheDirectory(for version: SpeechModelVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: asrVersion(version))
    }
}

/// The OpenAI Privacy Filter bundle, with the manifest its verifier reads.
enum PrivacyFilterShareProvider: ShareableModelProvider {
    static let displayName = "OpenAI Privacy Filter"

    static func shareableModels() -> [ShareableModel] {
        let directory = PrivacyFilterModelBundle.directoryURL()
        guard PrivacyFilterModelBundle.exists(at: directory),
            let files = ShareableFiles.list(root: directory)
        else { return [] }
        let manifest = try? PrivacyFilterModelBundle.readManifest(at: directory)
        return [
            ShareableModel(
                kind: .privacy,
                localId: PrivacyFilterModelBundle.version,
                name: displayName,
                repoId: manifest?.repoId,
                revision: manifest?.revision,
                files: files
            )
        ]
    }
}
