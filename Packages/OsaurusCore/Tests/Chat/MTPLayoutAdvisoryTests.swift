//
//  MTPLayoutAdvisoryTests.swift
//  OsaurusCoreTests
//
//  Pins the detector against real bundle layouts: the final Flash-Next JANG
//  contract must stay silent, each superseded layout must be flagged with
//  the right severity, and nothing outside the qwen4_exp + jang_config
//  family may ever trigger — a 27B (qwen3_5) with the identical stray files
//  is out of scope by definition, not by luck.
//

import XCTest

@testable import OsaurusCore

final class MTPLayoutAdvisoryTests: XCTestCase {

    private var bundleDir: URL!

    override func setUpWithError() throws {
        bundleDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mtp-layout-advisory-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let bundleDir {
            try? FileManager.default.removeItem(at: bundleDir)
        }
    }

    // MARK: - Fixture helpers

    private func write(_ name: String, json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: bundleDir.appendingPathComponent(name))
    }

    private func touch(_ relativePath: String) throws {
        let url = bundleDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    /// The proper final layout: model shards + index, jang_config sidecar,
    /// eligible stamp whose draft artifact EXISTS in `mtp_draft/`.
    private func writeProperFinalLayout() throws {
        try write("config.json", json: ["model_type": "qwen4_exp"])
        try write("jang_config.json", json: ["weight_format": "mxtq"])
        try touch("model-00001-of-00002.safetensors")
        try touch("model-00002-of-00002.safetensors")
        try write(
            "model.safetensors.index.json",
            json: [
                "weight_map": [
                    "model.layers.0.mlp.w": "model-00001-of-00002.safetensors",
                    "mtp.layers.0.mlp.w": "model-00002-of-00002.safetensors",
                ]
            ])
        try touch("mtp_draft/vmlx_mtp_proposal_head.safetensors")
        try write(
            "vmlx_mtp_proposal_head.json",
            json: [
                "eligible": true,
                "draft_artifact": [
                    "file": "mtp_draft/vmlx_mtp_proposal_head.safetensors"
                ],
            ])
    }

    private func evaluate() -> MTPLayoutAdvisory? {
        MTPLayoutAdvisory.evaluate(bundleDirectory: bundleDir)
    }

    // MARK: - The proper layout stays silent

    /// The final contract — including the mtp_draft/ SUBFOLDER sidecar,
    /// which is correct and must never be mistaken for a stray tensor file.
    func testProperFinalLayoutIsSilent() throws {
        try writeProperFinalLayout()
        XCTAssertNil(evaluate())
    }

    /// A JANG bundle with no MTP anywhere is simply a bundle without MTP —
    /// nothing to advise about.
    func testJANGBundleWithoutAnyMTPFilesIsSilent() throws {
        try write("config.json", json: ["model_type": "qwen4_exp"])
        try write("jang_config.json", json: [:])
        try touch("model.safetensors")
        XCTAssertNil(evaluate())
    }

    // MARK: - Case 1: withdrawn dedicated shard / index

    func testWithdrawnDedicatedMTPShardIsBrokenLayout() throws {
        try writeProperFinalLayout()
        try touch("mtp-00001-of-00001.safetensors")
        let advisory = try XCTUnwrap(evaluate())
        XCTAssertEqual(advisory.severity, .brokenLayout)
        XCTAssertTrue(advisory.findings.contains(.withdrawnMTPShard))
        // The specific finding owns the file; the generic stray-file sweep
        // must not double-report it.
        XCTAssertFalse(advisory.findings.contains(.strayRootTensorFile))
    }

    func testWithdrawnMTPIndexIsBrokenLayout() throws {
        try writeProperFinalLayout()
        try write("mtp.safetensors.index.json", json: ["weight_map": [:]])
        let advisory = try XCTUnwrap(evaluate())
        XCTAssertEqual(advisory.severity, .brokenLayout)
        XCTAssertTrue(advisory.findings.contains(.withdrawnMTPIndex))
    }

    // MARK: - Case 2: broken model index

    /// An `mtp.*` weight mapped to a shard that is not in the bundle: the
    /// load WILL fail, which is the strongest reason to re-download.
    func testIndexMappingMTPWeightToMissingFileIsBrokenLayout() throws {
        try writeProperFinalLayout()
        try write(
            "model.safetensors.index.json",
            json: [
                "weight_map": [
                    "model.layers.0.mlp.w": "model-00001-of-00002.safetensors",
                    "mtp.layers.0.mlp.w": "mtp-00001-of-00001.safetensors",
                ]
            ])
        // Note: the mtp shard file itself is NOT created.
        let advisory = try XCTUnwrap(evaluate())
        XCTAssertEqual(advisory.severity, .brokenLayout)
        XCTAssertTrue(advisory.findings.contains(.brokenIndexEntry))
    }

    /// A broken NON-mtp index entry is a different disease (incomplete
    /// download, handled elsewhere) — this detector only owns the MTP
    /// layout migration.
    func testBrokenNonMTPIndexEntryIsOutOfScope() throws {
        try writeProperFinalLayout()
        try write(
            "model.safetensors.index.json",
            json: [
                "weight_map": [
                    "model.layers.0.mlp.w": "model-00099-of-00099.safetensors"
                ]
            ])
        XCTAssertNil(evaluate())
    }

    // MARK: - Case 3: stray root-level tensor files

    /// The interim layout parked the proposal head at the bundle ROOT; the
    /// final contract keeps the root clean of everything but model shards.
    func testStrayRootProposalHeadTensorIsBrokenLayout() throws {
        try writeProperFinalLayout()
        try touch("vmlx_mtp_proposal_head.safetensors")
        let advisory = try XCTUnwrap(evaluate())
        XCTAssertEqual(advisory.severity, .brokenLayout)
        XCTAssertTrue(advisory.findings.contains(.strayRootTensorFile))
    }

    /// Single-file bundles name their weights `model.safetensors` with no
    /// shard counter — that is a model shard, not a stray.
    func testSingleFileModelSafetensorsIsNotAStray() throws {
        try write("config.json", json: ["model_type": "qwen4_exp"])
        try write("jang_config.json", json: [:])
        try touch("model.safetensors")
        try touch("mtp_draft/vmlx_mtp_proposal_head.safetensors")
        XCTAssertNil(evaluate())
    }

    // MARK: - Case 4: calibrated draft promised but missing

    func testEligibleStampWithMissingDraftArtifactIsDegradedOnly() throws {
        try writeProperFinalLayout()
        try FileManager.default.removeItem(
            at: bundleDir.appendingPathComponent(
                "mtp_draft/vmlx_mtp_proposal_head.safetensors"))
        let advisory = try XCTUnwrap(evaluate())
        XCTAssertEqual(advisory.severity, .missingCalibratedDraft)
        XCTAssertEqual(advisory.findings, [.missingCalibratedDraft])
    }

    /// An INELIGIBLE stamp promises nothing; a missing artifact under it is
    /// the expected state, not a defect.
    func testIneligibleStampWithMissingArtifactIsSilent() throws {
        try writeProperFinalLayout()
        try FileManager.default.removeItem(
            at: bundleDir.appendingPathComponent(
                "mtp_draft/vmlx_mtp_proposal_head.safetensors"))
        try write(
            "vmlx_mtp_proposal_head.json",
            json: [
                "eligible": false,
                "draft_artifact": [
                    "file": "mtp_draft/vmlx_mtp_proposal_head.safetensors"
                ],
            ])
        XCTAssertNil(evaluate())
    }

    /// Broken layout WINS over degraded when both are present: the text has
    /// to describe the worst consequence.
    func testBrokenLayoutOutranksMissingDraft() throws {
        try writeProperFinalLayout()
        try FileManager.default.removeItem(
            at: bundleDir.appendingPathComponent(
                "mtp_draft/vmlx_mtp_proposal_head.safetensors"))
        try touch("mtp-00001-of-00001.safetensors")
        let advisory = try XCTUnwrap(evaluate())
        XCTAssertEqual(advisory.severity, .brokenLayout)
        XCTAssertTrue(advisory.findings.contains(.missingCalibratedDraft))
    }

    // MARK: - Scope: exactly the Flash-Next JANG family

    /// The 27B family is qwen3_5. The SAME stray files must not trigger —
    /// scope is a property of the family, not of the filenames.
    func testQwen35BundleWithIdenticalStrayFilesIsSilent() throws {
        try write("config.json", json: ["model_type": "qwen3_5"])
        try write("jang_config.json", json: ["weight_format": "mxtq"])
        try touch("model.safetensors")
        try touch("mtp-00001-of-00001.safetensors")
        try touch("vmlx_mtp_proposal_head.safetensors")
        XCTAssertNil(evaluate())
    }

    /// qwen4_exp WITHOUT a jang_config (raw HF bundle) is outside the JANG
    /// family and out of scope.
    func testQwen4ExpWithoutJangConfigIsSilent() throws {
        try write("config.json", json: ["model_type": "qwen4_exp"])
        try touch("model.safetensors")
        try touch("mtp-00001-of-00001.safetensors")
        XCTAssertNil(evaluate())
    }

    /// An embedded `jang_config` key inside config.json marks the family
    /// even with no jang_config.json sidecar.
    func testEmbeddedJangConfigKeyMarksTheFamily() throws {
        try write(
            "config.json",
            json: ["model_type": "qwen4_exp", "jang_config": ["v": 2]])
        try touch("model.safetensors")
        try touch("mtp-00001-of-00001.safetensors")
        let advisory = try XCTUnwrap(evaluate())
        XCTAssertEqual(advisory.severity, .brokenLayout)
    }

    /// No config.json — not a readable bundle; nothing to advise about.
    func testMissingConfigJSONIsSilent() throws {
        try touch("mtp-00001-of-00001.safetensors")
        XCTAssertNil(evaluate())
    }

    func testUnparseableConfigJSONIsSilent() throws {
        try Data("not json{{".utf8).write(
            to: bundleDir.appendingPathComponent("config.json"))
        try touch("mtp-00001-of-00001.safetensors")
        XCTAssertNil(evaluate())
    }

    // MARK: - Fingerprint

    /// Same bundle, same improper state → same fingerprint (a dismissal
    /// survives relaunch); a different improper state re-arms the notice.
    func testFingerprintIsStableForAStateAndChangesWithIt() throws {
        try writeProperFinalLayout()
        try touch("mtp-00001-of-00001.safetensors")
        let first = try XCTUnwrap(evaluate())
        let again = try XCTUnwrap(evaluate())
        XCTAssertEqual(first.fingerprint, again.fingerprint)

        try write("mtp.safetensors.index.json", json: ["weight_map": [:]])
        let changed = try XCTUnwrap(evaluate())
        XCTAssertNotEqual(first.fingerprint, changed.fingerprint)
    }

    func testDismissalRoundTripsThroughItsStore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "mtp-advisory-tests"))
        defaults.removePersistentDomain(forName: "mtp-advisory-tests")
        XCTAssertFalse(
            MTPLayoutAdvisoryDismissals.isDismissed("a#b", defaults: defaults))
        MTPLayoutAdvisoryDismissals.recordDismissal("a#b", defaults: defaults)
        XCTAssertTrue(
            MTPLayoutAdvisoryDismissals.isDismissed("a#b", defaults: defaults))
        XCTAssertFalse(
            MTPLayoutAdvisoryDismissals.isDismissed("a#c", defaults: defaults))
        defaults.removePersistentDomain(forName: "mtp-advisory-tests")
    }

    // MARK: - Copy

    /// The text must name the fix, the superseded copy, and the re-download
    /// action — and never claim the model is unusable.
    func testCopyNamesTheFixAndTheAction() throws {
        try writeProperFinalLayout()
        try touch("mtp-00001-of-00001.safetensors")
        let broken = try XCTUnwrap(evaluate())
        XCTAssertTrue(broken.warningText.contains("Qwen 3.8 Flash-Next (JANG)"))
        XCTAssertTrue(broken.warningText.contains("superseded bundle layout"))
        XCTAssertTrue(broken.warningText.contains("Re-download"))
        XCTAssertTrue(broken.reassuranceText.contains("keep using"))

        try FileManager.default.removeItem(
            at: bundleDir.appendingPathComponent("mtp-00001-of-00001.safetensors"))
        try FileManager.default.removeItem(
            at: bundleDir.appendingPathComponent(
                "mtp_draft/vmlx_mtp_proposal_head.safetensors"))
        let degraded = try XCTUnwrap(evaluate())
        XCTAssertTrue(degraded.warningText.contains("calibrated MTP draft head"))
        XCTAssertTrue(degraded.warningText.contains("Re-download"))
        XCTAssertTrue(degraded.reassuranceText.contains("keep using"))
    }
}
