//
//  StructuredOutputTests.swift
//  OsaurusCoreTests
//
//  Native structured output for workflow nodes: the strict wire schema,
//  decoding back to the node schema, which backends can enforce a schema,
//  the per-provider request shapes, and the typed refusal for backends
//  that cannot.
//

import Foundation
import Testing
import struct MLXLMCommon.GenerationFailure

@testable import OsaurusCore

struct StructuredOutputSchemaTests {
    static let node: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "name": .object(["type": .string("string")]),
            "email": .object(["type": .string("string")]),
            "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
        ]),
        "required": .array([.string("name")]),
    ])

    @Test
    func strictWire_closesObjectsAndMakesOptionalsNullable() {
        let wire = StructuredOutputSchema.strictWire(Self.node)
        guard case .object(let obj) = wire, case .object(let props)? = obj["properties"] else {
            Issue.record("expected an object schema")
            return
        }
        #expect(obj["additionalProperties"] == .bool(false))
        #expect(obj["required"] == .array([.string("email"), .string("name"), .string("tags")]))
        #expect(props["name"] == .object(["type": .string("string")]))
        #expect(
            props["email"]
                == .object(["anyOf": .array([.object(["type": .string("string")]), .object(["type": .string("null")])])]))
    }

    @Test
    func scalarRoots_areWrappedAndUnwrapped() throws {
        let schema: JSONValue = .object(["type": .string("string"), "enum": .array([.string("a"), .string("b")])])
        let wire = StructuredOutputSchema.strictWire(schema)
        #expect(wire.objectValue?["required"] == .array([.string("value")]))
        #expect(try StructuredOutputSchema.decode(#"{"value": "b"}"#, schema: schema) == .string("b"))
        #expect(throws: StructuredOutputError.self) {
            _ = try StructuredOutputSchema.decode(#"{"value": "z"}"#, schema: schema)
        }
    }

    @Test
    func decode_dropsWireNullsForOptionals_andValidates() throws {
        let value = try StructuredOutputSchema.decode(
            #"{"name": "Ada", "email": null, "tags": null}"#, schema: Self.node)
        #expect(value == .object(["name": .string("Ada")]))
        #expect(throws: StructuredOutputError.notJSON("not json")) {
            _ = try StructuredOutputSchema.decode("not json", schema: Self.node)
        }
        #expect(throws: StructuredOutputError.self) {
            _ = try StructuredOutputSchema.decode(#"{"email": "a@b.co"}"#, schema: Self.node)
        }
    }

    @Test
    func decode_keepsNullWhenTheSchemaAllowsIt() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["note": .object(["type": .array([.string("string"), .string("null")])])]),
        ])
        #expect(try StructuredOutputSchema.decode(#"{"note": null}"#, schema: schema) == .object(["note": .null]))
    }

    // MARK: Review #18: $defs / allOf / maps / unions

    static let address: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["city": .object(["type": .string("string")]), "zip": .object(["type": .string("string")])]),
        "required": .array([.string("city")]),
    ])

    @Test
    func strictWire_recursesIntoDefsAllOfAndMapValues() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "$defs": .object(["Address": Self.address]),
            "properties": .object([
                "home": .object(["$ref": .string("#/$defs/Address")]),
                "merged": .object(["allOf": .array([Self.address, .object(["type": .string("object"), "properties": .object(["note": .object(["type": .string("string")])])])])]),
                "byName": .object(["type": .string("object"), "additionalProperties": Self.address]),
            ]),
            "required": .array([.string("home"), .string("merged"), .string("byName")]),
        ])
        let wire = StructuredOutputSchema.strictWire(schema)
        let obj = try #require(wire.objectValue)
        let defs = try #require(obj["$defs"]?.objectValue?["Address"]?.objectValue)
        #expect(defs["additionalProperties"] == .bool(false))
        #expect(defs["required"] == .array([.string("city"), .string("zip")]))
        #expect(defs["properties"]?.objectValue?["zip"]?.objectValue?["anyOf"] != nil, "optional in $defs made nullable")

        let props = try #require(obj["properties"]?.objectValue)
        guard case .array(let parts)? = props["merged"]?.objectValue?["allOf"] else {
            Issue.record("expected allOf parts")
            return
        }
        #expect(parts.allSatisfy { $0.objectValue?["additionalProperties"] == .bool(false) }, "allOf parts closed")

        let map = try #require(props["byName"]?.objectValue)
        #expect(map["properties"] == nil, "a map keeps its keys open")
        #expect(map["additionalProperties"]?.objectValue?["additionalProperties"] == .bool(false), "its values are strict")

        // Idempotent: the wire form of a wire form is itself.
        #expect(StructuredOutputSchema.strictWire(wire) == wire)
        #expect(StructuredOutputSchema.strictWire(StructuredOutputSchema.strictWire(Self.node)) == StructuredOutputSchema.strictWire(Self.node))
    }

    @Test
    func strictWire_keepsAnAnyKeysMapOpen_andClosesAnExplicitlyClosedEmptyObject() throws {
        let open: JSONValue = .object(["type": .string("object")])
        #expect(StructuredOutputSchema.strictWire(open).objectValue?["additionalProperties"] == .bool(true))
        #expect(StructuredOutputSchema.strictWire(open).objectValue?["properties"] == nil)
        #expect(StructuredOutputSchema.hasOpenMap(open))

        let closed: JSONValue = .object(["type": .string("object"), "additionalProperties": .bool(false)])
        #expect(StructuredOutputSchema.strictWire(closed).objectValue?["properties"] == .object([:]))
        #expect(!StructuredOutputSchema.hasOpenMap(closed))

        #expect(!StructuredOutputSchema.hasOpenMap(Self.node))
        let nested: JSONValue = .object([
            "type": .string("array"), "items": .object(["type": .string("object"), "additionalProperties": Self.string]),
        ])
        #expect(StructuredOutputSchema.hasOpenMap(nested))
    }

    static let string: JSONValue = .object(["type": .string("string")])

    @Test
    func decode_dropsNullsInsideTheMatchingUnionBranch_andMapValues() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "where": .object(["anyOf": .array([Self.string, Self.address])]),
                "places": .object(["oneOf": .array([Self.address, .object(["type": .string("array"), "items": Self.address])])]),
                "byName": .object(["type": .string("object"), "additionalProperties": Self.address]),
            ]),
            "required": .array([.string("where"), .string("places"), .string("byName")]),
        ])
        let value = try StructuredOutputSchema.decode(
            #"{"where": {"city": "Oslo", "zip": null}, "places": [{"city": "Rome", "zip": null}], "byName": {"a": {"city": "Kyiv", "zip": null}}}"#,
            schema: schema)
        #expect(value.objectValue?["where"] == .object(["city": .string("Oslo")]))
        #expect(value.objectValue?["places"] == .array([.object(["city": .string("Rome")])]))
        #expect(value.objectValue?["byName"] == .object(["a": .object(["city": .string("Kyiv")])]))
        // A string branch leaves the string alone.
        let plain = try StructuredOutputSchema.decode(
            #"{"where": "home", "places": {"city": "Rome"}, "byName": {}}"#, schema: schema)
        #expect(plain.objectValue?["where"] == .string("home"))
    }

    // MARK: Review #19: scalar roots are wrapped once, before dispatch

    @Test
    func objectRoot_wrapsScalarsOnce_andTheWireAgrees() {
        let scalar: JSONValue = .object(["type": .string("string")])
        let wrapped = StructuredOutputSchema.objectRoot(scalar)
        #expect(wrapped.objectValue?["properties"]?.objectValue?["value"] == scalar)
        #expect(StructuredOutputSchema.objectRoot(wrapped) == wrapped, "already an object root")
        #expect(StructuredOutputSchema.strictWire(wrapped) == StructuredOutputSchema.strictWire(scalar))
        #expect(StructuredOutputSchema.objectRoot(Self.node) == Self.node)
        let list: JSONValue = .object(["type": .string("array"), "items": scalar])
        #expect(StructuredOutputSchema.wrapsRoot(list))
        #expect(StructuredOutputSchema.objectRoot(list).objectValue?["required"] == .array([.string("value")]))
    }

    /// The schema a backend receives from `CoreModelService.generateStructured`
    /// is the object-root form — including the Foundation path, which does
    /// not run `strictWire` — so `decode` can unwrap what it produced.
    @Test
    func generateStructured_handsEveryBackendTheObjectRootSchema() async throws {
        let recorder = SchemaRecordingService(id: "recorder")
        let service = CoreModelService(localServices: [recorder])
        let scalar: JSONValue = .object(["type": .string("string"), "enum": .array([.string("a"), .string("b")])])
        let text = try await service.generateStructured(
            model: "recorder", prompt: "pick", systemPrompt: nil, schema: scalar, timeout: 5)
        let seen = try #require(await recorder.lastSchema)
        #expect(seen == StructuredOutputSchema.objectRoot(scalar))
        #expect(seen.objectValue?["properties"]?.objectValue?["value"] == scalar)
        #expect(try StructuredOutputSchema.decode(text, schema: scalar) == .string("a"))
    }
}

