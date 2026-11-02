//
//  MiniMaxM31SelectorPlumbingTests.swift
//  osaurusTests
//
//  MiniMax-M3.1-Flash-JANGHT1.9: the model selector's Reasoning choice (Default / On / Off) and its
//  Speculative Decoding choice (Off (AR) / On (Adaptive)), followed from the stored choice to what
//  vmlx-swift renders and runs.
//
//  Fixture: the bundle's own metadata, byte-identical to the published OsaurusAI bundle (sha256 checked
//  on every materialization), with tokenizer.json and the weight index stored xz-compressed. There are
//  no weights: the 23 target shards are absent and the drafter shard is an empty placeholder. Nothing
//  here loads a model or touches the GPU (tokenization runs on the CPU device).
//

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import MLXLLM
@testable import OsaurusCore

// MARK: - Fixture

enum MiniMaxM31Bundle {
    static let modelID = "OsaurusAI/MiniMax-M3.1-Flash-JANGHT1.9"
    /// config.json `model_type`; vmlx-swift's processor keys the M3 thinking adapter on it.
    static let modelType = "minimax_m3_vl"

    static let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/MiniMax-M3.1-Flash-JANGHT1.9", isDirectory: true)

    /// sha256 of each file as published (chat_template.jinja is the 2026-10-28 thinking_mode template).
    static let published: [String: String] = [
        "config.json": "6b78bc00aca17434520a6570415af9e4f83d77b212bd476573c27b8c5ff03a00",
        "chat_template.jinja": "e8fa0fa5a433202a36336a0ce70e7403b428add073c35e1a80a614b9590b2cab",
        "tokenizer.json": "bb1f1626cf01448f1e3b6036d0a061ffc66c91d9046aada14ea23a5441b5ad6e",
        "tokenizer_config.json": "15caca9f74fbce9b86dc014e9324cbefa56703d81ccd6d56020faa1c41d2eae5",
        "special_tokens_map.json": "401b624ec44507183d1dc65c74f7f3387699a77971aa19fa5a0cc57a3989ba97",
        "added_tokens.json": "63f277741fb061e615cb604286a845d971178ba4716732a59cf42b3752c0ce4e",
        "generation_config.json": "272d19efac5060ff8c9f76c7ed67909a5da1be466284ee4f1f1bd2a810c6fad2",
        "jang_config.json": "7bf0f955240b07965bd17c23cff5d394c2e16ee35fabea31ee32b994ab098343",
        "model.safetensors.index.json": "a0c9bc41b893a9f182b3907bcbace339fb0415f6999353731810e7bdcf44bfa6",
        "dspark/config.json": "d3f2ef9a308be0c5689e98b348d8cff73b90487db22ba79e9269f9b1f25cfa3a",
        "dspark/model.safetensors.index.json": "593f6315b17044d94d5a7e1d231669bcc4dbf9efb06657816d945f1f45c82a6a",
    ]

    /// The drafter's only shard, as named by `dspark/model.safetensors.index.json`. Written empty.
    static let drafterShard = "dspark/model-dspark-00001.safetensors"

    struct FixtureMismatch: Error, CustomStringConvertible {
        let description: String
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The published bytes of one file (`<name>.xz` is expanded), verified against `published`.
    static func publishedData(_ name: String) throws -> Data {
        let plain = source.appendingPathComponent(name)
        let data: Data
        if FileManager.default.fileExists(atPath: plain.path) {
            data = try Data(contentsOf: plain)
        } else {
            let packed = try Data(contentsOf: source.appendingPathComponent(name + ".xz"))
            data = try (packed as NSData).decompressed(using: .lzma) as Data
        }
        guard let expected = published[name], sha256(data) == expected else {
            throw FixtureMismatch(description: "\(name) does not match the published bundle")
        }
        return data
    }

    /// A fresh bundle directory named like the bundle, holding every published metadata file and an
    /// empty drafter shard. Remove it with `remove(_:)`.
    static func materialize() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-m31-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("MiniMax-M3.1-Flash-JANGHT1.9", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("dspark", isDirectory: true),
            withIntermediateDirectories: true
        )
        for name in published.keys {
            try publishedData(name).write(to: directory.appendingPathComponent(name))
        }
        try Data().write(to: directory.appendingPathComponent(drafterShard))
        return directory
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }
}

