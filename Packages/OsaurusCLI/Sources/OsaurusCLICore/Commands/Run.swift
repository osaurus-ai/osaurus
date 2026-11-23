//
//  Run.swift
//  osaurus
//
//  Interactive chat command that allows users to chat with a downloaded model via the CLI.
//

import Foundation

public struct RunCommand: Command {
    public static let name = "run"

    static let usage = """
        Usage: osaurus run <model_id> [--access-key KEY]

        Chats with a model in the terminal. Type `exit` (or press Ctrl-D) to quit.
        A failed turn prints the error and the chat stays open.
        """

    public static func execute(args: [String]) async {
        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(EXIT_SUCCESS)
        }
        let rest = AccessKeyResolver.removingAccessKeyOptions(from: args)
        guard let modelArg = rest.first, !modelArg.isEmpty, !modelArg.hasPrefix("-") else {
            fputs("Missing required <model_id>\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        }
        if rest.count > 1 {
            fputs("osaurus run: unknown argument `\(rest[1])`\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        }

        let client = await LocalServerClient.connect(command: "run", args: args)

        let sessionId = "cli-\(UUID().uuidString.prefix(8))"
        var transcript: [ChatMessage] = []

        print("Chatting with \(modelArg). Type 'exit' to quit.\n")
        while true {
            fputs("> ", stdout)
            fflush(stdout)
            guard let line = readLine(strippingNewline: true) else { break }
            let userInput = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if userInput.lowercased() == "exit" { break }
            if userInput.isEmpty { continue }

            transcript.append(ChatMessage(role: "user", content: userInput))
            if let reply = await streamTurn(client: client, model: modelArg, transcript: transcript, sessionId: sessionId) {
                if !reply.isEmpty { transcript.append(ChatMessage(role: "assistant", content: reply)) }
            } else {
                // Keep the conversation consistent: the failed message is
                // dropped so the next turn does not resend it unanswered.
                transcript.removeLast()
            }
        }
        print("Goodbye.")
        exit(EXIT_SUCCESS)
    }

    /// Streams one turn to stdout and returns the reply, or nil when the
    /// turn failed (the error is printed).
    private static func streamTurn(
        client: LocalServerClient,
        model: String,
        transcript: [ChatMessage],
        sessionId: String
    ) async -> String? {
        var request = client.request("/chat", method: "POST", timeout: 3600)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        let body = ChatRequest(
            model: model,
            messages: transcript,
            stream: true,
            temperature: nil,
            max_tokens: nil,
            session_id: sessionId
        )
        guard let payload = try? JSONEncoder().encode(body) else {
            fputs("Failed to encode chat request\n", stderr)
            return nil
        }
        request.httpBody = payload

        do {
            let (bytes, http) = try await client.bytes(for: request)
            if http.statusCode == 401 { client.exitUnauthorized() }
            if http.statusCode != 200 {
                var errorData = Data()
                do {
                    for try await chunk in bytes { errorData.append(chunk) }
                } catch {}
                let message = String(data: errorData, encoding: .utf8) ?? ""
                fputs("Chat request failed (status \(http.statusCode)).\n\(message)\n", stderr)
                return nil
            }

            let decoder = JSONDecoder()
            var reply = ""
            for try await line in bytes.lines {
                if line.isEmpty { continue }
                if let data = line.data(using: .utf8),
                    let event = try? decoder.decode(NDJSONEvent.self, from: data)
                {
                    if let content = event.message?.content, !content.isEmpty {
                        reply += content
                        print(content, terminator: "")
                        fflush(stdout)
                    }
                    if event.done == true {
                        print("")
                        break
                    }
                } else {
                    print(line)
                }
            }
            return reply
        } catch {
            fputs("\nStreaming error: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }
}
