import Foundation
import Testing

@testable import OsaurusCore

private actor ScriptedVerificationEngine: LocalModelVerificationEngine {
    private var transcripts: [LocalModelLiveProbeTranscript]
    private let cancellationOutcome: LocalModelCancellationProbeOutcome
    private let onFirstGenerate: (@Sendable () -> Void)?
    private let throwCancellationAtRequest: Int?
    private var didRunFirstGenerate = false
    private(set) var requests: [LocalModelLiveProbeRequest] = []

    init(
        transcripts: [LocalModelLiveProbeTranscript],
        cancellationOutcome: LocalModelCancellationProbeOutcome = .passed,
        onFirstGenerate: (@Sendable () -> Void)? = nil,
        throwCancellationAtRequest: Int? = nil
    ) {
        self.transcripts = transcripts
        self.cancellationOutcome = cancellationOutcome
        self.onFirstGenerate = onFirstGenerate
        self.throwCancellationAtRequest = throwCancellationAtRequest
    }

    func generate(
        modelId: String,
        modelName: String,
        request: LocalModelLiveProbeRequest
    ) async throws -> LocalModelLiveProbeTranscript {
        requests.append(request)
        if requests.count == throwCancellationAtRequest {
            throw CancellationError()
        }
        if !didRunFirstGenerate {
            didRunFirstGenerate = true
            onFirstGenerate?()
        }
        guard !transcripts.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return transcripts.removeFirst()
    }

    func probeCancellation(modelId: String, modelName: String) async -> LocalModelCancellationProbeOutcome {
        cancellationOutcome
    }

    func capturedRequests() -> [LocalModelLiveProbeRequest] { requests }
}

struct LocalModelVerificationWorkbenchTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func transcript(
        visible: String = "READY",
        reasoning: String = "",
        tool: String? = nil,
        arguments: String? = nil,
        tps: Double = 12,
        stop: String = "eos"
    ) -> LocalModelLiveProbeTranscript {
        LocalModelLiveProbeTranscript(
            visibleText: visible,
            reasoningText: reasoning,
            toolName: tool,
            toolArguments: arguments,
            tokenCount: 8,
            tokensPerSecond: tps,
            stopReason: stop,
            unclosedReasoning: false
        )
    }

    private func evidenceRow(
        _ probe: LocalModelVerificationProbe,
        status: LocalModelVerificationProbeStatus = .passed,
        tokensPerSecond: Double? = nil
    ) -> LocalModelVerificationProbeResult {
        LocalModelVerificationProbeResult(
            probe: probe,
            status: status,
            detail: "fixture",
            errorCode: nil,
            tokenCount: probe == .throughput ? 8 : nil,
            tokensPerSecond: tokensPerSecond,
            stopReason: probe == .stopAndEOS ? "eos" : nil
        )
    }

    private func completeEvidenceRows(tokensPerSecond: Double = 12) -> [LocalModelVerificationProbeResult] {
        LocalModelVerificationAuthority.requiredProbes.map { probe in
            evidenceRow(
                probe,
                tokensPerSecond: probe == .throughput ? tokensPerSecond : nil
            )
        }
    }

    private func storedArtifact(
        modelId: String,
        digestCharacter: Character,
        classification: LocalModelVerificationClassification = .proven
    ) -> LocalModelVerificationArtifact {
        LocalModelVerificationArtifact(
            schemaVersion: LocalModelVerificationArtifact.currentSchemaVersion,
            modelId: modelId,
            modelName: modelId,
            bundle: LocalModelBundleEvidence(
                digest: "sha256:" + String(repeating: digestCharacter, count: 64),
                stateFingerprint: "sha256:" + String(repeating: digestCharacter, count: 64),
                fileCount: 1,
                byteCount: 1,
                templateSource: "bundle:test",
                templateFallback: nil,
                parserFormat: "fixture",
                generationDefaults: [:],
                reasoningDeclared: false,
                vmlxRevision: nil,
                vmlxRevisionSource: LocalModelBundleInspector.vmlxRevisionSource
            ),
            classification: classification,
            startedAt: fixedDate,
            completedAt: fixedDate,
            probes: classification == .proven ? completeEvidenceRows() : []
        )
    }

    private func makeBundle(
        root: URL,
        reasoning: Bool = false,
        template: Bool = true
    ) throws -> MLXModel {
        let bundle = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(#"{"model_type":"fixture"}"#.utf8).write(
            to: bundle.appendingPathComponent("config.json"))
        let tokenizer = template
            ? (reasoning
                ? #"{"chat_template":"{% if enable_thinking %}<think>{% endif %}{{ messages }}","tool_call_parser":"fixture"}"#
                : #"{"chat_template":"{{ messages }}","tool_call_parser":"fixture"}"#)
            : #"{"tokenizer_class":"FixtureTokenizer"}"#
        try Data(tokenizer.utf8).write(to: bundle.appendingPathComponent("tokenizer_config.json"))
        let generation = reasoning
            ? #"{"top_k":20,"enable_thinking":true}"#
            : #"{"top_k":20}"#
        try Data(generation.utf8).write(to: bundle.appendingPathComponent("generation_config.json"))
        if reasoning && !template {
            try Data(#"{"chat":{"reasoning":{"supported":true}}}"#.utf8).write(
                to: bundle.appendingPathComponent("jang_config.json")
            )
        }
        try Data("weights".utf8).write(to: bundle.appendingPathComponent("model.safetensors"))
        return MLXModel(
            id: "org/fixture", name: "Fixture", description: "", downloadURL: "",
            bundleDirectory: bundle
        )
    }

    private func withEnvironment<T>(
        engine: ScriptedVerificationEngine,
        reasoning: Bool = false,
        template: Bool = true,
        _ body: (LocalModelVerificationService, MLXModel, EvidenceReportRegistryService, URL) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verification-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeBundle(root: root, reasoning: reasoning, template: template)
        let artifactDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        let ledgerURL = root.appendingPathComponent("model-ledger.json")
        let store = LocalModelVerificationArtifactStore()
        let registry = EvidenceReportRegistryService(now: { self.fixedDate })
        let service = LocalModelVerificationService(
            engine: engine, store: store, registry: registry, now: { self.fixedDate }
        )
        return try await LocalModelVerificationArtifactStore.$directoryOverrideForTests
            .withValue(artifactDirectory) {
                try await ModelCapabilityLedger.$fileURLOverrideForTests.withValue(ledgerURL) {
                    try await body(service, model, registry, ledgerURL)
                }
            }
    }

    @Test func artifactSchemaRoundTripsAndDigestStalenessIsExact() throws {
        let bundle = LocalModelBundleEvidence(
            digest: "sha256:" + String(repeating: "a", count: 64),
            stateFingerprint: "sha256:" + String(repeating: "c", count: 64),
            fileCount: 2, byteCount: 4,
            templateSource: "bundle:tokenizer_config.json", templateFallback: nil,
            parserFormat: "fixture", generationDefaults: ["top_k": "20"],
            reasoningDeclared: false,
            vmlxRevision: nil,
            vmlxRevisionSource: LocalModelBundleInspector.vmlxRevisionSource
        )
        let artifact = LocalModelVerificationArtifact(
            schemaVersion: LocalModelVerificationArtifact.currentSchemaVersion,
            modelId: "org/model", modelName: "Model", bundle: bundle,
            classification: .unproven, startedAt: fixedDate, completedAt: fixedDate,
            probes: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            LocalModelVerificationArtifact.self,
            from: encoder.encode(artifact)
        )
        #expect(decoded == artifact)
        #expect(!decoded.isStale(currentDigest: bundle.digest))
        #expect(decoded.isStale(currentDigest: "sha256:" + String(repeating: "b", count: 64)))
        #expect(decoded.isStale(currentDigest: nil))
        #expect(!decoded.isStale(currentStateFingerprint: bundle.stateFingerprint))
        #expect(decoded.isStale(currentStateFingerprint: nil))
    }

    @Test func evidenceAuthorityRejectsEmptyIncompleteDuplicateAndZeroThroughputRows() {
        #expect(LocalModelVerificationAuthority.classify([]) == .unproven)

        let incomplete = [evidenceRow(.generation)]
        #expect(LocalModelVerificationAuthority.classify(incomplete) == .partial)

        var duplicate = completeEvidenceRows()
        duplicate.append(evidenceRow(.generation))
        #expect(LocalModelVerificationAuthority.classify(duplicate) != .proven)

        let zeroThroughput = completeEvidenceRows(tokensPerSecond: 0)
        #expect(LocalModelVerificationAuthority.classify(zeroThroughput) == .failed)

        let missingThroughput = completeEvidenceRows().filter { $0.probe != .throughput }
        #expect(LocalModelVerificationAuthority.classify(missingThroughput) != .proven)
        #expect(LocalModelVerificationAuthority.classify(completeEvidenceRows()) == .proven)
    }

    @Test func exactDigestChangesWithFileContentAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-inspector-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("weights.safetensors")
        try Data("one".utf8).write(to: file)
        let first = try LocalModelBundleInspector.inspect(directory: root)
        let originalDate = try #require(
            try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        try Data("two".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: file.path
        )
        let second = try LocalModelBundleInspector.inspect(directory: root)
        let changedValues = try file.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey,
        ])
        #expect(first.digest != second.digest)
        #expect(changedValues.fileSize == 3)
        let restoredDate = changedValues.contentModificationDate ?? .distantPast
        #expect(abs(restoredDate.timeIntervalSince(originalDate)) < 0.001)
        let artifact = LocalModelVerificationArtifact(
            schemaVersion: LocalModelVerificationArtifact.currentSchemaVersion,
            modelId: "org/model", modelName: "Model", bundle: first,
            classification: .proven, startedAt: fixedDate, completedAt: fixedDate, probes: []
        )
        #expect(artifact.isStale(currentDigest: second.digest))
        #expect(first.templateFallback != nil)

        let link = root.appendingPathComponent("unsafe-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: LocalModelBundleInspector.InspectionError.self) {
            try LocalModelBundleInspector.inspect(directory: root)
        }
    }

    @Test func inspectorAllowsOnlyContainedHuggingFaceBlobSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("models--org--repo", isDirectory: true)
        let blobs = repository.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = repository.appendingPathComponent("snapshots/revision", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("config-blob")
        try Data(#"{"model_type":"fixture"}"#.utf8).write(to: blob)
        let config = snapshot.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(
            atPath: config.path,
            withDestinationPath: "../../blobs/config-blob"
        )
        let accepted = try LocalModelBundleInspector.inspect(directory: snapshot)
        #expect(accepted.fileCount == 1)
        #expect(accepted.byteCount > 0)

        let outside = root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        let escaping = snapshot.appendingPathComponent("escaping")
        try FileManager.default.createSymbolicLink(at: escaping, withDestinationURL: outside)
        #expect(throws: LocalModelBundleInspector.InspectionError.self) {
            try LocalModelBundleInspector.inspect(directory: snapshot)
        }
    }

    @Test func onlyOnDiskTemplateContentIsDigestBoundProvenance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tokenizerModel = try makeBundle(root: root.appendingPathComponent("tokenizer"))
        let tokenizerEvidence = try LocalModelBundleInspector.inspect(
            directory: tokenizerModel.localDirectory
        )
        #expect(tokenizerEvidence.templateSource == "bundle:tokenizer_config.json")
        #expect(tokenizerEvidence.templateFallback == nil)

        let standaloneModel = try makeBundle(
            root: root.appendingPathComponent("standalone"), template: false
        )
        try Data("{{ messages }}".utf8).write(
            to: standaloneModel.localDirectory.appendingPathComponent("chat_template.jinja")
        )
        let standaloneEvidence = try LocalModelBundleInspector.inspect(
            directory: standaloneModel.localDirectory
        )
        #expect(standaloneEvidence.templateSource == "bundle:chat_template.jinja")
        #expect(standaloneEvidence.templateFallback == nil)

        let configModel = try makeBundle(
            root: root.appendingPathComponent("config"), template: false
        )
        try Data(#"{"model_type":"fixture","chat_template":"{{ messages }}"}"#.utf8).write(
            to: configModel.localDirectory.appendingPathComponent("config.json")
        )
        let configEvidence = try LocalModelBundleInspector.inspect(
            directory: configModel.localDirectory
        )
        #expect(configEvidence.templateSource == "bundle:config.json")
        #expect(configEvidence.templateFallback == nil)
    }

    @Test func nestedRuntimeOnlyJangTemplateSourceBlocksAllToolProof() async throws {
        for hasStaleTokenizerTemplate in [false, true] {
            let engine = ScriptedVerificationEngine(transcripts: [transcript()])
            try await withEnvironment(
                engine: engine, template: hasStaleTokenizerTemplate
            ) { service, model, _, _ in
                try Data(
                    #"{"chat":{"chat_template_source":"builtin_encoding_module","has_tokenizer_chat_template":false}}"#.utf8
                ).write(to: model.localDirectory.appendingPathComponent("jang_config.json"))

                let (artifact, _) = try await service.verify(model: model)
                #expect(artifact.bundle.templateSource == "runtime:builtin_encoding_module")
                #expect(artifact.bundle.templateFallback != nil)
                for probe in [
                    LocalModelVerificationProbe.autoToolChoice, .schemaValidToolCall,
                    .toolResultContinuation, .secondToolCall,
                ] {
                    let row = artifact.probes.first { $0.probe == probe }
                    #expect(row?.status == .blocked)
                    #expect(row?.detail.contains("runtime-only chat-template source") == true)
                }
                #expect(artifact.classification != .proven)
                #expect(await engine.capturedRequests().count == 1)
            }
        }
    }

    @Test func inspectorPinsResolvedHuggingFaceContentAgainstSymlinkRetarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-retarget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("models--org--repo", isDirectory: true)
        let blobs = repository.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = repository.appendingPathComponent("snapshots/revision", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let firstBlob = blobs.appendingPathComponent("first")
        let secondBlob = blobs.appendingPathComponent("second")
        try Data("first".utf8).write(to: firstBlob)
        try Data("other".utf8).write(to: secondBlob)
        let weight = snapshot.appendingPathComponent("model.safetensors")
        try FileManager.default.createSymbolicLink(
            atPath: weight.path, withDestinationPath: "../../blobs/first"
        )
        let expected = try LocalModelBundleInspector.inspect(directory: snapshot)

        var checks = 0
        let pinned = try LocalModelBundleInspector.inspect(directory: snapshot) {
            checks += 1
            if checks == 2 {
                try FileManager.default.removeItem(at: weight)
                try FileManager.default.createSymbolicLink(
                    atPath: weight.path, withDestinationPath: "../../blobs/second"
                )
            }
        }
        #expect(pinned.digest == expected.digest)
        #expect(pinned.stateFingerprint == expected.stateFingerprint)
        #expect(try LocalModelBundleInspector.currentStateFingerprint(directory: snapshot)
            != expected.stateFingerprint)
    }

    @Test func completeToolSequenceProducesProvenArtifactAndIntegratesRegistryAndLedger() async throws {
        let engine = ScriptedVerificationEngine(transcripts: [
            transcript(),
            transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Paris"}"#),
            transcript(visible: "Paris is 21 C."),
            transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Berlin"}"#),
        ])
        try await withEnvironment(engine: engine) { service, model, registry, ledgerURL in
            let (artifact, url) = try await service.verify(model: model)
            #expect(artifact.classification == .proven)
            #expect(artifact.schemaVersion == LocalModelVerificationArtifact.currentSchemaVersion)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let permissions = try #require(
                try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            ).intValue
            #expect(permissions & 0o777 == 0o600)
            #expect(Set(artifact.probes.map(\.probe)) == Set(LocalModelVerificationProbe.allCases))
            #expect(registry.list().count == 1)
            #expect(registry.list().first?.status == .passed)

            let raw = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
            let record = try #require(
                raw[ModelCapabilityLedger.verificationStorageKey("org/fixture")] as? [String: Any]
            )
            #expect(record["verificationClassification"] as? String == "proven")
            #expect((record["verificationDigest"] as? String)?.hasPrefix("sha256:") == true)
            let recordedPath = try #require(record["verificationArtifactPath"] as? String)
            #expect(recordedPath.hasPrefix("model-verification/"))
            #expect(!recordedPath.hasPrefix("/"))
            #expect(!recordedPath.contains(NSHomeDirectory()))

            let requests = await engine.capturedRequests()
            #expect(requests.count == 4)
            #expect(requests[1].toolChoice == .auto)
            #expect(requests[2].messages.contains { $0.role == "tool" && $0.content?.contains("21") == true })
            #expect(requests[3].messages.contains { $0.role == "tool" })
        }
    }

    @Test func engineErrorsRemainExplicitAndClassifyFailed() async throws {
        let engine = ScriptedVerificationEngine(transcripts: [])
        try await withEnvironment(engine: engine) { service, model, registry, _ in
            let (artifact, _) = try await service.verify(model: model)
            #expect(artifact.classification == .failed)
            #expect(artifact.probes.first { $0.probe == .generation }?.status == .error)
            #expect(artifact.probes.first { $0.probe == .schemaValidToolCall }?.status == .error)
            #expect(artifact.probes.first { $0.probe == .toolResultContinuation }?.status == .blocked)
            #expect(artifact.probes.first { $0.probe == .markerLeakage }?.status == .blocked)
            #expect(artifact.probes.first { $0.probe == .generation }?.errorCode == "runtime_probe_failed")
            #expect(!artifact.probes.contains { $0.detail.contains(NSHomeDirectory()) })
            #expect(registry.list().first?.counts.errored == 3)
        }
    }

    @Test func templateFallbackCannotHideToolFailure() async throws {
        let engine = ScriptedVerificationEngine(transcripts: [])
        try await withEnvironment(engine: engine, template: false) { service, model, _, _ in
            let (artifact, _) = try await service.verify(model: model)
            #expect(artifact.bundle.templateFallback != nil)
            #expect(artifact.probes.first { $0.probe == .autoToolChoice }?.status == .blocked)
            #expect(artifact.probes.first { $0.probe == .schemaValidToolCall }?.status == .blocked)
            #expect(artifact.probes.first { $0.probe == .toolResultContinuation }?.status == .blocked)
            #expect(artifact.probes.first { $0.probe == .secondToolCall }?.status == .blocked)
            #expect(
                artifact.probes.first { $0.probe == .autoToolChoice }?.detail
                    .contains("contains no chat-template content") == true
            )
            #expect(artifact.classification == .failed)
        }
    }

    @Test func cancelledStopReasonDoesNotCountAsNaturalEOS() async throws {
        let engine = ScriptedVerificationEngine(transcripts: [
            transcript(stop: "cancelled"),
            transcript(
                visible: "", tool: "city_temperature",
                arguments: #"{"city":"Paris"}"#, stop: "cancelled"
            ),
            transcript(visible: "Paris is 21 C.", stop: "cancelled"),
            transcript(
                visible: "", tool: "city_temperature",
                arguments: #"{"city":"Berlin"}"#, stop: "cancelled"
            ),
        ])
        try await withEnvironment(engine: engine) { service, model, _, _ in
            let (artifact, _) = try await service.verify(model: model)
            #expect(artifact.probes.first { $0.probe == .stopAndEOS }?.status == .failed)
            #expect(artifact.classification == .failed)
        }
    }

    @Test func markerLeakAndCancellationFailureCannotBePromoted() async throws {
        let engine = ScriptedVerificationEngine(
            transcripts: [
                transcript(visible: "READY <tool_call>"),
                transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Paris"}"#),
                transcript(visible: "Paris is 21 C."),
                transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Berlin"}"#),
            ],
            cancellationOutcome: .failed("fixture rejected cancellation")
        )
        try await withEnvironment(engine: engine) { service, model, _, _ in
            let (artifact, _) = try await service.verify(model: model)
            #expect(artifact.classification == .failed)
            #expect(artifact.probes.first { $0.probe == .markerLeakage }?.status == .failed)
            #expect(artifact.probes.first { $0.probe == .cancellation }?.status == .failed)
        }
    }

    @Test func cancellationHandshakeRequiresObservedInFlightGeneration() async {
        let passed = await LocalModelCancellationHandshake.run(
            startTimeout: .seconds(1), terminationTimeout: .seconds(1)
        ) { started in
            started()
            try await Task.sleep(for: .seconds(30))
        }
        #expect(passed == .passed)

        let blocked = await LocalModelCancellationHandshake.run(
            startTimeout: .milliseconds(20)
        ) { _ in }
        guard case .blocked = blocked else {
            Issue.record("A request that never starts must remain blocked")
            return
        }

        let completed = await LocalModelCancellationHandshake.run(
            startTimeout: .seconds(1)
        ) { started in
            started()
        }
        guard case .blocked = completed else {
            Issue.record("Completion before a generated delta must remain blocked")
            return
        }
    }

    @Test func cancellationHandshakeRejectsNonCooperativeAndPostCancelStreams() async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let nonCooperative = await LocalModelCancellationHandshake.run(
            startTimeout: .seconds(1), terminationTimeout: .milliseconds(25)
        ) { observed in
            observed()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    continuation.resume()
                }
            }
        }
        #expect(nonCooperative == .failed("cancellation_stream_termination_timeout"))
        #expect(startedAt.duration(to: clock.now) < .milliseconds(250))

        let postCancel = await LocalModelCancellationHandshake.run(
            startTimeout: .seconds(1), terminationTimeout: .seconds(1)
        ) { observed in
            observed()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                observed()
            }
        }
        #expect(postCancel == .failed("cancellation_stream_emitted_after_cancel"))

        let preYieldFailure = await LocalModelCancellationHandshake.run(
            startTimeout: .seconds(1)
        ) { _ in
            throw CocoaError(.fileReadCorruptFile)
        }
        guard case .failed(let code) = preYieldFailure else {
            Issue.record("Completion without cancellation acknowledgement must fail")
            return
        }
        #expect(code.hasPrefix("cancellation_stream_start_runtime_stream_error_"))
    }

    @Test func publicationGuardRejectsCancelledAndReplacedRuns() {
        var guardState = LocalModelVerificationPublicationGuard()
        let first = guardState.begin(modelId: "org/first")
        #expect(guardState.permits(first, currentModelId: "org/first"))
        guardState.invalidate()
        #expect(!guardState.permits(first, currentModelId: "org/first"))

        let second = guardState.begin(modelId: "org/second")
        #expect(!guardState.permits(second, currentModelId: "org/first"))
        #expect(guardState.permits(second, currentModelId: "org/second"))
    }

    @Test func bundleMutationDuringVerificationCannotPublishEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verification-mutation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeBundle(root: root)
        let weightURL = model.localDirectory.appendingPathComponent("model.safetensors")
        let engine = ScriptedVerificationEngine(
            transcripts: [
                transcript(),
                transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Paris"}"#),
                transcript(visible: "Paris is 21 C."),
                transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Berlin"}"#),
            ],
            onFirstGenerate: {
                try? Data("changed".utf8).write(to: weightURL)
            }
        )
        let artifactDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        let service = LocalModelVerificationService(
            engine: engine,
            store: LocalModelVerificationArtifactStore(),
            registry: EvidenceReportRegistryService(),
            now: { self.fixedDate }
        )
        await LocalModelVerificationArtifactStore.$directoryOverrideForTests
            .withValue(artifactDirectory) {
                await #expect(throws: LocalModelVerificationService.VerificationError.self) {
                    try await service.verify(model: model)
                }
                #expect(await service.latest(modelId: model.id) == nil)
            }
    }

    @Test func reasoningAndTemplateFallbackAreHonestEvidenceRows() async throws {
        let engine = ScriptedVerificationEngine(transcripts: [
            transcript(),
            transcript(visible: "4", reasoning: "bounded thought"),
            transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Paris"}"#),
            transcript(visible: "Paris is 21 C."),
            transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Berlin"}"#),
        ])
        try await withEnvironment(engine: engine, reasoning: true, template: false) {
            service, model, _, _ in
            let (artifact, _) = try await service.verify(model: model)
            #expect(artifact.bundle.templateFallback != nil)
            #expect(artifact.probes.first { $0.probe == .reasoning }?.status == .passed)
            #expect(artifact.probes.first { $0.probe == .schemaValidToolCall }?.status == .blocked)
            #expect(artifact.classification == .partial)
        }
    }

    @Test func unsupportedReasoningIsSeparateFromFailure() async throws {
        let engine = ScriptedVerificationEngine(transcripts: [
            transcript(),
            transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Paris"}"#),
            transcript(visible: "Paris is 21 C."),
            transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Berlin"}"#),
        ])
        try await withEnvironment(engine: engine) { service, model, _, _ in
            let (artifact, _) = try await service.verify(model: model)
            #expect(artifact.probes.first { $0.probe == .reasoning }?.status == .unsupported)
            #expect(artifact.classification == .proven)
            #expect(!artifact.nonPassingEvidence.contains { $0.probe == .reasoning })
        }
    }

    @Test func reasoningErrorAndReasoningMarkerLeakCannotBeProven() async throws {
        let errorEngine = ScriptedVerificationEngine(transcripts: [transcript()])
        try await withEnvironment(engine: errorEngine, reasoning: true) { service, model, _, _ in
            let (artifact, _) = try await service.verify(model: model)
            #expect(artifact.probes.first { $0.probe == .reasoning }?.status == .error)
            #expect(artifact.classification != .proven)
        }

        let markerEngine = ScriptedVerificationEngine(transcripts: [
            transcript(),
            transcript(visible: "4", reasoning: "<|recipient|> hidden"),
            transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Paris"}"#),
            transcript(visible: "Paris is 21 C."),
            transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Berlin"}"#),
        ])
        try await withEnvironment(engine: markerEngine, reasoning: true) { service, model, _, _ in
            let (artifact, _) = try await service.verify(model: model)
            #expect(artifact.probes.first { $0.probe == .markerLeakage }?.status == .failed)
            #expect(artifact.classification == .failed)
        }
    }

    @Test func continuationGroundingRejectsUnrelatedAndEmbeddedNumbers() async throws {
        for answer in ["Paris temperature is 2100 C.", "Paris has 21 people; temperature unavailable."] {
            let engine = ScriptedVerificationEngine(transcripts: [
                transcript(),
                transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Paris"}"#),
                transcript(visible: answer),
                transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Berlin"}"#),
            ])
            try await withEnvironment(engine: engine) { service, model, _, _ in
                let (artifact, _) = try await service.verify(model: model)
                #expect(artifact.probes.first { $0.probe == .toolResultContinuation }?.status == .failed)
                #expect(artifact.classification == .failed)
            }
        }
    }

    @Test func cancellationNeverPublishesPartialEvidence() async throws {
        let engine = ScriptedVerificationEngine(
            transcripts: [transcript()], throwCancellationAtRequest: 1
        )
        try await withEnvironment(engine: engine) { service, model, registry, ledgerURL in
            await #expect(throws: CancellationError.self) {
                try await service.verify(model: model)
            }
            #expect(await service.latest(modelId: model.id) == nil)
            #expect(registry.list().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: ledgerURL.path))
        }
    }

    @Test func storeRejectsConcurrentVerificationAndUsesAtomicPrivateArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelVerificationArtifactStore()
        try await LocalModelVerificationArtifactStore.$directoryOverrideForTests.withValue(root) {
            try await store.begin(modelId: "org/model")
            await #expect(throws: (any Error).self) {
                try await store.begin(modelId: "org/model")
            }
            await store.end(modelId: "org/model")
            try await store.begin(modelId: "org/model")
            await store.end(modelId: "org/model")
        }
    }

    @Test func artifactStorageSeparatesCollidingNormalizedIdsAndRejectsCrossBoundContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-collision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelVerificationArtifactStore()
        let hyphen = storedArtifact(modelId: "org/foo-bar", digestCharacter: "a")
        let underscore = storedArtifact(modelId: "org/foo_bar", digestCharacter: "b")

        try await LocalModelVerificationArtifactStore.$directoryOverrideForTests.withValue(root) {
            let hyphenURL = try await store.save(hyphen)
            let underscoreURL = try await store.save(underscore)
            #expect(hyphenURL.deletingLastPathComponent() != underscoreURL.deletingLastPathComponent())
            #expect(await store.latest(modelId: hyphen.modelId)?.artifact.modelId == hyphen.modelId)
            #expect(await store.latest(modelId: underscore.modelId)?.artifact.modelId == underscore.modelId)

            try Data(contentsOf: hyphenURL).write(to: underscoreURL, options: .atomic)
            #expect(await store.latest(modelId: underscore.modelId) == nil)
            #expect(await store.latest(modelId: hyphen.modelId)?.artifact.bundle.digest == hyphen.bundle.digest)
        }
    }

    @Test func ledgerFailureRollsBackArtifactAndRegistryPublication() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeBundle(root: root)
        let artifactDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        let ledgerURL = root.appendingPathComponent("model-ledger.json")
        let registry = EvidenceReportRegistryService()
        let service = LocalModelVerificationService(
            engine: ScriptedVerificationEngine(transcripts: [
                transcript(),
                transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Paris"}"#),
                transcript(visible: "Paris is 21 C."),
                transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Berlin"}"#),
            ]),
            store: LocalModelVerificationArtifactStore(),
            registry: registry,
            now: { self.fixedDate }
        )

        await LocalModelVerificationArtifactStore.$directoryOverrideForTests
            .withValue(artifactDirectory) {
                await ModelCapabilityLedger.$fileURLOverrideForTests.withValue(ledgerURL) {
                    await ModelCapabilityLedger.$failVerificationWriteForTests.withValue(true) {
                        await #expect(throws: (any Error).self) {
                            try await service.verify(model: model)
                        }
                        #expect(await service.latest(modelId: model.id) == nil)
                        #expect(registry.list().isEmpty)
                    }
                }
            }
    }

    @Test func artifactStoreIgnoresUnknownSchemaVersions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verification-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelVerificationArtifactStore()
        let artifact = LocalModelVerificationArtifact(
            schemaVersion: LocalModelVerificationArtifact.currentSchemaVersion + 1,
            modelId: "org/model", modelName: "Model",
            bundle: LocalModelBundleEvidence(
                digest: "sha256:" + String(repeating: "a", count: 64),
                stateFingerprint: "sha256:" + String(repeating: "b", count: 64),
                fileCount: 1, byteCount: 1, templateSource: "bundle:test",
                templateFallback: nil, parserFormat: nil, generationDefaults: [:],
                reasoningDeclared: false,
                vmlxRevision: nil,
                vmlxRevisionSource: LocalModelBundleInspector.vmlxRevisionSource
            ),
            classification: .unproven, startedAt: fixedDate, completedAt: fixedDate,
            probes: []
        )
        try await LocalModelVerificationArtifactStore.$directoryOverrideForTests.withValue(root) {
            _ = try await store.save(artifact)
            let latest = await store.latest(modelId: artifact.modelId)
            #expect(latest == nil)
        }
    }

    @Test func ledgerRejectsEvidenceWithoutFullDigestAndPreservesExistingFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-verification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger.json")
        try ModelCapabilityLedger.$fileURLOverrideForTests.withValue(url) {
            try ModelCapabilityLedger.save(
                record: .init(
                    productionServing: .fail, blockReason: "existing", source: "gauntlet",
                    digest: "sha256:" + String(repeating: "a", count: 64)
                ),
                for: "org/model"
            )
            #expect(throws: (any Error).self) {
                try ModelCapabilityLedger.saveVerification(
                    classification: .proven, digest: "model-name", artifactPath: "/tmp/a",
                    measuredAt: "now", for: "org/model"
                )
            }
            #expect(throws: (any Error).self) {
                try ModelCapabilityLedger.saveVerification(
                    classification: .proven,
                    digest: "sha256:" + String(repeating: "z", count: 64),
                    artifactPath: "model-verification/a.json",
                    measuredAt: "now", for: "org/model"
                )
            }
            try ModelCapabilityLedger.saveVerification(
                classification: .partial,
                digest: "sha256:" + String(repeating: "b", count: 64),
                artifactPath: "/tmp/evidence.json", measuredAt: "now", for: "org/model"
            )
            let raw = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let servingRecord = try #require(raw["org/model"] as? [String: Any])
            let verificationRecord = try #require(
                raw[ModelCapabilityLedger.verificationStorageKey("org/model")] as? [String: Any]
            )
            #expect(servingRecord["productionServing"] as? String == "fail")
            #expect(servingRecord["blockReason"] as? String == "existing")
            #expect(servingRecord["source"] as? String == "gauntlet")
            #expect(
                servingRecord["digest"] as? String
                    == "sha256:" + String(repeating: "a", count: 64)
            )
            #expect(verificationRecord["verificationModelId"] as? String == "org/model")
            #expect(verificationRecord["verificationClassification"] as? String == "partial")
            #expect(
                verificationRecord["verificationDigest"] as? String
                    == "sha256:" + String(repeating: "b", count: 64)
            )
            #expect(verificationRecord["verificationMeasuredAt"] as? String == "now")
            let permissions = try #require(
                try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                    as? NSNumber
            ).intValue
            #expect(permissions & 0o777 == 0o600)
        }
    }

    @Test func corruptLedgerIsNotSilentlyReplaced() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: url)
        ModelCapabilityLedger.$fileURLOverrideForTests.withValue(url) {
            #expect(throws: (any Error).self) {
                try ModelCapabilityLedger.save(
                    record: .init(source: "fixture"), for: "org/model"
                )
            }
            #expect(throws: (any Error).self) {
                try ModelCapabilityLedger.saveVerification(
                    classification: .partial,
                    digest: "sha256:" + String(repeating: "a", count: 64),
                    artifactPath: "model-verification/a.json",
                    measuredAt: "now", for: "org/model"
                )
            }
            #expect((try? Data(contentsOf: url)) == corrupt)
        }
    }

    @Test func concurrentLedgerWritersPreserveServingAndVerificationRecords() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-concurrent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger.json")
        try await ModelCapabilityLedger.$fileURLOverrideForTests.withValue(url) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<12 {
                    group.addTask {
                        try ModelCapabilityLedger.save(
                            record: .init(source: "serving-\(index)"),
                            for: "org/serving-\(index)"
                        )
                    }
                    group.addTask {
                        try ModelCapabilityLedger.saveVerification(
                            classification: .partial,
                            digest: "sha256:" + String(repeating: "a", count: 64),
                            artifactPath: "model-verification/\(index).json",
                            measuredAt: "now", for: "org/verification-\(index)"
                        )
                    }
                }
                try await group.waitForAll()
            }
            let raw = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            for index in 0..<12 {
                #expect(raw["org/serving_\(index)"] != nil)
                #expect(raw[ModelCapabilityLedger.verificationStorageKey(
                    "org/verification-\(index)"
                )] != nil)
            }
        }
    }

    @Test func loadingValidatedArtifactReRegistersRestartEvidence() async throws {
        let engine = ScriptedVerificationEngine(transcripts: [
            transcript(),
            transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Paris"}"#),
            transcript(visible: "Paris is 21 C."),
            transcript(visible: "", tool: "city_temperature", arguments: #"{"city":"Berlin"}"#),
        ])
        try await withEnvironment(engine: engine) { service, model, _, _ in
            _ = try await service.verify(model: model)
            let restartedRegistry = EvidenceReportRegistryService()
            let restarted = LocalModelVerificationService(
                engine: ScriptedVerificationEngine(transcripts: []),
                store: LocalModelVerificationArtifactStore(),
                registry: restartedRegistry
            )
            #expect(await restarted.latest(modelId: model.id) != nil)
            #expect(restartedRegistry.list().count == 1)
        }
    }
}

