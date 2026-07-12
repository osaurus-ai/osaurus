//
//  LocalModelVerificationWorkbench.swift
//  osaurus
//
//  On-demand, digest-bound proof that a local bundle works through Osaurus's
//  real MLX generation and tool-continuation path.
//

import CryptoKit
import Foundation

enum LocalModelVerificationClassification: String, Codable, CaseIterable, Sendable {
    case proven
    case partial
    case unsupported
    case failed
    case unproven
}

enum LocalModelVerificationProbe: String, Codable, CaseIterable, Sendable {
    case generation
    case reasoning
    case schemaValidToolCall = "schema_valid_tool_call"
    case toolResultContinuation = "tool_result_continuation"
    case secondToolCall = "second_tool_call"
    case markerLeakage = "marker_leakage"
    case stopAndEOS = "stop_and_eos"
    case throughput
    case cancellation
}

enum LocalModelVerificationProbeStatus: String, Codable, Sendable {
    case passed
    case failed
    case blocked
    case unsupported
    case error
}

enum LocalModelCancellationProbeOutcome: Equatable, Sendable {
    case passed
    case blocked(String)
    case failed(String)
}

enum LocalModelCancellationHandshake {
    static func run(
        timeout: Duration = .seconds(30),
        operation: @escaping @Sendable (@escaping @Sendable () -> Void) async throws -> Void
    ) async -> LocalModelCancellationProbeOutcome {
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { started.continuation.finish() }
            try await operation {
                started.continuation.yield()
            }
        }
        let observedStart = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in started.stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard observedStart else {
            task.cancel()
            _ = await task.result
            return .blocked("No generation event was observed before the bounded cancellation deadline.")
        }

        task.cancel()
        switch await task.result {
        case .failure(let error) where error is CancellationError:
            return .passed
        case .failure(let error):
            return .failed("The in-flight generation failed during cancellation: \(error)")
        case .success:
            return .failed("The in-flight generation completed without acknowledging cancellation.")
        }
    }
}

struct LocalModelVerificationPublicationGuard: Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let modelId: String
    }

    private var generation: UInt64 = 0

    mutating func begin(modelId: String) -> Token {
        generation &+= 1
        return Token(generation: generation, modelId: modelId)
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func permits(_ token: Token, currentModelId: String) -> Bool {
        token.generation == generation && token.modelId == currentModelId
    }
}

struct LocalModelVerificationProbeResult: Codable, Equatable, Sendable, Identifiable {
    var id: String { probe.rawValue }
    let probe: LocalModelVerificationProbe
    let status: LocalModelVerificationProbeStatus
    let detail: String
    let tokenCount: Int?
    let tokensPerSecond: Double?
    let stopReason: String?
}

struct LocalModelBundleEvidence: Codable, Equatable, Sendable {
    let digest: String
    let stateFingerprint: String
    let fileCount: Int
    let byteCount: Int64
    let templateSource: String
    let templateFallback: String?
    let parserFormat: String?
    let generationDefaults: [String: String]
    let reasoningDeclared: Bool
    let vmlxRevision: String?
    let vmlxRevisionSource: String
}

struct LocalModelVerificationArtifact: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let modelId: String
    let modelName: String
    let bundle: LocalModelBundleEvidence
    let classification: LocalModelVerificationClassification
    let startedAt: Date
    let completedAt: Date
    let probes: [LocalModelVerificationProbeResult]

    var failedOrBlocked: [LocalModelVerificationProbeResult] {
        probes.filter { $0.status != .passed }
    }

    func isStale(currentDigest: String?) -> Bool {
        guard let currentDigest else { return true }
        return currentDigest != bundle.digest
    }

    func isStale(currentStateFingerprint: String?) -> Bool {
        guard let currentStateFingerprint else { return true }
        return currentStateFingerprint != bundle.stateFingerprint
    }
}

enum LocalModelVerificationAuthority {
    static let requiredProbes: Set<LocalModelVerificationProbe> = [
        .generation, .schemaValidToolCall, .toolResultContinuation, .secondToolCall,
        .markerLeakage, .stopAndEOS, .throughput, .cancellation,
    ]

