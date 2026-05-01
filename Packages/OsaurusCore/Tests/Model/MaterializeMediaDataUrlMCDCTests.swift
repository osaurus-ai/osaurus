// Copyright © 2026 osaurus.
//
// MC/DC tests for `ModelRuntime.materializeMediaDataUrl` (private,
// exercised through `ModelRuntime.mapOpenAIChatToMLX` from the public
// API surface — same observable behavior as direct call).
//
// Decision tree:
//
//   D1: urlString.hasPrefix("data:")        → false → return nil
//   D2: commaIndex = firstIndex(of: ",")    → nil   → return nil
//   D3: bytes = Data(base64Encoded: payload) → nil  → return nil
//   D4: header.firstIndex(of: "/")          → false → ext stays defaultExtension
//   D5: afterSlash.firstIndex(of: ";")      → false → ext = afterSlash
//   D6: header.lowercased().hasPrefix("audio/")  ← AUDIT FIX guard
//                                           → true → run canonicalization switch
//
// MC/DC focus rows:
//
//   * D1=F  → nil (non-data URL)
//   * D2=F  → nil (data: prefix but no comma)
//   * D3=F  → nil (well-formed envelope but invalid base64)
//   * D6=T  with ext=mp4 → file ext "m4a" (audio canonicalization fires)
//   * D6=F  with ext=mp4 → file ext "mp4" (video bypasses canonicalization)
//          ← THIS IS THE BUG-FIX REGRESSION ROW
//
// We exercise the function through `mapOpenAIChatToMLX` so the test
// stays at the public API boundary. Private helpers stay private.

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("materializeMediaDataUrl — MC/DC coverage (via mapOpenAIChatToMLX)")
struct MaterializeMediaDataUrlMCDCTests {

    // MARK: - Helper: build a single ChatMessage with a media data URL

    private func mappedURL(forVideoDataURL urlString: String) -> URL? {
        let json = """
            [{"role": "user", "content": [
              {"type": "video_url", "video_url": {"url": "\(urlString)"}}
            ]}]
            """.data(using: .utf8)!
        let msgs = try! JSONDecoder().decode([ChatMessage].self, from: json)
        let mapped = ModelRuntime.mapOpenAIChatToMLX(msgs)
        guard let video = mapped.first?.videos.first,
            case .url(let u) = video
        else { return nil }
        return u
    }

    private func mappedURL(forAudioFormat format: String, base64: String) -> URL? {
        let json = """
            [{"role": "user", "content": [
              {"type": "input_audio", "input_audio": {"data": "\(base64)", "format": "\(format)"}}
            ]}]
            """.data(using: .utf8)!
        let msgs = try! JSONDecoder().decode([ChatMessage].self, from: json)
        let mapped = ModelRuntime.mapOpenAIChatToMLX(msgs)
        guard let audio = mapped.first?.audios.first,
            case .url(let u) = audio
        else { return nil }
        return u
    }

    // MARK: - D1: data: prefix guard

    @Test("D1 F: non-data: URL falls through to .url(URL) without materialization")
    func d1_nonDataUrl_doesNotMaterialize() {
        // Video path with https URL — should NOT touch materializeMediaDataUrl
        // and instead pass through as URL(string:). Locks D1=F path.
        let url = mappedURL(forVideoDataURL: "https://example.com/clip.mp4")
        #expect(url?.absoluteString == "https://example.com/clip.mp4")
        #expect(url?.scheme == "https", "should NOT be a temp file://")
    }

