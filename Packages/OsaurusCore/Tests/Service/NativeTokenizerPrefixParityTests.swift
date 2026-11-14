import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing
import VMLXHub
import VMLXJinja
import VMLXTokenizers

@testable import MLXLLM
@testable import OsaurusCore

/// Opt-in CPU tokenizer diagnostics. Private requests and artifacts are supplied
/// by the runner; no model, model container, cache coordinator or weights load.
/// The tiny split:false regression is deliberately RED until the discrepancy
/// has been observed natively and a separately reviewed fix is authorized.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OSAURUS_NATIVE_TOKENIZER_PARITY_FIXTURE"] != nil))
struct NativeTokenizerPrefixParityTests {
    private struct Fixture: Decodable {
        var bundlePath: String
        var runtimeSettingsPath: String
        var modelKey: String
        var referenceAppSource: String
        var referenceRuntime: String
        var cases: [Case]

        struct Case: Decodable {
            var sequence: Int
            var requestPath: String
            var promptCount: Int
            var prefixCount: Int
            var prefixHash: String
        }
    }

    private struct StockContractFixture: Decodable {
        var nativeFixturePath: String
        var stockManifestPath: String
        var stockManifestSHA256: String
        var expectedRequestHashes: [String: String]
        var expectedCacheScope: String
        var expectedResolvedSalt: String
        var expectedPrefixHashes: [String: String]
    }

    private struct StockManifest: Decodable {
        var tokenizerSHA256: String
        var bundlePath: String
        var rows: [Row]
        enum CodingKeys: String, CodingKey {
            case tokenizerSHA256 = "tokenizer_sha256"
            case bundlePath = "bundle_path"
            case rows
        }
        struct Row: Decodable {
            var sequence: Int
            var fullCount: Int
            var noGenerationCount: Int
            var railIDs: [Int]
            var hashes: [String: String]
            enum CodingKeys: String, CodingKey {
                case sequence, hashes
                case fullCount = "full_count"
                case noGenerationCount = "no_generation_count"
                case railIDs = "rail_ids"
            }
        }
    }

    private func checkedStockData(_ name: String, row: StockManifest.Row, directory: URL) throws -> Data {
        let expected = try #require(row.hashes[name], "Every external golden must have an explicit SHA256")
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        try #require(digest(data) == expected, "Stock golden changed: \(name)")
        return data
    }

