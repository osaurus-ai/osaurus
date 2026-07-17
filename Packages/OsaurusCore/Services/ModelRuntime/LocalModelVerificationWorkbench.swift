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
    case autoToolChoice = "auto_tool_choice"
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
    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var observedDelta = false
        private var postCancelDeltas = 0

        func recordDelta() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { postCancelDeltas += 1 }
            let isFirst = !observedDelta
            observedDelta = true
            return isFirst
        }

        func markCancelled() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var observedPostCancelDelta: Bool {
            lock.lock()
            defer { lock.unlock() }
            return postCancelDeltas > 0
        }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private enum Event: Sendable {
        case started
        case completed(ResultKind)
    }

    private enum ResultKind: Sendable {
        case terminatedAfterCancellation
        case completedBeforeCancellation
        case cancelled
        case failed(String)
    }

    static func run(
        startTimeout: Duration = .seconds(30),
        terminationTimeout: Duration = .seconds(5),
        teardown: @escaping @Sendable () async -> Void = {},
        operation: @escaping @Sendable (@escaping @Sendable () -> Void) async throws -> Void
    ) async -> LocalModelCancellationProbeOutcome {
        let events = AsyncStream<Event>.makeStream()
        let observation = Observation()
        let task = Task {
            do {
                try await operation {
                    if observation.recordDelta() {
                        events.continuation.yield(.started)
                    }
                }
                events.continuation.yield(.completed(
                    observation.wasCancelled
                        ? .terminatedAfterCancellation
                        : .completedBeforeCancellation
                ))
            } catch is CancellationError {
                events.continuation.yield(.completed(.cancelled))
            } catch {
                let code = (error as NSError).code
                events.continuation.yield(.completed(.failed("runtime_stream_error_\(code)")))
            }
            events.continuation.finish()
        }

        let firstEvent: Event? = await withTaskGroup(of: Event?.self) { group in
            group.addTask {
                for await event in events.stream { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: startTimeout)
                return nil
            }
            guard let result = await group.next() else { return nil }
            group.cancelAll()
            return result
        }
        guard case .started = firstEvent else {
            task.cancel()
            if case .completed(.failed(let code)) = firstEvent {
                return .failed("cancellation_stream_start_\(code)")
            }
            if case .completed(.completedBeforeCancellation) = firstEvent {
                return .blocked("The generation stream completed before an in-flight event was observed.")
            }
            return .blocked("No generation event was observed before the bounded cancellation deadline.")
        }

        observation.markCancelled()
        task.cancel()
        let teardownTask = Task { await teardown() }
        let completion: ResultKind? = await withTaskGroup(of: ResultKind?.self) { group in
            group.addTask {
                for await event in events.stream {
                    if case .completed(let result) = event { return result }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: terminationTimeout)
                return nil
            }
            guard let result = await group.next() else { return nil }
            group.cancelAll()
            return result
        }
        guard let completion else {
            task.cancel()
            teardownTask.cancel()
            return .failed("cancellation_stream_termination_timeout")
        }
        teardownTask.cancel()
        if observation.observedPostCancelDelta {
            return .failed("cancellation_stream_emitted_after_cancel")
        }
        switch completion {
        case .terminatedAfterCancellation, .cancelled:
            return .passed
        case .completedBeforeCancellation:
            return .blocked("The generation stream completed before cancellation could be exercised.")
        case .failed(let code):
            return .failed("cancellation_stream_teardown_\(code)")
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
    let errorCode: String?
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
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let modelId: String
    let modelName: String
    let bundle: LocalModelBundleEvidence
    let classification: LocalModelVerificationClassification
    let startedAt: Date
    let completedAt: Date
    let probes: [LocalModelVerificationProbeResult]

    var nonPassingEvidence: [LocalModelVerificationProbeResult] {
        probes.filter { $0.status == .failed || $0.status == .error || $0.status == .blocked }
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
        .generation, .autoToolChoice, .schemaValidToolCall, .toolResultContinuation, .secondToolCall,
        .markerLeakage, .stopAndEOS, .throughput, .cancellation,
    ]

    static func classify(
        _ rows: [LocalModelVerificationProbeResult]
    ) -> LocalModelVerificationClassification {
        let grouped = Dictionary(grouping: rows, by: \.probe)
        let requiredRows = requiredProbes.compactMap { grouped[$0]?.first }
        let allRequiredRows = rows.filter { requiredProbes.contains($0.probe) }
        let hasDuplicateRequiredProbe = requiredProbes.contains { (grouped[$0]?.count ?? 0) != 1 }

        if allRequiredRows.contains(where: { $0.status == .error || $0.status == .failed }) {
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
            let reasoningStatus = rows.first(where: { $0.probe == .reasoning })?.status
            return reasoningStatus == .failed || reasoningStatus == .error
                ? .partial
                : .proven
        }
        if requiredRows.allSatisfy({ $0.status == .unsupported }) { return .unsupported }
        if requiredRows.contains(where: { $0.status == .passed }) { return .partial }
        return .unproven
    }

    static func validates(_ artifact: LocalModelVerificationArtifact) -> Bool {
        validDigest(artifact.bundle.digest)
            && classify(artifact.probes) == artifact.classification
    }

    static func validDigest(_ digest: String) -> Bool {
        guard digest.count == 71, digest.hasPrefix("sha256:") else { return false }
        return digest.dropFirst(7).allSatisfy { $0.isHexDigit }
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
        await LocalModelCancellationHandshake.run(
            teardown: { await ModelRuntime.shared.cancelGeneration(name: modelName) },
            operation: { observedDelta in
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
                for try await _ in stream {
                    observedDelta()
                }
            }
        )
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

    private struct BundleFile {
        let logicalURL: URL
        let contentURL: URL
    }

    private enum BooleanLookup {
        case missing
        case value(Bool)
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
        var files: [BundleFile] = []
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
                files.append(BundleFile(logicalURL: url, contentURL: resolved))
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw InspectionError.unsafeEntry(url.path)
            }
            files.append(BundleFile(logicalURL: url, contentURL: url))
        }
        files.sort {
            relativePath($0.logicalURL, under: directory)
                < relativePath($1.logicalURL, under: directory)
        }

        var rootHasher = SHA256()
        var stateHasher = SHA256()
        var totalBytes: Int64 = 0
        for file in files {
            try cancellationCheck()
            let relative = relativePath(file.logicalURL, under: directory)
            let values = try file.contentURL.resourceValues(forKeys: keys)
            update(&stateHasher, domain: "path", value: relative)
            update(&stateHasher, domain: "size", value: "\(values.fileSize ?? 0)")
            update(
                &stateHasher,
                domain: "mtime",
                value: "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            )
            let handle = try FileHandle(forReadingFrom: file.contentURL)
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

        let contentByRelativePath = Dictionary(uniqueKeysWithValues: files.map {
            (relativePath($0.logicalURL, under: directory), $0.contentURL)
        })
        let tokenizer = contentByRelativePath["tokenizer_config.json"].flatMap(jsonObject(at:))
        let config = contentByRelativePath["config.json"].flatMap(jsonObject(at:))
        let generation = contentByRelativePath["generation_config.json"].flatMap(jsonObject(at:))
        let jang = contentByRelativePath["jang_config.json"].flatMap(jsonObject(at:))
        let tokenizerTemplateEnabled = firstBool(
            keys: ["has_tokenizer_chat_template"], in: [jang], default: true
        )
        let hasTokenizerTemplate = tokenizerTemplateEnabled
            && tokenizer?["chat_template"] != nil
        let hasStandaloneTemplate = contentByRelativePath["chat_template.jinja"] != nil
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
            templateSource = "runtime:\(declaredTemplateSource)"
            templateFallback =
                "The runtime declares a non-file chat-template source that is not digest-bound or authoritatively pinned."
        } else {
            templateSource = "runtime fallback"
            templateFallback = "The bundle does not declare a chat template; the runtime-selected fallback is unproven."
        }

        let parser = firstString(
            keys: ["parser", "format", "tool_call_parser", "tool_calling"],
            in: [jang, tokenizer, config]
        )
        let standaloneTemplate = contentByRelativePath["chat_template.jinja"]
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        let tokenizerTemplate = tokenizerTemplateEnabled
            ? tokenizer?["chat_template"] as? String
            : nil
        let jangCapability = contentByRelativePath["jang_config.json"]
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(LocalReasoningCapability.analyzeJangConfig(data:))
        let reasoningCapability = (standaloneTemplate ?? tokenizerTemplate)
            .map(LocalReasoningCapability.analyze(template:))
            ?? jangCapability
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
        try inspect(directory: directory).stateFingerprint
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

    private static func update(_ hasher: inout SHA256, domain: String, value: String) {
        let domainData = Data(domain.utf8)
        let valueData = Data(value.utf8)
        withUnsafeBytes(of: UInt64(domainData.count).bigEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: domainData)
        withUnsafeBytes(of: UInt64(valueData.count).bigEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: valueData)
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

    private static func firstBool(
        keys: [String], in roots: [[String: Any]?], default defaultValue: Bool
    ) -> Bool {
        for root in roots.compactMap({ $0 }) {
            if case .value(let value) = recursiveFirstBool(
                keys: Set(keys), object: root
            ) {
                return value
            }
        }
        return defaultValue
    }

    private static func recursiveFirstBool(
        keys: Set<String>, object: Any
    ) -> BooleanLookup {
        if let dictionary = object as? [String: Any] {
            for key in dictionary.keys.sorted() {
                guard let value = dictionary[key] else { continue }
                if keys.contains(key), let boolean = value as? Bool { return .value(boolean) }
                let nested = recursiveFirstBool(keys: keys, object: value)
                if case .value = nested { return nested }
            }
        } else if let array = object as? [Any] {
            for value in array {
                let nested = recursiveFirstBool(keys: keys, object: value)
                if case .value = nested { return nested }
            }
        }
        return .missing
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

    func relativeArtifactPath(at url: URL) -> String {
        "model-verification/\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
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
        guard let latest = await store.latest(modelId: modelId) else { return nil }
        register(artifact: latest.artifact, at: latest.url)
        return latest
    }

    func verify(model: MLXModel) async throws -> (LocalModelVerificationArtifact, URL) {
        try await store.begin(modelId: model.id)
        var savedArtifactURL: URL?
        var ledgerProjected = false
        do {
            let startedAt = now()
            let bundle = try LocalModelBundleInspector.inspect(directory: model.localDirectory)
            let probes = try await runProbes(model: model, bundle: bundle)
            try Task.checkCancellation()
            let completedBundle = try LocalModelBundleInspector.inspect(directory: model.localDirectory)
            guard completedBundle.digest == bundle.digest else {
                throw VerificationError.bundleChangedDuringVerification
            }
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            let url = try await store.save(artifact)
            savedArtifactURL = url
            try Task.checkCancellation()
            let relativeArtifactPath = await store.relativeArtifactPath(at: url)
            try ModelCapabilityLedger.saveVerification(
                classification: artifact.classification,
                digest: artifact.bundle.digest,
                artifactPath: relativeArtifactPath,
                measuredAt: ISO8601DateFormatter().string(from: artifact.completedAt),
                for: model.id
            )
            ledgerProjected = true
            try Task.checkCancellation()
            register(artifact: artifact, at: url)
            await store.end(modelId: model.id)
            return (artifact, url)
        } catch {
            if let savedArtifactURL {
                try? await store.removeArtifact(at: savedArtifactURL)
            }
            if ledgerProjected {
                try? ModelCapabilityLedger.removeVerification(for: model.id)
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
        let plain = try await attempt(
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
            errorCode: plain.errorCode,
            transcript: plain.transcript
        ))

        var reasoningTranscript: LocalModelLiveProbeTranscript?
        if bundle.reasoningDeclared {
            let reasoningProbe = try await attempt(
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
            reasoningTranscript = reasoningProbe.transcript
            try Task.checkCancellation()
            rows.append(result(
                .reasoning,
                passed: reasoningProbe.transcript?.reasoningText.isEmpty == false
                    && reasoningProbe.transcript?.visibleText.isEmpty == false
                    && reasoningProbe.transcript?.unclosedReasoning == false,
                passDetail: "The runtime emitted a dedicated, closed reasoning channel.",
                failure: reasoningProbe.error ?? "The bundle declares reasoning, but this run emitted no clean reasoning channel plus visible answer.",
                errorCode: reasoningProbe.errorCode,
                transcript: reasoningProbe.transcript
            ))
        } else {
            rows.append(row(.reasoning, .unsupported, "The bundle does not declare a reasoning mode; no reasoning pass is claimed."))
        }

        var first: (
            transcript: LocalModelLiveProbeTranscript?, error: String?, errorCode: String?
        ) = (nil, nil, nil)
        var continuation: (
            transcript: LocalModelLiveProbeTranscript?, error: String?, errorCode: String?
        ) = (nil, nil, nil)
        var second: (
            transcript: LocalModelLiveProbeTranscript?, error: String?, errorCode: String?
        ) = (nil, nil, nil)
        if bundle.templateFallback != nil {
            let detail = bundle.templateSource.hasPrefix("runtime:")
                ? "The runtime-only chat-template source is not digest-bound or authoritatively pinned; dependent tool evidence remains unproven."
                : "The bundle contains no chat-template content; dependent tool evidence remains unproven."
            for probe in [
                LocalModelVerificationProbe.autoToolChoice, .schemaValidToolCall,
                .toolResultContinuation, .secondToolCall,
            ] {
                rows.append(row(probe, .blocked, detail))
            }
        } else {
            let tool = fixtureTool()
            first = try await attempt(
                model: model,
                request: LocalModelLiveProbeRequest(
                    messages: [ChatMessage(role: "user", content: "Use city_temperature for Paris. Do not guess.")],
                    tools: [tool], toolChoice: .auto, maxTokens: 128, stopSequences: []
                )
            )
            try Task.checkCancellation()
            rows.append(result(
                .autoToolChoice,
                passed: first.transcript?.toolName == "city_temperature"
                    && validCityArguments(first.transcript?.toolArguments, expected: "Paris"),
                passDetail: "The model selected a schema-valid tool through production auto choice.",
                failure: first.error ?? "The model did not select the fixture tool through auto choice.",
                errorCode: first.errorCode,
                transcript: first.transcript
            ))
            rows.append(result(
                .schemaValidToolCall,
                passed: first.transcript?.toolName == "city_temperature"
                    && validCityArguments(first.transcript?.toolArguments, expected: "Paris"),
                passDetail: "The model emitted city_temperature with schema-valid JSON arguments.",
                failure: first.error ?? "The first tool call was missing, named incorrectly, or had invalid arguments.",
                errorCode: first.errorCode,
                transcript: first.transcript
            ))
            let firstArgsValid = validCityArguments(first.transcript?.toolArguments, expected: "Paris")
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
                continuation = try await attempt(
                    model: model,
                    request: LocalModelLiveProbeRequest(
                        messages: history + [ChatMessage(role: "user", content: "State the returned Paris temperature in one sentence.")],
                        tools: [tool], toolChoice: .auto, maxTokens: 96, stopSequences: []
                    )
                )
                try Task.checkCancellation()
                rows.append(result(
                    .toolResultContinuation,
                    passed: continuation.transcript.map {
                        groundedTemperatureAnswer($0.visibleText, city: "Paris", celsius: 21)
                    } == true,
                    passDetail: "The continuation consumed the executed fixture result and returned 21 C.",
                    failure: continuation.error ?? "The continuation did not ground its answer in the injected tool result.",
                    errorCode: continuation.errorCode,
                    transcript: continuation.transcript
                ))
                second = try await attempt(
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
                    errorCode: second.errorCode,
                    transcript: second.transcript
                ))
            } else {
                rows.append(row(.toolResultContinuation, .blocked, "Blocked because the first tool call did not validate."))
                rows.append(row(.secondToolCall, .blocked, "Blocked because the first tool call did not validate."))
            }
        }

        let transcripts = [
            plain.transcript, reasoningTranscript, first.transcript,
            continuation.transcript, second.transcript,
        ]
            .compactMap { $0 }
        let leaked = transcripts.flatMap {
            markerLeaks(in: $0.visibleText) + markerLeaks(in: $0.reasoningText)
        }
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
            errorCode: rates.isEmpty ? "throughput_missing" : nil,
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
            rows.append(row(
                .cancellation, .blocked, detail,
                errorCode: "cancellation_stream_not_started"
            ))
        case .failed(let code):
            rows.append(row(
                .cancellation,
                .failed,
                "The runtime stream did not terminate cleanly after cancellation.",
                errorCode: code
            ))
        }
        return deduplicate(rows)
    }

    private func attempt(
        model: MLXModel,
        request: LocalModelLiveProbeRequest
    ) async throws -> (
        transcript: LocalModelLiveProbeTranscript?,
        error: String?,
        errorCode: String?
    ) {
        do {
            return (
                try await engine.generate(modelId: model.id, modelName: model.name, request: request),
                nil,
                nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (nil, "The runtime probe failed.", "runtime_probe_failed")
        }
    }

    private func groundedTemperatureAnswer(_ text: String, city: String, celsius: Int) -> Bool {
        let lowered = text.lowercased()
        guard lowered.contains(city.lowercased()) else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: String(celsius))
        return lowered.range(
            of: #"(?<![0-9.])"# + escaped
                + #"(?:\.0+)?\s*(?:°\s*c|celsius|c\b|degrees?\s*c(?:elsius)?)(?![0-9])"#,
            options: .regularExpression
        ) != nil
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
            "<|tool_call|>", "<|channel|>", "<|analysis|>", "<|recipient|>",
            "<|start|>", "<|end|>", "<|im_start|>", "<|im_end|>",
            "<|python_tag|>", "assistant to=", "\u{FFFE}",
        ]
        return markers.filter { text.localizedCaseInsensitiveContains($0) }
    }

    private func result(
        _ probe: LocalModelVerificationProbe,
        passed: Bool,
        passDetail: String,
        failure: String,
        errorCode: String?,
        transcript: LocalModelLiveProbeTranscript?
    ) -> LocalModelVerificationProbeResult {
        LocalModelVerificationProbeResult(
            probe: probe,
            status: passed ? .passed : (transcript == nil ? .error : .failed),
            detail: passed ? passDetail : failure,
            errorCode: passed ? nil : errorCode,
            tokenCount: transcript?.tokenCount,
            tokensPerSecond: transcript?.tokensPerSecond,
            stopReason: transcript?.stopReason
        )
    }

    private func row(
        _ probe: LocalModelVerificationProbe,
        _ status: LocalModelVerificationProbeStatus,
        _ detail: String,
        errorCode: String? = nil
    ) -> LocalModelVerificationProbeResult {
        LocalModelVerificationProbeResult(
            probe: probe, status: status, detail: detail,
            errorCode: errorCode,
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
