// Copyright © 2026 Osaurus AI. All rights reserved.

import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("DSV4 qualification manifest", .serialized)
struct DSV4HeadCacheQualificationManifestTests {
    private struct Fixture {
        let root: URL
        let manifestURL: URL
        let data: Data
        let value: [String: Any]
        let sha256: String

        var modelDirectory: URL {
            let model = value["model"] as! [String: Any]
            return URL(fileURLWithPath: model["canonical_root"] as! String)
        }

        var appExecutable: URL {
            let artifacts = value["artifacts"] as! [String: Any]
            let app = artifacts["app_executable"] as! [String: Any]
            return URL(fileURLWithPath: app["path"] as! String)
        }

        var environment: [String: String] {
            var value = [
                DSV4HeadCacheQualificationManifestVerifier.manifestPathEnvironmentKey: manifestURL.path,
                DSV4HeadCacheQualificationManifestVerifier.manifestSHA256EnvironmentKey: sha256,
            ]
            value[DSV4HeadCacheQualificationManifestVerifier.armEnvironmentKey] = "A"
            value["VMLX_DSV4_LM_HEAD_MODE"] = "exact"
            value["VMLX_DSV4_CACHE_FP32_LM_HEAD"] = "0"
            value["VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW"] = "0"
            return value
        }
    }

    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalJSONSHA256(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return sha256(data)
    }

    private static func makeFixture(reserveTraceOutput: Bool = false) throws -> Fixture {
        let requestedRoot = packageRoot()
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("dsv4-swift-qualification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: false)
        let root = requestedRoot.resolvingSymlinksInPath()
        let script = packageRoot()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/live-proof/test-verify-dsv4-head-cache-qualification.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--emit-fixture", root.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "fixture builder failed"
            throw DSV4HeadCacheQualificationManifestVerifier.VerificationError(
                field: "test.fixture",
                reason: detail
            )
        }
        let manifestPath = try #require(
            String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let data = try Data(contentsOf: manifestURL)
        let value = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        if reserveTraceOutput {
            let rails = try #require(value["output"] as? [String: Any])
            let campaignRoot = URL(fileURLWithPath: try #require(rails["campaign_root"] as? String))
            try FileManager.default.createDirectory(
                at: campaignRoot,
                withIntermediateDirectories: false
            )
            let stem = try #require(rails["stem"] as? String)
            guard FileManager.default.createFile(atPath: stem, contents: Data()) else {
                throw DSV4HeadCacheQualificationManifestVerifier.VerificationError(
                    field: "test.fixture",
                    reason: "could not reserve base output stem"
                )
            }
        }
        return Fixture(
            root: root,
            manifestURL: manifestURL,
            data: data,
            value: value,
            sha256: sha256(data)
        )
    }

    private static func removeFixture(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private static func encoded(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    @Test("exact manifest hash fails before JSON decode")
    func hashPrecedesDecode() throws {
        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verify(
                data: Data("not-json".utf8),
                expectedSHA256: String(repeating: "0", count: 64),
                phase: .processGuard
            )
            Issue.record("invalid bytes with a wrong pin must fail")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(error.field == "expected_manifest_sha256")
        }
    }

    @Test("runtime guard is absent only when both environment bindings are absent")
    func optionalRuntimeGuardEnvironmentContract() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }
        let absent = try DSV4HeadCacheQualificationManifestVerifier.verifyProcessGuardIfQualified(
            resolvedModelDirectory: fixture.modelDirectory,
            actualExecutableURL: fixture.appExecutable,
            artifactKind: .appExecutable,
            environment: [:]
        )
        #expect(absent == nil)

        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verifyProcessGuardIfQualified(
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: [
                    DSV4HeadCacheQualificationManifestVerifier.manifestPathEnvironmentKey:
                        fixture.manifestURL.path
                ]
            )
            Issue.record("a partial qualification environment must fail")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(
                error.field
                    == DSV4HeadCacheQualificationManifestVerifier.manifestSHA256EnvironmentKey
            )
        }

