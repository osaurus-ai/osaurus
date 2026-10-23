//
//  HarnessTestSupport.swift
//  osaurusTests
//

import Foundation

@testable import OsaurusCore

enum HarnessFixtures {
    static func temporaryDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: realPath(dir.path), isDirectory: true)
    }

    /// `/var/…` → `/private/var/…`, matching what a child's `pwd -P` reports.
    /// (`resolvingSymlinksInPath` goes the other way.)
    static func realPath(_ path: String) -> String {
        path.withCString { pointer -> String? in
            guard let real = realpath(pointer, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
        } ?? path
    }

    @discardableResult
    static func writeExecutable(_ contents: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func context(
        runtime: HarnessRuntime,
        chatId: UUID = UUID(),
        agentId: UUID = UUID(),
        workingDirectory: URL,
        isUserFolder: Bool = true,
        systemPrompt: String? = nil,
        claudeCode: ClaudeCodeAgentConfig = .default,
        osaurusCLIPath: String? = nil,
        apiBase: String? = nil,
        serverReachable: Bool = false,
        sessionMode: HarnessLaunchContext.SessionMode = .automatic
    ) -> HarnessLaunchContext {
        HarnessLaunchContext(
            runtime: runtime,
            chatId: chatId,
            agentId: agentId,
            agentName: "Test Agent",
            workingDirectory: workingDirectory,
            isUserFolder: isUserFolder,
            systemPrompt: systemPrompt,
            claudeCode: claudeCode,
            osaurusCLIPath: osaurusCLIPath,
            apiBase: apiBase,
            serverReachable: serverReachable,
            sessionMode: sessionMode
        )
    }

    static func collect(_ stream: AsyncThrowingStream<HarnessEvent, Error>) async throws -> [HarnessEvent] {
        var events: [HarnessEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    static func decodeAll(_ codec: HarnessCodec, _ lines: [String]) -> (events: [HarnessEvent], replies: [Data]) {
        var events: [HarnessEvent] = []
        var replies: [Data] = []
        for line in lines {
            let decoded = codec.decode(line: Data(line.utf8))
            events += decoded.events
            replies += decoded.replies
        }
        return (events, replies)
    }

    static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Whether a pid still names a live process.
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// A shell script that speaks enough of Pi's RPC protocol to drive a real
    /// `HarnessSession`. The message text picks the behavior:
    /// `crash` exits mid-turn, `hang` streams then waits for `abort`, `ask`
    /// raises a confirm dialog, `env` reports the launch contract, anything
    /// else answers `turn<N> pid=<pid>`. `get_state` reports `$FAKE_MODEL`
    /// (JSON; default: Pi's "unknown" model). On stdin EOF it writes "eof" to
    /// `$FAKE_EXIT_MARKER` and exits, unless `$FAKE_IGNORE_EOF` is set.
    static let fakePiScript = #"""
        #!/bin/sh
        turn=0
        if [ -n "$FAKE_MODEL" ]; then model=$FAKE_MODEL; else model='{"id":"unknown","provider":"unknown"}'; fi
        delta() {
          printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"%s"}}\n' "$1"
        }
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
          case "$line" in
            *'"type":"prompt"'*)
              turn=$((turn+1))
              printf '{"type":"response","command":"prompt","success":true,"id":"%s"}\n' "$id"
              printf '{"type":"agent_start"}\n'
              case "$line" in
                *'"message":"crash'*)
                  printf 'fake harness crashed\n' >&2
                  exit 3 ;;
                *'"message":"hang'*)
                  delta "working" ;;
                *'"message":"ask'*)
                  printf '{"type":"extension_ui_request","id":"d1","method":"confirm","title":"Proceed?","message":"Really?"}\n' ;;
                *'"message":"env'*)
                  delta "chat=$OSAURUS_CHAT_ID agent=$OSAURUS_AGENT_ID cwd=$(pwd -P) wd=$OSAURUS_WORKING_DIRECTORY token=$OSAURUS_AGENT_TOKEN grant=$OSAURUS_MCP_BRIDGE_GRANT args=$*"
                  printf '{"type":"agent_settled"}\n' ;;
                *)
                  delta "turn$turn pid=$$"
                  printf '{"type":"agent_settled"}\n' ;;
              esac ;;
            *'"type":"get_state"'*)
              printf '{"id":"%s","type":"response","command":"get_state","success":true,"data":{"model":%s,"isStreaming":false}}\n' "$id" "$model" ;;
            *'"type":"abort"'*)
              printf '{"type":"message_end","message":{"role":"assistant","stopReason":"aborted"}}\n'
              printf '{"type":"agent_settled"}\n' ;;
            *'"type":"extension_ui_response"'*)
              case "$line" in
                *'"confirmed":true'*) answer=yes ;;
                *) answer=no ;;
              esac
              delta "confirmed=$answer"
              printf '{"type":"agent_settled"}\n' ;;
          esac
        done
        if [ -n "$FAKE_IGNORE_EOF" ]; then
          exec sleep 600
        fi
        [ -n "$FAKE_EXIT_MARKER" ] && printf eof > "$FAKE_EXIT_MARKER"
        exit 0
        """#
}

extension Array where Element == HarnessEvent {
    var visibleText: String {
        compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
    }
}