/// The composer's semantic Thinking choice for this bundle (`supportsUnspecifiedDefault`).
enum M31Reasoning: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case `default` = "Default"
    case on = "On"
    case off = "Off"

    var testDescription: String { rawValue }

    /// The picker's value: nil = Default (no stored option).
    var enabled: Bool? {
        switch self {
        case .default: nil
        case .on: true
        case .off: false
        }
    }

    /// What the composer stores in the per-model option store. The bundle resolves to
    /// `AutoThinkingProfile` (asserted below), whose Thinking option is the inverted `disableThinking`;
    /// `ModelProfileRegistry.thinkingStoredOption` writes exactly this pair and Default removes it.
    var storedOptions: [String: ModelOptionValue] {
        guard let enabled, let option = AutoThinkingProfile.thinkingOption else { return [:] }
        return [option.id: .bool(option.inverted ? !enabled : enabled)]
    }

    var expectedThinkingMode: String? {
        switch self {
        case .default: nil
        case .on: "enabled"
        case .off: "disabled"
        }
    }

    /// The last prompt token: `\n` (adaptive, the model's first token decides), `<mm:think>`, `</mm:think>`.
    var expectedLastToken: Int {
        switch self {
        case .default: 10
        case .on: 200_059
        case .off: 200_060
        }
    }

    var expectedRail: String {
        switch self {
        case .default: ""
        case .on: "<mm:think>"
        case .off: "</mm:think>"
        }
    }

    var expectedSystemLine: String {
        "Current thinking mode: \(expectedThinkingMode ?? "adaptive")."
    }
}

/// The chat surfaces a Thinking choice must survive.
enum M31RequestShape: String, CaseIterable, Sendable {
    /// Ordinary chat turn, frozen controls applied.
    case chat
    /// Chat turn with tools enabled (tool_choice auto): the first step of a tool loop.
    case toolTurn
    /// A tool-loop continuation: the agent loop rebuilds the request after a tool result and reapplies
    /// the same frozen controls.
    case toolLoopStep
    /// Agent step carrying the frozen turn controls.
    case agentStep
    /// UI-owned agent step that carries no controls; ChatEngine reads the picker's persisted choice.
    case agentStepFromStore
    /// The next user turn of the same chat, after a reasoning answer.
    case followUpTurn

    var appliesTurnControls: Bool { self != .agentStepFromStore }

    static let tool = OsaurusCore.Tool(
        type: "function",
        function: ToolFunction(
            name: "read_note",
            description: "Read a note",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["path": .object(["type": .string("string")])]),
                "required": .array([.string("path")]),
            ])
        )
    )

    var messages: [ChatMessage] {
        let user = ChatMessage(role: "user", content: "What is in note.md?")
        switch self {
        case .chat, .toolTurn, .agentStep, .agentStepFromStore:
            return [ChatMessage(role: "system", content: "You are a careful assistant."), user]
        case .toolLoopStep:
            return [
                ChatMessage(role: "system", content: "You are a careful assistant."), user,
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        OsaurusCore.ToolCall(
                            id: "call_1",
                            type: "function",
                            function: ToolCallFunction(name: "read_note", arguments: #"{"path":"note.md"}"#)
                        )
                    ],
                    tool_call_id: nil,
                    reasoning_content: "I should read the note."
                ),
                ChatMessage(role: "tool", content: "NOTE_CODE=007", tool_calls: nil, tool_call_id: "call_1"),
            ]
        case .followUpTurn:
            return [
                ChatMessage(role: "system", content: "You are a careful assistant."), user,
                ChatMessage(
                    role: "assistant",
                    content: "It says NOTE_CODE=007.",
                    tool_calls: nil,
                    tool_call_id: nil,
                    reasoning_content: "The note holds a code."
                ),
                ChatMessage(role: "user", content: "Repeat the code."),
            ]
        }
    }

    func request(model: String) -> ChatCompletionRequest {
        let usesTools = self == .toolTurn || self == .toolLoopStep
        var request = ChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: nil,
            max_tokens: 64,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: usesTools ? [Self.tool] : nil,
            tool_choice: usesTools ? .auto : nil,
            session_id: nil
        )
        if self == .agentStep || self == .agentStepFromStore || self == .toolLoopStep {
            request.isAgentRequest = true
        }
        return request
    }
}

/// Captures what ChatEngine hands the local model service.
actor M31Capture {
    var parameters: GenerationParameters?
    var messages: [ChatMessage] = []
    func set(_ parameters: GenerationParameters, _ messages: [ChatMessage]) {
        self.parameters = parameters
        self.messages = messages
    }
}

struct M31CaptureService: ModelService {
    let capture: M31Capture
    let id: String
    func isAvailable() -> Bool { true }
    func handles(requestedModel: String?) -> Bool { requestedModel == id }
    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        await capture.set(parameters, messages)
        return "ok"
    }
    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        await capture.set(parameters, messages)
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }
}

/// vmlx-swift's production text processor for this bundle, built the way `LLMModelFactory._load` builds
/// it, minus the weights.
struct M31Processor {
    let tokenizer: any MLXLMCommon.Tokenizer
    let processor: LLMUserInputProcessor