    @Test("D1 T: data: URL goes through materialization to file://")
    func d1_dataUrl_materializesToTempFile() {
        let payload = Data([0x00, 0x01, 0x02, 0x03])
        let b64 = payload.base64EncodedString()
        let url = mappedURL(forVideoDataURL: "data:video/mp4;base64,\(b64)")
        #expect(url?.scheme == "file", "should be a temp file://")
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - D2: comma-index guard

    @Test("D2 F: data: URL without comma → nil → no source materializes")
    func d2_noComma_returnsNil() {
        // Malformed: data: prefix but no payload separator. Result: the
        // private function returns nil, so the video sources array stays
        // empty (mappedURL returns nil because there's no .url() entry).
        let url = mappedURL(forVideoDataURL: "data:video/mp4base64xxx")
        #expect(url == nil, "malformed data URL must not produce a file")
    }

    // MARK: - D3: base64 decode guard

    @Test("D3 F: data: URL with invalid base64 payload → nil")
    func d3_invalidBase64_returnsNil() {
        // `Data(base64Encoded:)` returns nil for non-base64 chars or
        // bad padding. "@@@" contains no valid b64 chars at all.
        let url = mappedURL(forVideoDataURL: "data:video/mp4;base64,@@@@")
        #expect(url == nil, "invalid base64 must not produce a file")
    }

    // MARK: - D6: audio mediatype gate (AUDIT FIX REGRESSION ROW)
    //
    // This is the critical regression row. Before the audit fix
    // (commit 44e12b94), the canonicalization switch ran unconditionally
    // and `mp4 → m4a` fired for video data URLs too, downgrading
    // .mp4 video to .m4a extension.

    @Test("D6 F (video/mp4): extension stays .mp4, NOT downgraded to .m4a")
    func d6_videoMp4_keepsMp4Extension() {
        // CRITICAL: this is the audit-fix regression test. Previously
        // the canonicalization table mapped mp4 → m4a unconditionally,
        // which broke when called from the video path.
        let payload = Data(repeating: 0xAB, count: 16)
        let b64 = payload.base64EncodedString()
        let url = mappedURL(forVideoDataURL: "data:video/mp4;base64,\(b64)")
        #expect(
            url?.pathExtension == "mp4",
            "video/mp4 must keep .mp4 — was incorrectly .m4a before audit fix"
        )
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    @Test("D6 T (audio/mp4): canonicalizes to .m4a (audio path keeps fix's intent)")
    func d6_audioMp4_canonicalizesToM4a() {
        // Audio path with format=mp4 → wraps as data:audio/mp4 → D6=T
        // → canonicalization fires → ext becomes .m4a.
        let payload = Data(repeating: 0xCD, count: 16)
        let b64 = payload.base64EncodedString()
        let url = mappedURL(forAudioFormat: "mp4", base64: b64)
        #expect(
            url?.pathExtension == "m4a",
            "audio with format=mp4 must canonicalize to .m4a for AVAudioConverter"
        )
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Audio canonicalization switch arms (each independently flips ext)

    @Test("Audio switch arm: x-wav → wav")
    func switch_xWav() {
        let b64 = Data([0x00]).base64EncodedString()
        // Synthesize a data URL header that header-parses to "x-wav"
        // We can only feed audio path through the public API since
        // the private function isn't exposed. The audio path goes
        // through `format` → `data:audio/<format>`. For x-wav we use
        // format="x-wav" — the audio extractor will build "data:audio/x-wav".
        let url = mappedURL(forAudioFormat: "x-wav", base64: b64)
        #expect(url?.pathExtension == "wav")
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    @Test("Audio switch arm: mpeg → mp3")
    func switch_mpeg() {
        let b64 = Data([0x00]).base64EncodedString()
        let url = mappedURL(forAudioFormat: "mpeg", base64: b64)
        #expect(url?.pathExtension == "mp3")
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    @Test("Audio switch arm: x-m4a → m4a")
    func switch_xM4a() {
        let b64 = Data([0x00]).base64EncodedString()
        let url = mappedURL(forAudioFormat: "x-m4a", base64: b64)
        #expect(url?.pathExtension == "m4a")
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    @Test("Audio switch default arm: wav stays wav (no remap)")
    func switch_default_wav() {
        let b64 = Data([0x00]).base64EncodedString()
        let url = mappedURL(forAudioFormat: "wav", base64: b64)
        #expect(url?.pathExtension == "wav", "wav already canonical, default arm")
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    @Test("Audio switch default arm: flac → flac (uncovered by switch)")
    func switch_default_flac() {
        let b64 = Data([0x00]).base64EncodedString()
        let url = mappedURL(forAudioFormat: "flac", base64: b64)
        #expect(url?.pathExtension == "flac", "flac not in switch → default-arm passthrough")
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
