//
//  RemoteImagePayloadPolicyTests.swift
//  osaurus
//
//  Pins the remote-bound image sizing policy: oversized attachments shrink
//  to the wire budget as JPEG, small attachments ship byte-identical, and a
//  mislabeled container gets its data-URI mime corrected — the 413/400
//  classes reported against Google cloud models with pasted screenshots.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OsaurusCore

@Suite("Remote image payload policy")
struct RemoteImagePayloadPolicyTests {

    private func solidImage(width: Int, height: Int, as type: UTType) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Speckle so JPEG can't compress to nothing and PNG sizes are honest.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for i in stride(from: 0, to: width, by: 7) {
            context.fill(CGRect(x: i, y: (i * 13) % max(1, height), width: 3, height: 3))
        }
        let image = context.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func decodedImageInfo(_ url: String) -> (mime: String, longSide: Int, bytes: Int)? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        let mime = header.split(separator: ";").first.map(String.init) ?? ""
        guard let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (mime, max(w, h), data.count)
    }

    @Test("oversized PNG shrinks to the long-side budget as a smaller JPEG")
    func oversizedShrinks() {
        let png = solidImage(width: 4200, height: 2600, as: .png)
        let url = "data:image/png;base64," + png.base64EncodedString()

        let rewritten = RemoteImagePayloadPolicy.preparedDataURL(url)

        #expect(rewritten != url)
        let info = decodedImageInfo(rewritten)
        #expect(info != nil)
        #expect(info?.mime == "image/jpeg")
        #expect((info?.longSide ?? .max) <= RemoteImagePayloadPolicy.maxLongSidePixels)
        #expect((info?.bytes ?? .max) < png.count)
    }

    @Test("small correctly-labeled image ships byte-identical")
    func smallImageUntouched() {
        let png = solidImage(width: 640, height: 480, as: .png)
        let url = "data:image/png;base64," + png.base64EncodedString()
        #expect(RemoteImagePayloadPolicy.preparedDataURL(url) == url)
    }

    @Test("JPEG mislabeled image/png gets its mime corrected, bytes unchanged")
    func mislabeledMimeCorrected() {
        let jpeg = solidImage(width: 640, height: 480, as: .jpeg)
        let base64 = jpeg.base64EncodedString()
        let mislabeled = "data:image/png;base64," + base64

        let rewritten = RemoteImagePayloadPolicy.preparedDataURL(mislabeled)

        #expect(rewritten == "data:image/jpeg;base64," + base64)
    }

    @Test("plain https URL and garbage data URI pass through unchanged")
    func passthroughs() {
        #expect(
            RemoteImagePayloadPolicy.preparedDataURL("https://example.com/cat.png")
                == "https://example.com/cat.png")
        #expect(
            RemoteImagePayloadPolicy.preparedDataURL("data:image/png;base64,!!!notbase64!!!")
                == "data:image/png;base64,!!!notbase64!!!")
    }

    @Test("prepared() rewrites only image parts and keeps tool plumbing intact")
    func preparedPreservesMessageFields() {
        let png = solidImage(width: 4200, height: 2600, as: .png)
        let url = "data:image/png;base64," + png.base64EncodedString()
        let message = ChatMessage(
            role: "user",
            content: nil,
            contentParts: [.text("what's in this?"), .imageUrl(url: url, detail: nil)]
        )

        let out = RemoteImagePayloadPolicy.prepared([message])

        #expect(out.count == 1)
        #expect(out[0].role == "user")
        guard let parts = out[0].contentParts, parts.count == 2 else {
            Issue.record("content parts lost")
            return
        }
        if case .text(let t) = parts[0] { #expect(t == "what's in this?") } else {
            Issue.record("text part lost")
        }
        if case .imageUrl(let rewritten, _) = parts[1] {
            #expect(rewritten != url)
            #expect(decodedImageInfo(rewritten)?.mime == "image/jpeg")
        } else {
            Issue.record("image part lost")
        }
    }
}
