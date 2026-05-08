//
//  Run.swift
//  osaurus
//
//  Interactive chat command that allows users to chat with a downloaded model via the CLI.
//

import Foundation

public struct RunCommand: Command {
    public static let name = "run"

    public static func execute(args: [String]) async {
        guard let modelArg = args.first, !modelArg.isEmpty else {
            fputs("Отсутствует обязательный <model_id>\n\n", stderr)
            // printUsage() // Usage is now handled by Main or Help command
            exit(EXIT_FAILURE)
        }

        let port = await ServerControl.ensureServerReadyOrExit(pollSeconds: 5.0)

        let sessionId = "cli-\(UUID().uuidString.prefix(8))"
        var transcript: [ChatMessage] = []

        print("Чат с \(modelArg). Чтобы выйти, введите 'exit'.\n")
        while true {
            // Prompt
            fputs("> ", stdout)
            fflush(stdout)
            guard let line = readLine(strippingNewline: true) else { break }
            let userInput = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if userInput.lowercased() == "exit" { break }
            if userInput.isEmpty { continue }

            transcript.append(ChatMessage(role: "user", content: userInput))

            // Build streaming request
            guard let url = URL(string: "http://127.0.0.1:\(port)/chat") else {
                fputs("Неверный URL для чата\n", stderr)
                exit(EXIT_FAILURE)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 3600  // allow long-lived stream (1 hour)

            let body = ChatRequest(
                model: modelArg,
                messages: transcript,
                stream: true,
                temperature: nil,
                max_tokens: nil,
                session_id: sessionId
            )
            do {
                let payload = try JSONEncoder().encode(body)
                request.httpBody = payload
            } catch {
                fputs("Не удалось закодировать запрос чата: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }

            // Stream NDJSON response
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    var errorData = Data()
                    do {
                        for try await chunk in bytes { errorData.append(contentsOf: [chunk]) }
                    } catch { /* ignore stream read errors on failure */  }
                    let message = String(data: errorData, encoding: .utf8) ?? ""
                    fputs("Запрос чата не выполнен (статус \(http.statusCode)).\n\(message)\n", stderr)
                    exit(EXIT_FAILURE)
                }

                let decoder = JSONDecoder()
                var assistantAggregate = ""
                for try await line in bytes.lines {
                    if line.isEmpty { continue }
                    // Decode NDJSON event and print incremental content
                    if let data = line.data(using: .utf8),
                        let event = try? decoder.decode(NDJSONEvent.self, from: data)
                    {
                        if let content = event.message?.content, !content.isEmpty {
                            assistantAggregate += content
                            print(content, terminator: "")
                            fflush(stdout)
                        }
                        if event.done == true {
                            print("")
                            break
                        }
                    } else {
                        // Fallback: just print raw line
                        print(line)
                    }
                }
                if !assistantAggregate.isEmpty {
                    transcript.append(ChatMessage(role: "assistant", content: assistantAggregate))
                }
            } catch {
                fputs("Ошибка потоковой передачи: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        print("До свидания.")
        exit(EXIT_SUCCESS)
    }
}
