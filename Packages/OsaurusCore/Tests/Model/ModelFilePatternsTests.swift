import OsaurusRepository
import Testing

@testable import OsaurusCore

struct ModelFilePatternsTests {
    @Test func appAndCLIDownloadTheSameFiles() {
        #expect(ModelDownloadService.downloadFilePatterns == ModelFilePatterns.download)
        #expect(ModelDownloadService.downloadExcludedFiles == ModelFilePatterns.excluded)
    }

    @Test func matchesByFileName() {
        #expect(ModelFilePatterns.matches(path: "tokenizer.model"))
        #expect(ModelFilePatterns.matches(path: "sub/model-00001-of-00002.safetensors"))
        #expect(!ModelFilePatterns.matches(path: "README.md"))
        #expect(!ModelFilePatterns.matches(path: "original/consolidated.pth"))
    }
}
