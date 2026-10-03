//
//  MediaActivityLogger.swift
//  osaurus
//
//  Activity-log rows for the non-chat model work Osaurus performs:
//  speech synthesis (TTS), speech-to-text (STT), text embeddings and
//  image / video generation. Each is one row with its own
//  `ActivityCategory`, a Local/Cloud locality, and the destination host
//  when the data left this Mac.
//
//  Content policy follows the rest of the log: spoken text, transcripts
//  and media prompts are stored as request/response bodies (and withheld
//  when Privacy › Activity Log › Store Prompts and Responses is off);
//  embedding inputs are never copied — only counts and sizes.
//
//  Double-log guard: the local HTTP API already writes an inbound row for
//  `/v1/embeddings`, `/v1/audio/transcriptions`, `/v1/images/*`. When one
//  of these emitters runs inside such a request (`ActivityAttribution`
//  says the caller is `.httpAPI`), it skips its own row so a reviewer sees
//  the single HTTP row with the model filled in by the handler.
//

import Foundation

enum MediaActivityLogger {

    /// Why a speech / media job ran (shown as "Triggered by").
    enum Trigger: String, Sendable {
        case readAloud = "read_aloud"
        case speakTool = "speak_tool"
        case voiceInput = "voice_input"
        case chatTool = "chat_tool"
        case imagePanel = "image_panel"
        case httpAPI = "http_api"
        case background
    }

    /// True when the current task is serving a local HTTP API request whose
    /// handler logs its own row.
    nonisolated static func servingHTTPRequest() -> Bool {
        ChatExecutionContext.currentRequestSource == .httpAPI
    }

    // MARK: - Speech synthesis

    struct SpeechJob: Sendable {
        let text: String
        let model: String
        let voice: String?
        let provider: String
        let endpoint: String?
        let trigger: Trigger
        let attribution: InsightsService.ActivityAttribution
        let started = Date()

        /// `audioSeconds` is the playable audio produced (nil when unknown).
        func finish(audioSeconds: Double?, error: String?, cancelled: Bool = false) {
            let durationMs = Date().timeIntervalSince(started) * 1000
            let host = EgressInfo.host(from: endpoint)
            let isRemote = host != nil
            var details: [String: String] = [
                "chars": String(text.count),
                "provider": provider,
                "trigger": trigger.rawValue,
            ]
            if let voice, !voice.isEmpty { details["voice"] = voice }
            if let audioSeconds, audioSeconds > 0 { details["audio_seconds"] = String(format: "%.1f", audioSeconds) }
            if cancelled { details["cancelled"] = "true" }
            let egress = isRemote
                ? EgressInfo(
                    destinationLabel: provider,
                    destinationHost: host,
                    bytesSent: text.utf8.count,
                    dataClasses: ["speech_text"],
                    details: details
                )
                : EgressInfo(details: details)
            InsightsService.logRequest(
                source: trigger == .speakTool ? .tool : .chatUI,
                method: "POST",
                path: isRemote ? "/v1/audio/speech" : "/internal/speech_synthesis",
                statusCode: error == nil ? 200 : 500,
                durationMs: durationMs,
                requestBody: text,
                model: model,
                finishReason: error != nil ? .error : (cancelled ? .cancelled : .stop),
                errorMessage: error,
                connection: isRemote
                    ? RequestConnectionInfo(remoteEndpoint: endpoint, transport: .direct, mode: .remoteInference)
                    : nil,
                category: .speechSynthesis,
                locality: isRemote ? .remote : .local,
                egress: egress,
                agentId: attribution.agentId,
                agentName: attribution.agentName,
                sessionId: attribution.sessionId
            )
        }
    }

    /// Call on the caller's task before synthesis starts. `endpoint` nil =
    /// local synthesis.
    nonisolated static func beginSpeech(
        text: String,
        model: String,
        voice: String?,
        provider: String,
        endpoint: String?,
        trigger: Trigger
    ) -> SpeechJob {
        SpeechJob(
            text: text, model: model, voice: voice, provider: provider, endpoint: endpoint,
            trigger: trigger, attribution: .current()
        )
    }

    // MARK: - Transcription (STT)

    struct TranscriptionJob: Sendable {
        let model: String
        let audioSeconds: Double?
        let audioBytes: Int?
        let audioFormat: String?
        let mode: String
        let attribution: InsightsService.ActivityAttribution
        let started = Date()

        func finish(transcript: String?, language: String?, error: String?, audioSeconds measured: Double? = nil) {
            let durationMs = Date().timeIntervalSince(started) * 1000
            var details: [String: String] = ["mode": mode]
            let audioSeconds = measured ?? self.audioSeconds
            if let audioSeconds, audioSeconds > 0 { details["audio_seconds"] = String(format: "%.1f", audioSeconds) }
            if let audioBytes { details["audio_bytes"] = String(audioBytes) }
            if let audioFormat { details["audio_format"] = audioFormat }
            if let language, !language.isEmpty { details["language"] = language }
            if let transcript { details["transcript_chars"] = String(transcript.count) }
            InsightsService.logRequest(
                source: .chatUI,
                method: "POST",
                path: "/internal/audio_transcription",
                statusCode: error == nil ? 200 : 500,
                durationMs: durationMs,
                responseBody: transcript,
                model: model,
                finishReason: error == nil ? .stop : .error,
                errorMessage: error,
                category: .audioTranscription,
                locality: .local,
                egress: EgressInfo(details: details),
                agentId: attribution.agentId,
                agentName: attribution.agentName,
                sessionId: attribution.sessionId
            )
        }
    }