    init(bundle: URL, modelType: String = MiniMaxM31Bundle.modelType) async throws {
        let tokenizerDirectory = JangLoader.resolveTokenizerClassSubstitution(
            for: JangLoader.resolveChatTemplateSidecarSubstitution(
                for: JangLoader.resolveTokenizerDirectory(for: bundle)
            )
        )
        tokenizer = try await SwiftTransformersTokenizerLoader().load(from: tokenizerDirectory)
        let template = ChatTemplateResolver.text(modelDirectory: bundle)
        let jang = try? JangLoader.loadConfig(at: bundle)
        let generationConfig = try JSONDecoder().decode(
            GenerationConfigFile.self,
            from: Data(contentsOf: bundle.appendingPathComponent("generation_config.json"))
        )
        processor = LLMUserInputProcessor(
            tokenizer: tokenizer,
            configuration: ModelConfiguration(directory: bundle),
            modelType: modelType,
            // MiniMaxM3Model keeps LLMModel's default message generator.
            messageGenerator: DefaultMessageGenerator(),
            defaultAdditionalContext: LLMUserInputProcessor.defaultContext(
                modelType: modelType,
                capabilities: jang?.capabilities,
                generationConfig: generationConfig,
                chatConfig: jang?.chat,
                chatTemplate: template
            ),
            templateReadsEnableThinking: BailingThinkingTemplateContext.templateReadsEnableThinking(template)
        )
    }

    func prepare(
        messages: [ChatMessage],
        tools: [OsaurusCore.Tool]?,
        toolChoice: ToolChoiceOption?,
        context: [String: any Sendable]
    ) throws -> LMInput {
        let chat = try ModelRuntime.makeMLXChatMessages(messages, preserveStructuredToolHistory: true)
        let toolSpecs = ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: toolChoice)
        return try Device.withDefaultDevice(.cpu) {
            try processor.prepare(
                input: UserInput(chat: chat, tools: toolSpecs, additionalContext: context)
            )
        }
    }
}

/// `ModelRuntime.resolveNativeMTPLaunchPlan` (private; `RuntimePolicySourceTests` pins its calls) for this
/// bundle, step for step, plus the per-request half of `ModelRuntime.generateEventStream` /
/// `MLXBatchAdapter.generate` that turns the loaded strategy into `GenerateParameters`.
struct M31LoadPlan {
    let bundle: URL
    let settings: VMLXServerRuntimeSettings
    let status: MTPBundleStatus?
    let admission: NativeMTPAdmission
    let loadConfiguration: LoadConfiguration
    /// `SessionHolder.draftStrategy`.
    let loaded: MLXLMCommon.DraftStrategy?

    init(bundle: URL, mtp: VMLXServerMTPSettings) throws {
        self.bundle = bundle
        var settings = VMLXServerRuntimeSettings()
        settings.mtp = mtp
        self.settings = settings
        let configData = try Data(contentsOf: bundle.appendingPathComponent("config.json"))
        let jang = try? JangLoader.loadConfig(at: bundle)
        let status = try MTPBundleInspector.inspect(modelDirectory: bundle, jangConfig: jang)
        self.status = status
        let admission = NativeMTPAdmission(
            configData: configData,
            jangConfig: jang,
            status: status,
            externalDrafterSelected: settings.resolvedDFlash2Selection(
                configData: configData,
                bundleDirectory: bundle
            ) != nil
                || settings.bundledUnoAdapter(configData: configData, bundleDirectory: bundle) != nil
                || settings.bundledDSparkDrafter(configData: configData, bundleDirectory: bundle) != nil
        )
        try admission.validateLoad(settings: settings, externalDrafterSelected: admission.externalDrafterSelected)
        self.admission = admission
        loadConfiguration = settings.resolvedLoadConfiguration(
            base: .osaurusProduction,
            configData: configData,
            jangConfig: jang,
            status: status,
            bundleDirectory: bundle
        )
        var unclamped = settings
        unclamped.mtp.draftTokenLimit = nil
        loaded = unclamped.resolvedMTPDraftStrategy(
            configData: configData,
            jangConfig: jang,
            status: status,
            bundleDirectory: bundle
        )
    }

    /// The `GenerateParameters` a request issued under `mtp` carries (the holder is NOT reloaded).
    func generateParameters(requestMTP mtp: VMLXServerMTPSettings, promptTokens: Int = 512) throws
        -> MLXLMCommon.GenerateParameters
    {
        let requested = try admission.requestStrategy(loaded: loaded, mtp: mtp)
        let effective = MLXBatchAdapter.effectiveDraftStrategy(
            generation: GenerationParameters(temperature: nil, maxTokens: 64),
            draftStrategy: requested,
            promptTokenCount: promptTokens
        )
        var parameters = ModelRuntime.makeGenerateParameters(
            temperature: 1,
            maxTokens: 64,
            topP: 0.95,
            repetitionPenalty: nil,
            draftStrategy: effective
        )
        parameters.nativeMTPDepthPolicy = MLXBatchAdapter.nativeMTPDepthPolicy(mtp)
        return parameters
    }

    var drafterDirectory: URL { bundle.appendingPathComponent("dspark", isDirectory: true) }
}

extension MLXLMCommon.DraftStrategy? {
    /// The drafter directory when this is `.dspark`, else nil.
    var m31DSparkPath: String? {
        guard case .dspark(let path)? = self else { return nil }
        return path.standardizedFileURL.path
    }
}