    static func classify(
        _ rows: [LocalModelVerificationProbeResult]
    ) -> LocalModelVerificationClassification {
        let grouped = Dictionary(grouping: rows, by: \.probe)
        let requiredRows = requiredProbes.compactMap { grouped[$0]?.first }
        let hasDuplicateRequiredProbe = requiredProbes.contains { (grouped[$0]?.count ?? 0) != 1 }

        if requiredRows.contains(where: { $0.status == .error || $0.status == .failed }) {
            return .failed
        }
        if let throughput = grouped[.throughput]?.first, throughput.status == .passed {
            guard let rate = throughput.tokensPerSecond, rate.isFinite, rate > 0 else {
                return .failed
            }
        }
        guard !hasDuplicateRequiredProbe, requiredRows.count == requiredProbes.count else {
            return requiredRows.contains(where: { $0.status == .passed }) ? .partial : .unproven
        }
        if requiredRows.allSatisfy({ $0.status == .passed }) {
            return rows.first(where: { $0.probe == .reasoning })?.status == .failed
                ? .partial
                : .proven
        }
        if requiredRows.allSatisfy({ $0.status == .unsupported }) { return .unsupported }
        if requiredRows.contains(where: { $0.status == .passed }) { return .partial }
        return .unproven
    }

    static func validates(_ artifact: LocalModelVerificationArtifact) -> Bool {
        classify(artifact.probes) == artifact.classification
    }
}

struct LocalModelLiveProbeRequest: Sendable {
    let messages: [ChatMessage]
    let tools: [Tool]
    let toolChoice: ToolChoiceOption?
    let maxTokens: Int
    let stopSequences: [String]
    let modelOptions: [String: ModelOptionValue]

    init(
        messages: [ChatMessage],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        maxTokens: Int,
        stopSequences: [String],
        modelOptions: [String: ModelOptionValue] = [:]
    ) {
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.modelOptions = modelOptions
    }
}

struct LocalModelLiveProbeTranscript: Equatable, Sendable {
    let visibleText: String
    let reasoningText: String
    let toolName: String?
    let toolArguments: String?
    let tokenCount: Int?
    let tokensPerSecond: Double?
    let stopReason: String?
    let unclosedReasoning: Bool
}

protocol LocalModelVerificationEngine: Sendable {
    func generate(
        modelId: String,
        modelName: String,
        request: LocalModelLiveProbeRequest
    ) async throws -> LocalModelLiveProbeTranscript

    func probeCancellation(modelId: String, modelName: String) async -> LocalModelCancellationProbeOutcome
}

