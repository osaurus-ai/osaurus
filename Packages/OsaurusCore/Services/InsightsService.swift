//
//  InsightsService.swift
//  osaurus
//
//  In-memory request/response logging service for debugging and analytics.
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

    /// All logged requests (most recent first)
    @Published private(set) var logs: [RequestLog] = []

    /// Total request count (may exceed logs.count due to ring buffer)
    @Published private(set) var totalRequestCount: Int = 0

    /// Active filter for path/model search
    @Published var searchFilter: String = ""

    /// Active filter for source
    @Published var sourceFilter: SourceFilter = .all

    /// Active filter for HTTP method
    @Published var methodFilter: MethodFilter = .all

    // MARK: - Computed Properties

    /// Filtered logs based on current filter settings
    var filteredLogs: [RequestLog] {
        logs.filter { log in
            // Search filter (path or model)
            if !searchFilter.isEmpty {
                let searchLower = searchFilter.lowercased()
                let matchesPath = log.path.lowercased().contains(searchLower)
                let matchesModel = log.model?.lowercased().contains(searchLower) ?? false
                let matchesShortModel = log.shortModelName.lowercased().contains(searchLower)
                if !matchesPath && !matchesModel && !matchesShortModel {
                    return false
                }
            }

            // Source filter
            switch sourceFilter {
            case .all:
                break
            case .chatUI:
                if log.source != .chatUI { return false }
            case .httpAPI:
                if log.source != .httpAPI { return false }
            }

            // Method filter
            switch methodFilter {
            case .all:
                break
            case .get:
                if log.method != "GET" { return false }
            case .post:
                if log.method != "POST" { return false }
            }

            return true
        }
    }

    /// Summary statistics
    var stats: InsightsStats {
        let total = logs.count
        let successCount = logs.filter { $0.isSuccess }.count
        let successRate = total > 0 ? Double(successCount) / Double(total) * 100 : 0
        let errors = logs.filter { $0.isError }.count
        let avgDuration = logs.isEmpty ? 0 : logs.map(\.durationMs).reduce(0, +) / Double(logs.count)

        // Inference-specific stats (only from chat requests)
        let inferenceLogs = logs.filter { $0.isInference }
        let totalInputTokens = inferenceLogs.reduce(0) { $0 + ($1.inputTokens ?? 0) }
        let totalOutputTokens = inferenceLogs.reduce(0) { $0 + ($1.outputTokens ?? 0) }
        let avgSpeed: Double = {
            let speeds = inferenceLogs.compactMap { $0.tokensPerSecond }
            return speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        }()

        return InsightsStats(
            totalRequests: total,
            successRate: successRate,
            errorCount: errors,
            averageDurationMs: avgDuration,
            inferenceCount: inferenceLogs.count,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            averageSpeed: avgSpeed
        )
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Logging Methods

    /// Log a completed request
    func log(_ request: RequestLog) {
        // Insert at beginning (most recent first)
        logs.insert(request, at: 0)
        totalRequestCount += 1

        // Enforce ring buffer limit
        if logs.count > maxLogCount {
            logs.removeLast(logs.count - maxLogCount)
        }
    }

    /// Clear all logs
    func clear() {
        logs.removeAll()
        totalRequestCount = 0
    }

    /// Clear filters
    func clearFilters() {
        searchFilter = ""
        sourceFilter = .all
        methodFilter = .all
    }
}

// MARK: - Supporting Types

enum SourceFilter: String, CaseIterable {
    case all = "All"
    case chatUI = "Chat"
    case httpAPI = "HTTP"
}

enum MethodFilter: String, CaseIterable {
    case all = "All"
    case get = "GET"
    case post = "POST"
}

struct InsightsStats {
    let totalRequests: Int
    let successRate: Double
    let errorCount: Int
    let averageDurationMs: Double

    // Inference-specific stats
    let inferenceCount: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let averageSpeed: Double

    var formattedSuccessRate: String {
        String(format: "%.0f%%", successRate)
    }

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
    /// Thread-safe logging from non-main-actor contexts
    nonisolated static func logRequest(
        source: RequestSource,
        method: String,
        path: String,
        statusCode: Int,
        durationMs: Double,
        requestBody: String? = nil,
        responseBody: String? = nil,
        userAgent: String? = nil,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: RequestLog.FinishReason? = nil,
        errorMessage: String? = nil
    ) {
        Task { @MainActor in
            let log = RequestLog(
                source: source,
                method: method,
                path: path,
                statusCode: statusCode,
                durationMs: durationMs,
                requestBody: requestBody,
                responseBody: responseBody,
                userAgent: userAgent,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                temperature: temperature,
                maxTokens: maxTokens,
                toolCalls: toolCalls,
                finishReason: finishReason,
                errorMessage: errorMessage
            )
            shared.log(log)
        }
    }

    /// Legacy compatibility for ChatEngine inference logging
    nonisolated static func logInference(
        source: RequestSource,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        durationMs: Double,
        temperature: Float?,
        maxTokens: Int,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: RequestLog.FinishReason = .stop,
        errorMessage: String? = nil
    ) {
        logRequest(
            source: source,
            method: "POST",
            path: "/chat/completions",
            statusCode: errorMessage != nil ? 500 : 200,
            durationMs: durationMs,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            temperature: temperature,
            maxTokens: maxTokens,
            toolCalls: toolCalls,
            finishReason: finishReason,
            errorMessage: errorMessage
        )
    }

    /// Logs HTTP requests with optional inference data
    nonisolated static func logAsync(
        method: String,
        path: String,
        clientIP: String = "127.0.0.1",
        userAgent: String? = nil,
        requestBody: String? = nil,
        responseBody: String? = nil,
        responseStatus: Int,
        durationMs: Double,
        model: String? = nil,
        tokensInput: Int? = nil,
        tokensOutput: Int? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: RequestLog.FinishReason? = nil,
        errorMessage: String? = nil
    ) {
        let source: RequestSource = method == "CHAT" ? .chatUI : .httpAPI

        logRequest(
            source: source,
            method: method == "CHAT" ? "POST" : method,
            path: path,
            statusCode: responseStatus,
            durationMs: durationMs,
            requestBody: requestBody,
            responseBody: responseBody,
            userAgent: userAgent,
            model: model,
            inputTokens: tokensInput,
            outputTokens: tokensOutput,
            temperature: temperature,
            maxTokens: maxTokens,
            toolCalls: toolCalls,
            finishReason: finishReason,
            errorMessage: errorMessage
        )
    }
}