    private struct Request: Decodable {
        var model: String
        var input: [ChatMessage]
        var tools: [OsaurusCore.Tool]
        var toolChoice: ToolChoiceOption
        var generation: [String: OsaurusCore.JSONValue]
    }

    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ value: Any, named name: String, in directory: URL) throws {
        try json(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    @Test(arguments: [60, 61])
    func productionCPUTokenizerMatchesRetainedNativePrefix(sequence: Int) async throws {
        let env = ProcessInfo.processInfo.environment
        let fixturePath = try #require(env["OSAURUS_NATIVE_TOKENIZER_PARITY_FIXTURE"])
        let outputPath = try #require(env["OSAURUS_NATIVE_TOKENIZER_PARITY_OUTPUT"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let row = try #require(fixture.cases.first { $0.sequence == sequence })
        let bundle = URL(fileURLWithPath: fixture.bundlePath)
        let output = URL(fileURLWithPath: outputPath).appendingPathComponent("request-\(sequence)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let requestData = try Data(contentsOf: URL(fileURLWithPath: row.requestPath))
        let request = try JSONDecoder().decode(Request.self, from: requestData)
        // These retained requests have no overrides. A new/missing policy input
        // is a failure, never permission to guess a comparable namespace.
        try #require(request.generation.isEmpty)
        try #require(MemoryLayout<Int>.size == 8)
        let configData = try Data(contentsOf: bundle.appendingPathComponent("config.json"))
        let modelConfig = try #require(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        try #require(modelConfig["model_type"] as? String == "llama")
        let jang = try JangLoader.loadConfig(at: bundle)
        let generationConfig = try JSONDecoder().decode(
            GenerationConfigFile.self,
            from: Data(contentsOf: bundle.appendingPathComponent("generation_config.json")))
        let templateSource = try String(contentsOf: bundle.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        let tokenizerConfig = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: bundle.appendingPathComponent("tokenizer_config.json"))) as? [String: Any])
        try #require(tokenizerConfig["chat_template"] as? String == templateSource)
        try #require(Qwen3XMLToolTemplate.matchesTemplate(templateSource))

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: bundle)
        let controllable = try #require(tokenizer as? any GenerationPromptControllableTokenizer)
        let chat = try ModelRuntime.makeMLXChatMessages(request.input, preserveStructuredToolHistory: true)
        let tools = ModelRuntime.makeTokenizerTools(tools: request.tools, toolChoice: request.toolChoice)
        let generation = GenerationParameters(temperature: nil, maxTokens: 65_536)
        let requestContext = MLXBatchAdapter.additionalContext(
            for: generation, modelName: request.model, toolChoice: request.toolChoice)
        let defaultContext = LLMUserInputProcessor.defaultContext(
            modelType: "llama", capabilities: jang.capabilities, generationConfig: generationConfig,
            chatConfig: jang.chat, chatTemplate: templateSource)
        let mergedContext = try llmMergedAdditionalContext(
            defaultAdditionalContext: defaultContext, requestAdditionalContext: requestContext, modelType: "llama")
        let processor = LLMUserInputProcessor(
            tokenizer: tokenizer, configuration: ModelConfiguration(directory: bundle), modelType: "llama",
            messageGenerator: DefaultMessageGenerator(), defaultAdditionalContext: defaultContext,
            templateReadsEnableThinking: BailingThinkingTemplateContext.templateReadsEnableThinking(templateSource))
        let settings = try JSONDecoder().decode(VMLXServerRuntimeSettings.self,
            from: Data(contentsOf: URL(fileURLWithPath: fixture.runtimeSettingsPath)))

        // The production processor constructs its LMInput array on CPU only.
        // Computing text-only salt does not evaluate model/cache tensors.
        let prepared = try Device.withDefaultDevice(.cpu) {
            try processor.prepare(input: UserInput(chat: chat, tools: tools, additionalContext: requestContext))
        }
        let ids = try #require(prepared.text.tokenIds)
        let coordinatorConfig = settings.cacheCoordinatorConfig(modelKey: fixture.modelKey)
        var parameters = GenerateParameters()
        let resolved = coordinatorConfig.resolveKVPolicy(
            kvMode: parameters.kvMode, maxKVSize: parameters.maxKVSize, promptTokenCount: ids.count)
        parameters.kvMode = resolved.kvMode
        parameters.maxKVSize = resolved.maxKVSize
        // Llama does not adopt PrefixCacheInvariantModel, so omitting the model
        // object does not elide any model-declared cache policy component.
        let salt = computeCacheSalt(for: prepared, parameters: parameters)
        let selected = Array(ids.prefix(row.prefixCount))
        let actualHash = DiskCache.hashTokens(selected, modelKey: fixture.modelKey, mediaSalt: salt)

        // Native Jinja reconstruction is only accepted when native re-encoding
        // exactly equals the actual production processor IDs. The bridge's
        // configured XML branch deliberately passes the original tool specs.
        let messages = DefaultMessageGenerator().generate(messages: chat)
        var renderContext: [String: VMLXJinja.Value] = [
            "messages": .array(try messages.map { try VMLXJinja.Value(any: $0) }),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools { renderContext["tools"] = .array(try tools.map { try VMLXJinja.Value(any: $0) }) }
        for (key, value) in mergedContext ?? [:] { renderContext[key] = try VMLXJinja.Value(any: value) }
        if let thinking = mergedContext?["enable_thinking"] { renderContext["thinking"] = try VMLXJinja.Value(any: thinking) }
        for key in ["bos_token", "eos_token", "unk_token", "pad_token"] {
            if let token = tokenizerConfig[key] as? String { renderContext[key] = .string(token) }
        }
        let rendered = try VMLXJinja.Template(templateSource, with: .init(lstripBlocks: true, trimBlocks: true)).render(renderContext)
        let renderedIDs = tokenizer.encode(text: rendered, addSpecialTokens: false)
        let noRail = try controllable.applyChatTemplate(
            messages: messages, tools: tools, additionalContext: mergedContext, addGenerationPrompt: false)
        let namespace: [String: Any] = [
            "reference_app_source": fixture.referenceAppSource,
            "reference_runtime": fixture.referenceRuntime,
            "request_sha256": digest(requestData), "template_sha256": digest(Data(templateSource.utf8)),
            "model_key": fixture.modelKey, "cache_scope": prepared.cacheScopeSalt.map { $0 as Any } ?? NSNull(),
            "resolved_salt": salt.map { $0 as Any } ?? NSNull(), "kv_mode": String(describing: parameters.kvMode),
            "max_kv": parameters.maxKVSize.map { $0 as Any } ?? NSNull(),
            "kv_bits": parameters.kvBits.map { $0 as Any } ?? NSNull(),
            "kv_group": parameters.kvGroupSize, "quantized_kv_start": parameters.quantizedKVStart,
            "native_prompt_count": ids.count, "expected_prompt_count": row.promptCount,
            "prefix_count": row.prefixCount, "hashed_prefix_count": selected.count,
            "prefix_hash": actualHash, "expected_prefix_hash": row.prefixHash,
            "no_generation_prompt_count": noRail.count, "render_reencodes_exactly": renderedIDs == ids,
            "cpu_only": true, "weights_loaded": false,
        ]
        try write(namespace, named: "receipt.json", in: output)
        try write(ids, named: "native-ids.json", in: output)
        try write(renderedIDs, named: "native-render-reencoded-ids.json", in: output)
        try write(noRail, named: "native-no-generation-prompt-ids.json", in: output)
        try Data(rendered.utf8).write(to: output.appendingPathComponent("native-render.txt"), options: .atomic)
        try write(messages, named: "native-messages.json", in: output)
        try write(tools ?? [], named: "native-tools.json", in: output)
        try write(mergedContext ?? [:], named: "native-template-context.json", in: output)

        #expect(ids.count == row.promptCount)
        #expect(selected.count == row.prefixCount)
        #expect(renderedIDs == ids, "Do not use the reconstructed render as actual input unless this matches")
        #expect(noRail.count == row.prefixCount)
        #expect(ids.prefix(noRail.count).elementsEqual(noRail))
        #expect(actualHash == row.prefixHash, "Native saved-prefix identity must match, not just token counts")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OSAURUS_NATIVE_TOKENIZER_STOCK_FIXTURE"] != nil),
          arguments: [60, 61])
    func productionCPUTokenizerMatchesStockBundleContract(sequence: Int) async throws {
        let env = ProcessInfo.processInfo.environment
        let contractPath = try #require(env["OSAURUS_NATIVE_TOKENIZER_STOCK_FIXTURE"])
        let outputPath = try #require(env["OSAURUS_NATIVE_TOKENIZER_STOCK_OUTPUT"])
        let contractData = try Data(contentsOf: URL(fileURLWithPath: contractPath))
        let contract = try JSONDecoder().decode(StockContractFixture.self, from: contractData)
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: contract.nativeFixturePath)))
        let row = try #require(fixture.cases.first { $0.sequence == sequence })
        let manifestURL = URL(fileURLWithPath: contract.stockManifestPath)
        let manifestData = try Data(contentsOf: manifestURL)
        try #require(digest(manifestData) == contract.stockManifestSHA256)
        let manifest = try JSONDecoder().decode(StockManifest.self, from: manifestData)
        let stock = try #require(manifest.rows.first { $0.sequence == sequence })
        let goldenDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent("request-\(sequence)")
        let expectedFullRender = try checkedStockData("full-render.txt", row: stock, directory: goldenDirectory)
        let expectedNoRailRender = try checkedStockData("no-generation-render.txt", row: stock, directory: goldenDirectory)
        let expectedFullData = try checkedStockData("full-ids.json", row: stock, directory: goldenDirectory)
        let expectedNoRailData = try checkedStockData("no-generation-ids.json", row: stock, directory: goldenDirectory)
        let expectedFull = try JSONDecoder().decode([Int].self, from: expectedFullData)
        let expectedNoRail = try JSONDecoder().decode([Int].self, from: expectedNoRailData)
        let expectedPrefixHash = try #require(contract.expectedPrefixHashes[String(sequence)])
        try #require(expectedFull.count == stock.fullCount && expectedNoRail.count == stock.noGenerationCount)
        try #require(!stock.railIDs.isEmpty && expectedFull == expectedNoRail + stock.railIDs)
        // These are new stock-derived keys, not renamed historical saved keys.
        try #require(expectedPrefixHash != row.prefixHash)
        try #require(MemoryLayout<Int>.size == 8)

        let bundle = URL(fileURLWithPath: fixture.bundlePath).resolvingSymlinksInPath()
        try #require(bundle.path == URL(fileURLWithPath: manifest.bundlePath).resolvingSymlinksInPath().path)
        let tokenizerData = try Data(contentsOf: bundle.appendingPathComponent("tokenizer.json"))
        try #require(digest(tokenizerData) == manifest.tokenizerSHA256)
        let requestData = try Data(contentsOf: URL(fileURLWithPath: row.requestPath))
        let expectedRequestHash = try #require(contract.expectedRequestHashes[String(sequence)])
        try #require(digest(requestData) == expectedRequestHash, "Use the exact retained production request")
        let request = try JSONDecoder().decode(Request.self, from: requestData)
        try #require(request.generation.isEmpty)
        let configData = try Data(contentsOf: bundle.appendingPathComponent("config.json"))
        let modelConfig = try #require(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        try #require(modelConfig["model_type"] as? String == "llama")
        let jang = try JangLoader.loadConfig(at: bundle)
        let generationConfig = try JSONDecoder().decode(GenerationConfigFile.self,
            from: Data(contentsOf: bundle.appendingPathComponent("generation_config.json")))
        let templateSource = try String(contentsOf: bundle.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        let tokenizerConfig = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: bundle.appendingPathComponent("tokenizer_config.json"))) as? [String: Any])
        try #require(tokenizerConfig["chat_template"] as? String == templateSource)
        try #require(Qwen3XMLToolTemplate.matchesTemplate(templateSource))
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: bundle)
        let controllable = try #require(tokenizer as? any GenerationPromptControllableTokenizer)
        let chat = try ModelRuntime.makeMLXChatMessages(request.input, preserveStructuredToolHistory: true)
        let tools = ModelRuntime.makeTokenizerTools(tools: request.tools, toolChoice: request.toolChoice)
        let generation = GenerationParameters(temperature: nil, maxTokens: 65_536)
        let requestContext = MLXBatchAdapter.additionalContext(
            for: generation, modelName: request.model, toolChoice: request.toolChoice)
        let defaultContext = LLMUserInputProcessor.defaultContext(
            modelType: "llama", capabilities: jang.capabilities, generationConfig: generationConfig,
            chatConfig: jang.chat, chatTemplate: templateSource)
        let mergedContext = try llmMergedAdditionalContext(
            defaultAdditionalContext: defaultContext, requestAdditionalContext: requestContext, modelType: "llama")
        let processor = LLMUserInputProcessor(
            tokenizer: tokenizer, configuration: ModelConfiguration(directory: bundle), modelType: "llama",
            messageGenerator: DefaultMessageGenerator(), defaultAdditionalContext: defaultContext,
            templateReadsEnableThinking: BailingThinkingTemplateContext.templateReadsEnableThinking(templateSource))
        // Production preparation under CPU only; no LanguageModel or weights.
        let prepared = try Device.withDefaultDevice(.cpu) {
            try processor.prepare(input: UserInput(chat: chat, tools: tools, additionalContext: requestContext))
        }
        let ids = try #require(prepared.text.tokenIds)
        let messages = DefaultMessageGenerator().generate(messages: chat)
        var renderContext: [String: VMLXJinja.Value] = [
            "messages": .array(try messages.map { try VMLXJinja.Value(any: $0) }),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools { renderContext["tools"] = .array(try tools.map { try VMLXJinja.Value(any: $0) }) }
        for (key, value) in mergedContext ?? [:] { renderContext[key] = try VMLXJinja.Value(any: value) }
        if let thinking = mergedContext?["enable_thinking"] { renderContext["thinking"] = try VMLXJinja.Value(any: thinking) }
        for key in ["bos_token", "eos_token", "unk_token", "pad_token"] {
            if let token = tokenizerConfig[key] as? String { renderContext[key] = .string(token) }
        }
        let nativeTemplate = try VMLXJinja.Template(templateSource, with: .init(lstripBlocks: true, trimBlocks: true))
        let rendered = try nativeTemplate.render(renderContext)
        renderContext["add_generation_prompt"] = .boolean(false)
        let noRailRendered = try nativeTemplate.render(renderContext)
        let renderedIDs = tokenizer.encode(text: rendered, addSpecialTokens: false)
        let noRailRenderedIDs = tokenizer.encode(text: noRailRendered, addSpecialTokens: false)
        let noRail = try controllable.applyChatTemplate(
            messages: messages, tools: tools, additionalContext: mergedContext, addGenerationPrompt: false)
        let settings = try JSONDecoder().decode(VMLXServerRuntimeSettings.self,
            from: Data(contentsOf: URL(fileURLWithPath: fixture.runtimeSettingsPath)))
        let coordinatorConfig = settings.cacheCoordinatorConfig(modelKey: fixture.modelKey)
        var parameters = GenerateParameters()
        let resolved = coordinatorConfig.resolveKVPolicy(
            kvMode: parameters.kvMode, maxKVSize: parameters.maxKVSize, promptTokenCount: ids.count)
        parameters.kvMode = resolved.kvMode
        parameters.maxKVSize = resolved.maxKVSize
        let salt = computeCacheSalt(for: prepared, parameters: parameters)
        let actualPrefix = Array(ids.prefix(expectedNoRail.count))
        let actualHash = DiskCache.hashTokens(actualPrefix, modelKey: fixture.modelKey, mediaSalt: salt)
        let independentStockHash = DiskCache.hashTokens(
            expectedNoRail, modelKey: fixture.modelKey, mediaSalt: contract.expectedResolvedSalt)

        let output = URL(fileURLWithPath: outputPath).appendingPathComponent("stock-request-\(sequence)")
        try #require(!FileManager.default.fileExists(atPath: output.path), "Use a fresh stock output directory; retained evidence is immutable")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try write([
            "lane": "post_fix_stock_bundle_contract", "sequence": sequence,
            "contract_sha256": digest(contractData), "stock_manifest_sha256": digest(manifestData),
            "reference_app_source": fixture.referenceAppSource, "reference_runtime": fixture.referenceRuntime,
            "request_sha256": digest(requestData), "tokenizer_sha256": digest(tokenizerData),
            "template_sha256": digest(Data(templateSource.utf8)),
            "render_sha256": digest(Data(rendered.utf8)), "no_generation_render_sha256": digest(Data(noRailRendered.utf8)),
            "model_key": fixture.modelKey,
            "cache_scope": prepared.cacheScopeSalt.map { $0 as Any } ?? NSNull(),
            "resolved_salt": salt.map { $0 as Any } ?? NSNull(),
            "expected_cache_scope": contract.expectedCacheScope, "expected_resolved_salt": contract.expectedResolvedSalt,
            "kv_mode": String(describing: parameters.kvMode),
            "max_kv": parameters.maxKVSize.map { $0 as Any } ?? NSNull(),
            "kv_bits": parameters.kvBits.map { $0 as Any } ?? NSNull(),
            "kv_group": parameters.kvGroupSize, "quantized_kv_start": parameters.quantizedKVStart,
            "native_prompt_count": ids.count, "stock_expected_prompt_count": expectedFull.count,
            "native_no_generation_count": noRail.count, "stock_expected_no_generation_count": expectedNoRail.count,
            "derived_stock_prefix_hash": actualHash, "expected_stock_prefix_hash": expectedPrefixHash,
            "retained_before_fix_prompt_count": row.promptCount,
            "retained_before_fix_prefix_count": row.prefixCount, "retained_before_fix_saved_hash": row.prefixHash,
            "full_ids_exact_stock": ids == expectedFull, "no_generation_ids_exact_stock": noRail == expectedNoRail,
            "faithful_render_unchanged": Data(rendered.utf8) == expectedFullRender,
            "faithful_no_generation_render_unchanged": Data(noRailRendered.utf8) == expectedNoRailRender,
            "render_reencodes_exactly": renderedIDs == ids,
            "cpu_only": true, "weights_loaded": false, "persisted_cache_write_proven": false,
        ] as [String: Any], named: "receipt.json", in: output)
        try write(ids, named: "native-ids.json", in: output)
        try write(noRail, named: "native-no-generation-prompt-ids.json", in: output)
        try write(renderedIDs, named: "native-render-reencoded-ids.json", in: output)
        try write(noRailRenderedIDs, named: "native-no-generation-render-reencoded-ids.json", in: output)
        try Data(rendered.utf8).write(to: output.appendingPathComponent("native-render.txt"), options: .atomic)
        try Data(noRailRendered.utf8).write(to: output.appendingPathComponent("native-no-generation-render.txt"), options: .atomic)

        #expect(Data(rendered.utf8) == expectedFullRender, "Tokenization correction must not change the faithful native render")
        #expect(Data(noRailRendered.utf8) == expectedNoRailRender)
        #expect(renderedIDs == ids && ids == expectedFull, "Actual production IDs must equal stock IDs, not only a count")
        #expect(noRailRenderedIDs == noRail && noRail == expectedNoRail)
        #expect(actualPrefix == expectedNoRail && ids == noRail + stock.railIDs)
        #expect(prepared.cachePrefixTokenCounts.contains(expectedNoRail.count))
        #expect(prepared.cacheScopeSalt == contract.expectedCacheScope)
        #expect(salt == contract.expectedResolvedSalt)
        // Exact known policy from retained native receipts; no guessed maxKV.
        #expect(String(describing: parameters.kvMode) == "none")
        #expect(parameters.maxKVSize == nil && parameters.kvBits == nil)
        #expect(parameters.kvGroupSize == 64 && parameters.quantizedKVStart == 0)
        #expect(independentStockHash == expectedPrefixHash && actualHash == expectedPrefixHash)
        #expect(actualHash != row.prefixHash, "Old native saved keys remain historical, never renamed as stock parity")
    }

    @Test
    func configuredMetaspaceSplitFalsePreservesStockCrossSpaceMerge() throws {
        let config: [NSString: Any] = ["tokenizer_class": "GPT2Tokenizer", "unk_token": "<unk>"]
        let data: [NSString: Any] = [
            "model": [
                "type": "BPE", "unk_token": "<unk>",
                "vocab": ["<unk>": 0, "▁": 1, "a": 2, "▁▁": 3, "▁▁a": 4, "▁a": 5],
                "merges": [["▁", "▁"], ["▁▁", "a"], ["▁", "a"]],
            ] as [String: Any],
            "pre_tokenizer": ["type": "Metaspace", "replacement": "▁", "prepend_scheme": "first", "split": false],
        ]
        let native = try PreTrainedTokenizer(tokenizerConfig: Config(config), tokenizerData: Config(data))
        let actual = native.encode(text: "  a", addSpecialTokens: false)
        if let outputPath = ProcessInfo.processInfo.environment["OSAURUS_NATIVE_TOKENIZER_PARITY_OUTPUT"] {
            let directory = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(["text": "  a", "configured_split": false, "stock_expected": [4], "native_actual": actual],
                named: "metaspace-split-false.json", in: directory)
        }
        #expect(actual == [4], "Stock split:false permits the ▁+▁ then ▁▁+a merge; no tolerance or forced config")
    }
}