/// The composer segment -> the settings value `ServerController.saveRuntimeSettings` persists.
func m31SavedMTP(segment: String?) throws -> VMLXServerMTPSettings {
    let mode = try #require(NativeMTPSelectionDefault.mode(for: segment))
    return NativeMTPSelectionDefault.adaptiveSelection(.init(mode: mode))
}

// MARK: - Reasoning

@Suite("MiniMax-M3.1 selector -> vmlx-swift: Reasoning")
struct MiniMaxM31ReasoningPlumbingTests {
    private func engine(
        capture: M31Capture,
        capability: LocalReasoningCapability.Capability,
        stored: [String: ModelOptionValue]
    ) -> ChatEngine {
        ChatEngine(
            services: [M31CaptureService(capture: capture, id: MiniMaxM31Bundle.modelID)],
            installedModelsProvider: { [] },
            reasoningCapabilityProvider: { _ in capability },
            // The picker's per-model store, which UI-owned agent loops read.
            agentModelOptionsProvider: { _ in stored.isEmpty ? nil : stored },
            agentReasoningChoicesProvider: { id, _ in
                AgentGenerationReasoningChoices.resolved(
                    modelID: id,
                    localCapability: capability,
                    efforts: nil,
                    options: AutoThinkingProfile.options
                )
            },
            source: .chatUI
        )
    }

    /// One request through ChatEngine, then the template context `MLXBatchAdapter.prepareInput` builds.
    private func dispatch(
        _ shape: M31RequestShape,
        choice: M31Reasoning,
        capability: LocalReasoningCapability.Capability
    ) async throws -> (
        request: ChatCompletionRequest, messages: [ChatMessage], parameters: GenerationParameters,
        context: [String: any Sendable]
    ) {
        let capture = M31Capture()
        let engine = engine(capture: capture, capability: capability, stored: choice.storedOptions)
        var request = shape.request(model: MiniMaxM31Bundle.modelID)
        if shape.appliesTurnControls {
            ChatTurnGenerationControls.capture(activeModelOptions: choice.storedOptions).apply(to: &request)
        }
        _ = try await engine.completeChat(request: request)
        let parameters = try #require(await capture.parameters)
        let context = MLXBatchAdapter.additionalContext(
            for: parameters,
            modelName: MiniMaxM31Bundle.modelID,
            toolChoice: request.tool_choice
        )
        return (request, await capture.messages, parameters, context)
    }

