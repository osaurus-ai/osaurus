//
//  InferenceTextOutputTests.swift
//  OsaurusCoreTests
//
//  Inference steps whose output is one text field run as plain text
//  generation and are wrapped into `{field: text}`; every other schema keeps
//  native structured output and is described to the model.
//

import Foundation
import Testing

@testable import OsaurusCore

struct InferenceTextOutputTests {
    static let string: JSONValue = .object(["type": .string("string"), "title": .string("Wrap-up")])

    static func object(_ props: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map(JSONValue.string)),
        ])
    }

    // MARK: Which schemas are one text field

    @Test
    func singleTextField_acceptsOnlyOneRequiredPlainString() {
        #expect(StructuredOutputSchema.singleTextField(Self.object(["wrap_up": Self.string], required: ["wrap_up"])) == "wrap_up")
        let described: JSONValue = .object([
            "type": .string("string"), "title": .string("Answer"), "description": .string("One paragraph."),
        ])
        #expect(StructuredOutputSchema.singleTextField(Self.object(["answer": described], required: ["answer"])) == "answer")

        #expect(StructuredOutputSchema.singleTextField(Self.object(["wrap_up": Self.string], required: [])) == nil)
        #expect(
            StructuredOutputSchema.singleTextField(
                Self.object(["a": Self.string, "b": Self.string], required: ["a", "b"])) == nil)
        for constraint: (String, JSONValue) in [
            ("enum", .array([.string("yes"), .string("no")])), ("const", .string("x")), ("format", .string("file")),
            ("pattern", .string("^a")), ("maxLength", .number(10)),
        ] {
            let field: JSONValue = .object(["type": .string("string"), constraint.0: constraint.1])
            #expect(
                StructuredOutputSchema.singleTextField(Self.object(["v": field], required: ["v"])) == nil,
                "\(constraint.0) keeps the schema-enforced path")
        }
        let list: JSONValue = .object(["type": .string("array"), "items": Self.string])
        #expect(StructuredOutputSchema.singleTextField(Self.object(["v": list], required: ["v"])) == nil)
        #expect(StructuredOutputSchema.singleTextField(Self.string) == nil, "a scalar root is wrapped, not text")
        #expect(StructuredOutputSchema.singleTextField(InferenceSpec.decideSchema(options: ["a", "b"])) == nil)
    }

    /// Every shipped writer step that returns prose takes the text path, so
    /// no default workflow or prepared ask depends on a model writing JSON.
    @Test @MainActor
    func shippedProseSteps_takeTheTextPath() throws {
        let templates = TeamSeeder.bundledDefaultWorkflows() + PreparedAskCatalog.templates()
        #expect(templates.count >= 19)
        var textSteps = 0
        for template in templates {
            let workflow = try #require(template.workflow, "\(template.name) has a workflow")
            for node in workflow.nodes {
                guard case .inference = node.kind,
                    StructuredOutputSchema.singleTextField(node.effectiveOutputSchema) != nil
                else { continue }
                textSteps += 1
            }
        }
        #expect(textSteps >= 18, "6 default writers and 12 prepared asks")
    }

    // MARK: Decoding the text

    @Test
    func decodeText_trimsWrapsAndRejectsEmpty() throws {
        let schema = Self.object(["wrap_up": Self.string], required: ["wrap_up"])
        let value = try StructuredOutputSchema.decodeText(
            "\n  Today: design review.\nStill due: slides.\n", field: "wrap_up", schema: schema)
        #expect(value == .object(["wrap_up": .string("Today: design review.\nStill due: slides.")]))
        #expect(throws: StructuredOutputError.self) {
            _ = try StructuredOutputSchema.decodeText(" \n ", field: "wrap_up", schema: schema)
        }
        #expect(
            WorkflowNodeError.isRetryable(StructuredOutputError.schemaMismatch(["wrap_up: the model returned no text"])))
    }

    // MARK: The call

    @Test
    func generateNodeText_sendsNoSchema_requiresCompleteOutput_andStreams() async throws {
        let backend = TextRecordingService(id: "writer", deltas: ["Today", ": one event.\n", "Tomorrow: dentist."])
        let service = CoreModelService(localServices: [backend])
        let streamed = DeltaLog()
        let text = try await service.generateNodeText(
            model: "writer", prompt: "{}", systemPrompt: "Write a wrap-up.", timeout: 5,
            requestSource: .httpAPI, onDelta: { streamed.append($0) })
        #expect(text == "Today: one event.\nTomorrow: dentist.")
        let params = try #require(await backend.lastParameters)
        #expect(params.responseSchema == nil)
        #expect(params.jsonSchema == nil)
        #expect(params.requireCompleteOutput)
        #expect(await backend.streamed, "text streams even where a schema would not")
        #expect(streamed.joined == text, "stats are not forwarded as text")
    }

    @Test
    func generateNodeText_withoutADeltaSink_usesTheOneShot() async throws {
        let backend = TextRecordingService(id: "writer", deltas: ["Done."])
        let service = CoreModelService(localServices: [backend])
        let text = try await service.generateNodeText(
            model: "writer", prompt: "{}", systemPrompt: nil, timeout: 5, requestSource: .httpAPI)
        #expect(text == "Done.")
        #expect(!(await backend.streamed))
        #expect(await backend.lastParameters?.requireCompleteOutput == true)
    }

    @Test
    func collect_failsATruncatedStreamOnlyWhenCompleteOutputIsRequired() async throws {
        func stream(_ stop: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("Today")
                continuation.yield(StreamingStatsHint.encode(tokenCount: 1, tokensPerSecond: 10, stopReason: stop))
                continuation.finish()
            }
        }
        await #expect(throws: MLXService.OneShotError.outputTruncated) {
            _ = try await CoreModelService.collect(stream("length"), requireCompleteOutput: true, onDelta: { _ in })
        }
        await #expect(throws: CancellationError.self) {
            _ = try await CoreModelService.collect(stream("cancelled"), requireCompleteOutput: true, onDelta: { _ in })
        }
        #expect(try await CoreModelService.collect(stream("stop"), requireCompleteOutput: true, onDelta: { _ in }) == "Today")
        #expect(try await CoreModelService.collect(stream("length"), onDelta: { _ in }) == "Today")
    }

    // MARK: The contract structured steps show the model

    @Test
    func outputContract_describesEveryFieldOfAStructuredReply() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "note": .object(["type": .string("string"), "title": .string("Note")]),
                "sources": .object([
                    "type": .string("array"), "title": .string("Sources"), "items": .object(["type": .string("string")]),
                    "description": .string("One URL each."),
                ]),
                "mood": .object(["type": .string("string"), "enum": .array([.string("calm"), .string("urgent")])]),
            ]),
            "required": .array([.string("note"), .string("sources")]),
        ])
        let contract = InferenceNodeExecutor.outputContract(schema)
        #expect(contract.hasPrefix("\n\nReply with one JSON object and nothing else."))
        #expect(contract.contains("- mood: one of \"calm\", \"urgent\", optional (null when absent)"))
        #expect(contract.contains("- note: string. Note"))
        #expect(contract.contains("- sources: list of string. Sources. One URL each."))
        #expect(contract.contains(#"write a line break as \n"#))
        let lines = contract.split(separator: "\n").map(String.init)
        #expect(lines.firstIndex { $0.hasPrefix("- mood") }! < lines.firstIndex { $0.hasPrefix("- note") }!, "grammar order")
    }

    @Test
    func outputContract_namesTheWrappedValueOfAScalarRoot_andDecideChoices() {
        let scalar: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")])])
        #expect(InferenceNodeExecutor.outputContract(scalar).contains("- value: list of string"))
        let decide = InferenceNodeExecutor.outputContract(InferenceSpec.decideSchema(options: ["refund", "reply"]))
        #expect(decide.contains("- choice: one of \"refund\", \"reply\""))
        #expect(InferenceNodeExecutor.outputContract(.object(["type": .string("object")])).isEmpty)
    }

    @Test
    func textContract_asksForTheTitledTextItself() {
        let titled = Self.object(["wrap_up": .object(["type": .string("string"), "title": .string("Wrap-up")])],
            required: ["wrap_up"])
        #expect(
            InferenceNodeExecutor.textContract(field: "wrap_up", schema: titled)
                == "\n\nReply with the wrap-up itself as plain text, not as JSON.")
        let untitled = Self.object(["answer": .object(["type": .string("string")])], required: ["answer"])
        #expect(InferenceNodeExecutor.textContract(field: "answer", schema: untitled).contains("the answer itself"))
    }
}

private final class DeltaLog: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [String] = []
    func append(_ delta: String) { lock.withLock { deltas.append(delta) } }
    var joined: String { lock.withLock { deltas.joined() } }
}

/// A backend that records what it was asked for and answers in text,
/// ending its stream with a stats sentinel like the local runtime does.
/// It applies no schema while streaming, so a schema-bound call would not
/// stream here.
private actor TextRecordingService: ModelService {
    nonisolated let id: String
    let deltas: [String]
    private(set) var lastParameters: GenerationParameters?
    private(set) var streamed = false

    init(id: String, deltas: [String]) {
        self.id = id
        self.deltas = deltas
    }

    nonisolated func isAvailable() -> Bool { true }
    nonisolated func handles(requestedModel: String?) -> Bool { requestedModel == id }
    nonisolated var streamsResponseSchema: Bool { false }

    func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?)
        async throws -> String
    {
        lastParameters = parameters
        return deltas.joined()
    }

    func streamDeltas(
        messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?, stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        lastParameters = parameters
        streamed = true
        let deltas = deltas
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            continuation.yield(StreamingStatsHint.encode(tokenCount: 8, tokensPerSecond: 40, stopReason: "stop"))
            continuation.finish()
        }
    }
}
