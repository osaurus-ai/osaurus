import AppKit
import Foundation
import Testing
@testable import OsaurusCore

/// #3021: a Qwen3.5 bundle with vision weights but no processor config cannot
/// take images. The app knew why (bundle evidence) but the composer said only
/// "not advertised", and a pasted image vanished without any message.
@Suite("Vision unavailable reason reaches the user", .serialized)
struct VisionUnavailableReasonTests {
    @Test func missingProcessorConfigIsTheStatedReason() throws {
        let root = try VisionBundleFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("processor_config.json"))
        let evidence = LocalVisionEvidence.inspect(root, refresh: true)
        #expect(!evidence.hasVision)
        #expect(evidence.reason.contains("preprocessor_config.json"))
    }

    @Test func composerRejectionCarriesTheBundleReason() {
        let reason = "The installed bundle has vision settings but no readable processor configuration."
        let descriptor = ModelMediaCapabilities.composerDescriptor(
            modelId: "community/qwen3.5-noprocessor",
            fallbackSupportsImages: false,
            localModelType: "qwen3_5",
            localCapabilities: .init(supportsImage: false, supportsVideo: false, supportsAudio: false),
            localImageEvidenceReason: reason
        )
        #expect(descriptor.image.reason == reason)
        #expect(descriptor.rejectionMessage(for: .image).hasPrefix(reason))
    }

    @Test func supportedImagesKeepTheirReason() {
        let descriptor = ModelMediaCapabilities.composerDescriptor(
            modelId: "community/qwen3.5-vl",
            fallbackSupportsImages: false,
            localModelType: "qwen3_5",
            localCapabilities: .init(supportsImage: true, supportsVideo: false, supportsAudio: false),
            localImageEvidenceReason: "irrelevant when supported"
        )
        #expect(descriptor.image.isUsable)
        #expect(descriptor.image.reason.contains("installed bundle evidence"))
    }

    @MainActor
    @Test func pasteboardImageDetection() {
        let board = NSPasteboard(name: NSPasteboard.Name("osaurus-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("just text", forType: .string)
        #expect(!PasteMonitorView.pasteboardHasImage(board))
        board.clearContents()
        board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        #expect(PasteMonitorView.pasteboardHasImage(board))
    }

    @MainActor
    @Test func imagePasteBelongsOnlyToTheFocusedComposerInItsWindow() {
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let activeText = NSTextView(frame: NSRect(x: 0, y: 0, width: 150, height: 100))
        let otherText = NSTextView(frame: NSRect(x: 160, y: 0, width: 150, height: 100))
        let monitor = PasteMonitorView()
        first.contentView?.addSubview(activeText)
        first.contentView?.addSubview(otherText)
        first.contentView?.addSubview(monitor)
        monitor.pasteTarget = { activeText }
        defer { monitor.removeFromSuperview() }
        #expect(first.makeFirstResponder(activeText))
        #expect(monitor.ownsPaste(in: first))
        #expect(!monitor.ownsPaste(in: second))
        #expect(!monitor.ownsPaste(in: nil))
        #expect(first.makeFirstResponder(otherText))
        #expect(!monitor.ownsPaste(in: first))
        monitor.pasteTarget = { nil }
        #expect(!monitor.ownsPaste(in: first))
    }

}
