//
//  InsightsService.swift
//  osaurus
//
//  In-memory inference logging service for debugging and analytics.
//  Uses a ring buffer to limit memory usage.
//

import Combine
import Foundation

@MainActor
final class InsightsService: ObservableObject {
    static let shared = InsightsService()

    // MARK: - Configuration

    /// Maximum number of logs to retain in memory
    private let maxLogCount: Int = 500

    // MARK: - Published State

    /// All logged inferences (most recent first)
    @Published private(set) var logs: [InferenceLog] = []

    /// Total inference count (may exceed logs.count due to ring buffer)
    @Published private(set) var totalInferenceCount: Int = 0

    /// Active filter for model name
    @Published var modelFilter: String = ""

    /// Active filter for source
    @Published var sourceFilter: SourceFilter = .all

    // MARK: - Computed Properties

    /// Filtered logs based on current filter settings
    var filteredLogs: [InferenceLog] {
        logs.filter { log in
            // Model filter
            if !modelFilter.isEmpty {
                let searchLower = modelFilter.lowercased()
                if !log.model.lowercased().contains(searchLower)
                    && !log.shortModelName.lowercased().contains(searchLower)
                {
                    return false
                }
            }

            // Source filter
            switch sourceFilter {
            case .all:
                return true
            case .chatUI:
                return log.source == .chatUI
            case .httpAPI:
                return log.source == .httpAPI
            case .sdk:
                return log.source == .sdk
            }
        }
    }

    /// Summary statistics
    var stats: InsightsStats {
        let total = logs.count
        let totalInputTokens = logs.reduce(0) { $0 + $1.inputTokens }
        let totalOutputTokens = logs.reduce(0) { $0 + $1.outputTokens }
        let errors = logs.filter { $0.isError }.count
        let avgSpeed = logs.isEmpty ? 0 : logs.map(\.tokensPerSecond).reduce(0, +) / Double(logs.count)
        let avgDuration = logs.isEmpty ? 0 : logs.map(\.durationMs).reduce(0, +) / Double(logs.count)

        return InsightsStats(
            totalInferences: total,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            errorCount: errors,
            averageSpeed: avgSpeed,
            averageDurationMs: avgDuration
        )
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Logging Methods

    /// Log a completed inference
    func log(_ inference: InferenceLog) {
        // Insert at beginning (most recent first)
        logs.insert(inference, at: 0)
        totalInferenceCount += 1

        // Enforce ring buffer limit
        if logs.count > maxLogCount {
            logs.removeLast(logs.count - maxLogCount)
        }
    }

    /// Clear all logs
    func clear() {
        logs.removeAll()
        totalInferenceCount = 0
    }

    /// Clear filters
    func clearFilters() {
        modelFilter = ""
        sourceFilter = .all
    }
}

// MARK: - Supporting Types

enum SourceFilter: String, CaseIterable {
    case all = "All"
    case chatUI = "Chat UI"
    case httpAPI = "HTTP"
    case sdk = "SDK"
}

struct InsightsStats {
    let totalInferences: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let errorCount: Int
    let averageSpeed: Double
    let averageDurationMs: Double

    var formattedAvgSpeed: String {
        if averageSpeed > 0 {
            return String(format: "%.1f tok/s", averageSpeed)
        }
        return "-"
    }

    var formattedAvgDuration: String {
        if averageDurationMs < 1000 {
            return String(format: "%.0fms", averageDurationMs)
        } else {
            return String(format: "%.1fs", averageDurationMs / 1000)
        }
    }
}

// MARK: - Nonisolated Logging Interface

extension InsightsService {
    /// Thread-safe logging from non-main-actor contexts (e.g., ChatEngine)
    nonisolated static func logInference(
        source: InferenceSource,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        durationMs: Double,
        temperature: Float,
        maxTokens: Int,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: InferenceLog.FinishReason = .stop,
        errorMessage: String? = nil
    ) {
        Task { @MainActor in
            let log = InferenceLog(
                source: source,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                durationMs: durationMs,
                temperature: temperature,
                maxTokens: maxTokens,
                toolCalls: toolCalls,
                finishReason: finishReason,
                errorMessage: errorMessage
            )
            shared.log(log)
        }
    }

    // Legacy compatibility - will be removed after HTTPHandler cleanup
    nonisolated static func logAsync(
        method: String,
        path: String,
        clientIP: String = "127.0.0.1",
        userAgent: String? = nil,
        requestBody: String? = nil,
        responseStatus: Int,
        durationMs: Double,
        model: String? = nil,
        tokensInput: Int? = nil,
        tokensOutput: Int? = nil,
        toolCalls: [ToolCallLog]? = nil,
        errorMessage: String? = nil
    ) {
        // Only log inference-related requests
        guard path.contains("chat") || method == "CHAT" else { return }

        let source: InferenceSource = method == "CHAT" ? .chatUI : .httpAPI
        let finishReason: InferenceLog.FinishReason = errorMessage != nil ? .error : .stop

        logInference(
            source: source,
            model: model ?? "unknown",
            inputTokens: tokensInput ?? 0,
            outputTokens: tokensOutput ?? 0,
            durationMs: durationMs,
            temperature: 0.7,
            maxTokens: 1024,
            toolCalls: toolCalls,
            finishReason: finishReason,
            errorMessage: errorMessage
        )
    }
}
