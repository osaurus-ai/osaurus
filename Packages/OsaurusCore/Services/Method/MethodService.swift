//
//  MethodService.swift
//  osaurus
//
//  Orchestrator for the methods subsystem: CRUD, scoring, YAML extraction.
//

import Foundation
import os

// MARK: - Errors

enum MethodServiceError: Error, LocalizedError, Equatable {
    case methodNotFound(String)

    var errorDescription: String? {
        switch self {
        case .methodNotFound(let id): return "Method not found: \(id)"
        }
    }
}

// MARK: - MethodService

public actor MethodService {
    public static let shared = MethodService()

    private let db = MethodDatabase.shared

    private init() {}

    // MARK: - CRUD

    public func create(
        name: String,
        description: String,
        triggerText: String? = nil,
        body: String,
        source: MethodSource,
        sourceModel: String? = nil
    ) async throws -> Method {
        let toolsUsed = extractToolIds(from: body)
        let skillsUsed = extractSkillIds(from: body)
        let tokenCount = TokenEstimator.estimate(body)

        let method = Method(
            name: name,
            description: description,
            triggerText: triggerText,
            body: body,
            source: source,
            sourceModel: sourceModel,
            toolsUsed: toolsUsed,
            skillsUsed: skillsUsed,
            tokenCount: tokenCount
        )

        try db.insertMethod(method)
        await MethodSearchService.shared.indexMethod(method)

        MethodLogger.service.info("Created method '\(name)' (id: \(method.id), tools: \(toolsUsed.count))")
        return method
    }

    public func update(_ method: Method) async throws {
        try db.updateMethod(method)
        await MethodSearchService.shared.indexMethod(method)
        MethodLogger.service.info("Updated method '\(method.name)' to v\(method.version)")
    }

    public func delete(id: String) async throws {
        try db.deleteMethod(id: id)
        await MethodSearchService.shared.removeMethod(id: id)
        MethodLogger.service.info("Deleted method \(id)")
    }

    public func load(id: String) throws -> Method? {
        try db.loadMethod(id: id)
    }

    public func loadScore(methodId: String) throws -> MethodScore? {
        try db.loadScore(methodId: methodId)
    }

    // MARK: - Scoring

    public func reportOutcome(
        methodId: String,
        outcome: MethodEventType,
        modelUsed: String? = nil,
        agentId: String? = nil,
        notes: String? = nil
    ) throws {
        let event = MethodEvent(
            methodId: methodId,
            eventType: outcome,
            modelUsed: modelUsed,
            agentId: agentId,
            notes: notes
        )
        try db.insertEvent(event)

        var score = try db.loadScore(methodId: methodId) ?? MethodScore(methodId: methodId)

        switch outcome {
        case .loaded:
            score.timesLoaded += 1
            score.lastUsedAt = Date()
        case .succeeded:
            score.timesSucceeded += 1
            score.lastUsedAt = Date()
        case .failed:
            score.timesFailed += 1
            score.lastUsedAt = Date()
        }

        score.recalculate()
        try db.upsertScore(score)
    }

    // MARK: - YAML Extraction

    func extractToolIds(from yaml: String) -> [String] {
        var tools: [String] = []
        var seen = Set<String>()
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("tool:") || trimmed.hasPrefix("- tool:") {
                let value =
                    trimmed
                    .replacingOccurrences(of: "- tool:", with: "")
                    .replacingOccurrences(of: "tool:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty, !seen.contains(value) {
                    tools.append(value)
                    seen.insert(value)
                }
            }
        }
        return tools
    }

    func extractSkillIds(from yaml: String) -> [String] {
        var skills: [String] = []
        var seen = Set<String>()
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("skill_context:") {
                let value =
                    trimmed
                    .replacingOccurrences(of: "skill_context:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty, !seen.contains(value) {
                    skills.append(value)
                    seen.insert(value)
                }
            }
        }
        return skills
    }

}