/// A backend that records the `responseSchema` it was handed and answers
/// in the wrapped shape, like Foundation Models would for an object root.
private actor SchemaRecordingService: ModelService {
    nonisolated let id: String
    private(set) var lastSchema: JSONValue?

    init(id: String) { self.id = id }

    nonisolated func isAvailable() -> Bool { true }
    nonisolated func handles(requestedModel: String?) -> Bool { requestedModel == id }

    func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?)
        async throws -> String
    {
        lastSchema = parameters.responseSchema
        return #"{"value": "a"}"#
    }

    func streamDeltas(
        messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?, stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        lastSchema = parameters.responseSchema
        return AsyncThrowingStream { continuation in
            continuation.yield(#"{"value": "a"}"#)
            continuation.finish()
        }
    }
}

struct StructuredOutputCapabilityTests {

    @Test
    func cloudProvidersAreSupported_agentsAndCLIsAreNot() {
        for type in [RemoteProviderType.openaiLegacy, .azureOpenAI, .anthropic, .openResponses, .openAICodex, .gemini, .osaurusRouter] {
            #expect(
                StructuredOutputCapability.support(
                    for: "p/model", providerType: type, isLocalMLX: false, foundationAvailable: false) == .supported)
        }
        if case .supported = StructuredOutputCapability.support(
            for: "coco/agent", providerType: .osaurus, isLocalMLX: false, foundationAvailable: false)
        {
            Issue.record("a remote Osaurus agent cannot enforce a schema")
        }
        if case .supported = StructuredOutputCapability.support(
            for: "claude-code/sonnet", providerType: nil, isLocalMLX: false, foundationAvailable: false)
        {
            Issue.record("Claude Code cannot enforce a schema")
        }
    }

    @Test
    func localMLX_dependsOnTheTokenizer() {
        #expect(
            StructuredOutputCapability.support(
                for: "mlx-community/Qwen3-8B-4bit", providerType: nil, isLocalMLX: true,
                localTokenizerSupported: true, foundationAvailable: true) == .supported)
        #expect(
            StructuredOutputCapability.support(
                for: "mlx-community/gemma-4-E2B", providerType: nil, isLocalMLX: true,
                localTokenizerSupported: false, foundationAvailable: true)
                == .unsupported(StructuredOutputCapability.localMLXReason))
    }

    @Test
    func openMaps_areRefusedByStrictModes_andAllowedWhereGrammarsCanExpressThem() {
        let map: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["counts": .object(["type": .string("object"), "additionalProperties": .object(["type": .string("number")])])]),
            "required": .array([.string("counts")]),
        ])
        for type in [RemoteProviderType.openaiLegacy, .azureOpenAI, .anthropic, .openResponses, .openAICodex, .osaurusRouter] {
            if case .supported = StructuredOutputCapability.support(
                for: "p/model", providerType: type, isLocalMLX: false, foundationAvailable: false, schemas: [map])
            {
                Issue.record("\(type) strict mode cannot express an open map")
            }
        }
        if case .supported = StructuredOutputCapability.support(
            for: "foundation", providerType: nil, isLocalMLX: false, foundationAvailable: true, schemas: [map])
        {
            Issue.record("GenerationSchema has no map")
        }
        #expect(
            StructuredOutputCapability.support(
                for: "p/model", providerType: .gemini, isLocalMLX: false, foundationAvailable: false, schemas: [map])
                == .supported)
        #expect(
            StructuredOutputCapability.support(
                for: "mlx-community/Qwen3-8B-4bit", providerType: nil, isLocalMLX: true, localTokenizerSupported: true,
                foundationAvailable: false, schemas: [map]) == .supported)
        // Closed schemas are unaffected.
        #expect(
            StructuredOutputCapability.support(
                for: "p/model", providerType: .openaiLegacy, isLocalMLX: false, foundationAvailable: false,
                schemas: [StructuredOutputSchemaTests.node]) == .supported)
    }

    /// Setup hands the checker the output schemas of every node that uses
    /// the slot, so a strict-mode model is refused for a map-shaped node
    /// at install time rather than at the provider.
    @Test
    func setup_flagsAModelThatCannotExpressTheSlotsSchemas() {
        var def = WF.intake()
        def.nodes.append(
            WorkflowNode(
                id: "tally", name: "Tally",
                kind: .inference(InferenceSpec(modelSlot: "decision", instructions: "Count {{input.client}}")),
                input: .object([:]),
                outputSchema: .object(["type": .string("object"), "additionalProperties": .object(["type": .string("number")])])))
        let template = WF.template(def)
        #expect(def.outputSchemas(forSlot: "decision").count == 2)
        #expect(def.outputSchemas(forSlot: "other").isEmpty)

        var env = SetupChecker.Environment(
            registeredToolNames: [],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: ["local/model"], providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true }, knowledgeCollectionExists: { _ in true })
        env.codeRuntimeAvailable = true
        var seen: [JSONValue] = []
        env.structuredOutput = { _, schemas in
            seen = schemas
            return schemas.contains(where: StructuredOutputSchema.hasOpenMap)
                ? .unsupported(StructuredOutputCapability.openMapReason("strict mode")) : .supported
        }
        let bindings = InstallBindings(models: ["decision": "local/model"])
        let report = SetupChecker.check(template, bindings: bindings, subjectId: UUID(), environment: env)
        #expect(seen.count == 2)
        let item = report.blocking.first { $0.kind == .model }
        #expect(item?.value == "decision")
        #expect(item?.detail.contains("open keys") == true)
    }

    @Test
    func foundation_dependsOnAvailability() {
        #expect(
            StructuredOutputCapability.support(
                for: "foundation", providerType: nil, isLocalMLX: false, foundationAvailable: true) == .supported)
        #expect(
            StructuredOutputCapability.support(
                for: "foundation", providerType: nil, isLocalMLX: false, foundationAvailable: false) != .supported)
    }
}

