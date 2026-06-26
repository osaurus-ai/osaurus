//
//  OcrSubagentKind.swift
//  OsaurusCore — Subagent framework
//
//  The OCR sub-agent kind that serves the single `ocr` tool: extract text from
//  one or more local images using a configured local OCR VLM (DeepSeek-OCR /
//  Unlimited-OCR). Resolves the per-agent OCR model, seeds a bounded multimodal
//  completion (image + grounding prompt) on that model through
//  `AgentSubagentRunner`, and hands back the extracted text as a compact digest.
//
//  `modelSource = .dedicatedConfigured` (its own per-agent model, like `image`),
//  but — unlike the image coordinator, which owns its residency internally — OCR
//  runs the bounded VLM completion through the shared text runner, so it uses the
//  host `ResidencyHandoff` (like `spawn`/text) to unload the resident chat model
//  when the OCR model is a DIFFERENT local model (single GPU residency). The
//  reject-before-evict policy gates (not enabled, permission denied, no model)
//  are resolved up front so nothing is evicted before we know the run can run.
//

import Foundation

/// Parsed, validated `ocr` tool arguments.
struct OcrJobParams: Sendable {
    /// One-to-four local image file paths to extract text from.
    var imagePaths: [String]
    /// Optional OCR model id; `nil` → use the per-agent configured default.
    var model: String?
    /// Optional extraction/grounding prompt; `nil` → the default grounding prompt.
    var prompt: String?
}

