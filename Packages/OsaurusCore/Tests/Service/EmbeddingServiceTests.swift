//
//  EmbeddingServiceTests.swift
//  osaurus
//
//  Tests for EmbeddingService: verifies the dimension constant and
//  startup gate behavior without requiring model download.
//

import Foundation
import Testing

@testable import OsaurusCore

struct EmbeddingServiceTests {

    @Test func embeddingDimensionIs128() {
        #expect(EmbeddingService.embeddingDimension == 128)
    }

    @Test func awaitStartupInitReturnsImmediatelyWhenNoTaskSet() async {
        await EmbeddingService.awaitStartupInit()
    }

    @Test func modelNameIsPotion() {
        #expect(EmbeddingService.modelName == "potion-base-4M")
    }
}