@Suite(
    "Live local model verification",
    .enabled(if: ProcessInfo.processInfo.environment["OSAURUS_LIVE_MODEL_VERIFICATION_PATH"] != nil),
    .serialized
)
struct LiveLocalModelVerificationTests {
    @Test func productionEngineProducesDigestBoundTruthfulEvidence() async throws {
        try Self.prepareMLXMetallib()
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["OSAURUS_LIVE_MODEL_VERIFICATION_PATH"])
        let modelId = environment["OSAURUS_LIVE_MODEL_VERIFICATION_ID"]
            ?? "mlx-community/Qwen3.5-9B-MLX-4bit"
        let bundleURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-model-verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousPathRoot = OsaurusPaths.overrideRoot
        let previousExternalRoots = ExternalModelLocator.testRootsOverride
        OsaurusPaths.overrideRoot = root.appendingPathComponent("app-root", isDirectory: true)
        let huggingFaceRoot = bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        ExternalModelLocator.testRootsOverride = [
            (root: huggingFaceRoot, source: .huggingFaceCache)
        ]
        ExternalModelLocator.invalidateInMemory()
        _ = ExternalModelLocator.rescan()
        defer {
            ExternalModelLocator.testRootsOverride = previousExternalRoots
            ExternalModelLocator.invalidateInMemory()
            OsaurusPaths.overrideRoot = previousPathRoot
        }
        #expect(
            ExternalModelLocator.path(forId: modelId)?.standardizedFileURL == bundleURL
        )

        let model = MLXModel(
            id: modelId,
            name: modelId.split(separator: "/").last.map(String.init) ?? modelId,
            description: "Live verification fixture",
            downloadURL: "",
            bundleDirectory: bundleURL,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )
        let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        let ledgerURL = root.appendingPathComponent("model-ledger.json")
        let registry = EvidenceReportRegistryService()
        let service = LocalModelVerificationService(
            engine: MLXLocalModelVerificationEngine(),
            store: LocalModelVerificationArtifactStore(),
            registry: registry
        )

        let result = try await LocalModelVerificationArtifactStore.$directoryOverrideForTests
            .withValue(artifactRoot) {
                try await ModelCapabilityLedger.$fileURLOverrideForTests.withValue(ledgerURL) {
                    try await service.verify(model: model)
                }
            }
        let artifact = result.0
        let currentBundle = try LocalModelBundleInspector.inspect(directory: bundleURL)
        #expect(artifact.schemaVersion == LocalModelVerificationArtifact.currentSchemaVersion)
        #expect(artifact.modelId == modelId)
        #expect(artifact.bundle.digest == currentBundle.digest)
        #expect(LocalModelVerificationAuthority.validates(artifact))
        #expect(Set(artifact.probes.map(\.probe)).isSuperset(of: LocalModelVerificationAuthority.requiredProbes))
        for probe in LocalModelVerificationAuthority.requiredProbes {
            #expect(artifact.probes.count { $0.probe == probe } == 1)
        }
        if artifact.classification == .proven {
            #expect(
                artifact.probes
                    .filter { LocalModelVerificationAuthority.requiredProbes.contains($0.probe) }
                    .allSatisfy { $0.status == .passed }
            )
            let throughput = try #require(
                artifact.probes.first { $0.probe == .throughput }?.tokensPerSecond
            )
            #expect(throughput.isFinite && throughput > 0)
        }
        let loaded = await LocalModelVerificationArtifactStore.$directoryOverrideForTests
            .withValue(artifactRoot) {
                await service.latest(modelId: modelId)
            }
        let loadedArtifact = try #require(loaded?.0)
        #expect(loadedArtifact.modelId == artifact.modelId)
        #expect(loadedArtifact.bundle.digest == artifact.bundle.digest)
        #expect(loadedArtifact.classification == artifact.classification)
        #expect(loadedArtifact.probes == artifact.probes)
        #expect(registry.list().first?.status != .passed || artifact.classification == .proven)

        let probeSummary = artifact.probes.map {
            "\($0.probe.rawValue)=\($0.status.rawValue)"
        }.joined(separator: ",")
        let rates = artifact.probes.compactMap(\.tokensPerSecond)
        print("LIVE_MODEL_VERIFICATION classification=\(artifact.classification.rawValue)")
        print("LIVE_MODEL_VERIFICATION probes=\(probeSummary)")
        print("LIVE_MODEL_VERIFICATION token_s=\(rates.map(String.init(describing:)).joined(separator: ","))")

        await ModelRuntime.shared.unloadModelsNotIn([])
    }

    private static func prepareMLXMetallib() throws {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            environment["OSAURUS_MLX_METALLIB"].map { URL(fileURLWithPath: $0) },
            repositoryRoot.appendingPathComponent(
                "build/DerivedData/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
            ),
            repositoryRoot.appendingPathComponent(
                "build/DerivedData/Build/Products/Release/osaurus.app/Contents/Resources/default.metallib"
            ),
        ].compactMap { $0 }
        guard let source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey:
                    "Build the app or set OSAURUS_MLX_METALLIB before running live model verification."
            ])
        }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let destinations = [
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug"),
            packageRoot.appendingPathComponent(
                ".build/arm64-apple-macosx/debug/OsaurusCorePackageTests.xctest/Contents/MacOS"
            ),
            packageRoot.appendingPathComponent(
                ".build/arm64-apple-macosx/debug/OsaurusCorePackageTests.xctest/Contents/Resources"
            ),
            packageRoot.appendingPathComponent(".build/debug"),
            packageRoot.appendingPathComponent(
                ".build/debug/OsaurusCorePackageTests.xctest/Contents/MacOS"
            ),
            packageRoot.appendingPathComponent(
                ".build/debug/OsaurusCorePackageTests.xctest/Contents/Resources"
            ),
        ]
        var installed = false
        for directory in destinations {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                for name in ["default.metallib", "mlx.metallib"] {
                    let destination = directory.appendingPathComponent(name)
                    if !fileManager.fileExists(atPath: destination.path) {
                        try fileManager.copyItem(at: source, to: destination)
                    }
                }
                installed = true
            } catch {
                continue
            }
        }
        guard installed else { throw CocoaError(.fileWriteNoPermission) }
    }
}
