//
//  MediaModelSourceResolverTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct MediaModelSourceResolverTests {
    typealias Entry = MediaModelSourceResolver.CatalogEntry

    private static func entry(
        _ repo: String, family: String?, kind: String? = "imageGen", size: Int64? = nil
    ) -> Entry {
        let id = ImageModelDownload.directoryName(forRepoId: repo)
        return Entry(id: id, repoId: repo, displayName: id, family: family, kind: kind, sizeBytes: size)
    }

    private static let catalog: [Entry] = [
        entry("OsaurusAI/Qwen-Image-2.1-mflux-8bit", family: "qwen-image-2.1", size: 24_000_000_000),
        entry("OsaurusAI/Qwen-Image-2.1-mflux-4bit", family: "qwen-image-2.1", size: 12_000_000_000),
        entry("OsaurusAI/Qwen-Image-2.1-Turbo-mflux-4bit", family: "qwen-image-2.1-turbo", size: 9_000_000_000),
        entry("OsaurusAI/FLUX-1-schnell-mflux-4bit", family: "flux1-schnell", size: 6_000_000_000),
        entry("OsaurusAI/SeedVR2-mflux", family: "seedvr2", kind: "imageUpscale", size: 3_000_000_000),
        entry("OsaurusAI/Wan2.1-T2V-mflux", family: "wan-2.1", kind: "videoGen", size: 15_000_000_000),
        entry("someone/unknown-bundle", family: nil, kind: nil, size: 1),
    ]

    private static func requirement(
        _ action: MediaAction, family: String? = nil, id: String? = nil, locality: MediaLocality = .local
    ) -> MediaModelRequirement {
        MediaModelRequirement(action: action, model: MediaModelSelector(family: family, id: id, locality: locality))
    }

    @Test func familyPicksTheSmallestOfItsExactVersions() {
        let outcome = MediaModelSourceResolver.resolve(Self.requirement(.generate, family: "qwen-image-2.1"), catalog: Self.catalog)
        guard case .download(let choice, let alternatives) = outcome else {
            Issue.record("expected a download, got \(outcome)")
            return
        }
        #expect(choice.repoId == "OsaurusAI/Qwen-Image-2.1-mflux-4bit")
        #expect(alternatives.map(\.repoId) == ["OsaurusAI/Qwen-Image-2.1-mflux-8bit"])
    }

    @Test func displayFormOfAFamilyMatchesToo() {
        let outcome = MediaModelSourceResolver.resolve(Self.requirement(.generate, family: "Qwen-Image 2.1"), catalog: Self.catalog)
        #expect(outcome.sources.first?.repoId == "OsaurusAI/Qwen-Image-2.1-mflux-4bit")
    }

    @Test func turboFamilyIsItsOwn() {
        let outcome = MediaModelSourceResolver.resolve(
            Self.requirement(.generate, family: "qwen-image-2.1-turbo"), catalog: Self.catalog)
        #expect(outcome.sources.map(\.repoId) == ["OsaurusAI/Qwen-Image-2.1-Turbo-mflux-4bit"])
    }

    @Test func exactIdWinsOverFamily() {
        let outcome = MediaModelSourceResolver.resolve(
            Self.requirement(.generate, id: "Qwen-Image-2.1-mflux-8bit"), catalog: Self.catalog)
        #expect(outcome.sources.map(\.repoId) == ["OsaurusAI/Qwen-Image-2.1-mflux-8bit"])
    }

    @Test func repoIdMatches() {
        let outcome = MediaModelSourceResolver.resolve(
            Self.requirement(.generate, id: "osaurusai/flux-1-schnell-mflux-4bit"), catalog: Self.catalog)
        #expect(outcome.sources.map(\.id) == ["FLUX-1-schnell-mflux-4bit"])
    }

    @Test func actionFiltersBundlesThatCannotDoIt() {
        let upscale = MediaModelSourceResolver.resolve(Self.requirement(.upscale), catalog: Self.catalog)
        #expect(upscale.sources.map(\.family) == ["seedvr2"])
        // Qwen-Image 2.1 also edits; FLUX.1 schnell does not.
        let edit = MediaModelSourceResolver.resolve(Self.requirement(.edit), catalog: Self.catalog)
        #expect(Set(edit.sources.map(\.family)) == ["qwen-image-2.1", "qwen-image-2.1-turbo"])
        let video = MediaModelSourceResolver.resolve(Self.requirement(.video), catalog: Self.catalog)
        #expect(video.sources.map(\.family) == ["wan-2.1"])
    }

    @Test func noModelNamedAsksWithTheSmallestFirst() {
        let outcome = MediaModelSourceResolver.resolve(Self.requirement(.generate), catalog: Self.catalog)
        guard case .choose(let options) = outcome else {
            Issue.record("expected a choice, got \(outcome)")
            return
        }
        #expect(options.first?.family == "flux1-schnell")
        #expect(!options.contains { $0.family == nil })
    }

    @Test func unknownSizesFollowKnownOnes() {
        let catalog = [
            Self.entry("a/Qwen-Image-2.1-mflux-6bit", family: "qwen-image-2.1"),
            Self.entry("a/Qwen-Image-2.1-mflux-8bit", family: "qwen-image-2.1", size: 20),
            Self.entry("a/Qwen-Image-2.1-mflux-4bit", family: "qwen-image-2.1", size: 10),
        ]
        let outcome = MediaModelSourceResolver.resolve(Self.requirement(.generate, family: "qwen-image-2.1"), catalog: catalog)
        #expect(outcome.sources.map(\.id) == ["Qwen-Image-2.1-mflux-4bit", "Qwen-Image-2.1-mflux-8bit", "Qwen-Image-2.1-mflux-6bit"])
    }

    @Test func remoteOnlyNeedsAProvider() {
        let outcome = MediaModelSourceResolver.resolve(
            Self.requirement(.generate, family: "qwen-image-2.1", locality: .remote), catalog: Self.catalog)
        #expect(outcome == .connectProvider)
    }

    @Test func familyNotInCatalog() {
        let local = MediaModelSourceResolver.resolve(Self.requirement(.generate, family: "imagen-4"), catalog: Self.catalog)
        #expect(local == .unavailable)
        let any = MediaModelSourceResolver.resolve(
            Self.requirement(.generate, family: "imagen-4", locality: .any), catalog: Self.catalog)
        #expect(any == .connectProvider)
    }

    @Test func toolsStandForAnyModelOfTheirKind() {
        #expect(MediaModelSourceResolver.requirement(forTool: "image")?.action == .generate)
        #expect(MediaModelSourceResolver.requirement(forTool: "video")?.action == .video)
        #expect(MediaModelSourceResolver.requirement(forTool: "image")?.model.locality == .any)
        #expect(MediaModelSourceResolver.requirement(forTool: "browser_use") == nil)
    }

    @Test func engineKnowsTheCatalogFamilies() {
        #expect(ImageGenerationService.engineFamily(forBundleName: "Qwen-Image-2.1-mflux-4bit")?.canonical == "qwen-image-2.1")
        #expect(ImageGenerationService.engineFamily(forBundleName: "OsaurusAI/FLUX.1-schnell-mflux-4bit")?.kind == "imageGen")
        #expect(ImageGenerationService.engineFamily(forBundleName: "not-a-model") == nil)
    }
}
