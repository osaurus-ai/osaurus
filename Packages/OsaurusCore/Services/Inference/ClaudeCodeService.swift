//
//  ClaudeCodeService.swift
//  osaurus
//
//  A `ToolCapableService` backed by the user's locally-installed, already
//  signed-in Claude Code CLI. This is how Osaurus reaches a Claude Pro/Max
//  subscription without an Anthropic API key: Claude Code is itself the
//  licensed client, and Anthropic supports driving it programmatically.
//  Osaurus never mints, stores, or sees an Anthropic credential.
//
//  Plugs in as a peer of `FoundationModelService` — non-HTTP, non-MLX, and
//  invisible to the routing layer beyond `isAvailable()` / `handles(_:)`.
//

import Foundation

/// Per-agent options for one Claude Code run.
public struct ClaudeCodeRunOptions: Sendable, Equatable {
    public var mode: ClaudeCodeMode
    /// Agent mode only: auto-approve the file-writing built-ins.
    public var allowWrites: Bool
    /// Agent mode only: auto-approve `Bash`.
    public var allowShell: Bool
    /// Agent mode only: attach Osaurus's config tools over MCP.
    public var allowOsaurusTools: Bool
    /// Nested under `allowOsaurusTools`: include the mutating ones.
    public var allowOsaurusConfigWrites: Bool
    /// Absolute path to the `osaurus` CLI that backs the MCP bridge. Resolved
    /// by the caller (the app knows its own bundle); nil disables the bridge
    /// even when `allowOsaurusTools` is set, so a source build without an
    /// embedded CLI degrades instead of spawning a bad command.
    public var osaurusCLIPath: String?
    /// The chat's working folder. Nil falls back to a scratch directory, so a
    /// run without a folder can't wander into the app bundle or the user's home.
    public var workingDirectory: URL?
    /// The agent this turn belongs to.
    ///
    /// Claude Code runs out of process, so `ChatExecutionContext.currentAgentId`
    /// — a `@TaskLocal` — cannot reach the tool calls it makes back through the
    /// MCP bridge. Carrying the id here lets the bridge mint a grant the server
    /// can verify, which is what restores the identity the boundary lost.
    public var agentId: UUID?

    public init(
        mode: ClaudeCodeMode = .agent,
        allowWrites: Bool = false,
        allowShell: Bool = false,
        allowOsaurusTools: Bool = false,
        allowOsaurusConfigWrites: Bool = false,
        osaurusCLIPath: String? = nil,
        workingDirectory: URL? = nil,
        agentId: UUID? = nil
    ) {
        self.mode = mode
        self.allowWrites = allowWrites
        self.allowShell = allowShell
        self.allowOsaurusTools = allowOsaurusTools
        self.allowOsaurusConfigWrites = allowOsaurusConfigWrites
        self.osaurusCLIPath = osaurusCLIPath
        self.workingDirectory = workingDirectory
        self.agentId = agentId
    }

    /// Whether this run should actually attach the MCP bridge.
    ///
    /// Text-only mode disables every tool, and the bridge is useless without a
    /// CLI to launch, so both are hard preconditions rather than caller duties.
    public var attachesOsaurusMCP: Bool {
        mode == .agent && allowOsaurusTools && osaurusCLIPath != nil
    }

    public static let `default` = ClaudeCodeRunOptions()
}

