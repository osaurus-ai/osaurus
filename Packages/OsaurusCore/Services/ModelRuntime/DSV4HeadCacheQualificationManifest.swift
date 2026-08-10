// Copyright 2026 Osaurus AI. All rights reserved.

import CryptoKit
import Darwin
import Foundation
import MLXLMCommon

/// The manifest verifier is deliberately standalone.  The existing model
/// admission path is outside this task's ownership boundary, so callers must
/// invoke this verifier before they create a campaign or begin model work.
///
/// The verifier has two phases.  `.preCampaign` hashes every model inventory
/// file once.  `.processGuard` checks the same exact set, canonical paths,
/// identity metadata, sizes, and attestation without rehashing the model
/// shards.  This keeps a matrix position from repeatedly warming the file
/// cache for a roughly 79-shard model.
public enum DSV4HeadCacheQualificationManifestVerifier {
    public static let schemaIdentifier = "osaurus.dsv4-head-cache-qualification/1"
    public static let manifestPathEnvironmentKey = "OSAURUS_DSV4_QUALIFICATION_MANIFEST"
    public static let manifestSHA256EnvironmentKey = "OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256"
    /// The arm is a process binding, not a row label.  A qualified process
    /// must publish all three vMLX controls before the first model load.
    public static let armEnvironmentKey = "OSAURUS_DSV4_QUALIFICATION_ARM"

    public enum QualificationArm: String, CaseIterable, Sendable {
        case A
        case B
        case P

        public var environment: [String: String] {
            switch self {
            case .A:
                return [
                    "VMLX_DSV4_LM_HEAD_MODE": "exact",
                    "VMLX_DSV4_CACHE_FP32_LM_HEAD": "0",
                    "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW": "0",
                ]
            case .B:
                return [
                    "VMLX_DSV4_LM_HEAD_MODE": "exact",
                    "VMLX_DSV4_CACHE_FP32_LM_HEAD": "1",
                    "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW": "0",
                ]
            case .P:
                return [
                    "VMLX_DSV4_LM_HEAD_MODE": "qmm",
                    "VMLX_DSV4_CACHE_FP32_LM_HEAD": "0",
                    "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW": "0",
                ]
            }
        }
    }

    public enum Phase: String, Sendable {
        case preCampaign = "pre_campaign"
        case processGuard = "process"
    }

    public enum RuntimeArtifactKind: String, Sendable {
        case appExecutable = "app_executable"
        case cli
    }

    public struct VerificationReport: Sendable, Equatable {
        public let manifestSHA256: String
        public let phase: Phase
        public let campaignID: String
        public let campaignRoot: String
        public let modelEntryCount: Int
        public let modelBytesHashed: Bool
        public let modelBytesHashedCount: Int
        public let identityChecks: Int

        public init(
            manifestSHA256: String,
            phase: Phase,
            campaignID: String,
            campaignRoot: String,
            modelEntryCount: Int,
            modelBytesHashed: Bool,
            modelBytesHashedCount: Int,
            identityChecks: Int
        ) {
            self.manifestSHA256 = manifestSHA256
            self.phase = phase
            self.campaignID = campaignID
            self.campaignRoot = campaignRoot
            self.modelEntryCount = modelEntryCount
            self.modelBytesHashed = modelBytesHashed
            self.modelBytesHashedCount = modelBytesHashedCount
            self.identityChecks = identityChecks
        }
    }

    /// Values copied from a manifest only after its exact bytes and process
    /// guard have passed. The adapter consumes this value; it never parses a
    /// manifest or creates its own attestations.
    public struct VerifiedTokenTraceInputs: Sendable, Equatable {
        public let attestations: TokenIDTraceAttestations
        public let settingsHash: String
        public let outputStem: URL

        public init(
            attestations: TokenIDTraceAttestations,
            settingsHash: String,
            outputStem: URL
        ) {
            self.attestations = attestations
            self.settingsHash = settingsHash
            self.outputStem = outputStem
        }

        /// vMLX requires fresh mutable lineage state for every request.
        public func makeConfiguration() -> TokenIDTraceConfiguration {
            TokenIDTraceConfiguration(
                attestations: attestations,
                settingsHash: settingsHash,
                outputStem: outputStem,
                externalAdapterParticipation: true
            )
        }
    }

    public struct VerificationError: Error, LocalizedError, Equatable, Sendable {
        public let field: String
        public let reason: String

        public init(field: String, reason: String) {
            self.field = field
            self.reason = reason
        }

        public var errorDescription: String? {
            "\(field): \(reason)"
        }
    }

    private struct Identity: Equatable, Sendable {
        let device: Int64
        let inode: Int64
        let mtimeNanoseconds: Int64
    }

    private struct FileRecord: Equatable, Sendable {
        let path: String
        let size: Int64
        let identity: Identity?
    }

    private struct SourceRoots: Sendable {
        let repository: String
        let fixtures: String
    }

    private static let requiredSourceSuffixes = [
        "Packages/OsaurusCore/Package.swift",
        "Packages/OsaurusCore/Services/ModelRuntime.swift",
        "Packages/OsaurusCore/Services/ModelRuntime/SwiftTransformersTokenizerLoader.swift",
        "Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift",
    ]

    private static let requiredRequestKinds: Set<String> = [
        "ordinary_coding",
        "instruction",
        "tool_call",
        "refusal",
        "long_context",
        "repeated_prefix_miss",
        "repeated_prefix_hit",
        "normal_unload",
        "normal_reload",
        "adapter_token_id",
    ]

    /// Verifies a manifest file.  The file bytes are hashed before any JSON
    /// decoding takes place.  The caller should supply the value from
    /// `OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256`.
    public static func verify(
        fileAt url: URL,
        expectedSHA256: String?,
        phase: Phase = .preCampaign
    ) throws -> VerificationReport {
        let data = try readManifestData(fileAt: url)
        return try verify(data: data, expectedSHA256: expectedSHA256, phase: phase)
    }

    /// Verifies exact manifest bytes.  This overload is useful to callers that
    /// already own a sealed read and to deterministic unit tests.
    public static func verify(
        data: Data,
        expectedSHA256: String?,
        phase: Phase = .preCampaign
    ) throws -> VerificationReport {
        try verifyDecodedManifest(
            data: data,
            expectedSHA256: expectedSHA256,
            phase: phase
        ).report
    }

    private static func verifyDecodedManifest(
        data: Data,
        expectedSHA256: String?,
        phase: Phase
    ) throws -> (report: VerificationReport, root: [String: Any]) {
        let actualSHA256 = sha256(data)
        if let expectedSHA256 {
            try requireDigest(expectedSHA256, field: "expected_manifest_sha256")
            guard expectedSHA256 == actualSHA256 else {
                throw failure(
                    "expected_manifest_sha256",
                    "manifest hash mismatch; actual=\(actualSHA256)"
                )
            }
        }

        guard data.count <= 4 * 1024 * 1024 else {
            throw failure("manifest", "exceeds bounded maximum of 4194304 bytes")
        }

        let object = try decodeObject(data)

        let report = try validate(object, manifestSHA256: actualSHA256, phase: phase)
        return (report, object)
    }

    public static func verifyProcessGuard(
        fileAt url: URL,
        expectedSHA256: String,
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind
    ) throws -> VerificationReport {
        let data = try readManifestData(fileAt: url)
        return try verifyRuntimeBoundManifest(
            data: data,
            expectedSHA256: expectedSHA256,
            resolvedModelDirectory: resolvedModelDirectory,
            actualExecutableURL: actualExecutableURL,
            artifactKind: artifactKind
        ).report
    }

