import Foundation
import MLX
import MLXLMCommon
import MLXVLM

/// Explicit non-generative System One requests. No conversational cache, speculative decoder,
/// sampler or tool loop is created. All weights and transient state are dropped at request end.
actor DecisionService {
    static let shared = DecisionService()

    func respond(data: Data) async throws -> Data {
        let request = try DecisionJSON.parse(data)
        let fields = Set(request.entries?.map(\.0) ?? [])
        let supported: Set<String> = ["model", "state", "questions", "images", "videos", "assets"]
        guard fields.isSubset(of: supported) else {
            throw DecisionRuntimeError.invalid(
                "Unknown decision fields: "
                    + fields.subtracting(supported).sorted().joined(separator: ", ")
            )
        }
        guard let name = request["model"]?.string,
            let installed = ModelManager.findInstalledMLXModel(named: name),
            DecisionBundle.isDecisionModel(at: installed.localDirectory)
        else {
            throw DecisionRuntimeError.invalid("System One requires an installed decision model")
        }
        // Reuse the existing auxiliary admission, ownership and residency policy.
        // An API request has no authority to evict an unrelated chat/API model.
        return try await AuxiliaryModelHandoff.run(
            targetModelName: installed.id,
            invocation: .current(),
            sessionID: nil,
            agentID: UUID(),
            operationName: "decision"
        ) { @Sendable in
            try await self.respondAdmitted(data: data)
        }
    }

    private func respondAdmitted(data: Data) async throws -> Data {
        let request = try DecisionJSON.parse(data)
        guard let name = request["model"]?.string,
            let installed = ModelManager.findInstalledMLXModel(named: name),
            DecisionBundle.isDecisionModel(at: installed.localDirectory),
            let questions = request["questions"]?.entries, !questions.isEmpty
        else {
            throw DecisionRuntimeError.invalid(
                "System One requires an installed decision model and named questions"
            )
        }
        if let assets = request["assets"], !assets.isNull, assets.entries?.isEmpty != true {
            throw DecisionRuntimeError.invalid(
                "Asset references are not supported by this decision endpoint; use state-level images"
            )
        }
        let directory = installed.localDirectory
        let metadata = try DecisionBundle(directory: directory)
        let compatibility = ModelCompatibilityDiagnostics.report(
            modelId: installed.id,
            modelName: installed.name,
            modelTypeHint: installed.modelType,
            bundleURL: directory,
            externalSource: installed.externalSource
        )
        try ModelCompatibilityDiagnostics.validateLoadAllowed(
            compatibility,
            modelName: installed.name
        )
        try ModelRuntime.verifyShardManifest(at: directory, name: installed.name)

        let settings = ServerRuntimeSettingsStore.snapshot()
        let facts = LoadBundleFacts.inspect(bundleURL: directory)
        let estimatedWorkingSet = ModelRuntime.estimatedMemorySafetyWorkingSetBytes(
            loadFootprintBytes: Int64(clamping: facts.gpuResidentWeightBytes),
            physicalMemoryBytes: facts.physicalMemory,
            modelDirectory: directory
        )
        let plan = ServerRuntimeSettingsStore.resolvedMemorySafetyPlan(
            for: settings,
            baseLoadConfiguration: .osaurusProduction,
            bundleFacts: facts,
            host: MemoryStatus.snapshot(),
            request: VMLXMemoryRequestEstimate(workingSetBytes: estimatedWorkingSet)
        )
        if let issue = plan.blockingIssues.first {
            throw DecisionRuntimeError.invalid("Memory Safety: \(issue.field): \(issue.message)")
        }
        let access = try await ModelRuntime.shared.beginModelDeletionProtectedAccess(
            modelID: installed.id,
            modelName: installed.name
        )
        do {
            try await MetalGate.shared.enterDecision()
        } catch {
            await ModelRuntime.shared.finishModelDeletionProtectedAccess(access)
            throw error
        }
        do {
            let result = try await execute(
                request: request,
                questions: questions,
                directory: directory,
                name: installed.id,
                metadata: metadata,
                loadConfiguration: plan.loadConfiguration,
                weightsBytes: Int64(clamping: facts.gpuResidentWeightBytes),
                workingSetBytes: estimatedWorkingSet,
                budgetBytes: plan.resolvedLoadBudgetBytes,
                physicalMemoryBytes: plan.resolvedPhysicalMemoryBytes,
                explicitAllocatorBytes: settings.memorySafety.customAllocatorCacheBytes
            )
            Stream.gpu.synchronize()
            Memory.clearCache()
            print(
                "[Decision] request_drained active_bytes=\(Memory.activeMemory) pool_bytes=\(Memory.cacheMemory)"
            )
            await MetalGate.shared.exitDecision()
            await ModelRuntime.shared.finishModelDeletionProtectedAccess(access)
            return result
        } catch {
            Stream.gpu.synchronize()
            Memory.clearCache()
            print(
                "[Decision] request_drained active_bytes=\(Memory.activeMemory) pool_bytes=\(Memory.cacheMemory)"
            )
            await MetalGate.shared.exitDecision()
            await ModelRuntime.shared.finishModelDeletionProtectedAccess(access)
            throw error
        }
    }

    private func execute(
        request: DecisionJSON,
        questions: [(String, DecisionJSON)],
        directory: URL,
        name: String,
        metadata: DecisionBundle,
        loadConfiguration: LoadConfiguration,
        weightsBytes: Int64,
        workingSetBytes: UInt64?,
        budgetBytes: UInt64?,
        physicalMemoryBytes: UInt64,
        explicitAllocatorBytes: UInt64?
    ) async throws -> Data {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-decision-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let images = try materialize(request["images"], media: "image", directory: temporary)
        let videos = try materialize(request["videos"], media: "video", directory: temporary)
        let model = try await D3Model.load(
            directory: directory,
            tokenizerLoader: SwiftTransformersTokenizerLoader(),
            loadConfiguration: loadConfiguration
        )
        let previousAllocator = Memory.cacheLimit
        Memory.cacheLimit = await ModelRuntime.shared.decisionAllocatorCacheLimit(
            weightsBytes: weightsBytes,
            workingSetBytes: workingSetBytes,
            budgetBytes: budgetBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            explicitAllocatorBytes: explicitAllocatorBytes
        )
        print(
            "[Decision] allocator_window model=\(name) limit_bytes=\(Memory.cacheLimit) prior_bytes=\(previousAllocator)"
        )
        // execute returns only after model.unload; restore before the caller releases MetalGate.
        defer { Memory.cacheLimit = previousAllocator }
        do {
            var answers: [String: MLXLMCommon.JSONValue] = [:]
            var total = 0
            var completed = 0
            let state = request["state"] ?? .null
            for (key, raw) in questions {
                try Task.checkCancellation()
                if raw["type"]?.string == "box" {
                    do {
                        guard let instructions = raw["instructions"]?.string,
                            let fields = raw.entries,
                            fields.allSatisfy({ ["type", "instructions"].contains($0.0) })
                        else {
                            throw DecisionRuntimeError.invalid(
                                "This endpoint supports image Box with type and instructions; video at/track are not implemented"
                            )
                        }
                        let result = try await model.decideBox(
                            state: state,
                            instructions: instructions,
                            images: images,
                            videos: videos
                        )
                        total += result.inputTokens
                        if completed > 0
                            && metadata.configuration.attentionMode == .prefixBidirectional
                        {
                            total -= result.stateTokens
                        }
                        completed += 1
                        answers[key] = .object([
                            "type": .string("box"),
                            "box": .object(result.box.mapValues(MLXLMCommon.JSONValue.double)),
                            "confidence": .double(result.confidence),
                        ])
                        print(
                            "[Decision] model=\(name) question=\(key) type=box input_tokens=\(result.inputTokens) output_tokens=0 prompt_tps=\(Double(result.inputTokens)/max(result.seconds,1e-9)) active_bytes=\(Memory.activeMemory) pool_bytes=\(Memory.cacheMemory) cache=none"
                        )
                    } catch is CancellationError { throw CancellationError() } catch {
                        answers[key] = .object([
                            "type": .string("box"), "error": .string("invalid_question"),
                            "reason": .string(error.localizedDescription),
                            "message": .string(error.localizedDescription),
                        ])
                    }
                    continue
                }
                let q: D3Question
                do {
                    try Self.validateQuestionFields(raw)
                    q = try D3Question(raw)
                } catch {
                    answers[key] = .object([
                        "type": .string(raw["type"]?.string ?? ""),
                        "error": .string("invalid_question"),
                        "reason": .string(error.localizedDescription),
                        "message": .string(error.localizedDescription),
                    ])
                    continue
                }
                do {
                    let result = try await model.decide(
                        state: state,
                        question: q,
                        images: images,
                        videos: videos
                    )
                    total += result.inputTokens
                    if completed > 0 && metadata.configuration.attentionMode == .prefixBidirectional {
                        total -= result.stateTokens
                    }
                    completed += 1
                    answers[key] = result.answer
                    print(
                        "[Decision] model=\(name) question=\(key) input_tokens=\(result.inputTokens) output_tokens=0 prompt_tps=\(result.promptTokensPerSecond) active_bytes=\(Memory.activeMemory) pool_bytes=\(Memory.cacheMemory) cache=none"
                    )
                } catch is CancellationError { throw CancellationError() } catch {
                    answers[key] = .object([
                        "type": .string(raw["type"]?.string ?? ""),
                        "error": .string("invalid_model_output"),
                        "reason": .string(error.localizedDescription),
                        "message": .string(error.localizedDescription),
                    ])
                }
            }
            let response = MLXLMCommon.JSONValue.object([
                "model": .string(name), "answers": .object(answers),
                "usage": .object(["input_tokens": .int(total), "output_tokens": .int(0)]),
            ])
            let data = try JSONEncoder().encode(response)
            await model.unload()
            return data
        } catch {
            await model.unload()
            throw error
        }
    }
    /// Match the server model-list UI; visibility does not forbid explicit requests.
    nonisolated static func exposureID(for modelID: String) -> String {
        modelID.split(separator: "/").last.map(String.init)?.lowercased() ?? modelID.lowercased()
    }

    /// Reject extensions before constructing a semantically different question.
    nonisolated static func validateQuestionFields(_ question: DecisionJSON) throws {
        guard let fields = question.entries,
            fields.allSatisfy({ ["type", "instructions", "criteria"].contains($0.0) })
        else {
            throw DecisionRuntimeError.invalid(
                "Decision questions support type, instructions and criteria; question-level media and extensions are not implemented"
            )
        }
    }

    /// Use the existing bounded active-work policy, not a profile's temporary load cap.
    /// Explicit user maxima and the admitted budget remain hard ceilings.
    nonisolated static func allocatorReuseLimit(
        weightsBytes: Int64,
        physicalMemoryBytes: UInt64,
        admittedMemoryLimit: Int,
        budgetHeadroom: Int?,
        explicitAllocatorBytes: UInt64?,
        residentCaps: [Int?] = []
    ) -> Int {
        ModelRuntime.effectiveGenerationMLXCacheLimit(
            persistentLimit: 0,
            admittedMemoryLimit: admittedMemoryLimit,
            modelWeightsBytes: weightsBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            requiresAdmittedCeiling: true,
            configuredLimits: residentCaps + [
                ModelRuntime.explicitAllocatorCacheLimitBytes(
                    customAllocatorCacheBytes: explicitAllocatorBytes
                ),
                ModelRuntime.allocatorCacheCapFromHeadroom(budgetHeadroom),
            ]
        )
    }

    /// The decision endpoint accepts encoded media, never arbitrary host filesystem paths.
    private func materialize(_ value: DecisionJSON?, media: String, directory: URL) throws -> [URL] {
        guard let value, !value.isNull else { return [] }
        guard let values = value.array else {
            throw DecisionRuntimeError.invalid(media + "s must be an array")
        }
        return try values.enumerated().map { index, item in
            guard let text = item.string, let comma = text.firstIndex(of: ","),
                text[..<comma].lowercased().hasPrefix("data:" + media + "/"),
                text[..<comma].lowercased().hasSuffix(";base64"),
                let bytes = Data(base64Encoded: String(text[text.index(after: comma)...]))
            else {
                throw DecisionRuntimeError.invalid("Decision media must be base64 data URLs")
            }
            let ext: String
            if media == "image" {
                ext = try MediaFileValidation.detectImageFormat(bytes).rawValue
            } else {
                try MediaFileValidation.validateVideo(bytes)
                ext = "mp4"
            }
            let url = directory.appendingPathComponent("\(media)-\(index).\(ext)")
            try bytes.write(to: url)
            return url
        }
    }

}