/// The production adapter deliberately uses the same streaming path as native
/// chat. No template, parser, sampler, or stop behavior is replaced here.
actor MLXLocalModelVerificationEngine: LocalModelVerificationEngine {
    func generate(
        modelId: String,
        modelName: String,
        request: LocalModelLiveProbeRequest
    ) async throws -> LocalModelLiveProbeTranscript {
        let parameters = GenerationParameters(
            temperature: nil,
            maxTokens: request.maxTokens,
            maxTokensExplicit: true,
            modelOptions: request.modelOptions,
            suppressProgressUI: true,
            requestSource: .httpAPI
        )
        let stream = try await ModelRuntime.shared.streamWithTools(
            messages: request.messages,
            parameters: parameters,
            stopSequences: request.stopSequences,
            tools: request.tools,
            toolChoice: request.toolChoice,
            modelId: modelId,
            modelName: modelName
        )

        var visible = ""
        var reasoning = ""
        var toolName: String?
        var toolArguments: String?
        var tokenCount: Int?
        var tokensPerSecond: Double?
        var stopReason: String?
        var unclosedReasoning = false

        do {
            for try await delta in stream {
                try Task.checkCancellation()
                if let decoded = StreamingReasoningHint.decode(delta) {
                    reasoning += decoded
                } else if let decoded = StreamingToolHint.decode(delta) {
                    toolName = decoded
                } else if let decoded = StreamingToolHint.decodeArgs(delta) {
                    toolArguments = decoded
                } else if let stats = StreamingStatsHint.decode(delta) {
                    tokenCount = stats.tokenCount
                    tokensPerSecond = stats.tokensPerSecond
                    stopReason = stats.stopReason
                    unclosedReasoning = stats.unclosedReasoning
                } else if !StreamingToolHint.isSentinel(delta) {
                    visible += delta
                }
            }
        } catch let invocation as ServiceToolInvocation {
            toolName = invocation.toolName
            toolArguments = invocation.jsonArguments
        }

        try Task.checkCancellation()
        return LocalModelLiveProbeTranscript(
            visibleText: visible,
            reasoningText: reasoning,
            toolName: toolName,
            toolArguments: toolArguments,
            tokenCount: tokenCount,
            tokensPerSecond: tokensPerSecond,
            stopReason: stopReason,
            unclosedReasoning: unclosedReasoning
        )
    }

    func probeCancellation(modelId: String, modelName: String) async -> LocalModelCancellationProbeOutcome {
        await LocalModelCancellationHandshake.run { observedStart in
            let parameters = GenerationParameters(
                temperature: nil,
                maxTokens: 2_048,
                maxTokensExplicit: true,
                suppressProgressUI: true,
                requestSource: .httpAPI
            )
            let stream = try await ModelRuntime.shared.streamWithTools(
                messages: [ChatMessage(
                    role: "user",
                    content: "Count upward indefinitely, one number per line."
                )],
                parameters: parameters,
                stopSequences: [],
                tools: [],
                toolChoice: nil,
                modelId: modelId,
                modelName: modelName
            )
            var observedEvent = false
            for try await _ in stream {
                if !observedEvent {
                    observedEvent = true
                    observedStart()
                }
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
        }
    }
}

enum LocalModelBundleInspector {
    static let vmlxRevisionSource = "unverified: linked runtime exposes no source revision"

    enum InspectionError: LocalizedError {
        case missingBundle
        case unsafeEntry(String)

        var errorDescription: String? {
            switch self {
            case .missingBundle:
                return "The local model bundle is missing."
            case .unsafeEntry(let path):
                return "The model bundle contains a symbolic link or non-regular entry: \(path)"
            }
        }
    }

    static func inspect(
        directory: URL,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> LocalModelBundleEvidence {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InspectionError.missingBundle
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            throw InspectionError.missingBundle
        }

        let huggingFaceRepositoryRoot = huggingFaceRepositoryRoot(for: directory)
        var files: [URL] = []
        for case let url as URL in enumerator {
            try cancellationCheck()
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard let huggingFaceRepositoryRoot,
                    isContained(resolved, in: huggingFaceRepositoryRoot),
                    (try resolved.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
                else {
                    throw InspectionError.unsafeEntry(url.path)
                }
                files.append(url)
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw InspectionError.unsafeEntry(url.path)
            }
            files.append(url)
        }
        files.sort { relativePath($0, under: directory) < relativePath($1, under: directory) }

        var rootHasher = SHA256()
        var stateHasher = SHA256()
        var totalBytes: Int64 = 0
        for file in files {
            try cancellationCheck()
            let relative = relativePath(file, under: directory)
            let values = try file.resourceValues(forKeys: keys)
            stateHasher.update(data: Data(relative.utf8))
            stateHasher.update(data: Data("\(values.fileSize ?? 0)".utf8))
            stateHasher.update(data: Data("\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)".utf8))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var fileHasher = SHA256()
            var fileBytes: Int64 = 0
            while true {
                try cancellationCheck()
                let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
                if data.isEmpty { break }
                fileHasher.update(data: data)
                fileBytes += Int64(data.count)
            }
            totalBytes += fileBytes
            rootHasher.update(data: Data(relative.utf8))
            rootHasher.update(data: Data([0]))
            rootHasher.update(data: Data(fileHasher.finalize()))
            withUnsafeBytes(of: fileBytes.bigEndian) { rootHasher.update(bufferPointer: $0) }
        }

        let tokenizer = jsonObject(at: directory.appendingPathComponent("tokenizer_config.json"))
        let config = jsonObject(at: directory.appendingPathComponent("config.json"))
        let generation = jsonObject(at: directory.appendingPathComponent("generation_config.json"))
        let jang = jsonObject(at: directory.appendingPathComponent("jang_config.json"))
        let hasTokenizerTemplate = tokenizer?["chat_template"] != nil
        let hasStandaloneTemplate = fm.fileExists(
            atPath: directory.appendingPathComponent("chat_template.jinja").path)
        let templateSource: String
        let templateFallback: String?
        let declaredTemplateSource = firstString(keys: ["chat_template_source"], in: [jang])
        if hasTokenizerTemplate {
            templateSource = "bundle:tokenizer_config.json"
            templateFallback = nil
        } else if hasStandaloneTemplate {
            templateSource = "bundle:chat_template.jinja"
            templateFallback = nil
        } else if config?["chat_template"] != nil {
            templateSource = "bundle:config.json"
            templateFallback = nil
        } else if let declaredTemplateSource {
            templateSource = "bundle:\(declaredTemplateSource)"
            templateFallback = nil
        } else {
            templateSource = "runtime fallback"
            templateFallback = "The bundle does not declare a chat template; the runtime-selected fallback is unproven."
        }

        let parser = firstString(
            keys: ["parser", "format", "tool_call_parser", "tool_calling"],
            in: [jang, tokenizer, config]
        )
        let reasoningCapability = LocalReasoningCapability.readChatTemplate(at: directory)
            .map(LocalReasoningCapability.analyze(template:))
            ?? LocalReasoningCapability.readJangConfigReasoning(at: directory)
        let reasoningDeclared = reasoningCapability?.supportsThinking == true
        let defaults = (generation ?? [:]).reduce(into: [String: String]()) { output, entry in
            guard let rendered = scalarString(entry.value) else { return }
            output[entry.key] = rendered
        }

        return LocalModelBundleEvidence(
            digest: "sha256:" + rootHasher.finalize().map { String(format: "%02x", $0) }.joined(),
            stateFingerprint: "sha256:" + stateHasher.finalize().map { String(format: "%02x", $0) }.joined(),
            fileCount: files.count,
            byteCount: totalBytes,
            templateSource: templateSource,
            templateFallback: templateFallback,
            parserFormat: parser,
            generationDefaults: defaults,
            reasoningDeclared: reasoningDeclared,
            vmlxRevision: nil,
            vmlxRevisionSource: vmlxRevisionSource
        )
    }

    static func currentStateFingerprint(directory: URL) throws -> String {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { throw InspectionError.missingBundle }
        var entries: [(String, Int, TimeInterval)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { throw InspectionError.unsafeEntry(url.path) }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw InspectionError.unsafeEntry(url.path) }
            entries.append((
                relativePath(url, under: directory),
                values.fileSize ?? 0,
                values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        entries.sort { $0.0 < $1.0 }
        var hasher = SHA256()
        for entry in entries {
            hasher.update(data: Data(entry.0.utf8))
            hasher.update(data: Data("\(entry.1)".utf8))
            hasher.update(data: Data("\(entry.2)".utf8))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private static func huggingFaceRepositoryRoot(for directory: URL) -> URL? {
        var candidate = directory.standardizedFileURL
        while candidate.path != "/" {
            if candidate.lastPathComponent.hasPrefix("models--") {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func scalarString(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func firstString(keys: [String], in roots: [[String: Any]?]) -> String? {
        for root in roots.compactMap({ $0 }) {
            if let found = recursiveFirstString(keys: Set(keys), object: root) { return found }
        }
        return nil
    }

    private static func recursiveFirstString(keys: Set<String>, object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in dictionary.keys.sorted() {
                guard let value = dictionary[key] else { continue }
                if keys.contains(key), let rendered = scalarString(value) {
                    return rendered
                }
                if let found = recursiveFirstString(keys: keys, object: value) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = recursiveFirstString(keys: keys, object: value) { return found }
            }
        }
        return nil
    }

}

actor LocalModelVerificationArtifactStore {
    @TaskLocal static var directoryOverrideForTests: URL?

    private var inFlightModels: Set<String> = []
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func begin(modelId: String) throws {
        guard inFlightModels.insert(modelId).inserted else {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "Verification is already running for this model."
            ])
        }
    }

    func end(modelId: String) {
        inFlightModels.remove(modelId)
    }

    func save(_ artifact: LocalModelVerificationArtifact) throws -> URL {
        let directory = Self.directoryOverrideForTests
            ?? OsaurusPaths.config().appendingPathComponent("model-verification", isDirectory: true)
        let modelKey = Self.modelStorageKey(artifact.modelId)
        let modelDirectory = directory.appendingPathComponent(modelKey, isDirectory: true)
        try fileManager.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = modelDirectory.appendingPathComponent(
            Self.artifactFileName(digest: artifact.bundle.digest)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(artifact)
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    func latest(modelId: String) -> (artifact: LocalModelVerificationArtifact, url: URL)? {
        let directory = Self.directoryOverrideForTests
            ?? OsaurusPaths.config().appendingPathComponent("model-verification", isDirectory: true)
        let modelKey = Self.modelStorageKey(modelId)
        let modelDirectory = directory.appendingPathComponent(modelKey, isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.compactMap { url -> (LocalModelVerificationArtifact, URL, Date)? in
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                url.pathExtension == "json",
                let data = try? Data(contentsOf: url),
                let artifact = try? decoder.decode(LocalModelVerificationArtifact.self, from: data),
                artifact.schemaVersion == LocalModelVerificationArtifact.currentSchemaVersion,
                artifact.modelId == modelId,
                url.lastPathComponent == Self.artifactFileName(digest: artifact.bundle.digest),
                LocalModelVerificationAuthority.validates(artifact)
            else { return nil }
            let date = values?.contentModificationDate ?? artifact.completedAt
            return (artifact, url, date)
        }
        .max { $0.2 < $1.2 }
        .map { ($0.0, $0.1) }
    }

    func removeArtifact(at url: URL) throws {
        guard url.pathExtension == "json" else { return }
        try fileManager.removeItem(at: url)
    }

    private static func modelStorageKey(_ modelId: String) -> String {
        SHA256.hash(data: Data(modelId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func artifactFileName(digest: String) -> String {
        digest.replacingOccurrences(of: ":", with: "-") + ".json"
    }
}

actor LocalModelVerificationService {
    enum VerificationError: LocalizedError {
        case bundleChangedDuringVerification

        var errorDescription: String? {
            switch self {
            case .bundleChangedDuringVerification:
                return "The model bundle changed during verification. Run verification again."
            }
        }
    }

    static let shared = LocalModelVerificationService(
        engine: MLXLocalModelVerificationEngine(),
        store: LocalModelVerificationArtifactStore(),
        registry: .shared
    )

    private let engine: any LocalModelVerificationEngine
    private let store: LocalModelVerificationArtifactStore
    private let registry: EvidenceReportRegistryService
    private let now: @Sendable () -> Date

    init(
        engine: any LocalModelVerificationEngine,
        store: LocalModelVerificationArtifactStore,
        registry: EvidenceReportRegistryService,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.store = store
        self.registry = registry
        self.now = now
    }

    func latest(modelId: String) async -> (LocalModelVerificationArtifact, URL)? {
        await store.latest(modelId: modelId)
    }

    func verify(model: MLXModel) async throws -> (LocalModelVerificationArtifact, URL) {
        try await store.begin(modelId: model.id)
        var savedArtifactURL: URL?
        do {
            let startedAt = now()
            let bundle = try LocalModelBundleInspector.inspect(directory: model.localDirectory)
            let probes = try await runProbes(model: model, bundle: bundle)
            let completedBundle = try LocalModelBundleInspector.inspect(directory: model.localDirectory)
            guard completedBundle.digest == bundle.digest else {
                throw VerificationError.bundleChangedDuringVerification
            }
            let artifact = LocalModelVerificationArtifact(
                schemaVersion: LocalModelVerificationArtifact.currentSchemaVersion,
                modelId: model.id,
                modelName: model.name,
                bundle: bundle,
                classification: LocalModelVerificationAuthority.classify(probes),
                startedAt: startedAt,
                completedAt: now(),
                probes: probes
            )
            let url = try await store.save(artifact)
            savedArtifactURL = url
            try ModelCapabilityLedger.saveVerification(
                classification: artifact.classification,
                digest: artifact.bundle.digest,
                artifactPath: url.path,
                measuredAt: ISO8601DateFormatter().string(from: artifact.completedAt),
                for: model.id
            )
            register(artifact: artifact, at: url)
            await store.end(modelId: model.id)
            return (artifact, url)
        } catch {
            if let savedArtifactURL {
                try? await store.removeArtifact(at: savedArtifactURL)
            }
            await store.end(modelId: model.id)
            throw error
        }
    }

    private func runProbes(
        model: MLXModel,
        bundle: LocalModelBundleEvidence
    ) async throws -> [LocalModelVerificationProbeResult] {
        var rows: [LocalModelVerificationProbeResult] = []
        let plain = await attempt(
            model: model,
            request: LocalModelLiveProbeRequest(
                messages: [ChatMessage(role: "user", content: "Reply with exactly READY.")],
                tools: [], toolChoice: nil, maxTokens: 32, stopSequences: []
            )
        )
        try Task.checkCancellation()
        rows.append(result(
            .generation,
            passed: plain.transcript?.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            passDetail: "The model produced visible text through the native MLX chat path.",
            failure: plain.error ?? "The model produced no visible final answer.",
            transcript: plain.transcript
        ))

        if bundle.reasoningDeclared {
            let reasoningProbe = await attempt(
                model: model,
                request: LocalModelLiveProbeRequest(
                    messages: [ChatMessage(
                        role: "user",
                        content: "Reason briefly, then answer with exactly 4: what is 2 + 2?"
                    )],
                    tools: [], toolChoice: nil, maxTokens: 128, stopSequences: [],
                    modelOptions: ["reasoningEffort": .string("high")]
                )
            )
            try Task.checkCancellation()
            rows.append(result(
                .reasoning,
                passed: reasoningProbe.transcript?.reasoningText.isEmpty == false
                    && reasoningProbe.transcript?.visibleText.isEmpty == false
                    && reasoningProbe.transcript?.unclosedReasoning == false,
                passDetail: "The runtime emitted a dedicated, closed reasoning channel.",
                failure: reasoningProbe.error ?? "The bundle declares reasoning, but this run emitted no clean reasoning channel plus visible answer.",
                transcript: reasoningProbe.transcript
            ))
        } else {
            rows.append(row(.reasoning, .unsupported, "The bundle does not declare a reasoning mode; no reasoning pass is claimed."))
        }

        let tool = fixtureTool()
        let first = await attempt(
            model: model,
            request: LocalModelLiveProbeRequest(
                messages: [ChatMessage(role: "user", content: "Use city_temperature for Paris. Do not guess.")],
                tools: [tool], toolChoice: .required, maxTokens: 128, stopSequences: []
            )
        )
        try Task.checkCancellation()
        let firstArgsValid = validCityArguments(first.transcript?.toolArguments, expected: "Paris")
        rows.append(result(
            .schemaValidToolCall,
            passed: first.transcript?.toolName == "city_temperature" && firstArgsValid,
            passDetail: "The model emitted city_temperature with schema-valid JSON arguments.",
            failure: first.error ?? "The first tool call was missing, named incorrectly, or had invalid arguments.",
            transcript: first.transcript
        ))

        var continuation: (transcript: LocalModelLiveProbeTranscript?, error: String?) = (nil, nil)
        var second: (transcript: LocalModelLiveProbeTranscript?, error: String?) = (nil, nil)
        if first.transcript?.toolName == "city_temperature", firstArgsValid {
            let callId = "verification_call_1"
            let history = [
                ChatMessage(role: "user", content: "Use city_temperature for Paris. Do not guess."),
                ChatMessage(
                    role: "assistant", content: nil,
                    tool_calls: [ToolCall(
                        id: callId, type: "function",
                        function: ToolCallFunction(name: "city_temperature", arguments: first.transcript?.toolArguments ?? "{}")
                    )],
                    tool_call_id: nil
                ),
                ChatMessage(role: "tool", content: #"{"city":"Paris","celsius":21}"#, tool_calls: nil, tool_call_id: callId),
            ]
            continuation = await attempt(
                model: model,
                request: LocalModelLiveProbeRequest(
                    messages: history + [ChatMessage(role: "user", content: "State the returned Paris temperature in one sentence.")],
                    tools: [tool], toolChoice: .auto, maxTokens: 96, stopSequences: []
                )
            )
            try Task.checkCancellation()
            let grounded = continuation.transcript?.visibleText.contains("21") == true
            rows.append(result(
                .toolResultContinuation,
                passed: grounded,
                passDetail: "The continuation consumed the executed fixture result and returned 21.",
                failure: continuation.error ?? "The continuation did not ground its answer in the injected tool result.",
                transcript: continuation.transcript
            ))
            second = await attempt(
                model: model,
                request: LocalModelLiveProbeRequest(
                    messages: history + [ChatMessage(role: "user", content: "Now use city_temperature for Berlin. Do not guess.")],
                    tools: [tool], toolChoice: .required, maxTokens: 128, stopSequences: []
                )
            )
            try Task.checkCancellation()
            rows.append(result(
                .secondToolCall,
                passed: second.transcript?.toolName == "city_temperature"
                    && validCityArguments(second.transcript?.toolArguments, expected: "Berlin"),
                passDetail: "The model emitted a second schema-valid tool call after tool history.",
                failure: second.error ?? "The model failed the second tool call after result history.",
                transcript: second.transcript
            ))
        } else {
            rows.append(row(.toolResultContinuation, .blocked, "Blocked because the first tool call did not validate."))
            rows.append(row(.secondToolCall, .blocked, "Blocked because the first tool call did not validate."))
        }

        let transcripts = [plain.transcript, first.transcript, continuation.transcript, second.transcript]
            .compactMap { $0 }
        let leaked = transcripts.flatMap { markerLeaks(in: $0.visibleText) }
        if transcripts.isEmpty {
            rows.append(row(
                .markerLeakage,
                .blocked,
                "No successful transcript was available to inspect for marker leakage."
            ))
        } else {
            rows.append(row(
                .markerLeakage,
                leaked.isEmpty ? .passed : .failed,
                leaked.isEmpty
                    ? "No reasoning, tool, or parser markers leaked into visible output."
                    : "Visible output leaked protocol markers: \(leaked.sorted().joined(separator: ", "))."
            ))
        }
        let stopEvidence = transcripts.contains { transcript in
            guard let stop = transcript.stopReason?.lowercased() else { return false }
            return stop == "stop" || stop == "eos" || stop == "end_of_sequence"
        }
        rows.append(row(
            .stopAndEOS,
            stopEvidence ? .passed : .failed,
            stopEvidence
                ? "The runtime reported a natural stop/EOS reason."
                : "No natural stop/EOS reason was reported by any completed probe."
        ))
        let rates = transcripts.compactMap(\.tokensPerSecond).filter { $0.isFinite && $0 > 0 }
        rows.append(LocalModelVerificationProbeResult(
            probe: .throughput,
            status: rates.isEmpty ? .failed : .passed,
            detail: rates.isEmpty ? "No positive decode token/s evidence was emitted." : "Recorded positive decode throughput.",
            tokenCount: transcripts.compactMap(\.tokenCount).max(),
            tokensPerSecond: rates.max(),
            stopReason: nil
        ))
        let cancellation = await engine.probeCancellation(modelId: model.id, modelName: model.name)
        try Task.checkCancellation()
        switch cancellation {
        case .passed:
            rows.append(row(
                .cancellation,
                .passed,
                "A generation event was observed before the in-flight request acknowledged cancellation."
            ))
        case .blocked(let detail):
            rows.append(row(.cancellation, .blocked, detail))
        case .failed(let detail):
            rows.append(row(.cancellation, .failed, detail))
        }
        if bundle.templateFallback != nil {
            rows.append(row(
                .schemaValidToolCall,
                .blocked,
                "The bundle has no declared chat template; runtime fallback use remains unproven even if output parsed."
            ))
        }
        return deduplicate(rows)
    }

    private func attempt(
        model: MLXModel,
        request: LocalModelLiveProbeRequest
    ) async -> (transcript: LocalModelLiveProbeTranscript?, error: String?) {
        do {
            return (try await engine.generate(modelId: model.id, modelName: model.name, request: request), nil)
        } catch is CancellationError {
            return (nil, "Probe was cancelled.")
        } catch {
            return (nil, String(describing: error))
        }
    }

    private func fixtureTool() -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: "city_temperature",
                description: "Return a deterministic fixture temperature for a city.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "city": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("city")]),
                    "additionalProperties": .bool(false),
                ])
            )
        )
    }

    private func validCityArguments(_ json: String?, expected: String) -> Bool {
        guard let json, let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object.count == 1, let city = object["city"] as? String
        else { return false }
        return city.caseInsensitiveCompare(expected) == .orderedSame
    }

    private func markerLeaks(in text: String) -> [String] {
        let markers = [
            "<think>", "</think>", "<tool_call>", "</tool_call>",
            "<|tool_call|>", "<|channel|>", "<|analysis|>", "\u{FFFE}",
        ]
        return markers.filter { text.localizedCaseInsensitiveContains($0) }
    }

    private func result(
        _ probe: LocalModelVerificationProbe,
        passed: Bool,
        passDetail: String,
        failure: String,
        transcript: LocalModelLiveProbeTranscript?
    ) -> LocalModelVerificationProbeResult {
        LocalModelVerificationProbeResult(
            probe: probe,
            status: passed ? .passed : (transcript == nil ? .error : .failed),
            detail: passed ? passDetail : failure,
            tokenCount: transcript?.tokenCount,
            tokensPerSecond: transcript?.tokensPerSecond,
            stopReason: transcript?.stopReason
        )
    }

    private func row(
        _ probe: LocalModelVerificationProbe,
        _ status: LocalModelVerificationProbeStatus,
        _ detail: String
    ) -> LocalModelVerificationProbeResult {
        LocalModelVerificationProbeResult(
            probe: probe, status: status, detail: detail,
            tokenCount: nil, tokensPerSecond: nil, stopReason: nil
        )
    }

    private func deduplicate(
        _ rows: [LocalModelVerificationProbeResult]
    ) -> [LocalModelVerificationProbeResult] {
        var byProbe: [LocalModelVerificationProbe: LocalModelVerificationProbeResult] = [:]
        for row in rows {
            guard let existing = byProbe[row.probe] else {
                byProbe[row.probe] = row
                continue
            }
            if statusSeverity(row.status) > statusSeverity(existing.status) {
                byProbe[row.probe] = row
            }
        }
        return LocalModelVerificationProbe.allCases.compactMap { byProbe[$0] }
    }

    private func statusSeverity(_ status: LocalModelVerificationProbeStatus) -> Int {
        switch status {
        case .passed: 0
        case .unsupported: 1
        case .blocked: 2
        case .failed: 3
        case .error: 4
        }
    }

    private func register(artifact: LocalModelVerificationArtifact, at url: URL) {
        let counts = EvidenceReportCounts(
            total: artifact.probes.count,
            passed: artifact.probes.count { $0.status == .passed },
            failed: artifact.probes.count { $0.status == .failed },
            errored: artifact.probes.count { $0.status == .error },
            skipped: artifact.probes.count { $0.status == .unsupported },
            blocked: artifact.probes.count { $0.status == .blocked }
        )
        let status: EvidenceReportStatus = switch artifact.classification {
        case .proven: .passed
        case .partial: .partial
        case .unsupported: .blocked
        case .failed: .failed
        case .unproven: .unknown
        }
        registry.register(EvidenceReportDescriptor(
            id: "model-verification|\(artifact.modelId)|\(artifact.bundle.digest)",
            kind: .liveProof,
            source: "local-model-verification",
            artifactURL: url,
            status: status,
            counts: counts,
            startedAt: artifact.startedAt,
            completedAt: artifact.completedAt,
            metadata: [
                "model_id": artifact.modelId,
                "bundle_digest": artifact.bundle.digest,
                "classification": artifact.classification.rawValue,
                "vmlx_revision": artifact.bundle.vmlxRevision ?? "unverified",
                "vmlx_revision_source": artifact.bundle.vmlxRevisionSource,
            ]
        ))
    }
}