actor ClaudeCodeService: ToolCapableService {
    static let serviceId = "claude-code"
    nonisolated let id: String = serviceId

    nonisolated func isAvailable() -> Bool {
        ClaudeCodeConfiguration.isAvailable()
    }

    /// Claims only its own `claude-code/…` ids. Unlike `FoundationModelService`
    /// it never claims the empty / "default" model, so installing Claude Code
    /// can't silently take over the system default.
    nonisolated func handles(requestedModel: String?) -> Bool {
        guard let requestedModel else { return false }
        return ClaudeCodeModel.fromPickerId(requestedModel) != nil
    }

    // MARK: - ModelService

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        let stream = try await streamDeltas(
            messages: messages,
            parameters: parameters,
            requestedModel: requestedModel,
            stopSequences: []
        )
        return try await Self.collectVisibleText(from: stream)
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        let model = ClaudeCodeModel.fromPickerId(requestedModel ?? "") ?? .sonnet
        let options = parameters.claudeCode ?? .default

        guard let executable = ClaudeCodeConfiguration.resolveExecutable() else {
            throw ClaudeCodeError.binaryNotFound(searchedPath: ClaudeCodeConfiguration.searchedPath())
        }

        let rendered = Self.renderPrompt(messages: messages)

        // The MCP bridge proxies to the local HTTP server, so a config written
        // while the server is down would hand the model tools whose every call
        // fails. Resolving it here (rather than at settings time) also means
        // starting the server mid-session makes the tools work on the next turn.
        // Minted before the config so the grant can be embedded in it. Nil when
        // the run has no agent to speak for; the bridge still attaches, the
        // child is just unattributed and the Default agent's tools will refuse.
        let bridgeGrant: String? = await {
            guard options.attachesOsaurusMCP, let agentId = options.agentId else { return nil }
            return await ClaudeCodeBridgeGrantStore.shared.mint(
                agentId: agentId,
                allowsConfigWrites: options.allowOsaurusConfigWrites
            )
        }()

        let mcpConfigURL = await Self.makeOsaurusMCPConfig(options: options, bridgeGrant: bridgeGrant)

        // Tell the model what it actually has. Osaurus agent prompts routinely
        // instruct "read state with osaurus_status"; that text arrives here
        // regardless, so an un-bridged run must be told the tools are absent or
        // it burns the turn guessing at permission errors.
        let toolNote = ClaudeCodeConfiguration.osaurusToolsSystemNote(
            available: mcpConfigURL != nil,
            allowConfigWrites: options.allowOsaurusConfigWrites,
            reason: Self.osaurusToolsUnavailableReason(
                options: options,
                bridgeAttached: mcpConfigURL != nil
            )
        )
        let systemPrompt = [rendered.systemPrompt, toolNote]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let arguments = ClaudeCodeConfiguration.arguments(
            model: model,
            mode: options.mode,
            allowedTools: ClaudeCodeConfiguration.allowedTools(
                allowWrites: options.allowWrites,
                allowShell: options.allowShell,
                allowOsaurusTools: mcpConfigURL != nil,
                allowOsaurusConfigWrites: options.allowOsaurusConfigWrites
            ),
            systemPrompt: systemPrompt,
            mcpConfigPath: mcpConfigURL?.path
        )

        let events = ClaudeCodeProcessRunner.stream(
            executable: executable,
            arguments: arguments,
            prompt: rendered.prompt,
            workingDirectory: options.workingDirectory ?? Self.scratchDirectory()
        )

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let producerTask = Task {
            // A grant outlives its usefulness the moment the turn ends, so it is
            // revoked on every exit — normal finish, thrown error, and
            // cancellation alike. `defer` rather than a trailing call because
            // the loop below has three separate returns.
            defer {
                if let bridgeGrant {
                    Task { await ClaudeCodeBridgeGrantStore.shared.revoke(bridgeGrant) }
                }
                if let mcpConfigURL {
                    try? FileManager.default.removeItem(at: mcpConfigURL)
                }
            }
            do {
                for try await event in events {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    for delta in Self.encode(event) {
                        continuation.yield(delta)
                    }
                }
                continuation.finish()
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }
        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }
        return stream
    }

    // MARK: - ToolCapableService

    /// Osaurus's tools are never forwarded to the CLI.
    ///
    /// In agent mode Claude Code runs its own loop with its own tools, so the
    /// host loop must stay out of the way — the same short-circuit
    /// `RemoteProviderService` uses for a Mode 2 remote agent run.
    ///
    /// In text-only mode the CLI has no tools at all: `claude -p` accepts tool
    /// definitions only over MCP, never as OpenAI-style schemas, so there is no
    /// way to hand it `tools`. Either way the correct behavior is to stream
    /// text and never throw `ServiceToolInvocation`.
    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await streamDeltas(
            messages: messages,
            parameters: parameters,
            requestedModel: requestedModel,
            stopSequences: stopSequences
        )
    }

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String {
        let stream = try await streamWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            requestedModel: requestedModel
        )
        return try await Self.collectVisibleText(from: stream)
    }

    // MARK: - Event encoding

    /// Map a decoded CLI event onto the in-band wire contract every Osaurus
    /// service shares (plain text + `\u{FFFE}` sentinels).
    static func encode(_ event: ClaudeCodeStreamEvent) -> [String] {
        switch event {
        case .text(let text):
            return [text]

        case .reasoning(let text):
            return [StreamingReasoningHint.encode(text)]

        case .toolTrace(let trace):
            return [StreamingAgentToolHint.encode(trace)]

        case .stats(let outputTokens, let tokensPerSecond, let stopReason):
            return [
                StreamingStatsHint.encode(
                    tokenCount: outputTokens,
                    tokensPerSecond: tokensPerSecond,
                    stopReason: stopReason
                )
            ]

        case .rateLimit(let status, let utilization, _):
            // Surfaced, never retried — this is the user's interactive Pro/Max
            // budget and silently re-spending it would be worse than saying so.
            // Only warn once the CLI itself flags a threshold breach.
            guard status != "allowed" else { return [] }
            let percent = Int((utilization * 100).rounded())
            return [
                StreamingAgentToolHint.encode(
                    StreamingAgentToolHint.Trace(
                        phase: "completed",
                        name: "rate limit \(percent)%",
                        callId: nil,
                        isError: status != "allowed_warning",
                        endRun: false
                    )
                )
            ]

        case .failure:
            // Surfaced as a thrown error by the runner's exit handling; the
            // in-band frame carries no extra signal worth showing twice.
            return []
        }
    }

    // MARK: - Prompt rendering

    struct RenderedPrompt {
        let systemPrompt: String?
        let prompt: String
    }

    /// Flatten the OpenAI-style message array into what `claude -p` accepts.
    ///
    /// The CLI's print mode takes a single prompt string plus an appended
    /// system prompt; there is no structured multi-turn input short of
    /// `--input-format stream-json`, which only carries user messages. So
    /// prior turns are rendered as a labeled transcript. This is a real
    /// fidelity limit of the CLI surface, not an oversight — assistant turns
    /// reach the model as quoted history rather than as native assistant
    /// messages.
    static func renderPrompt(messages: [ChatMessage]) -> RenderedPrompt {
        var systemParts: [String] = []
        var transcript: [String] = []

        for message in messages {
            let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch message.role {
            case "system":
                systemParts.append(text)
            case "assistant":
                transcript.append("Assistant: \(text)")
            case "tool":
                transcript.append("Tool result: \(text)")
            default:
                transcript.append("User: \(text)")
            }
        }

        // A single trailing user turn is by far the common case; sending it
        // bare (no "User:" label) keeps the prompt identical to what the user
        // would have typed into the CLI themselves.
        let prompt: String
        if transcript.count == 1, let only = transcript.first, only.hasPrefix("User: ") {
            prompt = String(only.dropFirst("User: ".count))
        } else {
            prompt = transcript.joined(separator: "\n\n")
        }

        return RenderedPrompt(
            systemPrompt: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n"),
            prompt: prompt
        )
    }

    // MARK: - Helpers

    /// Concatenate visible prose, dropping every `\u{FFFE}` control frame.
    /// Mirrors `MLXService.generateOneShot` so a non-streaming caller never
    /// finds a sentinel embedded in `content`.
    private static func collectVisibleText(
        from stream: AsyncThrowingStream<String, Error>
    ) async throws -> String {
        var out = ""
        for try await delta in stream where !StreamingToolHint.isSentinel(delta) {
            out += delta
        }
        return out
    }

    /// Scratch cwd for runs with no working folder. Inside Osaurus's own
    /// directory so it's covered by existing cleanup and never the app bundle.
    private static func scratchDirectory() -> URL {
        let dir = OsaurusPaths.root().appendingPathComponent("claude-code", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Why the bridge isn't attached, so the system note can be specific.
    ///
    /// Nil when it *is* attached. The distinction matters to the user: "switch
    /// it on in settings" and "start the Osaurus server" are different fixes,
    /// and a model that can name the right one saves a round trip.
    private static func osaurusToolsUnavailableReason(
        options: ClaudeCodeRunOptions,
        bridgeAttached: Bool
    ) -> ClaudeCodeConfiguration.OsaurusToolsUnavailableReason? {
        if bridgeAttached { return nil }
        if options.mode == .textOnly { return .textOnlyMode }
        if !options.allowOsaurusTools { return .notEnabled }
        // Opted in, agent mode, but no config was produced. A missing CLI is
        // reported as "not enabled" — it isn't actionable by the user and a
        // packaged build always has one; the live case is a stopped server.
        return options.osaurusCLIPath == nil ? .notEnabled : .serverNotRunning
    }

    /// Write the `--mcp-config` file for this run, or nil when the bridge
    /// shouldn't be attached.
    ///
    /// Returns nil — rather than an empty config — when the run doesn't want
    /// the bridge, when there's no CLI to launch, or when the Osaurus server
    /// isn't listening. That last check is what stops the model from being
    /// handed tools it can't actually use: `osaurus mcp` is a proxy, so with
    /// the server down every call would fail at the transport layer with an
    /// error the model can't act on.
    ///
    /// Every turn receives a unique file. A fixed filename lets concurrent
    /// chats overwrite one another's grant between process launch and MCP
    /// startup, crossing agent identity and write scope. The producer removes
    /// this file on every normal, error, and cancellation exit.
    private static func makeOsaurusMCPConfig(
        options: ClaudeCodeRunOptions,
        bridgeGrant: String?
    ) async -> URL? {
        guard options.attachesOsaurusMCP, let cliPath = options.osaurusCLIPath else { return nil }
        let port = await MainActor.run { ServerConfigurationStore.load()?.port ?? 1337 }
        guard isOsaurusServerReachable(port: port) else { return nil }
        guard
            let json = ClaudeCodeConfiguration.mcpConfigJSON(
                cliPath: cliPath,
                allowConfigWrites: options.allowOsaurusConfigWrites,
                bridgeGrant: bridgeGrant
            )
        else { return nil }

        let url = scratchDirectory().appendingPathComponent(
            "mcp-config-\(UUID().uuidString).json",
            isDirectory: false
        )
        do {
            try Data(json.utf8).write(to: url, options: .atomic)
            // The file now carries the turn's grant, so it must not be readable
            // by other accounts on the machine. `.atomic` writes a fresh inode
            // under the process umask, so the mode is set after the fact rather
            // than assumed.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return url
        } catch {
            return nil
        }
    }

    /// Cheap liveness probe for the local HTTP server.
    ///
    /// A TCP connect, not an HTTP round trip: this runs on the send path and
    /// only needs to answer "is anything listening", which is exactly what a
    /// refused connect tells us.
    private static func isOsaurusServerReachable(port configured: Int, timeout: TimeInterval = 0.5)
        -> Bool
    {
        guard configured > 0, configured <= Int(UInt16.max) else { return false }
        let port = UInt16(configured)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return connected
    }
}
