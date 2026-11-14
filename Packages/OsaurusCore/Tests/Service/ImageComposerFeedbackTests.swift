import Foundation
import Testing
@testable import OsaurusCore

@Suite("Image composer feedback")
struct ImageComposerFeedbackTests {
    @Test func pastedPromptPreservesParagraphsAndSyntax() throws {
        let pasted = "Scene: a [blue] teapot.\n\nBackground: a table (white).\n\nLight: dusk."
        #expect(try ImageComposerRequestBuilder.prompt(text: "", attachments: [.pastedContent(pasted)]) == pasted)
        #expect(try ImageComposerRequestBuilder.prompt(text: "Make it red.", attachments: [.pastedContent(pasted)])
            == "Make it red.\n\n" + pasted)
    }

    @Test func pastedPromptKeepsAttachmentOrderAndIgnoresNonPromptFiles() throws {
        let attachments: [OsaurusCore.Attachment] = [.pastedContent("Scene"), .image(Data([1, 2])),
            .document(filename: "notes.txt", content: "not pasted", fileSize: 10), .pastedContent("Light")]
        #expect(try ImageComposerRequestBuilder.prompt(text: "", attachments: attachments) == "Scene\n\nLight")
        #expect(try ImageComposerRequestBuilder.prompt(text: " \n", attachments: [.image(Data())]).isEmpty)
    }

    @Test func missingSpilledPasteDoesNotGenerateFromPartialPrompt() {
        let missing = OsaurusCore.Attachment(kind: .documentRef(filename: OsaurusCore.Attachment.pastedContentFilename,
            hash: String(repeating: "0", count: 64), fileSize: 123))
        #expect(throws: CocoaError.self) {
            try ImageComposerRequestBuilder.prompt(text: "A partial instruction", attachments: [missing])
        }
    }

    @Test func generatedImagesParseAsImagesIncludingSpecialPathCharacters() throws {
        let urls = [URL(fileURLWithPath: "/tmp/image (1).png"), URL(fileURLWithPath: "/tmp/second image.png")]
        let markdown = urls.map(ImageComposerRequestBuilder.generatedImageMarkdown).joined(separator: "\n\n")
        let blocks = parseBlocks(markdown)
        #expect(blocks.count == 2)
        for (block, expected) in zip(blocks, urls) {
            guard case .image(let url, _) = block.kind else {
                Issue.record("Generated output was not parsed as an image: \(block.kind)")
                continue
            }
            #expect(URL(string: url)?.path == expected.path)
        }
    }
}