        let optionalReport = try DSV4HeadCacheQualificationManifestVerifier
            .verifyProcessGuardIfQualified(
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: fixture.environment
            )
        let report = try #require(
            optionalReport
        )
        #expect(report.phase == .processGuard)
        #expect(!report.modelBytesHashed)
    }

    @Test("pre-model admission does not consume a swapped second manifest read")
    func preModelGuardUsesOneVerifiedManifestRead() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        var swappedValue = fixture.value
        var swappedModel = try #require(swappedValue["model"] as? [String: Any])
        swappedModel["id"] = "unit/swapped"
        swappedValue["model"] = swappedModel
        let swappedData = try Self.encoded(swappedValue)

        var readCount = 0
        let report = try DSV4HeadCacheQualificationManifestVerifier
            .verifyPreModelWorkIfQualifiedUsingReaderForTesting(
                modelID: "unit/dsv4",
                requestID: "ordinary-coding",
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: fixture.environment,
                manifestReader: { _ in
                    readCount += 1
                    return readCount == 1 ? fixture.data : swappedData
                }
            )

        #expect(report != nil)
        #expect(readCount == 1)
    }

    @Test("raw qualification bindings always enter the fail-closed path")
    func rawQualificationBindingsNeverBecomeNormalNoOp() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verifyProcessGuardIfQualified(
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: [
                    DSV4HeadCacheQualificationManifestVerifier.armEnvironmentKey: "invalid"
                ]
            )
            Issue.record("an invalid arm key must not become a normal-process no-op")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(
                error.field
                    == DSV4HeadCacheQualificationManifestVerifier.armEnvironmentKey
            )
        }

        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verifyProcessGuardIfQualified(
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: [
                    DSV4HeadCacheQualificationManifestVerifier.armEnvironmentKey: ""
                ]
            )
            Issue.record("an empty arm key must not become a normal-process no-op")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(
                error.field
                    == DSV4HeadCacheQualificationManifestVerifier.armEnvironmentKey
            )
        }

        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verifyProcessGuardIfQualified(
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: [
                    DSV4HeadCacheQualificationManifestVerifier.manifestPathEnvironmentKey: ""
                ]
            )
            Issue.record("an empty manifest path key must not become a normal-process no-op")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(
                error.field
                    == DSV4HeadCacheQualificationManifestVerifier.manifestPathEnvironmentKey
            )
        }

        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verifyProcessGuardIfQualified(
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: [
                    DSV4HeadCacheQualificationManifestVerifier.manifestSHA256EnvironmentKey:
                        fixture.sha256
                ]
            )
            Issue.record("a manifest hash key without a path must fail closed")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(
                error.field
                    == DSV4HeadCacheQualificationManifestVerifier.manifestPathEnvironmentKey
            )
        }

        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verifyProcessGuardIfQualified(
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: ["VMLX_DSV4_LM_HEAD_MODE": "exact"]
            )
            Issue.record("a lone vMLX control key must fail closed")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(
                error.field
                    == DSV4HeadCacheQualificationManifestVerifier.manifestPathEnvironmentKey
            )
        }
    }

    @Test("token trace raw arm-only bindings fail closed")
    func tokenTraceRawArmOnlyBindingsFailClosed() throws {
        let cases = [
            (rawArm: "invalid", reason: "must be exactly A, B, or P"),
            (rawArm: "", reason: "is required for a qualified process"),
        ]

        for testCase in cases {
            do {
                _ = try DSV4HeadCacheQualificationManifestVerifier
                    .tokenTraceConfigurationIfQualified(
                        requestID: nil,
                        resolvedModelDirectory: URL(fileURLWithPath: "/missing-model"),
                        actualExecutableURL: URL(fileURLWithPath: "/missing-executable"),
                        artifactKind: .appExecutable,
                        environment: [
                            DSV4HeadCacheQualificationManifestVerifier.armEnvironmentKey:
                                testCase.rawArm,
                        ]
                    )
                Issue.record(
                    "raw arm \(testCase.rawArm.debugDescription) must not become a no-op"
                )
            } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
                #expect(
                    error.field
                        == DSV4HeadCacheQualificationManifestVerifier.armEnvironmentKey
                )
                #expect(error.reason == testCase.reason)
            }
        }
    }

    @Test("qualification errors interpolate the bound arm and request ID")
    func qualificationErrorsUseExactBoundValues() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        var missingControl = fixture.environment
        missingControl.removeValue(forKey: "VMLX_DSV4_LM_HEAD_MODE")
        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier
                .validateProcessArmEnvironment(missingControl)
            Issue.record("a missing arm control must fail")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(error.field == "VMLX_DSV4_LM_HEAD_MODE")
            #expect(error.reason == "is required for qualification arm (A)")
        }

        var mismatchedValue = fixture.value
        var requests = try #require(mismatchedValue["requests"] as? [[String: Any]])
        let ordinaryIndex = try #require(
            requests.firstIndex { ($0["id"] as? String) == "ordinary-coding" }
        )
        requests[ordinaryIndex]["arm"] = "B"
        mismatchedValue["requests"] = requests
        let mismatchedData = try Self.encoded(mismatchedValue)
        var mismatchedEnvironment = fixture.environment
        mismatchedEnvironment[
            DSV4HeadCacheQualificationManifestVerifier.manifestSHA256EnvironmentKey
        ] = Self.sha256(mismatchedData)

        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier
                .verifyPreModelWorkIfQualifiedUsingReaderForTesting(
                    modelID: "unit/dsv4",
                    requestID: "ordinary-coding",
                    resolvedModelDirectory: fixture.modelDirectory,
                    actualExecutableURL: fixture.appExecutable,
                    artifactKind: .appExecutable,
                    environment: mismatchedEnvironment,
                    manifestReader: { _ in mismatchedData }
                )
            Issue.record("a request bound to the wrong arm must fail")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(error.field == "requests.ordinary-coding.arm")
            #expect(error.reason == "does not match process arm (A)")
        }
    }

    @Test("runtime guard binds the actual model directory and selected executable")
    func runtimePathBindingsRejectMismatches() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }
        let otherModel = fixture.root.appendingPathComponent("other-model", isDirectory: true)
        try FileManager.default.createDirectory(at: otherModel, withIntermediateDirectories: false)
        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verifyProcessGuard(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.sha256,
                resolvedModelDirectory: otherModel,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable
            )
            Issue.record("a different resolved model directory must fail")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(error.field == "runtime.resolved_model_directory")
        }

        let artifacts = try #require(fixture.value["artifacts"] as? [String: Any])
        let cli = try #require(artifacts["cli"] as? [String: Any])
        let cliURL = URL(fileURLWithPath: try #require(cli["path"] as? String))
        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verifyProcessGuard(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.sha256,
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: cliURL,
                artifactKind: .appExecutable
            )
            Issue.record("the CLI path must not satisfy the app artifact binding")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(error.field == "runtime.actual_executable")
        }
    }

    @Test("the pre-model guard binds arm, model ID, and request before load")
    func preModelGuardBindsProcess() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        let report = try DSV4HeadCacheQualificationManifestVerifier
            .verifyPreModelWorkIfQualified(
                modelID: "unit/dsv4",
                requestID: "ordinary-coding",
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: fixture.environment
            )
        #expect(report != nil)

        var wrongArm = fixture.environment
        wrongArm["VMLX_DSV4_CACHE_FP32_LM_HEAD"] = "1"
        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.validateProcessArmEnvironment(wrongArm)
            Issue.record("a mixed control set must fail")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(error.field == "VMLX_DSV4_CACHE_FP32_LM_HEAD")
        }

        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verifyPreModelWorkIfQualified(
                modelID: "unit/other",
                requestID: "ordinary-coding",
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: fixture.environment
            )
            Issue.record("a wrong model ID must fail before model work")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(error.field == "model.id")
        }
    }

    @Test("trace selector follows the verified request field and reserves unique stems")
    func traceSelectorAndCanonicalBindings() throws {
        let fixture = try Self.makeFixture(reserveTraceOutput: true)
        defer { Self.removeFixture(fixture) }
        let unload = try DSV4HeadCacheQualificationManifestVerifier.tokenTraceConfigurationIfQualified(
            requestID: "normal-unload",
            resolvedModelDirectory: fixture.modelDirectory,
            actualExecutableURL: fixture.appExecutable,
            artifactKind: .appExecutable,
            environment: fixture.environment
        )
        #expect(unload == nil)

        let optionalFirst = try DSV4HeadCacheQualificationManifestVerifier
            .tokenTraceConfigurationIfQualified(
                requestID: "ordinary-coding",
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: fixture.environment
            )
        let first = try #require(optionalFirst)
        let optionalSecond = try DSV4HeadCacheQualificationManifestVerifier
            .tokenTraceConfigurationIfQualified(
                requestID: "adapter-token-id",
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: fixture.environment
            )
        let second = try #require(optionalSecond)
        #expect(first.externalAdapterParticipation)
        #expect(first.outputStem != second.outputStem)
        #expect(FileManager.default.fileExists(atPath: first.outputStem!.deletingLastPathComponent().path))

        let model = try #require(fixture.value["model"] as? [String: Any])
        let inventory = try #require(model["inventory"] as? [String: Any])
        let tokenizers = try #require(inventory["tokenizer"] as? [[String: Any]])
        let root = try #require(model["canonical_root"] as? String)
        let tokenizerBindings: [[String: Any]] = try tokenizers.map { item in
            let path = try #require(item["path"] as? String)
            return [
                "path": String(path.dropFirst(root.count + 1)),
                "sha256": try #require(item["sha256"] as? String),
                "size": try #require(item["size"] as? NSNumber).int64Value,
            ]
        }.sorted { ($0["path"] as! String) < ($1["path"] as! String) }
        #expect(first.attestations.tokenizer == (try Self.canonicalJSONSHA256(tokenizerBindings)))

        let artifacts = try #require(fixture.value["artifacts"] as? [String: Any])
        let app = try #require(artifacts["app_executable"] as? [String: Any])
        let binaryBinding: [String: Any] = [
            "artifact_kind": "app_executable",
            "path": try #require(app["path"] as? String),
            "sha256": try #require(app["sha256"] as? String),
            "size": try #require(app["size"] as? NSNumber).int64Value,
        ]
        #expect(first.attestations.binary == (try Self.canonicalJSONSHA256(binaryBinding)))
        let modelAttestation = try #require(model["attestation"] as? [String: Any])
        #expect(first.attestations.model == (try #require(modelAttestation["sha256"] as? String)))
        let sources = try #require(fixture.value["sources"] as? [String: Any])
        let pins = try #require(fixture.value["dependency_pins"] as? [[String: Any]])
        let dependencyPin = try #require(pins.first?["revision"] as? String)
        let sourceBinding: [String: Any] = [
            "dependency_pin": dependencyPin,
            "osaurus_head": try #require(sources["head"] as? String),
            "vmlx_head": dependencyPin,
        ]
        #expect(first.attestations.source == (try Self.canonicalJSONSHA256(sourceBinding)))
        let settings = try #require(fixture.value["runtime_settings"] as? [String: Any])
        let exactSettings = try #require(settings["exact_bytes"] as? [String: Any])
        #expect(first.settingsHash == (try #require(exactSettings["sha256"] as? String)))

        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.tokenTraceConfigurationIfQualified(
                requestID: "unknown-row",
                resolvedModelDirectory: fixture.modelDirectory,
                actualExecutableURL: fixture.appExecutable,
                artifactKind: .appExecutable,
                environment: fixture.environment
            )
            Issue.record("an unknown request ID must fail")
        } catch let error as DSV4HeadCacheQualificationManifestVerifier.VerificationError {
            #expect(error.field == "token_trace.request_id")
        }
    }

    @Test("timed shadow, source support, and trace policy mismatches fail")
    func frozenSnapshotAndTracePolicyRejectMismatches() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        var shadowValue = fixture.value
        var arms = try #require(shadowValue["arms"] as? [String: Any])
        var armB = try #require(arms["B"] as? [String: Any])
        armB["shadow"] = ["declared": true, "logical_bytes": 2_118_123_520]
        arms["B"] = armB
        shadowValue["arms"] = arms
        let shadowData = try Self.encoded(shadowValue)
        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verify(
                data: shadowData,
                expectedSHA256: Self.sha256(shadowData),
                phase: .processGuard
            )
            Issue.record("timed shadow-on must fail")
        } catch is DSV4HeadCacheQualificationManifestVerifier.VerificationError {}

        var traceValue = fixture.value
        var requests = try #require(traceValue["requests"] as? [[String: Any]])
        requests[0]["trace_accepted_ids"] = false
        traceValue["requests"] = requests
        let traceData = try Self.encoded(traceValue)
        do {
            _ = try DSV4HeadCacheQualificationManifestVerifier.verify(
                data: traceData,
                expectedSHA256: Self.sha256(traceData),
                phase: .processGuard
            )
            Issue.record("a generation row with tracing off must fail")
        } catch is DSV4HeadCacheQualificationManifestVerifier.VerificationError {}
    }
}