    @Test("Fixture is the published bundle's metadata and carries no weights")
    func fixtureProvenance() throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        for (name, expected) in MiniMaxM31Bundle.published {
            #expect(MiniMaxM31Bundle.sha256(try Data(contentsOf: bundle.appendingPathComponent(name))) == expected)
        }
        let shard = try FileManager.default.attributesOfItem(
            atPath: bundle.appendingPathComponent(MiniMaxM31Bundle.drafterShard).path
        )
        #expect((shard[.size] as? NSNumber)?.intValue == 0)
        let config = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("config.json")))
                as? [String: Any]
        )
        #expect(config["model_type"] as? String == MiniMaxM31Bundle.modelType)
    }

    @Test("Reasoning row: a tri-state toggle whose untouched Default is the template's Adaptive mode")
    func reasoningRowIsTriStateAdaptive() throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        let capability = LocalReasoningCapability.detect(at: bundle)
        #expect(capability.supportsThinking)
        #expect(capability.isToggleableThinking)
        // `supportsUnspecifiedDefault` in the composer: Default / On / Off, Default sends nothing.
        #expect(capability.preservesOmittedThinking)
        #expect(capability.declaredDefaultThinkingOn == nil)

        // No family profile claims the id, so the selector uses AutoThinkingProfile's inverted
        // `disableThinking` option for this toggleable bundle.
        for id in [MiniMaxM31Bundle.modelID, "MiniMax-M3.1-Flash-JANGHT1.9", "minimax-m3.1-flash-janght1.9"] {
            #expect(ModelProfileRegistry.profiles.allSatisfy { !$0.matches(modelId: id) }, "\(id)")
        }
        #expect(AutoThinkingProfile.thinkingOption?.id == "disableThinking")
        #expect(AutoThinkingProfile.thinkingOption?.inverted == true)
        #expect(AutoThinkingProfile.options.map(\.id) == ["disableThinking"])
        #expect(M31Reasoning.default.storedOptions.isEmpty)
        #expect(M31Reasoning.on.storedOptions == ["disableThinking": .bool(false)])
        #expect(M31Reasoning.off.storedOptions == ["disableThinking": .bool(true)])

        // The bundle declares no effort control, so no effort key can ride along with the toggle.
        let jang = try Data(contentsOf: bundle.appendingPathComponent("jang_config.json"))
        #expect(DeclaredReasoningEffort.parseJangDeclaration(data: jang) == nil)

        // Custom-agent editor: the Thinking switch is offered and both explicit values validate.
        let choices = AgentGenerationReasoningChoices.resolved(
            modelID: MiniMaxM31Bundle.modelID,
            localCapability: capability,
            efforts: nil,
            options: AutoThinkingProfile.options
        )
        #expect(choices.showsThinkingControl)
        for enabled in [true, false] {
            try choices.validate(settings: AgentGenerationSettings(enableThinking: enabled))
        }

        // The untouched policy adds no thinking control on any surface.
        for agentOrTool in [false, true] {
            #expect(
                AgentReasoningPolicy.defaultEnableThinking(
                    isAgentOrToolRequest: agentOrTool,
                    explicitEnableThinking: nil,
                    explicitReasoningEffort: nil,
                    modelOptions: [:],
                    usesReasoningEffortControl: false,
                    capability: capability
                ) == nil
            )
        }

        // vmlx-swift's bundle default context is empty, so omission reaches the template as Adaptive.
        let template = try #require(ChatTemplateResolver.text(modelDirectory: bundle))
        #expect(MiniMaxM31Bundle.sha256(Data(template.utf8)) == MiniMaxM31Bundle.published["chat_template.jinja"])
        let generationConfig = try JSONDecoder().decode(
            GenerationConfigFile.self,
            from: Data(contentsOf: bundle.appendingPathComponent("generation_config.json"))
        )
        let jangConfig = try? JangLoader.loadConfig(at: bundle)
        #expect(
            LLMUserInputProcessor.defaultContext(
                modelType: MiniMaxM31Bundle.modelType,
                capabilities: jangConfig?.capabilities,
                generationConfig: generationConfig,
                chatConfig: jangConfig?.chat,
                chatTemplate: template
            ) == nil
        )
    }

    @Test(
        "Reasoning choice -> request modelOptions -> enable_thinking -> thinking_mode on every chat surface",
        arguments: M31Reasoning.allCases
    )
    func reasoningChoiceReachesTemplateContext(choice: M31Reasoning) async throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        let capability = LocalReasoningCapability.detect(at: bundle)
        for shape in M31RequestShape.allCases {
            let (_, _, parameters, context) = try await dispatch(shape, choice: choice, capability: capability)
            // Request: the inverted stored option, or nothing for Default.
            #expect(parameters.modelOptions["disableThinking"]?.boolValue == choice.enabled.map { !$0 }, "\(shape)")
            #expect(parameters.modelOptions["reasoningEffort"] == nil, "\(shape)")
            // MLXBatchAdapter's template context: enable_thinking absent / true / false, nothing else.
            #expect(context.keys.contains("enable_thinking") == (choice != .default), "\(shape)")
            #expect(context["enable_thinking"] as? Bool == choice.enabled, "\(shape)")
            #expect(context["reasoning_effort"] == nil, "\(shape)")
            #expect(context["thinking_mode"] == nil, "\(shape)")
            // vmlx-swift's MiniMax-M3 adapter, the first thing LLMUserInputProcessor.prepare applies.
            let applied = MiniMaxM3ThinkingTemplateContext.apply(
                additionalContext: context,
                modelType: MiniMaxM31Bundle.modelType
            )
            #expect(applied?["thinking_mode"] as? String == choice.expectedThinkingMode, "\(shape)")
            #expect(applied?["enable_thinking"] == nil, "\(shape)")
        }
    }

    @Test(
        "A custom agent's Thinking override reaches thinking_mode while the model row is untouched",
        arguments: [true, false]
    )
    func agentThinkingOverride(enabled: Bool) async throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        let capability = LocalReasoningCapability.detect(at: bundle)
        let capture = M31Capture()
        let engine = engine(capture: capture, capability: capability, stored: [:])
        var request = M31RequestShape.agentStep.request(model: MiniMaxM31Bundle.modelID)
        var controls = ChatTurnGenerationControls.capture(activeModelOptions: [:])
        controls.agentSettings = AgentGenerationSettings(enableThinking: enabled)
        controls.apply(to: &request)
        _ = try await engine.completeChat(request: request)
        let parameters = try #require(await capture.parameters)
        let context = MLXBatchAdapter.additionalContext(for: parameters, modelName: MiniMaxM31Bundle.modelID)
        #expect(context["enable_thinking"] as? Bool == enabled)
        #expect(
            MiniMaxM3ThinkingTemplateContext.apply(additionalContext: context, modelType: MiniMaxM31Bundle.modelType)?[
                "thinking_mode"
            ] as? String == (enabled ? "enabled" : "disabled")
        )
    }

    @Test(
        "vmlx-swift's processor and the bundle tokenizer render the chosen rail: last token and system line",
        arguments: M31Reasoning.allCases
    )
    func processorRendersChosenRail(choice: M31Reasoning) async throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        let capability = LocalReasoningCapability.detect(at: bundle)
        let rig = try await M31Processor(bundle: bundle)
        #expect(rig.tokenizer.convertTokenToId("<mm:think>") == 200_059)
        #expect(rig.tokenizer.convertTokenToId("</mm:think>") == 200_060)
        #expect(rig.tokenizer.encode(text: "\n", addSpecialTokens: false) == [10])

        for shape in [M31RequestShape.chat, .toolLoopStep, .agentStepFromStore, .followUpTurn] {
            let (request, messages, _, context) = try await dispatch(shape, choice: choice, capability: capability)
            #expect(!messages.isEmpty)
            let prepared = try rig.prepare(
                messages: messages,
                tools: request.tools,
                toolChoice: request.tool_choice,
                context: context
            )
            let ids = try #require(prepared.text.tokenIds)
            #expect(ids.last == choice.expectedLastToken, "\(shape): tail \(ids.suffix(4))")
            let rendered = rig.tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
            print(
                "M31-RECEIPT reasoning=\(choice.rawValue) shape=\(shape.rawValue) context=\(context.keys.sorted().map { "\($0)=\(context[$0]!)" }) prompt_tokens=\(ids.count) tail_ids=\(Array(ids.suffix(4))) tail=\(String(rendered.suffix(16)).debugDescription) cache_scope=\(prepared.cacheScopeSalt ?? "nil")"
            )
            #expect(
                rendered.hasSuffix("]~b]ai\n" + choice.expectedRail),
                "\(shape): \(rendered.suffix(40).debugDescription)"
            )
            #expect(rendered.contains(choice.expectedSystemLine), "\(shape)")
            for other in M31Reasoning.allCases where other != choice {
                #expect(!rendered.contains(other.expectedSystemLine), "\(shape)")
            }
            // The mode is part of the prefix-cache scope (it changes the system line and the suffix).
            if let mode = choice.expectedThinkingMode {
                #expect(prepared.cacheScopeSalt?.contains("thinking_mode=\(mode)") == true, "\(shape)")
            } else {
                #expect(prepared.cacheScopeSalt?.contains("thinking_mode") != true, "\(shape)")
            }
            if shape == .toolLoopStep {
                #expect(rendered.contains("NOTE_CODE=007"))
                #expect(rendered.contains("read_note"))
            }
        }
    }

    @Test("Control: without the bundle's minimax_m3 model_type the same On request renders Adaptive")
    func controlModelTypeGatesTheAdapter() async throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        let capability = LocalReasoningCapability.detect(at: bundle)
        let (request, messages, _, context) = try await dispatch(.chat, choice: .on, capability: capability)
        #expect(context["enable_thinking"] as? Bool == true)
        let unmapped = try await M31Processor(bundle: bundle, modelType: "minimax")
        let ids = try #require(
            unmapped.prepare(
                messages: messages,
                tools: request.tools,
                toolChoice: request.tool_choice,
                context: context
            )
            .text.tokenIds
        )
        // The template never reads enable_thinking; only the M3 adapter turns it into thinking_mode.
        #expect(ids.last == M31Reasoning.default.expectedLastToken)
        #expect(
            unmapped.tokenizer.decode(tokenIds: ids, skipSpecialTokens: false).contains(
                "Current thinking mode: adaptive."
            )
        )
    }
}