struct StructuredOutputWireTests {
    static let schema = StructuredOutputSchemaTests.node

    static func service(_ type: RemoteProviderType) -> RemoteProviderService {
        RemoteProviderService(
            provider: RemoteProvider(
                name: "P", host: "api.example.com", providerProtocol: .https, port: nil, basePath: "/v1",
                authType: .none, providerType: type),
            models: ["m"], resolvedHeaders: [:])
    }

    static func params(schema: JSONValue? = Self.schema, agentRun: Bool = false) -> GenerationParameters {
        var p = GenerationParameters(temperature: nil, maxTokens: 256, runAsRemoteAgent: agentRun)
        p.responseSchema = schema
        return p
    }

    static func request(_ type: RemoteProviderType, params: GenerationParameters = Self.params()) async
        -> RemoteChatRequest
    {
        await service(type).buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")], parameters: params, model: "m", stream: false,
            tools: nil, toolChoice: nil)
    }

    static func dict<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test
    func chatCompletions_sendsStrictJSONSchema() async throws {
        let body = try Self.dict(await Self.request(.openaiLegacy))
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let spec = try #require(format["json_schema"] as? [String: Any])
        #expect(spec["strict"] as? Bool == true)
        #expect(spec["name"] as? String == StructuredOutputSchema.defaultName)
        let sent = try #require(spec["schema"] as? [String: Any])
        #expect(sent["additionalProperties"] as? Bool == false)
    }

    @Test
    func anthropic_mapsToOutputConfigFormat() async throws {
        let body = try Self.dict(await Self.request(.anthropic).toAnthropicRequest())
        let config = try #require(body["output_config"] as? [String: Any])
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["schema"] is [String: Any])
    }

    @Test
    func anthropic_withoutSchemaSendsNoOutputConfig() async throws {
        let body = try Self.dict(await Self.request(.anthropic, params: Self.params(schema: nil)).toAnthropicRequest())
        #expect(body["output_config"] == nil)
    }

    @Test
    func gemini_mapsToResponseJsonSchemaWithJSONMime() async throws {
        let body = try Self.dict(await Self.request(.gemini).toGeminiRequest())
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
        #expect(config["responseJsonSchema"] is [String: Any])
    }

    @Test
    func responses_mapsToTextFormat() async throws {
        let body = try Self.dict(try await Self.request(.openResponses).toOpenResponsesRequest())
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
        #expect(format["schema"] is [String: Any])
    }

    @Test
    func remoteAgentRuns_neverCarryASchema() async throws {
        let body = try Self.dict(await Self.request(.osaurus, params: Self.params(agentRun: true)))
        #expect(body["response_format"] == nil)
    }

    @Test
    func osaurusAgentProvider_refusesBeforeAnyRequest() async {
        await #expect(throws: StructuredOutputError.self) {
            _ = try await Self.service(.osaurus).generateOneShot(
                messages: [ChatMessage(role: "user", content: "hi")], parameters: Self.params(), requestedModel: "p/m")
        }
    }

    @Test
    func localMLX_forwardsTheStrictWireSchemaAndSelectsNonReasoning() throws {
        let out = try MLXService.structuredParameters(Self.params(), model: "raptor")
        let wire = try #require(out.jsonSchema)
        #expect(try StructuredOutputSchema.localWire(Self.schema) == wire)
        let parsed = try #require(JSONValue.parse(wire))
        #expect(parsed == StructuredOutputSchema.strictWire(Self.schema))
        // Sorted keys: the same node schema always compiles the same grammar.
        #expect(wire.hasPrefix(#"{"additionalProperties":false,"properties":{"#))
        #expect(out.modelOptions["disableThinking"] == .bool(true))
        #expect(out.responseSchema == Self.schema)
    }

    @Test
    func localMLX_leavesAnExplicitReasoningChoiceAlone() throws {
        var explicit = Self.params()
        explicit.modelOptions["reasoningEffort"] = .string("high")
        let out = try MLXService.structuredParameters(explicit, model: "raptor")
        #expect(out.modelOptions["disableThinking"] == nil)
        #expect(out.modelOptions["reasoningEffort"] == .string("high"))

        var off = Self.params()
        off.modelOptions["disableThinking"] = .bool(false)
        #expect(try MLXService.structuredParameters(off, model: "raptor").modelOptions["disableThinking"] == .bool(false))
    }

    @Test
    func localMLX_withoutASchemaIsUntouched() throws {
        let plain = GenerationParameters(temperature: nil, maxTokens: 16)
        let out = try MLXService.structuredParameters(plain, model: "raptor")
        #expect(out.jsonSchema == nil)
        #expect(out.modelOptions.isEmpty)
    }

    @Test
    func localMLX_preparationFailuresBecomeTheTypedRefusal() {
        let engine = ChatEngine.EngineError(kind: .invalidStructuredOutput("tokenizer unsupported"))
        #expect(
            MLXService.mapStructuredFailure(engine, model: "raptor") as? StructuredOutputError
                == .unsupportedModel(model: "raptor", reason: "tokenizer unsupported"))
        let preparation = GenerationFailure(stage: .preparation, cause: "active reasoning envelope")
        #expect(
            MLXService.mapStructuredFailure(preparation, model: "raptor") as? StructuredOutputError
                == .unsupportedModel(model: "raptor", reason: "active reasoning envelope"))
        // Decoding failures stay what they are so the node's retry policy applies.
        let decoding = GenerationFailure(stage: .decoding, cause: "ended before the matcher accepted a stop token")
        #expect(MLXService.mapStructuredFailure(decoding, model: "raptor") as? GenerationFailure == decoding)
        #expect(WorkflowNodeError.isRetryable(decoding))
        #expect(!WorkflowNodeError.isRetryable(MLXService.mapStructuredFailure(preparation, model: "raptor")))
        struct Other: Error {}
        #expect(MLXService.mapStructuredFailure(Other(), model: "raptor") is Other)
    }
}
