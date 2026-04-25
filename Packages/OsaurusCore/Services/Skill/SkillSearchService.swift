//
//  SkillSearchService.swift
//  osaurus
//
//  Wraps VecturaKit for hybrid search over SKILL.md files.
//  Derived index — files on disk are the source of truth.
//

import CryptoKit
import Foundation
import VecturaKit
import os

public enum SkillSearchLogger {
    static let search = Logger(subsystem: "ai.osaurus", category: "skill.search")
}

public struct SkillSearchResult: Sendable {
    public let skill: Skill
    public let searchScore: Float

    public init(skill: Skill, searchScore: Float) {
        self.skill = skill
        self.searchScore = searchScore
    }
}

public actor SkillSearchService {
    public static let shared = SkillSearchService()

    private static let defaultSearchThreshold: Float = 0.30

    private var vectorDB: VecturaKit?
    private var isInitialized = false
    private var reverseIdMap: [String: UUID] = [:]

    private init() {}

    // MARK: - Initialization

    public func initialize() async {
        guard !isInitialized else { return }

        let storageDir = OsaurusPaths.skills().appendingPathComponent("vectura", isDirectory: true)

        for attempt in 1 ... 2 {
            do {
                OsaurusPaths.ensureExistsSilent(storageDir)

                let config = try VecturaConfig(
                    name: "osaurus-skills",
                    directoryURL: storageDir,
                    dimension: EmbeddingService.embeddingDimension,
                    searchOptions: VecturaConfig.SearchOptions(
                        defaultNumResults: 10,
                        minThreshold: 0.3,
                        hybridWeight: 0.7,
                        k1: 1.2,
                        b: 0.75
                    ),
                    memoryStrategy: .automatic()
                )

                vectorDB = try await VecturaKit(config: config, embedder: EmbeddingService.sharedEmbedder)
                isInitialized = true
                await rehydrateReverseIdMap()
                SkillSearchLogger.search.info("VecturaKit initialized successfully for skills")
                break
            } catch {
                if attempt == 1 {
                    SkillSearchLogger.search.warning(
                        "VecturaKit init failed for skills, deleting storage to recover: \(error)"
                    )
                    try? FileManager.default.removeItem(at: storageDir)
                } else {
                    SkillSearchLogger.search.error("VecturaKit init failed for skills (search unavailable): \(error)")
                    vectorDB = nil
                }
            }
        }
    }

    /// See `ToolSearchService.rehydrateReverseIdMap` for the rationale.
    /// Skills are loaded from `SkillManager.shared.skills` (which is
    /// populated from disk eagerly), so this is a cheap walk.
    private func rehydrateReverseIdMap() async {
        let allSkills = await MainActor.run { SkillManager.shared.skills }
        for skill in allSkills {
            _ = deterministicUUID(for: skill.id)
        }
        SkillSearchLogger.search.info("Skill reverse-id map rehydrated with \(allSkills.count) entries")
    }

    // MARK: - Indexing

    public func indexSkill(_ skill: Skill) async {
        guard let db = vectorDB else { return }
        do {
            let id = deterministicUUID(for: skill.id)
            let text = buildIndexText(for: skill)
            _ = try await db.addDocument(text: text, id: id)
        } catch {
            SkillSearchLogger.search.error("Failed to index skill \(skill.name): \(error)")
        }
    }

    public func removeSkill(id: UUID) async {
        guard let db = vectorDB else { return }
        do {
            let uuid = deterministicUUID(for: id)
            try await db.deleteDocuments(ids: [uuid])
            reverseIdMap.removeValue(forKey: uuid.uuidString)
        } catch {
            SkillSearchLogger.search.error("Failed to remove skill \(id) from index: \(error)")
        }
    }

    // MARK: - Search

    public func search(
        query: String,
        topK: Int = 10,
        threshold: Float? = nil
    ) async -> [SkillSearchResult] {
        guard topK > 0 else { return [] }
        guard let db = vectorDB else { return [] }
        do {
            let fetchCount = topK * 3
            let results = try await db.search(
                query: .text(query),
                numResults: fetchCount,
                threshold: threshold ?? Self.defaultSearchThreshold
            )

            let scoreMap = Dictionary(
                results.map { ($0.id.uuidString, Float($0.score)) },
                uniquingKeysWith: { first, _ in first }
            )

            let matchedSkillIds = results.compactMap { reverseIdMap[$0.id.uuidString] }
            guard !matchedSkillIds.isEmpty else { return [] }

            let allSkills = await MainActor.run { SkillManager.shared.skills }
            let skillById = Dictionary(allSkills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            return Array(
                matchedSkillIds.compactMap { skillId -> SkillSearchResult? in
                    guard let skill = skillById[skillId], skill.enabled else { return nil }
                    let uuid = deterministicUUID(for: skillId)
                    guard let score = scoreMap[uuid.uuidString] else { return nil }
                    return SkillSearchResult(skill: skill, searchScore: score)
                }
                .sorted { $0.searchScore > $1.searchScore }
                .prefix(topK)
            )
        } catch {
            SkillSearchLogger.search.error("Skill search failed: \(error)")
            return []
        }
    }

    // MARK: - Rebuild

    public func rebuildIndex() async {
        guard let db = vectorDB else { return }
        do {
            try await db.reset()
            reverseIdMap.removeAll()

            let allSkills = await MainActor.run { SkillManager.shared.skills }
            var texts: [String] = []
            var ids: [UUID] = []
            texts.reserveCapacity(allSkills.count)
            ids.reserveCapacity(allSkills.count)
            for skill in allSkills {
                let id = deterministicUUID(for: skill.id)
                texts.append(buildIndexText(for: skill))
                ids.append(id)
            }
            if !texts.isEmpty {
                _ = try await db.addDocuments(texts: texts, ids: ids)
            }
            SkillSearchLogger.search.info("Skill index rebuilt with \(allSkills.count) skills")
        } catch {
            SkillSearchLogger.search.error("Failed to rebuild skill index: \(error)")
        }
    }

    // MARK: - Helpers

    private func buildIndexText(for skill: Skill) -> String {
        if !skill.keywords.isEmpty {
            return "\(skill.name) \(skill.keywords.joined(separator: " "))"
        }
        return "\(skill.name) \(skill.description)"
    }

    private func deterministicUUID(for skillId: UUID) -> UUID {
        let hash = SHA256.hash(data: Data("skill:\(skillId.uuidString)".utf8))
        let bytes = Array(hash)
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        reverseIdMap[uuid.uuidString] = skillId
        return uuid
    }
}
