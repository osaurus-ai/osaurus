//
//  ComputerUseModelCatalogTests.swift
//  OsaurusCoreTests — Computer Use
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Computer Use model catalog")
struct ComputerUseModelCatalogTests {
    @Test("only candidates with a recorded runtime proof are listed")
    func listsOnlyProvenCandidates() {
        let proven = ComputerUseModelCatalog.candidates.filter { $0.proof != nil }.map(\.model.id)
        #expect(ComputerUseModelCatalog.models.map(\.id) == proven)
        for candidate in ComputerUseModelCatalog.candidates {
            if let proof = candidate.proof {
                #expect(!proof.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @Test("candidate ids are unique Hugging Face repos")
    func candidateIdsAreUniqueRepos() {
        let ids = ComputerUseModelCatalog.candidates.map { $0.model.id.lowercased() }
        #expect(Set(ids).count == ids.count)
        for candidate in ComputerUseModelCatalog.candidates {
            #expect(candidate.model.id.split(separator: "/").count == 2)
            #expect(candidate.model.downloadURL == "https://huggingface.co/\(candidate.model.id)")
            #expect(!RetiredModelBundles.isRetired(id: candidate.model.id))
        }
    }

    @Test("installed models are a subset of the listed catalog")
    func installedIsSubsetOfListed() {
        let listed = Set(ComputerUseModelCatalog.models.map(\.id))
        #expect(ComputerUseModelCatalog.installedModels().allSatisfy { listed.contains($0.id) })
    }

    @Test("the Computer Use tab shares its bundles as language models")
    func sharesAsLanguageModels() {
        #expect(ModelShareKind(LocalModelKind.computerUse) == .language)
    }
}