    /// Runtime admission seam. No qualification bindings means no guard;
    /// either binding alone is an error; both bind the actual model and binary.
    public static func verifyProcessGuardIfQualified(
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> VerificationReport? {
        try verifyProcessGuardIfQualifiedWithRoot(
            resolvedModelDirectory: resolvedModelDirectory,
            actualExecutableURL: actualExecutableURL,
            artifactKind: artifactKind,
            environment: environment,
            manifestReader: { url in try Self.readManifestData(fileAt: url) }
        )?.report
    }

    private static func verifyProcessGuardIfQualifiedWithRoot(
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind,
        environment: [String: String],
        manifestReader: (URL) throws -> Data
    ) throws -> (report: VerificationReport, root: [String: Any])? {
        let qualificationKeys = [
            manifestPathEnvironmentKey,
            manifestSHA256EnvironmentKey,
            armEnvironmentKey,
        ] + Array(QualificationArm.A.environment.keys)
        guard qualificationKeys.contains(where: { environment[$0] != nil }) else {
            return nil
        }

        let hasRawArmBinding = environment[armEnvironmentKey] != nil
        if hasRawArmBinding {
            _ = try validateProcessArmEnvironment(environment)
        }
        let manifestPath = environment[manifestPathEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        let expectedSHA256 = environment[manifestSHA256EnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        guard let manifestPath else { throw failure(manifestPathEnvironmentKey, "is required") }
        guard let expectedSHA256 else { throw failure(manifestSHA256EnvironmentKey, "is required") }
        if !hasRawArmBinding {
            _ = try validateProcessArmEnvironment(environment)
        }
        let data = try manifestReader(URL(fileURLWithPath: manifestPath))
        return try verifyRuntimeBoundManifest(
            data: data,
            expectedSHA256: expectedSHA256,
            resolvedModelDirectory: resolvedModelDirectory,
            actualExecutableURL: actualExecutableURL,
            artifactKind: artifactKind
        )
    }

    /// Pure arm/environment guard used by both the model admission path and
    /// the loopback qualification routes.  A partial control set is never
    /// interpreted as the default arm.
    @discardableResult
    public static func validateProcessArmEnvironment(
        _ environment: [String: String]
    ) throws -> QualificationArm {
        guard let rawArm = environment[armEnvironmentKey], !rawArm.isEmpty else {
            throw failure(armEnvironmentKey, "is required for a qualified process")
        }
        guard let arm = QualificationArm(rawValue: rawArm) else {
            throw failure(armEnvironmentKey, "must be exactly A, B, or P")
        }
        for key in arm.environment.keys {
            guard let actual = environment[key] else {
                throw failure(key, "is required for qualification arm (\(rawArm))")
            }
            guard actual == arm.environment[key] else {
                let expectedValue = arm.environment[key] ?? "<missing>"
                throw failure(
                    key,
                    "does not match qualification arm \(rawArm); expected \(expectedValue)"
                )
            }
        }
        return arm
    }

    /// Admission guard that must run after resolving the canonical local
    /// directory but before eviction, bundle inspection, or vMLX work.  It
    /// binds the request row and model ID in addition to the process guard.
    /// Outside a qualification process it is a no-op so normal inference keeps
    /// its existing behavior.
    public static func verifyPreModelWorkIfQualified(
        modelID: String,
        requestID: String?,
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> VerificationReport? {
        try verifyPreModelWorkIfQualified(
            modelID: modelID,
            requestID: requestID,
            resolvedModelDirectory: resolvedModelDirectory,
            actualExecutableURL: actualExecutableURL,
            artifactKind: artifactKind,
            environment: environment,
            manifestReader: { url in try Self.readManifestData(fileAt: url) }
        )
    }

    static func verifyPreModelWorkIfQualifiedUsingReaderForTesting(
        modelID: String,
        requestID: String?,
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind,
        environment: [String: String],
        manifestReader: (URL) throws -> Data
    ) throws -> VerificationReport? {
        try verifyPreModelWorkIfQualified(
            modelID: modelID,
            requestID: requestID,
            resolvedModelDirectory: resolvedModelDirectory,
            actualExecutableURL: actualExecutableURL,
            artifactKind: artifactKind,
            environment: environment,
            manifestReader: manifestReader
        )
    }

    private static func verifyPreModelWorkIfQualified(
        modelID: String,
        requestID: String?,
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind,
        environment: [String: String],
        manifestReader: (URL) throws -> Data
    ) throws -> VerificationReport? {
        let verified = try verifyProcessGuardIfQualifiedWithRoot(
            resolvedModelDirectory: resolvedModelDirectory,
            actualExecutableURL: actualExecutableURL,
            artifactKind: artifactKind,
            environment: environment,
            manifestReader: manifestReader
        )
        guard let verified else { return nil }

        guard let requestID, !requestID.isEmpty else {
            throw failure("qualification.request_id", "is required before qualified model work")
        }
        let checkedRequestID = try identifier(requestID, field: "qualification.request_id")
        let root = verified.root
        let model = try object(root["model"], field: "model")
        guard try string(model["id"], field: "model.id") == modelID else {
            throw failure("model.id", "does not match the requested model ID")
        }
        let arm = try validateProcessArmEnvironment(environment)
        let request = try manifestRequest(id: checkedRequestID, root: root)
        let requestArm = try string(request["arm"], field: "requests.\(checkedRequestID).arm")
        guard requestArm == arm.rawValue else {
            throw failure(
                "requests.\(checkedRequestID).arm",
                "does not match process arm (\(arm.rawValue))"
            )
        }
        return verified.report
    }

    /// Select tracing without making the adapter parse qualification data.
    /// Outside a qualification environment this returns nil. Inside one,
    /// missing or unknown request IDs fail closed; valid non-adapter rows stay
    /// trace-free, and the adapter-token-ID row receives one fresh config.
    public static func tokenTraceConfigurationIfQualified(
        requestID: String?,
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TokenIDTraceConfiguration? {
        let qualificationKeys = [
            manifestPathEnvironmentKey,
            manifestSHA256EnvironmentKey,
            armEnvironmentKey,
        ] + Array(QualificationArm.A.environment.keys)
        guard qualificationKeys.contains(where: { environment[$0] != nil }) else {
            return nil
        }

        let hasRawArmBinding = environment[armEnvironmentKey] != nil
        if hasRawArmBinding {
            _ = try validateProcessArmEnvironment(environment)
        }
        let manifestPath = environment[manifestPathEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        let expectedSHA256 = environment[manifestSHA256EnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        guard let manifestPath else { throw failure(manifestPathEnvironmentKey, "is required") }
        guard let expectedSHA256 else { throw failure(manifestSHA256EnvironmentKey, "is required") }
        if !hasRawArmBinding {
            _ = try validateProcessArmEnvironment(environment)
        }
        guard let requestID, !requestID.isEmpty else {
            throw failure("token_trace.request_id", "is required in an active qualification process")
        }

        let checkedRequestID = try identifier(requestID, field: "token_trace.request_id")
        let data = try readManifestData(fileAt: URL(fileURLWithPath: manifestPath))
        let verified = try verifyRuntimeBoundManifest(
            data: data,
            expectedSHA256: expectedSHA256,
            resolvedModelDirectory: resolvedModelDirectory,
            actualExecutableURL: actualExecutableURL,
            artifactKind: artifactKind
        )
        let request = try manifestRequest(
            id: checkedRequestID,
            root: verified.root
        )
        guard (request["trace_accepted_ids"] as? Bool) == true else { return nil }
        return try tokenTraceInputs(
            root: verified.root,
            requestID: checkedRequestID,
            artifactKind: artifactKind
        ).makeConfiguration()
    }

    /// Verify the exact manifest selected by the two required environment
    /// bindings, bind the actual model and binary, and reserve one unique
    /// token-trace namespace. No user-specific default path is accepted.
    public static func verifiedTokenTraceInputsFromEnvironment(
        requestID: String,
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> VerifiedTokenTraceInputs {
        guard let manifestPath = environment[manifestPathEnvironmentKey], !manifestPath.isEmpty else {
            throw failure(manifestPathEnvironmentKey, "is required")
        }
        guard let expectedSHA256 = environment[manifestSHA256EnvironmentKey], !expectedSHA256.isEmpty else {
            throw failure(manifestSHA256EnvironmentKey, "is required")
        }
        return try verifiedTokenTraceInputs(
            fileAt: URL(fileURLWithPath: manifestPath),
            expectedSHA256: expectedSHA256,
            requestID: requestID,
            resolvedModelDirectory: resolvedModelDirectory,
            actualExecutableURL: actualExecutableURL,
            artifactKind: artifactKind
        )
    }

    /// Return a fresh vMLX configuration for one verified generation request
    /// whose manifest row requires accepted-ID evidence.
    public static func verifiedTokenTraceConfigurationFromEnvironment(
        requestID: String,
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TokenIDTraceConfiguration {
        try verifiedTokenTraceInputsFromEnvironment(
            requestID: requestID,
            resolvedModelDirectory: resolvedModelDirectory,
            actualExecutableURL: actualExecutableURL,
            artifactKind: artifactKind,
            environment: environment
        ).makeConfiguration()
    }

    public static func verifiedTokenTraceInputs(
        fileAt url: URL,
        expectedSHA256: String,
        requestID: String,
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind
    ) throws -> VerifiedTokenTraceInputs {
        let checkedRequestID = try identifier(requestID, field: "token_trace.request_id")
        let data = try readManifestData(fileAt: url)
        let verified = try verifyRuntimeBoundManifest(
            data: data,
            expectedSHA256: expectedSHA256,
            resolvedModelDirectory: resolvedModelDirectory,
            actualExecutableURL: actualExecutableURL,
            artifactKind: artifactKind
        )
        let request = try manifestRequest(id: checkedRequestID, root: verified.root)
        guard (request["trace_accepted_ids"] as? Bool) == true else {
            throw failure("token_trace.request_id", "does not require accepted-ID evidence")
        }
        return try tokenTraceInputs(
            root: verified.root,
            requestID: checkedRequestID,
            artifactKind: artifactKind
        )
    }

    private static func tokenTraceInputs(
        root: [String: Any],
        requestID checkedRequestID: String,
        artifactKind: RuntimeArtifactKind
    ) throws -> VerifiedTokenTraceInputs {

        let model = try object(root["model"], field: "model")
        let attestation = try object(model["attestation"], field: "model.attestation")
        let inventory = try object(model["inventory"], field: "model.inventory")
        let modelRoot = try canonicalPath(
            model["canonical_root"],
            field: "model.canonical_root",
            mustExist: true,
            directory: true
        )
        let tokenizerItems = try array(inventory["tokenizer"], field: "model.inventory.tokenizer", minCount: 1)
        let tokenizerBindings = try tokenizerItems.enumerated().map { index, value -> [String: Any] in
            let item = try object(value, field: "model.inventory.tokenizer[\(index)]")
            let path = try canonicalPath(
                item["path"],
                field: "model.inventory.tokenizer[\(index)].path",
                mustExist: true,
                directory: false
            )
            try requireContained(path, modelRoot, field: "model.inventory.tokenizer[\(index)].path")
            let relativePath = String(path.dropFirst(modelRoot.count + 1))
            return [
                "path": relativePath,
                "sha256": try requireDigest(
                    item["sha256"],
                    field: "model.inventory.tokenizer[\(index)].sha256"
                ),
                "size": try integer(item["size"], field: "model.inventory.tokenizer[\(index)].size"),
            ]
        }.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        let tokenizerAttestation = try canonicalJSONSHA256(
            tokenizerBindings,
            field: "token_trace.tokenizer_attestation"
        )

        let artifacts = try object(root["artifacts"], field: "artifacts")
        let activeExecutable = try object(
            artifacts[artifactKind.rawValue],
            field: "artifacts.\(artifactKind.rawValue)"
        )
        let sources = try object(root["sources"], field: "sources")
        let pins = try array(root["dependency_pins"], field: "dependency_pins", minCount: 4, maxCount: 4)
        let pinRevisions = try pins.enumerated().map { index, value in
            let pin = try object(value, field: "dependency_pins[\(index)]")
            return try requireRevision(pin["revision"], field: "dependency_pins[\(index)].revision")
        }
        guard let dependencyPin = pinRevisions.first, Set(pinRevisions).count == 1 else {
            throw failure("dependency_pins", "must bind one exact vMLX revision")
        }
        let runtimeSettings = try object(root["runtime_settings"], field: "runtime_settings")
        let exactSettings = try object(runtimeSettings["exact_bytes"], field: "runtime_settings.exact_bytes")
        let output = try object(root["output"], field: "output")
        let campaignRoot = try canonicalPath(
            output["campaign_root"],
            field: "output.campaign_root",
            mustExist: true,
            directory: true
        )
        let baseStem = try canonicalPath(
            output["stem"],
            field: "output.stem",
            mustExist: true,
            directory: false
        )
        try requireContained(baseStem, campaignRoot, field: "output.stem")
        let outputStem = try reserveTokenTraceStem(baseStem: baseStem, requestID: checkedRequestID)

        return VerifiedTokenTraceInputs(
            attestations: TokenIDTraceAttestations(
                model: try requireDigest(attestation["sha256"], field: "model.attestation.sha256"),
                tokenizer: tokenizerAttestation,
                binary: try canonicalJSONSHA256(
                    [
                        "artifact_kind": artifactKind.rawValue,
                        "path": try canonicalPath(
                            activeExecutable["path"],
                            field: "artifacts.\(artifactKind.rawValue).path",
                            mustExist: true,
                            directory: false
                        ),
                        "sha256": try requireDigest(
                            activeExecutable["sha256"],
                            field: "artifacts.\(artifactKind.rawValue).sha256"
                        ),
                        "size": try integer(
                            activeExecutable["size"],
                            field: "artifacts.\(artifactKind.rawValue).size"
                        ),
                    ],
                    field: "token_trace.binary_attestation"
                ),
                source: try canonicalJSONSHA256(
                    [
                        "dependency_pin": dependencyPin,
                        "osaurus_head": try requireRevision(sources["head"], field: "sources.head"),
                        "vmlx_head": dependencyPin,
                    ],
                    field: "token_trace.source_attestation"
                )
            ),
            settingsHash: try requireDigest(exactSettings["sha256"], field: "runtime_settings.exact_bytes.sha256"),
            outputStem: outputStem
        )
    }

    private static func verifyRuntimeBoundManifest(
        data: Data,
        expectedSHA256: String,
        resolvedModelDirectory: URL,
        actualExecutableURL: URL,
        artifactKind: RuntimeArtifactKind
    ) throws -> (report: VerificationReport, root: [String: Any]) {
        let verified = try verifyDecodedManifest(
            data: data,
            expectedSHA256: expectedSHA256,
            phase: .processGuard
        )
        let report = verified.report
        let root = verified.root

        let model = try object(root["model"], field: "model")
        let expectedModelRoot = try canonicalPath(
            model["canonical_root"],
            field: "model.canonical_root",
            mustExist: true,
            directory: true
        )
        let actualModelRoot = try canonicalPath(
            resolvedModelDirectory.path,
            field: "runtime.resolved_model_directory",
            mustExist: true,
            directory: true
        )
        guard actualModelRoot == expectedModelRoot else {
            throw failure(
                "runtime.resolved_model_directory",
                "does not equal manifest.model.canonical_root"
            )
        }

        let artifacts = try object(root["artifacts"], field: "artifacts")
        let selected = try object(
            artifacts[artifactKind.rawValue],
            field: "artifacts.\(artifactKind.rawValue)"
        )
        let selectedReference: [String: Any] = [
            "path": selected["path"] as Any,
            "sha256": selected["sha256"] as Any,
            "size": selected["size"] as Any,
        ]
        let expectedExecutable = try fileReference(
            selectedReference,
            field: "artifacts.\(artifactKind.rawValue)",
            hashBytes: true
        ).path
        let actualExecutable = try canonicalPath(
            actualExecutableURL.path,
            field: "runtime.actual_executable",
            mustExist: true,
            directory: false
        )
        guard actualExecutable == expectedExecutable else {
            throw failure(
                "runtime.actual_executable",
                "does not equal the selected \(artifactKind.rawValue) artifact"
            )
        }
        return (report, root)
    }

    private static func manifestRequest(
        id: String,
        root: [String: Any]
    ) throws -> [String: Any] {
        let requests = try array(root["requests"], field: "requests")
        let request = try requests.enumerated().compactMap { index, value -> [String: Any]? in
            let item = try object(value, field: "requests[\(index)]")
            return item["id"] as? String == id ? item : nil
        }.first
        guard let request else {
            throw failure("token_trace.request_id", "does not name a manifest request")
        }
        return request
    }

    private static func readManifestData(fileAt url: URL) throws -> Data {
        let path = try canonicalPath(
            url.path,
            field: "manifest_path",
            mustExist: true,
            directory: false
        )
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        } catch {
            throw failure("manifest_path", "could not read manifest: \(error.localizedDescription)")
        }
    }

    private static func requiredEnvironment(
        _ key: String,
        in environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw failure(key, "is required")
        }
        return value
    }

    private static func decodeObject(_ data: Data) throws -> [String: Any] {
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard let dictionary = json as? [String: Any] else {
                throw failure("json", "top level must be an object")
            }
            return dictionary
        } catch let error as VerificationError {
            throw error
        } catch {
            throw failure("json", "invalid JSON: \(error.localizedDescription)")
        }
    }

    /// Hash a deliberately small JSON value with lexicographically sorted
    /// object keys and no escaped slashes. Arrays must already be in their
    /// normative order before this helper is called.
    private static func canonicalJSONSHA256(_ value: Any, field: String) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw failure(field, "cannot encode the canonical binding")
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            return sha256(data)
        } catch {
            throw failure(field, "cannot encode the canonical binding: \(error.localizedDescription)")
        }
    }

    /// Reserve an empty, private directory and put the returned vMLX stem
    /// inside it. mkdir(2) supplies the exclusive namespace reservation; a
    /// pre-existing trace artifact is a hard failure, never an overwrite.
    private static func reserveTokenTraceStem(baseStem: String, requestID: String) throws -> URL {
        let parent = URL(fileURLWithPath: baseStem).deletingLastPathComponent().path
        _ = try canonicalPath(parent, field: "output.stem.parent", mustExist: true, directory: true)

        for _ in 0..<16 {
            let nonce = UUID().uuidString.lowercased()
            let reservationPath = "\(baseStem).\(requestID).\(nonce)"
            if Darwin.mkdir(reservationPath, S_IRWXU) == 0 {
                let stem = URL(fileURLWithPath: reservationPath, isDirectory: true)
                    .appendingPathComponent("trace", isDirectory: false)
                for stream in TokenIDTraceStreamKind.allCases {
                    for pathExtension in ["\(stream.rawValue).ids", "\(stream.rawValue).json"] {
                        let artifactPath = stem.appendingPathExtension(pathExtension).path
                        var info = stat()
                        if Darwin.lstat(artifactPath, &info) == 0 {
                            throw failure(
                                "output.stem",
                                "final token-trace artifact already exists: \(artifactPath)"
                            )
                        }
                        guard errno == ENOENT else {
                            throw failure("output.stem", "cannot inspect final artifact path: \(artifactPath)")
                        }
                    }
                }
                return stem
            }
            let code = errno
            if code == EEXIST { continue }
            throw failure(
                "output.stem",
                "could not reserve a unique token-trace namespace: \(String(cString: strerror(code)))"
            )
        }
        throw failure("output.stem", "could not reserve a unique token-trace namespace after 16 attempts")
    }

    private static func validate(
        _ root: [String: Any],
        manifestSHA256: String,
        phase: Phase
    ) throws -> VerificationReport {
        let allowed: Set<String> = [
            "schema", "campaign_id", "sources", "dependency_pins", "artifacts", "model", "schemas",
            "generation", "runtime_settings", "arms", "diagnostics", "effective_path_proof", "requests", "prefixes",
            "fixtures", "output", "safety", "decision", "notes",
        ]
        let required = allowed.subtracting(["notes"])
        try checkObject(root, field: "manifest", allowed: allowed, required: required)
        try requireString(root["schema"], field: "schema", equals: schemaIdentifier)
        let campaignID = try identifier(root["campaign_id"], field: "campaign_id")

        let sourceRoots = try validateSources(root["sources"])
        try validateDependencyPins(root["dependency_pins"])
        try validateArtifacts(root["artifacts"])

        let hashModelBytes = phase == .preCampaign
        let modelResult = try validateModel(root["model"], hashBytes: hashModelBytes)
        try validateSchemas(root["schemas"], sourceRoots: sourceRoots)
        try validateGeneration(root["generation"])
        try validateRuntimeSettings(root["runtime_settings"])
        try validateArms(root["arms"])
        try validateDiagnostics(root["diagnostics"])
        try validateEffectivePathProof(root["effective_path_proof"])
        let fixtureIDs = try validateFixtures(root["fixtures"], fixtureRoot: sourceRoots.fixtures)
        try validateRequests(root["requests"], fixtureIDs: fixtureIDs)
        try validatePrefixes(root["prefixes"])
        let campaignRoot = try validateOutput(root["output"])
        try validateSafety(root["safety"])
        try validateDecision(root["decision"])
        if let notes = root["notes"] {
            _ = try string(notes, field: "notes", maxLength: 4096)
        }

        return VerificationReport(
            manifestSHA256: manifestSHA256,
            phase: phase,
            campaignID: campaignID,
            campaignRoot: campaignRoot,
            modelEntryCount: modelResult.entryCount,
            modelBytesHashed: hashModelBytes,
            modelBytesHashedCount: hashModelBytes ? modelResult.entryCount : 0,
            identityChecks: modelResult.identityChecks
        )
    }

    private static func validateSources(_ value: Any?) throws -> SourceRoots {
        let object = try object(value, field: "sources")
        try checkObject(
            object,
            field: "sources",
            allowed: ["paths", "base", "head", "clean", "sealed_diff"],
            required: ["paths", "base", "head"]
        )
        let rawPaths = try array(object["paths"], field: "sources.paths", minCount: requiredSourceSuffixes.count)
        let paths = try rawPaths.enumerated().map { index, value in
            try canonicalPath(value, field: "sources.paths[\(index)]", mustExist: true, directory: false)
        }
        guard Set(paths).count == paths.count else {
            throw failure("sources.paths", "duplicate paths are forbidden")
        }
        for suffix in requiredSourceSuffixes where !paths.contains(where: { $0.hasSuffix(suffix) }) {
            throw failure("sources.paths", "missing required source binding \(suffix)")
        }
        let packageSuffix = "/Packages/OsaurusCore/Package.swift"
        guard let packagePath = paths.first(where: { $0.hasSuffix(packageSuffix) }) else {
            throw failure("sources.paths", "cannot derive the repository fixture root")
        }
        let repositoryRoot = String(packagePath.dropLast(packageSuffix.count))
        let fixtureRoot = try canonicalPath(
            repositoryRoot + "/scripts/live-proof/fixtures/dsv4-head-cache-v1",
            field: "fixtures.root",
            mustExist: true,
            directory: true
        )
        try requireRevision(object["base"], field: "sources.base")
        try requireRevision(object["head"], field: "sources.head")
        let hasClean = object["clean"] != nil
        let hasDiff = object["sealed_diff"] != nil
        guard hasClean != hasDiff else {
            throw failure("sources", "provide exactly one of clean or sealed_diff")
        }
        if hasClean {
            guard (object["clean"] as? Bool) == true else {
                throw failure("sources.clean", "must be true when supplied")
            }
        } else {
            _ = try fileReference(object["sealed_diff"], field: "sources.sealed_diff", hashBytes: true)
        }
        return SourceRoots(repository: repositoryRoot, fixtures: fixtureRoot)
    }

    private static func validateDependencyPins(_ value: Any?) throws {
        let pins = try array(value, field: "dependency_pins", minCount: 4, maxCount: 4)
        var paths: Set<String> = []
        var revisions: Set<String> = []
        for (index, rawPin) in pins.enumerated() {
            let field = "dependency_pins[\(index)]"
            let pin = try object(rawPin, field: field)
            try checkObject(pin, field: field, allowed: ["path", "revision"], required: ["path", "revision"])
            let path = try canonicalPath(pin["path"], field: "\(field).path", mustExist: true, directory: false)
            let revision = try requireRevision(pin["revision"], field: "\(field).revision")
            paths.insert(path)
            revisions.insert(revision)
            let content: Data
            do {
                content = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw failure(field, "could not read pin surface: \(error.localizedDescription)")
            }
            guard content.range(of: Data(revision.utf8)) != nil else {
                throw failure(field, "path does not contain its bound revision")
            }
        }
        guard paths.count == 4 else {
            throw failure("dependency_pins", "the four paths must be distinct")
        }
        guard revisions.count == 1 else {
            throw failure("dependency_pins", "all four paths must bind one revision")
        }
    }

    private static func validateArtifacts(_ value: Any?) throws {
        let object = try object(value, field: "artifacts")
        try checkObject(
            object,
            field: "artifacts",
            allowed: ["app_executable", "cli", "default_metallib"],
            required: ["app_executable", "cli", "default_metallib"]
        )
        for key in ["app_executable", "cli", "default_metallib"] {
            _ = try fileReference(object[key], field: "artifacts.\(key)", hashBytes: true)
        }
    }

    private static func validateModel(_ value: Any?, hashBytes: Bool) throws -> (entryCount: Int, totalBytes: Int64, identityChecks: Int) {
        let model = try object(value, field: "model")
        try checkObject(
            model,
            field: "model",
            allowed: ["canonical_root", "id", "revision", "attestation", "inventory"],
            required: ["canonical_root", "id", "revision", "attestation", "inventory"]
        )
        let root = try canonicalPath(model["canonical_root"], field: "model.canonical_root", mustExist: true, directory: true)
        _ = try string(model["id"], field: "model.id", maxLength: 512)
        let revision = try requireRevision(model["revision"], field: "model.revision")

        let attestation = try object(model["attestation"], field: "model.attestation")
        try checkObject(
            attestation,
            field: "model.attestation",
            allowed: ["type", "repository", "revision", "path", "sha256", "size"],
            required: ["type", "repository", "revision", "path", "sha256", "size"]
        )
        let attestationType = try string(attestation["type"], field: "model.attestation.type")
        guard ["huggingface_revision", "local_signed_attestation"].contains(attestationType) else {
            throw failure("model.attestation.type", "unsupported attestation type")
        }
        _ = try string(attestation["repository"], field: "model.attestation.repository")
        guard try requireRevision(attestation["revision"], field: "model.attestation.revision") == revision else {
            throw failure("model.attestation.revision", "must equal model.revision")
        }
        let attestationReference = [
            "path": attestation["path"] as Any,
            "sha256": attestation["sha256"] as Any,
            "size": attestation["size"] as Any,
        ]
        _ = try fileReference(attestationReference, field: "model.attestation", hashBytes: true)

        let inventory = try object(model["inventory"], field: "model.inventory")
        try checkObject(
            inventory,
            field: "model.inventory",
            allowed: ["config", "tokenizer", "weights", "file_count", "total_bytes"],
            required: ["config", "tokenizer", "weights", "file_count", "total_bytes"]
        )
        var records: [FileRecord] = []
        records.append(try modelFileReference(inventory["config"], field: "model.inventory.config", hashBytes: hashBytes, root: root))
        let tokenizers = try array(inventory["tokenizer"], field: "model.inventory.tokenizer", minCount: 1)
        for (index, item) in tokenizers.enumerated() {
            records.append(try modelFileReference(item, field: "model.inventory.tokenizer[\(index)]", hashBytes: hashBytes, root: root))
        }
        let weights = try array(inventory["weights"], field: "model.inventory.weights", minCount: 1, maxCount: 256)
        for (index, item) in weights.enumerated() {
            records.append(try modelFileReference(item, field: "model.inventory.weights[\(index)]", hashBytes: hashBytes, root: root))
        }

        let expectedCount = try integer(inventory["file_count"], field: "model.inventory.file_count", minimum: 3)
        let expectedBytes = try integer(inventory["total_bytes"], field: "model.inventory.total_bytes")
        guard expectedCount == Int64(records.count) else {
            throw failure("model.inventory.file_count", "must equal the exact inventory count")
        }
        let actualBytes = records.reduce(Int64(0)) { $0 + $1.size }
        guard expectedBytes == actualBytes else {
            throw failure("model.inventory.total_bytes", "must equal the exact inventory byte sum")
        }

        let expectedPaths = Set(records.map(\.path))
        let actualPaths = try inventoryPaths(root: root)
        guard expectedPaths == actualPaths else {
            let missing = expectedPaths.subtracting(actualPaths).sorted().joined(separator: ",")
            let extra = actualPaths.subtracting(expectedPaths).sorted().joined(separator: ",")
            throw failure("model.inventory", "exact inventory set mismatch; missing=[\(missing)] extra=[\(extra)]")
        }

        var identityChecks = 0
        for record in records {
            guard let expectedIdentity = record.identity else {
                throw failure("model.inventory", "identity metadata is required for every model file")
            }
            let current = try identity(atPath: record.path, field: "model.inventory.identity")
            guard current == expectedIdentity else {
                throw failure("model.inventory", "identity mismatch for \(record.path)")
            }
            identityChecks += 1
        }
        return (records.count, actualBytes, identityChecks)
    }

    private static func validateSchemas(_ value: Any?, sourceRoots: SourceRoots) throws {
        let schemas = try object(value, field: "schemas")
        try checkObject(schemas, field: "schemas", allowed: ["manifest", "request", "output"], required: ["manifest", "request", "output"])
        let expected: [String: (version: String, path: String)] = [
            "manifest": (
                schemaIdentifier,
                sourceRoots.repository + "/scripts/live-proof/dsv4-head-cache-qualification-v1.schema.json"
            ),
            "request": (
                "dsv4-head-cache-request/1",
                sourceRoots.fixtures + "/request-rails.json"
            ),
            "output": (
                "dsv4-head-cache-output/1",
                sourceRoots.fixtures + "/output-rails.json"
            ),
        ]
        for key in ["manifest", "request", "output"] {
            guard let expectedStamp = expected[key] else {
                throw failure("schemas.\(key)", "missing internal contract binding")
            }
            let stamp = try object(schemas[key], field: "schemas.\(key)")
            try checkObject(
                stamp,
                field: "schemas.\(key)",
                allowed: ["version", "path", "sha256", "size"],
                required: ["version", "path", "sha256", "size"]
            )
            try requireString(
                stamp["version"],
                field: "schemas.\(key).version",
                equals: expectedStamp.version
            )
            let reference: [String: Any] = [
                "path": stamp["path"] as Any,
                "sha256": stamp["sha256"] as Any,
                "size": stamp["size"] as Any,
            ]
            let record = try fileReference(reference, field: "schemas.\(key)", hashBytes: true)
            let expectedPath = try canonicalPath(
                expectedStamp.path,
                field: "schemas.\(key).expected_path",
                mustExist: true,
                directory: false
            )
            guard record.path == expectedPath else {
                throw failure("schemas.\(key).path", "must bind the tracked contract file \(expectedPath)")
            }
        }
    }

    private static func validateGeneration(_ value: Any?) throws {
        let generation = try object(value, field: "generation")
        try checkObject(
            generation,
            field: "generation",
            allowed: ["seed", "temperature", "top_p", "max_tokens", "processors", "eos", "stop"],
            required: ["seed", "temperature", "top_p", "max_tokens", "processors", "eos", "stop"]
        )
        guard try integer(generation["seed"], field: "generation.seed") == 42,
            try integer(generation["temperature"], field: "generation.temperature") == 0,
            try integer(generation["top_p"], field: "generation.top_p") == 1,
            try integer(generation["max_tokens"], field: "generation.max_tokens") == 64
        else {
            throw failure("generation", "seed, temperature, top_p, and max_tokens must be exactly 42, 0, 1, and 64")
        }
        for key in ["processors", "eos", "stop"] {
            let values = try array(generation[key], field: "generation.\(key)", minCount: 1).enumerated().map {
                try string($0.element, field: "generation.\(key)[\($0.offset)]")
            }
            guard Set(values).count == values.count else {
                throw failure("generation.\(key)", "ordered list contains duplicates")
            }
        }
    }

    private static func validateRuntimeSettings(_ value: Any?) throws {
        let settings = try object(value, field: "runtime_settings")
        try checkObject(
            settings,
            field: "runtime_settings",
            allowed: ["exact_bytes", "mtp", "proposals", "decode_compile"],
            required: ["exact_bytes", "mtp", "proposals", "decode_compile"]
        )
        _ = try fileReference(settings["exact_bytes"], field: "runtime_settings.exact_bytes", hashBytes: true)
        for key in ["mtp", "proposals", "decode_compile"] {
            guard (settings[key] as? Bool) == false else {
                throw failure("runtime_settings.\(key)", "must be false")
            }
        }
    }

    private static func validateArms(_ value: Any?) throws {
        let arms = try object(value, field: "arms")
        try checkObject(arms, field: "arms", allowed: ["A", "B", "P"], required: ["A", "B", "P"])
        try validateArm(arms["A"], field: "arms.A", id: "A", mode: "exact", requested: false, sourceSupported: true, prepared: false, identity: nil, bytes: 0)
        try validateArm(arms["B"], field: "arms.B", id: "B", mode: "exactCached", requested: true, sourceSupported: true, prepared: true, identity: .required, bytes: 2_118_123_520)
        try validateArm(arms["P"], field: "arms.P", id: "P", mode: "qmm", requested: false, sourceSupported: true, prepared: false, identity: nil, bytes: 0)
    }

    private enum ExpectedIdentity {
        case required
        case none
    }

    private static func validateArm(
        _ value: Any?,
        field: String,
        id: String,
        mode: String,
        requested: Bool,
        sourceSupported: Bool,
        prepared: Bool,
        identity: ExpectedIdentity?,
        bytes: Int64
    ) throws {
        let arm = try object(value, field: field)
        try checkObject(
            arm,
            field: field,
            allowed: ["id", "mode", "environment", "cache_requested", "source_supported", "prepared", "cache_identity", "logical_bytes", "shadow"],
            required: ["id", "mode", "environment", "cache_requested", "source_supported", "prepared", "cache_identity", "logical_bytes", "shadow"]
        )
        try requireString(arm["id"], field: "\(field).id", equals: id)
        try requireString(arm["mode"], field: "\(field).mode", equals: mode)
        let environment = try object(arm["environment"], field: "\(field).environment")
        let expectedEnvironment = try QualificationArm(rawValue: id).map(\.environment) ?? [:]
        try checkObject(
            environment,
            field: "\(field).environment",
            allowed: Set(expectedEnvironment.keys),
            required: Set(expectedEnvironment.keys)
        )
        guard expectedEnvironment.allSatisfy({ environment[$0.key] as? String == $0.value }) else {
            throw failure("\(field).environment", "does not match the frozen arm environment")
        }
        guard (arm["cache_requested"] as? Bool) == requested,
            (arm["source_supported"] as? Bool) == sourceSupported,
            (arm["prepared"] as? Bool) == prepared,
            try integer(arm["logical_bytes"], field: "\(field).logical_bytes") == bytes
        else {
            throw failure(field, "does not match the frozen arm contract")
        }
        switch identity {
        case nil, .some(.none):
            guard arm["cache_identity"] is NSNull else {
                throw failure("\(field).cache_identity", "must be null")
            }
        case .some(.required):
            let cacheIdentity = try string(arm["cache_identity"], field: "\(field).cache_identity", maxLength: 512)
            guard !cacheIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw failure("\(field).cache_identity", "must be nonempty")
            }
        }
        let shadow = try object(arm["shadow"], field: "\(field).shadow")
        try checkObject(shadow, field: "\(field).shadow", allowed: ["declared", "logical_bytes"], required: ["declared", "logical_bytes"])
        guard (shadow["declared"] as? Bool) == false else {
            throw failure("\(field).shadow.declared", "timed arms must keep shadow off")
        }
        let shadowBytes = try integer(shadow["logical_bytes"], field: "\(field).shadow.logical_bytes")
        guard shadowBytes == 0 else {
            throw failure("\(field).shadow.logical_bytes", "timed arms must report zero shadow bytes")
        }
    }

    private static func validateDiagnostics(_ value: Any?) throws {
        let diagnostics = try object(value, field: "diagnostics")
        try checkObject(
            diagnostics,
            field: "diagnostics",
            allowed: ["shadow_control"],
            required: ["shadow_control"]
        )
        let control = try object(
            diagnostics["shadow_control"],
            field: "diagnostics.shadow_control"
        )
        try checkObject(
            control,
            field: "diagnostics.shadow_control",
            allowed: ["timed", "environment", "snapshot"],
            required: ["timed", "environment", "snapshot"]
        )
        guard (control["timed"] as? Bool) == false else {
            throw failure("diagnostics.shadow_control.timed", "must be false")
        }
        let environment = try object(
            control["environment"],
            field: "diagnostics.shadow_control.environment"
        )
        let expectedEnvironment: [String: String] = [
            "VMLX_DSV4_CACHE_FP32_LM_HEAD": "1",
            "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW": "1",
            "VMLX_DSV4_LM_HEAD_MODE": "exact",
        ]
        try checkObject(
            environment,
            field: "diagnostics.shadow_control.environment",
            allowed: Set(expectedEnvironment.keys),
            required: Set(expectedEnvironment.keys)
        )
        guard expectedEnvironment.allSatisfy({ environment[$0.key] as? String == $0.value }) else {
            throw failure(
                "diagnostics.shadow_control.environment",
                "does not match the frozen diagnostic-only control"
            )
        }
        let snapshot = try object(
            control["snapshot"],
            field: "diagnostics.shadow_control.snapshot"
        )
        let snapshotKeys: Set<String> = [
            "cache_requested", "shadow_requested", "source_quantized", "source_supported",
            "prepared", "logical_bytes", "effective_path",
        ]
        try checkObject(
            snapshot,
            field: "diagnostics.shadow_control.snapshot",
            allowed: snapshotKeys,
            required: snapshotKeys
        )
        let logicalBytes = try integer(
            snapshot["logical_bytes"],
            field: "diagnostics.shadow_control.snapshot.logical_bytes"
        )
        guard (snapshot["cache_requested"] as? Bool) == true,
            (snapshot["shadow_requested"] as? Bool) == true,
            (snapshot["source_quantized"] as? Bool) == true,
            (snapshot["source_supported"] as? Bool) == true,
            (snapshot["prepared"] as? Bool) == true,
            logicalBytes == 2_118_123_520,
            (snapshot["effective_path"] as? String) == "exact"
        else {
            throw failure(
                "diagnostics.shadow_control.snapshot",
                "does not match the frozen diagnostic snapshot"
            )
        }
    }

    private static func validateEffectivePathProof(_ value: Any?) throws {
        let proof = try object(value, field: "effective_path_proof")
        try checkObject(
            proof,
            field: "effective_path_proof",
            allowed: ["source_gate", "adapter_gate", "runtime_artifact", "arm_order", "effective_arm"],
            required: ["source_gate", "adapter_gate", "runtime_artifact", "arm_order", "effective_arm"]
        )
        try sourceBinding(proof["source_gate"], field: "effective_path_proof.source_gate", suffix: "Packages/OsaurusCore/Services/ModelRuntime.swift")
        try sourceBinding(proof["adapter_gate"], field: "effective_path_proof.adapter_gate", suffix: "Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift")
        _ = try fileReference(proof["runtime_artifact"], field: "effective_path_proof.runtime_artifact", hashBytes: true)
        let order = try array(proof["arm_order"], field: "effective_path_proof.arm_order", minCount: 3, maxCount: 3).compactMap { $0 as? String }
        guard order == ["A", "B", "P"] else {
            throw failure("effective_path_proof.arm_order", "must be exactly [A, B, P]")
        }
        let effectiveArm = try string(proof["effective_arm"], field: "effective_path_proof.effective_arm")
        guard ["A", "B", "P"].contains(effectiveArm) else {
            throw failure("effective_path_proof.effective_arm", "must name A, B, or P")
        }
    }

    private static func validateRequests(_ value: Any?, fixtureIDs: Set<String>) throws {
        let requests = try array(value, field: "requests", minCount: requiredRequestKinds.count)
        var ids: Set<String> = []
        var kinds: Set<String> = []
        for (index, rawRequest) in requests.enumerated() {
            let field = "requests[\(index)]"
            let request = try object(rawRequest, field: field)
            try checkObject(request, field: field, allowed: ["id", "kind", "fixture_id", "arm", "expected_rail", "max_tokens", "trace_accepted_ids"], required: ["id", "kind", "fixture_id", "arm", "expected_rail", "max_tokens", "trace_accepted_ids"])
            let id = try identifier(request["id"], field: "\(field).id")
            guard ids.insert(id).inserted else { throw failure(field, "duplicate request id") }
            let kind = try string(request["kind"], field: "\(field).kind")
            guard requiredRequestKinds.contains(kind) else { throw failure("\(field).kind", "unsupported Gate D request kind") }
            kinds.insert(kind)
            let fixtureID = try string(request["fixture_id"], field: "\(field).fixture_id")
            guard fixtureIDs.contains(fixtureID) else { throw failure("\(field).fixture_id", "unknown fixture \(fixtureID)") }
            let arm = try string(request["arm"], field: "\(field).arm")
            guard ["A", "B", "P"].contains(arm) else { throw failure("\(field).arm", "must be A, B, or P") }
            _ = try string(request["expected_rail"], field: "\(field).expected_rail", maxLength: 256)
            guard try integer(request["max_tokens"], field: "\(field).max_tokens") == 64 else { throw failure("\(field).max_tokens", "must be 64") }
            guard let traceAcceptedIDs = request["trace_accepted_ids"] as? Bool,
                traceAcceptedIDs == (kind != "normal_unload")
            else {
                throw failure(
                    "\(field).trace_accepted_ids",
                    "must be false only for normal_unload and true for generation rows"
                )
            }
        }
        let missing = requiredRequestKinds.subtracting(kinds)
        guard missing.isEmpty else { throw failure("requests", "missing Gate D request kinds: \(missing.sorted().joined(separator: ","))") }
    }

    private static func validatePrefixes(_ value: Any?) throws {
        let prefixes = try object(value, field: "prefixes")
        try checkObject(prefixes, field: "prefixes", allowed: ["miss", "hit"], required: ["miss", "hit"])
        for (key, expected) in [("miss", "miss"), ("hit", "hit")] {
            let field = "prefixes.\(key)"
            let prefix = try object(prefixes[key], field: field)
            try checkObject(prefix, field: field, allowed: ["id", "request_id", "expected", "cache_identity"], required: ["id", "request_id", "expected", "cache_identity"])
            _ = try identifier(prefix["id"], field: "\(field).id")
            _ = try string(prefix["request_id"], field: "\(field).request_id")
            try requireString(prefix["expected"], field: "\(field).expected", equals: expected)
            if key == "miss" {
                guard prefix["cache_identity"] is NSNull else { throw failure("\(field).cache_identity", "miss must have null identity") }
            } else {
                let identity = try string(prefix["cache_identity"], field: "\(field).cache_identity", maxLength: 512)
                guard !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("\(field).cache_identity", "hit identity must be nonempty") }
            }
        }
    }

    private static func validateFixtures(_ value: Any?, fixtureRoot: String) throws -> Set<String> {
        let fixtures = try array(value, field: "fixtures", minCount: 3)
        var ids: Set<String> = []
        for (index, rawFixture) in fixtures.enumerated() {
            let field = "fixtures[\(index)]"
            let fixture = try object(rawFixture, field: field)
            try checkObject(fixture, field: field, allowed: ["id", "path", "sha256", "size"], required: ["id", "path", "sha256", "size"])
            let id = try identifier(fixture["id"], field: "\(field).id")
            guard ids.insert(id).inserted else { throw failure(field, "duplicate fixture id") }
            let path = try canonicalPath(fixture["path"], field: "\(field).path", mustExist: true, directory: false)
            try requireContained(path, fixtureRoot, field: "\(field).path")
        let reference = [
            "path": fixture["path"] as Any,
            "sha256": fixture["sha256"] as Any,
            "size": fixture["size"] as Any,
        ]
        _ = try fileReference(reference, field: field, hashBytes: true)
        }
        return ids
    }

    private static func validateOutput(_ value: Any?) throws -> String {
        let output = try object(value, field: "output")
        let keys: Set<String> = ["campaign_root", "ledger", "stem", "state", "cache", "tmp"]
        try checkObject(output, field: "output", allowed: keys, required: keys)
        let root = try canonicalPath(output["campaign_root"], field: "output.campaign_root", mustExist: false)
        var paths: [String: String] = ["campaign_root": root]
        for key in ["ledger", "stem", "state", "cache", "tmp"] {
            let path = try canonicalPath(output[key], field: "output.\(key)", mustExist: false)
            try requireContained(path, root, field: "output.\(key)")
            paths[key] = path
        }
        guard Set(paths.values).count == paths.count else { throw failure("output", "rails must be distinct") }
        return root
    }

    private static func validateSafety(_ value: Any?) throws {
        let safety = try object(value, field: "safety")
        try checkObject(safety, field: "safety", allowed: ["fail_closed", "allow_destructive_actions", "require_manifest_hash_env", "manifest_external", "live_claims"], required: ["fail_closed", "allow_destructive_actions", "require_manifest_hash_env", "manifest_external", "live_claims"])
        guard (safety["fail_closed"] as? Bool) == true else { throw failure("safety.fail_closed", "must be true") }
        guard (safety["allow_destructive_actions"] as? Bool) == false else { throw failure("safety.allow_destructive_actions", "must be false") }
        guard (safety["require_manifest_hash_env"] as? Bool) == true else { throw failure("safety.require_manifest_hash_env", "must be true") }
        guard (safety["manifest_external"] as? Bool) == true else { throw failure("safety.manifest_external", "must be true") }
        guard let claims = safety["live_claims"] as? String, ["none", "measured"].contains(claims) else { throw failure("safety.live_claims", "must be none or measured") }
    }

    private static func validateDecision(_ value: Any?) throws {
        let decision = try object(value, field: "decision")
        try checkObject(decision, field: "decision", allowed: ["status", "qualified", "live_gates_ran", "reason"], required: ["status", "qualified", "live_gates_ran", "reason"])
        let status = try string(decision["status"], field: "decision.status")
        guard ["unproven", "qualified", "rejected"].contains(status) else { throw failure("decision.status", "unsupported decision status") }
        guard let qualified = decision["qualified"] as? Bool, let gatesRan = decision["live_gates_ran"] as? Bool else { throw failure("decision", "qualified and live_gates_ran must be booleans") }
        _ = try string(decision["reason"], field: "decision.reason", maxLength: 2048)
        guard qualified == (status == "qualified") else { throw failure("decision", "qualified must match status") }
        guard !qualified || gatesRan else { throw failure("decision", "qualified requires live_gates_ran=true") }
    }

    private static func sourceBinding(_ value: Any?, field: String, suffix: String) throws {
        let binding = try object(value, field: field)
        try checkObject(binding, field: field, allowed: ["path", "sha256", "size", "symbol"], required: ["path", "sha256", "size", "symbol"])
        let path = try canonicalPath(binding["path"], field: "\(field).path", mustExist: true, directory: false)
        guard path.hasSuffix(suffix) else { throw failure("\(field).path", "must bind \(suffix)") }
        let reference = [
            "path": binding["path"] as Any,
            "sha256": binding["sha256"] as Any,
            "size": binding["size"] as Any,
        ]
        let record = try fileReference(reference, field: field, hashBytes: true)
        _ = try string(binding["symbol"], field: "\(field).symbol", maxLength: 512)
        let expectedSize = try integer(binding["size"], field: "\(field).size")
        guard record.size == expectedSize else { throw failure(field, "source size mismatch") }
    }

    private static func modelFileReference(_ value: Any?, field: String, hashBytes: Bool, root: String) throws -> FileRecord {
        let item = try object(value, field: field)
        try checkObject(item, field: field, allowed: ["path", "sha256", "size", "identity"], required: ["path", "sha256", "size", "identity"])
        let path = try canonicalPath(item["path"], field: "\(field).path", mustExist: true, directory: false)
        try requireContained(path, root, field: "\(field).path")
        let record = try fileReference(item, field: field, hashBytes: hashBytes)
        let expectedIdentity = try manifestIdentity(item["identity"], field: "\(field).identity")
        return FileRecord(path: record.path, size: record.size, identity: expectedIdentity)
    }

    private static func fileReference(_ value: Any?, field: String, hashBytes: Bool) throws -> FileRecord {
        let item = try object(value, field: field)
        try checkObject(item, field: field, allowed: ["path", "sha256", "size", "identity"], required: ["path", "sha256", "size"])
        let path = try canonicalPath(item["path"], field: "\(field).path", mustExist: true, directory: false)
        try requireDigest(item["sha256"], field: "\(field).sha256")
        let expectedSize = try integer(item["size"], field: "\(field).size")
        let actualSize = try fileSize(path, field: field)
        guard expectedSize == actualSize else { throw failure(field, "size mismatch") }
        if hashBytes {
            let actualHash = try sha256File(path, field: field)
            guard actualHash == item["sha256"] as? String else { throw failure(field, "SHA-256 mismatch") }
        }
        let identity: Identity?
        if let rawIdentity = item["identity"] {
            identity = try manifestIdentity(rawIdentity, field: "\(field).identity")
        } else {
            identity = nil
        }
        return FileRecord(path: path, size: actualSize, identity: identity)
    }

    private static func manifestIdentity(_ value: Any?, field: String) throws -> Identity {
        let object = try object(value, field: field)
        try checkObject(object, field: field, allowed: ["device", "inode", "mtime_ns"], required: ["device", "inode", "mtime_ns"])
        return Identity(
            device: try integer(object["device"], field: "\(field).device"),
            inode: try integer(object["inode"], field: "\(field).inode"),
            mtimeNanoseconds: try integer(object["mtime_ns"], field: "\(field).mtime_ns")
        )
    }

    private static func inventoryPaths(root: String) throws -> Set<String> {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: []) else {
            throw failure("model.inventory", "could not enumerate model root")
        }
        var result: Set<String> = []
        for case let url as URL in enumerator {
            let path = try canonicalPath(url.path, field: "model.inventory.actual", mustExist: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { continue }
            let mode = try lstatMode(path, field: "model.inventory.actual")
            if mode == S_IFLNK { throw failure("model.inventory", "symlink file is forbidden: \(path)") }
            if mode == S_IFREG { result.insert(path) }
        }
        return result
    }

    private static func checkObject(
        _ value: [String: Any],
        field: String,
        allowed: Set<String>,
        required: Set<String>
    ) throws {
        let unknown = Set(value.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else { throw failure(field, "unknown field(s): \(unknown.joined(separator: ", "))") }
        let missing = required.subtracting(value.keys).sorted()
        guard missing.isEmpty else { throw failure(field, "missing field(s): \(missing.joined(separator: ", "))") }
    }

    private static func object(_ value: Any?, field: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw failure(field, "must be an object") }
        return object
    }

    private static func array(_ value: Any?, field: String, minCount: Int = 0, maxCount: Int = 512) throws -> [Any] {
        guard let array = value as? [Any] else { throw failure(field, "must be an array") }
        guard array.count >= minCount else { throw failure(field, "must contain at least \(minCount) item(s)") }
        guard array.count <= maxCount else { throw failure(field, "exceeds bounded maximum of \(maxCount) items") }
        return array
    }

    private static func string(_ value: Any?, field: String, maxLength: Int = 4096) throws -> String {
        guard let value = value as? String, !value.isEmpty else { throw failure(field, "must be a nonempty string") }
        guard value.count <= maxLength else { throw failure(field, "exceeds maximum length \(maxLength)") }
        if value.range(of: "__REPLACE|PLACEHOLDER|REPLACE_WITH|<REQUIRED_", options: [.regularExpression, .caseInsensitive]) != nil {
            throw failure(field, "placeholder is not a live value")
        }
        return value
    }

    private static func requireString(_ value: Any?, field: String, equals expected: String) throws {
        guard try string(value, field: field) == expected else { throw failure(field, "must equal \(expected)") }
    }

    private static func integer(_ value: Any?, field: String, minimum: Int64 = 0) throws -> Int64 {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue == Double(number.int64Value)
        else {
            throw failure(field, "must be an integer")
        }
        guard number.int64Value >= minimum else { throw failure(field, "must be at least \(minimum)") }
        return number.int64Value
    }

    private static func identifier(_ value: Any?, field: String) throws -> String {
        let value = try string(value, field: field, maxLength: 128)
        guard value.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            throw failure(field, "must match the bounded lowercase identifier form")
        }
        return value
    }

    @discardableResult
    private static func requireDigest(_ value: Any?, field: String) throws -> String {
        let value = try string(value, field: field, maxLength: 64)
        guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw failure(field, "must be 64 lowercase hexadecimal characters")
        }
        return value
    }

