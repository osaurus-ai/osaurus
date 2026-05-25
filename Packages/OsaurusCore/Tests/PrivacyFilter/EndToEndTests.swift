//
//  EndToEndTests.swift
//  osaurusTests
//
//  Gated end-to-end suite that loads the actual on-device classifier
//  bundle when `PRIVACY_FILTER_MODEL_DIR` is set in the environment.
//  CI without the bundle skips the entire suite cleanly — these tests
//  are an integration check, not a build-block.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PrivacyFilter End-to-End", .enabled(if: ProcessInfo.processInfo.environment["PRIVACY_FILTER_MODEL_DIR"] != nil))
struct EndToEndTests {

    /// Loads the model bundle and runs a deterministic probe sentence
    /// through detection. The forward pass must execute without
    /// throwing AND produce at least one entity for a sentence that
    /// contains a name, phone number, and email. Useful when
    /// hand-verifying the MLX-Swift wiring against the Python
    /// reference (`mlx-embeddings`).
    @MainActor
    @Test func detect_findsAtLeastOneEntityInLoadedProbe() async throws {
        guard let modelDir = ProcessInfo.processInfo.environment["PRIVACY_FILTER_MODEL_DIR"] else {
            return
        }
        try await PrivacyFilterEngine.shared.loadIfNeeded(bundle: URL(fileURLWithPath: modelDir))

        let map = RedactionMap(conversationID: UUID())
        let detections = try await PrivacyFilterEngine.shared.detect(
            in: "Alice Anderson called from 415-555-9876 about her account 1234-5678.",
            map: map,
            skipCodeBlocks: true
        )
        // Anything > 0 means the trained head produced a usable signal
        // for at least one of the obvious PII spans in the probe. If
        // the forward pass is silently wrong we expect either zero
        // detections (uniform logits) or a runtime throw — both fail
        // this assertion.
        #expect(detections.count > 0)
    }
}
