//
//  ListingExampleBuilderTests.swift
//  osaurus
//
//  Example runs for a store listing: what a run or a conversation
//  becomes before the publisher sees it (and before anything leaves the
//  Mac), images re-encoded without their metadata, and the small rules
//  around topics and listing details.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OsaurusCore

@Suite
struct ListingExampleBuilderTests {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static func run(
        status: WorkflowRunStatus, input: JSONValue, output: JSONValue? = nil, error: String? = nil,
        artifacts: [WorkflowArtifact] = []
    ) -> WorkflowRun {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Cover Maker", templateID: UUID(), templateVersion: 3,
            caller: WorkflowCaller(kind: .test), input: input, nodeIDs: [], startedAt: started)
        run.status = status
        run.output = output
        run.error = error.map { WorkflowRunError(reason: $0) }
        run.artifacts = artifacts
        run.finishedAt = started.addingTimeInterval(4.2)
        return run
    }

    @Test
    func aRunLosesItsSecretsAndPathsButKeepsWhatItDid() {
        let token = "sk9f2c81d0a7b6e5f4c3d2e1f0a9b8c7"
        let run = Self.run(
            status: .completed,
            input: .object([
                "email": .string("Hi, I'd like a refund"),
                "api_key": .string("hunter2"),
                "folder": .string("\(Self.home)/Documents/Clients"),
                "auth": .string(token),
            ]),
            output: .object(["reply": .string("Saved to \(Self.home)/Desktop/reply.txt with Bearer \(token)")]),
            artifacts: (0 ..< 8).map {
                WorkflowArtifact(
                    source: .generated, filename: "cover-\($0).png", mimeType: "image/png", path: "/tmp/cover-\($0).png")
            } + [WorkflowArtifact(source: .output, filename: "notes.txt", path: "/tmp/notes.txt")])

        let draft = ListingExampleBuilder.draft(from: run, secretKeys: ["api_key"])

        guard case .object(let input) = draft.input, case .object(let output) = draft.output else {
            Issue.record("expected objects")
            return
        }
        #expect(input["api_key"] == nil, "secret inputs never leave")
        #expect(input["email"] == .string("Hi, I'd like a refund"))
        #expect(input["folder"] == .string("~/Documents/Clients"))
        #expect(input["auth"] == .string(TemplateExportSanitizer.redacted))
        #expect(output["reply"] == .string("Saved to ~/Desktop/reply.txt with Bearer YOUR_KEY"))
        #expect(draft.status == .succeeded && draft.error == nil)
        #expect(draft.templateVersion == 3)
        #expect(draft.durationMs == 4200)
        #expect(draft.title == "Hi, I'd like a refund")
        #expect(draft.images.count == 8, "only images; the text file stays out")
        #expect(draft.includedImages.count == ListingEdits.maxImagesPerExample)
        #expect(draft.isNew)
    }

    @Test
    func aFailedRunShowsItsErrorAndNoResult() {
        let run = Self.run(
            status: .failed, input: .object(["path": .string("/Volumes/Work/secret.pdf")]),
            output: .object(["partial": .bool(true)]), error: "Couldn't open \(Self.home)/Work/secret.pdf")
        let draft = ListingExampleBuilder.draft(from: run, secretKeys: [])
        #expect(draft.status == .failed)
        #expect(draft.output == nil)
        #expect(draft.error == "Couldn't open ~/Work/secret.pdf")
        #expect(draft.input == .object(["path": .string("secret.pdf")]), "other volumes keep only the file name")
    }

    @Test
    func aConversationIsItsFirstRequestAndTheReplyBeforeTheNext() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let image = SharedArtifact(
            contextId: "c", contextType: .chat, filename: "chart.png", mimeType: "image/png", fileSize: 10,
            hostPath: "\(Self.home)/.osaurus/artifacts/chart.png")
        let session = ChatSessionData(
            turns: [
                ChatTurnData(role: .user, content: "Plot my sales\nfor March", createdAt: start),
                ChatTurnData(role: .assistant, content: "Working on it", sharedArtifacts: [image]),
                ChatTurnData(role: .tool, content: "{}"),
                ChatTurnData(
                    role: .assistant, content: "Here's the chart.", sharedArtifacts: [image],
                    completedAt: start.addingTimeInterval(12)),
                ChatTurnData(role: .user, content: "Now April"),
                ChatTurnData(role: .assistant, content: "April chart."),
            ])
        let draft = try #require(ListingExampleBuilder.draft(fromChat: session, templateVersion: 2))
        #expect(draft.input == .string("Plot my sales\nfor March"))
        #expect(draft.output == .string("Here's the chart."))
        #expect(draft.title == "Plot my sales")
        #expect(draft.images.map(\.filename) == ["chart.png"], "one image, shared twice")
        #expect(draft.durationMs == 12_000)
        #expect(draft.templateVersion == 2)

        let unanswered = ChatSessionData(turns: [ChatTurnData(role: .user, content: "Hello?")])
        #expect(ListingExampleBuilder.draft(fromChat: unanswered, templateVersion: 1) == nil)
    }

    @Test
    func anOversizedPayloadIsCutToFitTheRegistry() {
        let long = String(repeating: "word ", count: 20_000)
        let fitted = ListingExampleBuilder.fitted(.object(["text": .string(long), "n": .number(1)]))
        #expect(ListingExampleBuilder.encodedSize(fitted) <= ListingExampleBuilder.maxPayloadBytes)
        guard case .object(let o) = fitted, case .string(let text) = o["text"] else {
            Issue.record("expected the object, trimmed")
            return
        }
        #expect(text.count == ListingExampleBuilder.trimmedStringLength + 1)
        #expect(o["n"] == .number(1))

        let many = JSONValue.array((0 ..< 2000).map { .object(["k\($0)": .string(String(repeating: "x", count: 1500))]) })
        #expect(ListingExampleBuilder.fitted(many) == .string("Too large to show here."))
    }

    @Test
    func anExampleUploadsWithATitleAndOnlyItsUploadedImages() {
        var draft = ListingExampleBuilder.draft(
            from: Self.run(status: .completed, input: .null, output: .string("ok")), secretKeys: [])
        draft.title = "   \n"
        let image = ListingExample.Image(path: "id/abc.png", mime: "image/png", size: 3, width: 1, height: 1)
        let upload = ListingExampleBuilder.upload(draft, images: [image], index: 1)
        #expect(upload.title == "Example 2")
        #expect(upload.images.map(\.path) == ["id/abc.png"])
        #expect(upload.output == .string("ok"))
    }

    // MARK: - Images

    private static func jpegWithLocation(width: Int, height: Int) throws -> URL {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("listing-\(UUID().uuidString).jpg")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private static func properties(_ data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }
        return props
    }

    @Test
    func anImageIsReencodedWithoutItsLocationAndCameraAndMadeSmall() throws {
        let url = try Self.jpegWithLocation(width: 3000, height: 1500)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Self.properties(try Data(contentsOf: url))
        #expect(original[kCGImagePropertyGPSDictionary] != nil, "the fixture carries a location")

        let encoded = try ListingImageEncoder.encode(contentsOf: url)
        #expect(encoded.width == 2048 && encoded.height == 1024)
        #expect(encoded.data.count <= WorkflowsRegistryAPIClient.maxImageBytes)
        #expect(["image/png", "image/jpeg"].contains(encoded.mime))
        let props = Self.properties(encoded.data)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil)
        #expect((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] == nil)
    }

    @Test
    func anImageThatCantBeMadeSmallEnoughOrReadIsRefused() throws {
        let url = try Self.jpegWithLocation(width: 400, height: 400)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ListingImageEncoder.Failure.tooLarge) {
            try ListingImageEncoder.encode(contentsOf: url, maxBytes: 64)
        }
        #expect(throws: ListingImageEncoder.Failure.unreadable) {
            try ListingImageEncoder.encode(data: Data("not an image".utf8))
        }
    }

    // MARK: - Topics and details

    @Test
    func topicsKeepTheRegistrysOrderAndCap() {
        #expect(
            ListingTopic.normalized(["fun", "Writing", "nope", "coding", "data"]) == [.writing, .coding, .data])
        #expect(ListingTopic.normalized([]) == [])
    }

    @Test
    func detailsChangeOnlyWhenTheyDiffer_andGoBackWithAReset() {
        let template = (name: "Cover Maker", summary: "Makes covers.")
        #expect(
            ListingEdits.details(
                name: "Cover Maker", summary: "Makes covers.", template: template, shown: template, edited: false)
                == nil)
        #expect(
            ListingEdits.details(
                name: " Covers, Fast ", summary: "Makes covers.", template: template, shown: template, edited: false)
                == .set(name: "Covers, Fast", summary: "Makes covers."))
        let shown = (name: "Covers, Fast", summary: "Makes covers.")
        #expect(
            ListingEdits.details(name: "Covers, Fast", summary: "Makes covers.", template: template, shown: shown, edited: true)
                == nil)
        #expect(
            ListingEdits.details(name: "Cover Maker", summary: "Makes covers.", template: template, shown: shown, edited: true)
                == .reset)
        #expect(!ListingEdits.isValid(name: "  ", summary: ""))
        #expect(!ListingEdits.isValid(name: "Two\nlines", summary: ""))
        #expect(!ListingEdits.isValid(name: "Ok", summary: String(repeating: "x", count: 2001)))
        #expect(ListingEdits.isValid(name: "Ok", summary: ""))
    }

    @Test
    func aRetryOnlySendsWhatFailed() {
        let edits = ListingEdits(details: .reset, topics: [.fun], examples: [])
        var result = ListingEditsResult()
        result.topicsError = "nope"
        let again = edits.failed(in: result)
        #expect(again.details == nil && again.examples == nil)
        #expect(again.topics == [.fun])
    }
}