final class OcrSubagentKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.ocr

    private let params: OcrJobParams
    private let argumentsJSON: String

    /// Cap on the OCR text handed back to the parent.
    private static let digestMaxChars = 16_000
    /// Token cap for the OCR completion (text can be long for dense documents).
    private static let ocrMaxTokens = 8_192
    /// Max images per call.
    static let maxImages = 4
    /// Per-image byte ceiling (mirrors the image-edit source limit).
    private static let maxImageBytes = 80 * 1024 * 1024
    /// Default grounding prompt — DeepSeek-OCR / Unlimited-OCR emit clean output
    /// for the grounding form (bare prompts can emit a leading EOS → empty).
    private static let defaultPrompt = "<|grounding|>OCR this image."

    // Resolved up front in `resolveModel`, read by permission/handoff/run.
    private var residencyShouldUnload = false
    private var residencyRequiredBytes: Int64 = 0
    private var ramSafetyEnabled = false
    private var handoffMaxElapsedSeconds = 120

    init(params: OcrJobParams, argumentsJSON: String) {
        self.params = params
        self.argumentsJSON = argumentsJSON
    }

    var feedTitle: String {
        let count = params.imagePaths.count
        return "ocr: \(count) image\(count == 1 ? "" : "s")"
    }

    // MARK: - Model resolution (reject-before-evict)

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let config = SubagentConfigurationStore.snapshot()
        // Per-agent OCR enable + model (no global master switch): Default / main
        // chat → its own OCR switch + configured model; a custom agent → its own
        // `ocrEnabled` toggle + per-agent model, resolved from the launching
        // agent (`scope`).
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }
        guard
            SubagentToolVisibility.ocrAvailable(
                isDefault: isDefault,
                config: config,
                perAgentEnabled: settings?.ocrEnabled ?? false
            )
        else {
            throw SubagentError.denied("OCR is not enabled for this agent.")
        }
        if SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id,
            isDefault: isDefault,
            config: config,
            settings: settings
        ) == .deny {
            throw SubagentError.denied("OCR is denied by this agent's permission settings.")
        }

        // Resolve the model: explicit request → per-agent configured default →
        // a first-ready installed OCR model (name contains "ocr"). All must be
        // an INSTALLED local bundle (OCR runs locally on the GPU).
        let configured = SubagentToolVisibility.effectiveOcrModel(
            isDefault: isDefault,
            config: config,
            settings: settings
        )
        let resolvedName = try Self.resolveModelName(
            requested: params.model,
            configured: configured
        )

        // Decide the residency handoff from ACTUAL GPU residency: if the OCR
        // model is local and a DIFFERENT chat model is resident, unload it first
        // so only one model touches the GPU at a time (avoids the MLX
        // shared-command-stream SIGABRT). The handoff middleware runs the
        // refuse-before-evict RAM preflight before any eviction.
        let residentChatModels = await ModelRuntime.shared.cachedModelSummaries().map(\.name)
        let otherResidentModels = residentChatModels.filter {
            $0.caseInsensitiveCompare(resolvedName) != .orderedSame
        }
        if !otherResidentModels.isEmpty {
            self.residencyShouldUnload = true
            self.residencyRequiredBytes = ChatResidencyHandoff.estimatedChatModelBytes(named: resolvedName)
            self.ramSafetyEnabled = config.ramSafetyPreflightEnabled
            self.handoffMaxElapsedSeconds = SubagentToolVisibility.effectiveBudgets(
                isDefault: isDefault,
                config: config,
                settings: settings
            ).maxElapsedSeconds
        }

        return ResolvedModel(name: resolvedName, id: resolvedName, isLocal: true)
    }

    /// Resolve the OCR model name to an installed local bundle, or throw a
    /// helpful `unavailable` error. Tries the explicit request, then the
    /// per-agent configured default.
    private static func resolveModelName(requested: String?, configured: String?) throws -> String {
        for candidate in [requested, configured] {
            guard let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { continue }
            guard ModelManager.findInstalledModel(named: name) != nil else {
                throw SubagentError.unavailable(
                    "OCR model '\(name)' is not installed. Pick an installed OCR model in the agent's Sub-agents tab."
                )
            }
            return name
        }
        throw SubagentError.unavailable(
            "No OCR model is configured. Install a local OCR model (e.g. DeepSeek-OCR / Unlimited-OCR) "
                + "and select it in the agent's Sub-agents tab."
        )
    }

    // MARK: - Permission

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }
        let policy = SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id,
            isDefault: isDefault,
            config: config,
            settings: settings
        )
        switch policy {
        case .deny:
            return .denied("OCR is denied by this agent's permission settings.")
        case .alwaysAllow:
            return .allow
        case .ask:
            if ChatExecutionContext.autoApproveToolPrompts { return .allow }
            let approvalJSON = SubagentApprovalArguments.enrichedJSON(
                from: argumentsJSON,
                values: ["resolved_model": resolved.name]
            )
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: "ocr",
                description: OcrTool.toolDescription,
                argumentsJSON: approvalJSON
            )
            return approved ? .allow : .userDenied("User denied OCR.")
        }
    }

    // MARK: - Residency handoff

    func makeHandoff() -> SubagentHandoff {
        guard residencyShouldUnload else { return PassthroughHandoff() }
        let plan = ResidencyPlan(
            shouldUnload: true,
            requiredBytes: residencyRequiredBytes,
            ramSafetyEnabled: ramSafetyEnabled,
            maxElapsedSeconds: handoffMaxElapsedSeconds
        )
        return ResidencyHandoff.production { _ in plan }
    }

    // MARK: - Run

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        feed.emitPhase("extracting", detail: resolved.name)

        let images: [Data]
        do {
            images = try Self.loadImages(paths: params.imagePaths)
        } catch let error as OcrInputError {
            throw SubagentError.invalidArgs(
                message: String(describing: error),
                field: "images",
                expected: "one to \(Self.maxImages) existing local image files under 80 MB each"
            )
        }

        let prompt = (params.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? Self.defaultPrompt
        let seed: [ChatMessage] = [
            ChatMessage(
                role: "system",
                content:
                    "You are an OCR engine. Transcribe the text in the user's image(s) exactly as it "
                    + "appears, preserving line breaks and reading order. Output only the transcribed "
                    + "text, with no commentary."
            ),
            ChatMessage(role: "user", text: prompt, imageData: images),
        ]
        let deadline = Date().addingTimeInterval(TimeInterval(handoffMaxElapsedSeconds))
        let sessionId = "ocr-\(scope.toolCallId)-\(UUID().uuidString)"

        let result = try await AgentSubagentRunner.run(
            modelName: resolved.name,
            seedMessages: seed,
            maxTokens: Self.ocrMaxTokens,
            maxIterations: 1,
            deadline: deadline,
            sessionId: sessionId,
            isInterrupted: { interrupt.isInterrupted }
        )

        switch result.exit {
        case .finalResponse, .endedBySurface:
            let text = (result.digest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw SubagentError.emptyExhausted(
                    "OCR returned no text. The image may be blank, or the model may need a grounding prompt."
                )
            }
            let capped =
                text.count > Self.digestMaxChars
                ? String(text.prefix(Self.digestMaxChars)) + "\n[text truncated]"
                : text
            let count = params.imagePaths.count
            return SubagentResult(
                payload: [
                    "kind": "ocr_result",
                    "model": resolved.name,
                    "image_count": count,
                    "text": capped,
                    "summary": "Extracted text from \(count) image\(count == 1 ? "" : "s") with \(resolved.name).",
                    "handoff": residencyShouldUnload,
                ] as [String: Any],
                summary: capped
            )
        case .cancelled:
            throw SubagentError.timedOut("OCR hit its \(handoffMaxElapsedSeconds)s time budget.")
        case .iterationCapReached:
            throw SubagentError.iterationCap("OCR did not produce text within its turn budget.")
        case .toolRejected:
            throw SubagentError.toolRejected("OCR attempted unavailable child tool use.")
        case .overBudget:
            throw SubagentError.overBudget("OCR exceeded its context budget. Try fewer / smaller images.")
        case .emptyResponseExhausted:
            throw SubagentError.emptyExhausted(
                "OCR returned empty output. The model may need a grounding prompt or a different OCR model."
            )
        }
    }

    // MARK: - Image loading

    static func loadImages(paths: [String]) throws -> [Data] {
        let trimmed =
            paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty, trimmed.count <= maxImages else {
            throw OcrInputError.invalidImageCount
        }
        return try trimmed.map { path in
            // Accept an inline data URL directly (base64-encoded image bytes).
            if path.hasPrefix("data:"), let comma = path.firstIndex(of: ","),
                let data = Data(base64Encoded: String(path[path.index(after: comma)...]))
            {
                return data
            }
            let url =
                URL(string: path).flatMap { $0.isFileURL ? $0 : nil }
                ?? URL(fileURLWithPath: path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw OcrInputError.notAFile(path)
            }
            if let size = values.fileSize, size > maxImageBytes {
                throw OcrInputError.fileTooLarge(path)
            }
            return try Data(contentsOf: url)
        }
    }
}

/// Argument/IO validation failures for the `ocr` tool.
enum OcrInputError: Error, CustomStringConvertible {
    case invalidImageCount
    case notAFile(String)
    case fileTooLarge(String)

    var description: String {
        switch self {
        case .invalidImageCount:
            return "images must contain one to \(OcrSubagentKind.maxImages) image paths"
        case .notAFile(let path):
            return "image path is not a regular file: \(path)"
        case .fileTooLarge(let path):
            return "image exceeds the 80 MB limit: \(path)"
        }
    }
}