    @discardableResult
    private static func requireRevision(_ value: Any?, field: String) throws -> String {
        let value = try string(value, field: field, maxLength: 40)
        guard value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw failure(field, "must be 40 lowercase hexadecimal characters")
        }
        return value
    }

    private static func canonicalPath(_ value: Any?, field: String, mustExist: Bool, directory: Bool? = nil) throws -> String {
        let path = try string(value, field: field, maxLength: 4096)
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path != "/" else {
            throw failure(field, "must be a canonical absolute path")
        }
        guard path == URL(fileURLWithPath: path).standardizedFileURL.path,
            !path.contains("//")
        else {
            throw failure(field, "must not contain repeated separators or a non-normal form")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == true,
            !components.dropFirst().contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
        else {
            throw failure(field, "contains an invalid path component")
        }
        var current = "/"
        var missing = false
        for component in components.dropFirst() {
            current = current == "/" ? "/\(component)" : "\(current)/\(component)"
            if let mode = try? lstatMode(current, field: field) {
                if mode == S_IFLNK { throw failure(field, "symlink component is forbidden: \(current)") }
                if current != path && mode != S_IFDIR { throw failure(field, "non-directory component: \(current)") }
            } else {
                missing = true
                break
            }
        }
        if mustExist {
            guard !missing else { throw failure(field, "path does not exist") }
            let mode = try lstatMode(path, field: field)
            guard mode != S_IFLNK else { throw failure(field, "final symlink is forbidden") }
            if directory == true, mode != S_IFDIR { throw failure(field, "must be a directory") }
            if directory == false, mode != S_IFREG { throw failure(field, "must be a regular file") }
        }
        return path
    }

    private static func requireContained(_ path: String, _ root: String, field: String) throws {
        guard path == root || path.hasPrefix(root + "/") else {
            throw failure(field, "path escapes canonical root \(root)")
        }
    }

    private static func lstatMode(_ path: String, field: String) throws -> mode_t {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else {
            throw failure(field, "cannot inspect path component \(path)")
        }
        return info.st_mode & S_IFMT
    }

    private static func fileSize(_ path: String, field: String) throws -> Int64 {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { throw failure(field, "cannot stat file") }
        return Int64(info.st_size)
    }

    private static func identity(atPath path: String, field: String) throws -> Identity {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { throw failure(field, "cannot read identity") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw failure(field, "identity target must be a regular file") }
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return Identity(device: Int64(info.st_dev), inode: Int64(info.st_ino), mtimeNanoseconds: mtime)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256File(_ path: String, field: String) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw failure(field, "could not open file for hashing: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let block: Data?
            do {
                block = try handle.read(upToCount: 1024 * 1024)
            } catch {
                throw failure(field, "could not read file for hashing: \(error.localizedDescription)")
            }
            guard let block, !block.isEmpty else { break }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ field: String, _ reason: String) -> VerificationError {
        VerificationError(field: field, reason: reason)
    }
}

/// Public façade named after the artifact.  Keeping the call site short makes
/// it possible for a future model-admission gate to invoke the verifier
/// without coupling that gate to the manifest's private parsing helpers.
public struct DSV4HeadCacheQualificationManifest: Sendable, Equatable {
    public let report: DSV4HeadCacheQualificationManifestVerifier.VerificationReport

    public init(report: DSV4HeadCacheQualificationManifestVerifier.VerificationReport) {
        self.report = report
    }

    public static func verify(
        data: Data,
        expectedSHA256: String?,
        phase: DSV4HeadCacheQualificationManifestVerifier.Phase = .preCampaign
    ) throws -> DSV4HeadCacheQualificationManifest {
        DSV4HeadCacheQualificationManifest(
            report: try DSV4HeadCacheQualificationManifestVerifier.verify(
                data: data,
                expectedSHA256: expectedSHA256,
                phase: phase
            )
        )
    }

    public static func verify(
        fileAt url: URL,
        expectedSHA256: String?,
        phase: DSV4HeadCacheQualificationManifestVerifier.Phase = .preCampaign
    ) throws -> DSV4HeadCacheQualificationManifest {
        DSV4HeadCacheQualificationManifest(
            report: try DSV4HeadCacheQualificationManifestVerifier.verify(
                fileAt: url,
                expectedSHA256: expectedSHA256,
                phase: phase
            )
        )
    }
}

/// Short module-level spelling used by the adapter's injected selector seam.
public typealias RuntimeArtifactKind =
    DSV4HeadCacheQualificationManifestVerifier.RuntimeArtifactKind