// MARK: - Speculative Decoding / native MTP

@Suite("MiniMax-M3.1 selector -> vmlx-swift: Speculative Decoding")
struct MiniMaxM31SpeculativePlumbingTests {
    private static let segments: [String?] = [nil, "off", "auto"]

    @Test("Picker row: shown for the bundled DSpark drafter, Off (AR) and On (Adaptive), default On")
    func pickerRow() throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        let status = try #require(
            ModelRuntime.inspectLoadingModelMTP(name: MiniMaxM31Bundle.modelID, directory: bundle)
        )
        #expect(status.bundledDSpark)
        #expect(status.speculationAvailable)  // the composer shows the row
        #expect(!status.speculationBlocked)  // ... with both segments, Off (AR) and On (Adaptive)
        #expect(status.familyDefaultOn)  // untouched (family default) displays On (Adaptive)
        #expect(status.speculationCapabilityDescription == "Bundled DSpark drafter detected")
        // The segments map to exactly three saved modes.
        #expect(NativeMTPSelectionDefault.mode(for: nil) == .familyDefault)
        #expect(NativeMTPSelectionDefault.mode(for: "off") == .off)
        #expect(NativeMTPSelectionDefault.mode(for: "auto") == .auto)

        // The row exists only because of dspark/: without it there is nothing to offer.
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("dspark"))
        let headless = try #require(
            ModelRuntime.inspectLoadingModelMTP(name: MiniMaxM31Bundle.modelID, directory: bundle)
        )
        #expect(!headless.speculationAvailable)
    }

    @Test("Off (AR) -> draftStrategy nil; On (Adaptive) and the untouched default -> .dspark(<bundle>/dspark)")
    func choiceReachesGenerateParameters() throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        let configData = try Data(contentsOf: bundle.appendingPathComponent("config.json"))
        // The load plan's MiMo/N2 shortcut does not apply to this bundle.
        #expect(!ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(MiniMaxM31Bundle.modelID, configData: configData))
        for segment in Self.segments {
            let mtp = try m31SavedMTP(segment: segment)
            let plan = try M31LoadPlan(bundle: bundle, mtp: mtp)
            let parameters = try plan.generateParameters(requestMTP: mtp)
            print(
                "M31-RECEIPT speculative=\(segment ?? "default(nil)") saved_mode=\(mtp.mode.rawValue) loaded=\(plan.loaded?.kindName ?? "none") request=\(parameters.draftStrategy?.kindName ?? "none") drafter=\(parameters.draftStrategy.m31DSparkPath ?? "-") native_mtp_load=\(plan.loadConfiguration.nativeMTP) depth_policy=\(parameters.nativeMTPDepthPolicy)"
            )
            #expect(!plan.loadConfiguration.nativeMTP, "\(segment ?? "default")")
            if segment == "off" {
                #expect(plan.loaded == nil)
                #expect(!plan.admission.externalDrafterSelected)
                #expect(parameters.draftStrategy == nil)
            } else {
                #expect(plan.admission.externalDrafterSelected)
                #expect(plan.loaded.m31DSparkPath == plan.drafterDirectory.standardizedFileURL.path)
                #expect(parameters.draftStrategy.m31DSparkPath == plan.drafterDirectory.standardizedFileURL.path)
                #expect(parameters.draftStrategy?.kindName == "dspark")
                // DSpark runs on the solo lane only.
                #expect(MLXBatchAdapter.requiresSoloLease(maxBatchSize: 8, draftStrategy: parameters.draftStrategy))
                // A short prompt does not drop it (that gate is native MTP's).
                #expect(
                    try plan.generateParameters(requestMTP: mtp, promptTokens: 3).draftStrategy.m31DSparkPath != nil
                )
            }
        }
    }

    @Test("Switching the row is a possible load input; Off decodes plainly even on a holder loaded with the drafter")
    func switchingReloadsAndOffNeverDrafts() throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        func runtime(_ segment: String?) throws -> VMLXServerRuntimeSettings {
            var settings = VMLXServerRuntimeSettings()
            settings.mtp = try m31SavedMTP(segment: segment)
            return settings
        }
        for previous in Self.segments {
            for next in Self.segments {
                let reloads = ServerController.loadedModelRuntimeInputsRequireRefresh(
                    previous: try runtime(previous),
                    next: try runtime(next)
                )
                // Every change of the row is flagged as a possible load input (settings-level, any bundle);
                // re-selecting the same value is not. Whether THIS bundle's resident model reloads is decided per
                // model (`ModelRuntime.applySpeculativeLoadChange`): it does not, see
                // SpeculativeToggleResidencyTests.
                #expect(reloads == (previous != next), "\(previous ?? "default") -> \(next ?? "default")")
            }
        }

        let on = try M31LoadPlan(bundle: bundle, mtp: try m31SavedMTP(segment: "auto"))
        let untouched = try M31LoadPlan(bundle: bundle, mtp: try m31SavedMTP(segment: nil))
        #expect(on.loaded.m31DSparkPath == untouched.loaded.m31DSparkPath)
        #expect(on.loadConfiguration.nativeMTP == untouched.loadConfiguration.nativeMTP)

        // Even without the reload, an Off request on the drafter-loaded holder carries no strategy, so vmlx
        // never attaches or runs the drafter for it (`TokenIterator` gates both on `draftStrategy`).
        let off = try m31SavedMTP(segment: "off")
        #expect(try on.admission.requestStrategy(loaded: on.loaded, mtp: off) == nil)
        #expect(ModelRuntime.requestDraftStrategy(on.loaded, mtp: off) == nil)
        #expect(try on.generateParameters(requestMTP: off).draftStrategy == nil)
        #expect(MLXBatchAdapter.nativeMTPDepthPolicy(off) == .fixed)

        // An On request on an Off-loaded holder that was NOT updated stays plain (no error, no phantom
        // strategy); `applySpeculativeLoadChange` updates the resident holder in place instead of reloading
        // (SpeculativeToggleResidencyTests).
        let offLoaded = try M31LoadPlan(bundle: bundle, mtp: off)
        #expect(try offLoaded.generateParameters(requestMTP: try m31SavedMTP(segment: "auto")).draftStrategy == nil)
    }

    @Test("Adaptive governs DSpark width: no depth, width or block size reaches the request, even from legacy settings")
    func adaptiveGovernsWidth() throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        // The drafter's trained block (7) is only Adaptive's starting width inside vmlx-swift.
        let drafter = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("dspark/config.json")))
                as? [String: Any]
        )
        #expect(drafter["dspark_block_size"] as? Int == 7)

        var legacy: [VMLXServerMTPSettings] = []
        for depth in 1 ... 3 {
            for limit in 1 ... 3 {
                for block in [nil, 4, 8] as [Int?] {
                    legacy.append(
                        .init(mode: .forceOn, draftTokenLimit: limit, dflash2BlockSize: block, explicitDepth: depth)
                    )
                    legacy.append(.init(mode: .auto, draftTokenLimit: limit, dflash2BlockSize: block))
                }
            }
        }
        for stored in legacy {
            let saved = NativeMTPSelectionDefault.adaptiveSelection(stored)
            #expect(saved.mode == .auto)
            #expect(saved.explicitDepth == nil && saved.draftTokenLimit == nil && saved.dflash2BlockSize == nil)
            // Saved or (hypothetically) raw, the strategy is the drafter path alone.
            for mtp in [saved, stored] {
                let plan = try M31LoadPlan(bundle: bundle, mtp: mtp)
                let strategy = try plan.generateParameters(requestMTP: mtp).draftStrategy
                #expect(strategy.m31DSparkPath == plan.drafterDirectory.standardizedFileURL.path)
                #expect(strategy?.nativeMTPDepth == nil && strategy?.dflash2BlockSize == nil)
                #expect(plan.loadConfiguration.nativeMTPManualDepth == nil)
            }
        }

        // Osaurus never pins vmlx-swift's DSpark diagnostic levers.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = try #require(FileManager.default.enumerator(at: packageRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator {
            let path = url.path
            if path.contains("/Tests/") || path.contains("/.build/") { continue }
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for lever in [
                "VMLX_DSPARK_WIDTH", "VMLX_DSPARK_MAX_DRAFT", "setenv(\"VMLX_DSPARK", "setenv(\"VMLX_DSV41_DSPARK",
            ] {
                #expect(!source.contains(lever), "\(url.lastPathComponent) mentions \(lever)")
            }
        }
        #expect(scanned > 100)
    }

    @Test("Native MTP: no head or tensors, never offered as native, never requested")
    func nativeMTPNeverOfferedOrRequested() throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        // The published weight index names no MTP tensor; the config declares no MTP layers.
        let index = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: bundle.appendingPathComponent("model.safetensors.index.json"))
            )
                as? [String: Any]
        )
        let names = try #require(index["weight_map"] as? [String: String]).keys
        #expect(names.count == 3416)
        #expect(names.filter { $0.lowercased().contains("mtp") || $0.lowercased().contains("nextn") }.isEmpty)
        let configData = try Data(contentsOf: bundle.appendingPathComponent("config.json"))
        #expect(!ModelRuntime.modelTypeIsMTPControlTarget(configData: configData))

        let status = try MTPBundleInspector.inspect(
            modelDirectory: bundle,
            jangConfig: try? JangLoader.loadConfig(at: bundle)
        )
        #expect(!status.bundleHasMTP && status.tensorCount == 0 && status.configuredLayers == 0)
        let row = try #require(ModelRuntime.inspectLoadingModelMTP(name: MiniMaxM31Bundle.modelID, directory: bundle))
        #expect(!row.bundleHasMTP && !row.isTargetMTPFamily)
        // Resident-model capability (the composer's other source) never reads it as a native head.
        #expect(!FloatingInputCard.statusIndicatesNativeMTPHead(row.statusLine))

        // Every mode, legacy depth and limit: no load plan or request carries native MTP.
        for mode in VMLXMTPServerMode.allCases {
            for depth in [nil, 1, 2, 3] as [Int?] {
                for limit in [nil, 1, 3] as [Int?] {
                    let mtp = VMLXServerMTPSettings(mode: mode, draftTokenLimit: limit, explicitDepth: depth)
                    let plan = try M31LoadPlan(bundle: bundle, mtp: mtp)
                    #expect(!plan.loadConfiguration.nativeMTP)
                    #expect(plan.loaded?.usesNativeMTP != true)
                    #expect(try plan.generateParameters(requestMTP: mtp).draftStrategy?.usesNativeMTP != true)
                }
            }
        }

        // The native decision alone (drafter removed): never speculative; an explicit native depth is refused.
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("dspark"))
        for mode in [VMLXMTPServerMode.auto, .familyDefault, .off] {
            let plan = try M31LoadPlan(bundle: bundle, mtp: .init(mode: mode))
            #expect(plan.loaded == nil)
            #expect(try plan.generateParameters(requestMTP: .init(mode: mode)).draftStrategy == nil)
            var settings = VMLXServerRuntimeSettings()
            settings.mtp = .init(mode: mode)
            #expect(
                settings.resolvedMTPLaunch(configData: configData, jangConfig: nil, status: plan.status).launchMode
                    == .off
            )
        }
        #expect(throws: NativeMTPAdmission.Refusal.self) {
            _ = try M31LoadPlan(bundle: bundle, mtp: .init(mode: .forceOn, explicitDepth: 2))
        }
    }
}
