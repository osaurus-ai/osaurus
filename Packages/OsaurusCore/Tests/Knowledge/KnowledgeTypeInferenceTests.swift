//
//  KnowledgeTypeInferenceTests.swift
//  osaurusTests
//
//  Folder-based category inference: top-level folder → slug, root
//  files → no inference.
//

import Foundation
import Testing

@testable import OsaurusCore

struct KnowledgeTypeInferenceTests {

    @Test
    func infersFromTopLevelFolder() {
        #expect(KnowledgeTypeInference.infer(relPath: "recipes/pasta.md") == "recipes")
        #expect(KnowledgeTypeInference.infer(relPath: "Medical Records/allergies.md") == "medical-records")
        #expect(KnowledgeTypeInference.infer(relPath: "how_to/router setup.md") == "how-to")
    }

    @Test
    func usesOnlyTheTopLevelFolderForNestedPaths() {
        #expect(KnowledgeTypeInference.infer(relPath: "family/kids/school.md") == "family")
    }

    @Test
    func rootLevelFilesGetNoInference() {
        #expect(KnowledgeTypeInference.infer(relPath: "about-me.md") == "")
    }

    @Test
    func slugDropsPunctuationAndCollapsesSeparators() {
        #expect(KnowledgeTypeInference.slugify("Notes — 2024 (personal)") == "notes-2024-personal")
        #expect(KnowledgeTypeInference.slugify("...") == "")
        #expect(KnowledgeTypeInference.slugify("  Trip   Plans  ") == "trip-plans")
    }
}