    /// Returns nil when the caller is an HTTP API request (that handler logs
    /// its own row).
    nonisolated static func beginTranscription(
        model: String,
        audioSeconds: Double?,
        audioBytes: Int?,
        audioFormat: String?,
        mode: String
    ) -> TranscriptionJob? {
        guard !servingHTTPRequest() else { return nil }
        return TranscriptionJob(
            model: model, audioSeconds: audioSeconds, audioBytes: audioBytes, audioFormat: audioFormat,
            mode: mode, attribution: .current()
        )
    }

    // MARK: - Embeddings

    /// Optional caller-declared purpose (`memory_search`, `tool_index`,
    /// `skill_search`, `knowledge_index`, `method_search`, `plugin_embed`…)
    /// recorded in the embedding row's details.
    @TaskLocal static var embeddingPurpose: String?

    /// One embedding batch. Metadata only.
    nonisolated static func logEmbedding(
        model: String,
        textCount: Int,
        totalChars: Int,
        dimensions: Int?,
        purpose: String?,
        durationMs: Double,
        error: String?
    ) {
        guard !servingHTTPRequest() else { return }
        let attribution = InsightsService.ActivityAttribution.current()
        var details: [String: String] = [
            "texts": String(textCount),
            "chars": String(totalChars),
        ]
        if let dimensions { details["dims"] = String(dimensions) }
        if let purpose, !purpose.isEmpty { details["purpose"] = purpose }
        InsightsService.logRequest(
            source: attribution.sessionId == nil ? .system : .chatUI,
            method: "POST",
            path: "/internal/embeddings",
            statusCode: error == nil ? 200 : 500,
            durationMs: durationMs,
            model: model,
            finishReason: error == nil ? .stop : .error,
            errorMessage: error,
            category: .embedding,
            locality: .local,
            egress: EgressInfo(details: details),
            agentId: attribution.agentId,
            agentName: attribution.agentName,
            sessionId: attribution.sessionId
        )
    }

    // MARK: - Media generation

    enum MediaKind: String, Sendable { case image, video }
    enum MediaOperation: String, Sendable { case generate, edit, upscale, quote }

    struct MediaJob: Sendable {
        let kind: MediaKind
        let operation: MediaOperation
        let model: String
        let prompt: String?
        let provider: String
        /// nil = generated on this Mac.
        let endpoint: String?
        let requestedCount: Int
        let size: String?
        let steps: Int?
        let durationSeconds: Double?
        let trigger: Trigger
        let attribution: InsightsService.ActivityAttribution
        var started = Date()

        /// Same job with the model resolved after creation (the native
        /// coordinator picks the default model after the row is opened).
        func withModel(_ resolved: String) -> MediaJob {
            var copy = MediaJob(
                kind: kind, operation: operation, model: resolved, prompt: prompt, provider: provider,
                endpoint: endpoint, requestedCount: requestedCount, size: size, steps: steps,
                durationSeconds: durationSeconds, trigger: trigger, attribution: attribution
            )
            copy.started = started
            return copy
        }

        func finish(producedCount: Int?, jobId: String? = nil, error: String?) {
            let durationMs = Date().timeIntervalSince(started) * 1000
            let host = EgressInfo.host(from: endpoint)
            let isRemote = host != nil
            var details: [String: String] = [
                "media_kind": kind.rawValue,
                "operation": operation.rawValue,
                "count": String(producedCount ?? requestedCount),
                "requested_count": String(requestedCount),
                "provider": provider,
                "trigger": trigger.rawValue,
            ]
            if let size, !size.isEmpty { details["size"] = size }
            if let steps { details["steps"] = String(steps) }
            if let durationSeconds, durationSeconds > 0 { details["duration_seconds"] = String(format: "%.0f", durationSeconds) }
            if let jobId, !jobId.isEmpty { details["job_id"] = jobId }
            if let prompt { details["prompt_chars"] = String(prompt.count) }
            let egress = isRemote
                ? EgressInfo(
                    destinationLabel: provider,
                    destinationHost: host,
                    bytesSent: prompt?.utf8.count,
                    dataClasses: ["media_prompt"],
                    details: details
                )
                : EgressInfo(details: details)
            InsightsService.logRequest(
                source: trigger == .chatTool ? .tool : .chatUI,
                method: "POST",
                path: isRemote ? "/v1/\(kind.rawValue)s/\(operation.rawValue)" : "/internal/\(kind.rawValue)_\(operation.rawValue)",
                statusCode: error == nil ? 200 : 500,
                durationMs: durationMs,
                requestBody: prompt,
                model: model,
                finishReason: error == nil ? .stop : .error,
                errorMessage: error,
                connection: isRemote
                    ? RequestConnectionInfo(remoteEndpoint: endpoint, transport: .direct, mode: .remoteInference)
                    : nil,
                category: .mediaGeneration,
                locality: isRemote ? .remote : .local,
                egress: egress,
                agentId: attribution.agentId,
                agentName: attribution.agentName,
                sessionId: attribution.sessionId
            )
        }
    }

    /// Returns nil when the caller is an HTTP API request (that handler logs
    /// its own row).
    nonisolated static func beginMedia(
        kind: MediaKind,
        operation: MediaOperation,
        model: String,
        prompt: String?,
        provider: String,
        endpoint: String?,
        requestedCount: Int,
        size: String? = nil,
        steps: Int? = nil,
        durationSeconds: Double? = nil,
        trigger: Trigger
    ) -> MediaJob? {
        guard !servingHTTPRequest() else { return nil }
        return MediaJob(
            kind: kind, operation: operation, model: model, prompt: prompt, provider: provider,
            endpoint: endpoint, requestedCount: requestedCount, size: size, steps: steps,
            durationSeconds: durationSeconds, trigger: trigger, attribution: .current()
        )
    }
}
