//
//  ReplyNodeExecutor.swift
//  osaurus
//
//  Reply steps: post a message, and optionally a file, into the channel
//  conversation that started the run. A run no message started has no
//  conversation; the step says `sent: false, reason: no_conversation` and
//  the run goes on, so one workflow serves a channel and a tab alike. Test
//  runs never post: the log shows what would have been sent. A platform
//  that refuses the message fails the step (retryable) unless part of it
//  already went out, so a retry never posts the same text twice. Past the
//  per-run cap (`ReplySpec.maximumRepliesPerRun`) a step sends nothing and
//  says `reason: reply_cap` without failing.
//

import Foundation

enum ReplyNodeExecutor {

    static func run(
        spec: ReplySpec, context: WorkflowNodeContext, replier: WorkflowChannelReplier = .live
    ) async throws -> WorkflowNodeOutcome {
        let text = BindingRenderer.renderReadableText(spec.text, in: context.bindings)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = spec.caption.map { BindingRenderer.renderReadableText($0, in: context.bindings) }?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        let file = try spec.file.flatMap { raw -> URL? in
            let rendered = BindingRenderer.renderText(raw, in: context.bindings)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rendered.isEmpty else { return nil }
            switch WorkflowFileScope(context: context).resolve(rendered) {
            case .success(let url): return url
            case .failure(.notFound(let path)):
                throw WorkflowNodeError.unsupported(L("The file to reply with does not exist: \(path)"))
            case .failure(.outside(let path)):
                throw WorkflowNodeError.unsupported(
                    L("The file to reply with is outside this run's folders: \(path)"))
            }
        }
        guard !text.isEmpty || file != nil else {
            throw WorkflowNodeError.unsupported(L("The reply rendered empty: no text and no file."))
        }

        let target = context.caller.channelReply
        var output: [String: JSONValue] = [
            "sent": .bool(false),
            "platform": target.map { .string($0.kind.rawValue) } ?? .null,
            "room_id": target.map { .string($0.conversationId) } ?? .null,
            "thread_id": target?.threadId.map(JSONValue.string) ?? .null,
            "attachment_sent": .bool(false),
            "truncated": .bool(false),
            "reason": .null,
        ]
        var logs: [String] = []

        if context.isTest {
            if !text.isEmpty { logs.append(L("Test run: would reply “\(text)”.")) }
            if let file { logs.append(L("Test run: would send the file \(file.lastPathComponent).")) }
            output["reason"] = .string("test_run")
            return WorkflowNodeOutcome(output: .object(output), logs: logs)
        }

        var textSent = false
        if !text.isEmpty {
            let delivery = await replier.send(text, runID: context.runID, caller: context.caller)
            if delivery.reason == WorkflowChannelReplier.Delivery.noConversation.reason {
                logs.append(L("Nobody messaged this run, so there is no conversation to reply to."))
                output["reason"] = .string("no_conversation")
                return WorkflowNodeOutcome(output: .object(output), logs: logs)
            }
            if delivery.reason == WorkflowChannelReplier.Delivery.replyCap.reason {
                logs.append(Self.capLog)
                output["reason"] = .string("reply_cap")
                return WorkflowNodeOutcome(output: .object(output), logs: logs)
            }
            if !delivery.sent {
                try fail(delivery, partial: false, logs: &logs, output: &output)
                return WorkflowNodeOutcome(output: .object(output), logs: logs)
            }
            textSent = true
            output["sent"] = .bool(true)
            output["truncated"] = .bool(delivery.truncated)
            logs.append(L("Replied in the conversation (\(text.count) characters)."))
            if delivery.truncated {
                logs.append(L("The reply was longer than the channel takes, so it was cut short."))
            }
        }

        if let file {
            let delivery = await replier.sendAttachment(
                path: file.path, caption: caption, runID: context.runID, caller: context.caller)
            if delivery.reason == WorkflowChannelReplier.Delivery.noConversation.reason {
                logs.append(L("Nobody messaged this run, so there is no conversation to reply to."))
                output["reason"] = .string("no_conversation")
                return WorkflowNodeOutcome(output: .object(output), logs: logs)
            }
            if delivery.sent {
                output["sent"] = .bool(true)
                output["attachment_sent"] = .bool(true)
                logs.append(L("Sent the file \(file.lastPathComponent)."))
            } else if delivery.reason == WorkflowChannelReplier.Delivery.replyCap.reason {
                output["reason"] = .string("reply_cap")
                logs.append(Self.capLog)
            } else if let reason = delivery.reason, reason.hasPrefix("unsupported_on_") {
                output["reason"] = .string(reason)
                logs.append(L("This channel cannot take files; \(file.lastPathComponent) was not sent."))
            } else if delivery.reason == "no_live_connection" {
                output["reason"] = .string("no_live_connection")
                logs.append(
                    L(
                        "This channel takes files only as a reply to the message, which Osaurus no longer holds; \(file.lastPathComponent) was not sent."
                    ))
            } else {
                try fail(delivery, partial: textSent, logs: &logs, output: &output)
            }
        }
        return WorkflowNodeOutcome(output: .object(output), logs: logs)
    }

    private static var capLog: String {
        L("This run already posted \(ReplySpec.maximumRepliesPerRun) replies, the most one run may; nothing more was sent.")
    }

    /// A refused send. Paused writes are the person's choice and do not
    /// fail the run; anything else fails the step unless part of the reply
    /// already went out.
    private static func fail(
        _ delivery: WorkflowChannelReplier.Delivery, partial: Bool, logs: inout [String],
        output: inout [String: JSONValue]
    ) throws {
        let reason = delivery.reason ?? "send_failed"
        output["reason"] = .string(reason)
        let message = delivery.error ?? L("The channel did not take the reply.")
        logs.append(message)
        if reason == "writes_paused" || partial { return }
        throw WorkflowNodeError.toolFailed(tool: "reply", kind: reason, message: message, retryable: true)
    }
}
