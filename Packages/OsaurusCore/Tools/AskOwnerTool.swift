//
//  AskOwnerTool.swift
//  osaurus
//
//  `ask_owner`: on a shared agent set to "Require Approval for Teammate
//  Tool Calls", the agent can put a question to its owner while a teammate or
//  another person's agent is driving it. The run parks the same way an
//  approval does (`OwnerApprovalService.ask`): the owner answers from the
//  notification's Reply field, the paired phone, or Approvals, and
//  the answer comes back as the tool result. Offered only on those runs.
//

import Foundation

final class AskOwnerTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "ask_owner"
    static let questionLimit = 2_000

    let name = AskOwnerTool.toolName
    let description =
        "Ask your owner a question while someone else is using you, and wait for their answer. "
        + "Use it only when you need the owner's decision or knowledge to continue; "
        + "the person you are talking to cannot answer it for them. Returns the owner's reply, "
        + "or an error if they did not answer in time."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "question": .object([
                "type": .string("string"),
                "description": .string("The question for the owner. One or two sentences, self-contained."),
            ])
        ]),
        "required": .array([.string("question")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let questionReq = requireString(args, "question", expected: "question for the owner", tool: name)
        guard case .value(let raw) = questionReq else { return questionReq.failureEnvelope ?? "" }
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= Self.questionLimit else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "question must be 1 to \(Self.questionLimit) characters.",
                field: "question",
                tool: name
            )
        }
        guard let route = ChatExecutionContext.ownerApprovalRoute else {
            return ToolEnvelope.failure(
                kind: .permissionDenied,
                message: "ask_owner is only available when someone else is using a shared agent set to ask its owner.",
                tool: name
            )
        }
        let callId = ChatExecutionContext.currentToolCallId
        let answer = await OwnerApprovalService.shared.ask(route: route, question: question, callId: callId)
        let owner = await MainActor.run { OwnerApprovalService.shared.ownerLabel }
        switch answer {
        case .replied(let text):
            return ToolEnvelope.success(tool: name, result: ["answer": text, "answered_by": owner])
        case .timedOut:
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "No answer from the owner (\(owner)) in time. Continue without it.",
                tool: name,
                retryable: false
            )
        case .dismissed:
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: "The owner (\(owner)) dismissed the question. Continue without it.",
                tool: name
            )
        case .abandoned:
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "The question ended before the owner answered.",
                tool: name
            )
        case .tooManyPending:
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Several requests are already waiting for the owner (\(owner)). Wait for those answers first.",
                tool: name,
                retryable: true
            )
        }
    }
}
