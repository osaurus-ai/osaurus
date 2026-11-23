//
//  ImageModelCatalogNamingTests.swift
//  osaurusTests
//
//  Image catalog rows: readable names from repo ids, one family per model
//  (never merging Turbo with its base), version order, and the default pick.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ImageModelCatalogNamingTests {

    private static let gb: Int64 = 1_000_000_000

    @Test(arguments: [
        ("OsaurusAI/Qwen-Image-2.1-Turbo-mflux-8bit", "Qwen Image 2.1 Turbo", "8-bit"),
        ("OsaurusAI/Qwen-Image-2.1-mflux-6bit", "Qwen Image 2.1", "6-bit"),
        ("OsaurusAI/FLUX-3-Image-Klein-mflux-4bit", "FLUX 3 Image Klein", "4-bit"),
        ("OsaurusAI/ideogram-4-mflux-8bit", "Ideogram 4", "8-bit"),
        ("cocktailpeanut/ideogram-4-fp8", "Ideogram 4", "FP8"),
        ("cocktailpeanut/ideogram-4-nf4", "Ideogram 4", "NF4"),
        ("OsaurusAI/Z-Image-Turbo-mflux-4bit", "Z Image Turbo", "4-bit"),
        ("OsaurusAI/FLUX.1-schnell-mflux-8bit", "FLUX.1 Schnell", "8-bit"),
        ("OsaurusAI/Qwen-Image-mflux-6bit", "Qwen Image", "6-bit"),
        ("OsaurusAI/Qwen-Image-Edit-mflux-q5", "Qwen Image Edit", "5-bit"),
        ("Qwen-Image-2.1-mflux-8-bit", "Qwen Image 2.1", "8-bit"),
    ])
    func readableNames(repoId: String, name: String, version: String) {
        let parsed = ImageModelCatalogNaming.parse(repoId)
        #expect(parsed.displayName == name)
        #expect(parsed.versionLabel == version)
    }

    @Test func folderNameMatchesRepoFamily() {
        let repo = ImageModelCatalogNaming.parse("OsaurusAI/Qwen-Image-2.1-mflux-8bit")
        let folder = ImageModelCatalogNaming.parse("Qwen-Image-2.1-mflux-4bit")
        #expect(repo.familyKey == folder.familyKey)
    }

    @Test func turboAndBaseNeverShareAFamily() {
        let base = ImageModelCatalogNaming.parse("OsaurusAI/Qwen-Image-2.1-mflux-8bit")
        let turbo = ImageModelCatalogNaming.parse("OsaurusAI/Qwen-Image-2.1-Turbo-mflux-8bit")
        let original = ImageModelCatalogNaming.parse("OsaurusAI/Qwen-Image-mflux-8bit")
        let edit = ImageModelCatalogNaming.parse("OsaurusAI/Qwen-Image-Edit-mflux-q8")
        #expect(Set([base.familyKey, turbo.familyKey, original.familyKey, edit.familyKey]).count == 4)
    }

    @Test func mirrorsFoldAcrossPublishers() {
        let mirror = ImageModelCatalogNaming.parse("cocktailpeanut/ideogram-4-fp8")
        let org = ImageModelCatalogNaming.parse("OsaurusAI/ideogram-4-mflux-4bit")
        #expect(mirror.familyKey == org.familyKey)
    }

    @Test func unquantizedNameKeepsEveryWord() {
        let parsed = ImageModelCatalogNaming.parse("someone/SeedVR2-3B")
        #expect(parsed.displayName == "SeedVR2 3B")
        #expect(parsed.versionLabel == nil)
    }

    @Test func pickerNameAddsTheVersion() {
        #expect(ImageModelCatalogNaming.pickerName("Qwen-Image-2.1-Turbo-mflux-8bit") == "Qwen Image 2.1 Turbo (8-bit)")
        #expect(ImageModelCatalogNaming.pickerName("SeedVR2-3B") == "SeedVR2 3B")
    }

    @Test func bestFirstOrdersByPrecisionThenSize() {
        let versions: [ImageModelCatalogNaming.Version] = [
            .init(id: "q4", bits: 4, sizeBytes: 10 * Self.gb),
            .init(id: "q8", bits: 8, sizeBytes: 18 * Self.gb),
            .init(id: "fp8", bits: 8, sizeBytes: 20 * Self.gb),
            .init(id: "q6", bits: 6, sizeBytes: nil),
        ]
        #expect(ImageModelCatalogNaming.bestFirst(versions).map(\.id) == ["fp8", "q8", "q6", "q4"])
    }

    @Test func recommendedFitsTheMacOrFallsBackToSmallest() {
        let versions: [ImageModelCatalogNaming.Version] = [
            .init(id: "4bit", bits: 4, sizeBytes: 11 * Self.gb),
            .init(id: "6bit", bits: 6, sizeBytes: 14 * Self.gb),
            .init(id: "8bit", bits: 8, sizeBytes: 18 * Self.gb),
        ]
        #expect(ImageModelCatalogNaming.recommendedId(versions, physicalMemoryGB: 128) == "8bit")
        #expect(ImageModelCatalogNaming.recommendedId(versions, physicalMemoryGB: 24) == "6bit")
        #expect(ImageModelCatalogNaming.recommendedId(versions, physicalMemoryGB: 16) == "4bit")
    }

    @Test func recommendedUsesLowestPrecisionUntilSizesLoad() {
        let versions: [ImageModelCatalogNaming.Version] = [
            .init(id: "8bit", bits: 8, sizeBytes: 18 * Self.gb),
            .init(id: "4bit", bits: 4, sizeBytes: nil),
        ]
        #expect(ImageModelCatalogNaming.recommendedId(versions, physicalMemoryGB: 128) == "4bit")
    }

    @Test func framingNamesTheEnds() {
        #expect(ModelVersionFraming.label(index: 0, count: 1) == nil)
        #expect(ModelVersionFraming.label(index: 0, count: 3) == "Best quality")
        #expect(ModelVersionFraming.label(index: 1, count: 3) == "Balanced")
        #expect(ModelVersionFraming.label(index: 2, count: 3) == "Smallest download")
    }
}
