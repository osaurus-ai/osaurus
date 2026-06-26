// Copyright 2026 Osaurus AI. All rights reserved.

import Foundation

/// Verdict vocabulary for runtime evidence rows.
///
/// The names intentionally mirror the project proof standard: a row is not
/// "green" just because a model loaded or one prompt returned text. Runtime
/// promotion has to distinguish proven behavior from partial, failed, and
/// still-unproven coverage.
public enum RuntimeProofVerdict: String, Codable, Sendable, Equatable, CaseIterable {
    case proven
    case partial
    case failed
    case unproven
}

/// Evidence dimensions that a runtime row may claim.
public enum RuntimeProofRequirement: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case visibleOutput
    case tokensPerSecond
    case noParserMarkerLeak
    case multiTurnCoherency
    case systemPromptInjection
    case ramFootprint
    case cancellation
    case cacheHit
    case mediaPayload
}

/// Cache topology determines what counts as real cache proof.
public enum RuntimeProofCacheTopology: String, Codable, Sendable, Equatable {
    case fullAttention
    case hybridSSM
    case zayaCCA
    case deepSeekHybridPool
    case rotating
    case unknown
}

/// Cache evidence captured from one runtime proof row.
public struct RuntimeProofCacheEvidence: Codable, Sendable, Equatable {
    public var topology: RuntimeProofCacheTopology
    public var kvLayerCount: Int?
    public var prefixHits: Int
    public var diskL2Hits: Int
    public var diskL2Stores: Int
    public var ssmCompanionHits: Int
    public var zayaCompanionHits: Int
    public var poolRestoreHits: Int
    public var turboQuantKVLayerCount: Int?

    public init(
        topology: RuntimeProofCacheTopology,
        kvLayerCount: Int? = nil,
        prefixHits: Int = 0,
        diskL2Hits: Int = 0,
        diskL2Stores: Int = 0,
        ssmCompanionHits: Int = 0,
        zayaCompanionHits: Int = 0,
        poolRestoreHits: Int = 0,
        turboQuantKVLayerCount: Int? = nil
    ) {
        self.topology = topology
        self.kvLayerCount = kvLayerCount
        self.prefixHits = prefixHits
        self.diskL2Hits = diskL2Hits
        self.diskL2Stores = diskL2Stores
        self.ssmCompanionHits = ssmCompanionHits
        self.zayaCompanionHits = zayaCompanionHits
        self.poolRestoreHits = poolRestoreHits
        self.turboQuantKVLayerCount = turboQuantKVLayerCount
    }

    var provesRequiredHit: Bool {
        switch topology {
        case .fullAttention:
            return (kvLayerCount ?? 0) > 0 && prefixHits > 0 && diskL2Hits > 0
        case .hybridSSM:
            return (kvLayerCount ?? 0) > 0 && diskL2Hits > 0 && ssmCompanionHits > 0
        case .zayaCCA:
            return diskL2Hits > 0 && zayaCompanionHits > 0
        case .deepSeekHybridPool:
            return diskL2Hits > 0 && poolRestoreHits > 0
        case .rotating:
            return diskL2Hits > 0 || diskL2Stores > 0
        case .unknown:
            return false
        }
    }
}

/// Media evidence for VLM/audio/video rows.
public struct RuntimeProofMediaEvidence: Codable, Sendable, Equatable {
    public var payloadKind: String
    public var payloadBytes: Int
    public var cacheSaltRecorded: Bool
    public var mediaCacheHitValidated: Bool
    public var routedThroughMediaPath: Bool

    public init(
        payloadKind: String,
        payloadBytes: Int,
        cacheSaltRecorded: Bool,
        mediaCacheHitValidated: Bool,
        routedThroughMediaPath: Bool
    ) {
        self.payloadKind = payloadKind
        self.payloadBytes = payloadBytes
        self.cacheSaltRecorded = cacheSaltRecorded
        self.mediaCacheHitValidated = mediaCacheHitValidated
        self.routedThroughMediaPath = routedThroughMediaPath
    }

    var provesMediaPath: Bool {
        !payloadKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && payloadBytes > 0
            && cacheSaltRecorded
            && mediaCacheHitValidated
            && routedThroughMediaPath
    }
}

/// Source-side evidence for system-prompt injection proof. A positive source
/// trace proves only that the configured prompt reached the composed static
/// prompt. Runtime proof still needs a live model probe on the row itself.
public struct RuntimeProofSystemPromptEvidence: Codable, Sendable, Equatable {
    public var sourceTracePassed: Bool
    public var matchingSectionIds: [String]
    public var staticPrefixContainsExpectedPrompt: Bool
    public var renderedPromptContainsExpectedPrompt: Bool

    public init(
        sourceTracePassed: Bool,
        matchingSectionIds: [String],
        staticPrefixContainsExpectedPrompt: Bool,
        renderedPromptContainsExpectedPrompt: Bool
    ) {
        self.sourceTracePassed = sourceTracePassed
        self.matchingSectionIds = matchingSectionIds
        self.staticPrefixContainsExpectedPrompt = staticPrefixContainsExpectedPrompt
        self.renderedPromptContainsExpectedPrompt = renderedPromptContainsExpectedPrompt
    }

    public init(trace: SystemPromptInjectionTrace) {
        self.init(
            sourceTracePassed: trace.passed,
            matchingSectionIds: trace.matchingSectionIds,
            staticPrefixContainsExpectedPrompt: trace.staticPrefixContainsExpectedPrompt,
            renderedPromptContainsExpectedPrompt: trace.renderedPromptContainsExpectedPrompt
        )
    }

    var personaSectionContainsExpectedPrompt: Bool {
        matchingSectionIds.contains(PromptSectionID.persona)
    }

    var provesSourceTrace: Bool {
        sourceTracePassed
            && personaSectionContainsExpectedPrompt
            && staticPrefixContainsExpectedPrompt
            && renderedPromptContainsExpectedPrompt
    }
}

/// One row of runtime proof evidence.
public struct RuntimeProofRow: Codable, Sendable, Equatable {
    public var modelId: String
    public var scenario: String
    public var verdict: RuntimeProofVerdict
    public var requirements: Set<RuntimeProofRequirement>
    public var artifactPaths: [String]
    public var visibleOutput: String?
    public var reasoningOutput: String?
    public var tokensPerSecond: Double?
    public var generationTokenCount: Int?
    public var finishReason: String?
    public var ramWithinLimit: Bool
    public var cancellationCleanedUp: Bool
    public var cacheEvidence: RuntimeProofCacheEvidence?
    public var mediaEvidence: RuntimeProofMediaEvidence?
    public var systemPromptEvidence: RuntimeProofSystemPromptEvidence?
    public var systemPromptProbePassed: Bool
    public var multiTurnCoherent: Bool
    public var parserMarkerLeaks: [String]

    public init(
        modelId: String,
        scenario: String,
        verdict: RuntimeProofVerdict,
        requirements: Set<RuntimeProofRequirement>,
        artifactPaths: [String] = [],
        visibleOutput: String? = nil,
        reasoningOutput: String? = nil,
        tokensPerSecond: Double? = nil,
        generationTokenCount: Int? = nil,
        finishReason: String? = nil,
        ramWithinLimit: Bool = false,
        cancellationCleanedUp: Bool = false,
        cacheEvidence: RuntimeProofCacheEvidence? = nil,
        mediaEvidence: RuntimeProofMediaEvidence? = nil,
        systemPromptEvidence: RuntimeProofSystemPromptEvidence? = nil,
        systemPromptProbePassed: Bool = false,
        multiTurnCoherent: Bool = false,
        parserMarkerLeaks: [String] = []
    ) {
        self.modelId = modelId
        self.scenario = scenario
        self.verdict = verdict
        self.requirements = requirements
        self.artifactPaths = artifactPaths
        self.visibleOutput = visibleOutput
        self.reasoningOutput = reasoningOutput
        self.tokensPerSecond = tokensPerSecond
        self.generationTokenCount = generationTokenCount
        self.finishReason = finishReason
        self.ramWithinLimit = ramWithinLimit
        self.cancellationCleanedUp = cancellationCleanedUp
        self.cacheEvidence = cacheEvidence
        self.mediaEvidence = mediaEvidence
        self.systemPromptEvidence = systemPromptEvidence
        self.systemPromptProbePassed = systemPromptProbePassed
        self.multiTurnCoherent = multiTurnCoherent
        self.parserMarkerLeaks = parserMarkerLeaks
    }
}

public enum RuntimeProofIssueSeverity: String, Codable, Sendable, Equatable {
    case blocker
    case warning
}

public struct RuntimeProofValidationIssue: Codable, Sendable, Equatable {
    public var severity: RuntimeProofIssueSeverity
    public var requirement: RuntimeProofRequirement?
    public var message: String

    public init(
        severity: RuntimeProofIssueSeverity,
        requirement: RuntimeProofRequirement?,
        message: String
    ) {
        self.severity = severity
        self.requirement = requirement
        self.message = message
    }
}

public struct RuntimeProofValidationResult: Codable, Sendable, Equatable {
    public var row: RuntimeProofRow
    public var issues: [RuntimeProofValidationIssue]

    public init(row: RuntimeProofRow, issues: [RuntimeProofValidationIssue]) {
        self.row = row
        self.issues = issues
    }

    public var blockers: [RuntimeProofValidationIssue] {
        issues.filter { $0.severity == .blocker }
    }

    public var isAcceptableForProvenClaim: Bool {
        row.verdict == .proven && blockers.isEmpty
    }
}

public enum RuntimeProofValidator {
    private static let knownParserMarkers = [
        "<|tool", "</|",
        "<tool_call", "</tool_call",
        "<think>", "</think>",
        "DSML", "xml_function",
        "\u{FFFE}tool:", "\u{FFFE}args:", "\u{FFFE}reasoning:",
    ]

    public static func validate(_ row: RuntimeProofRow) -> RuntimeProofValidationResult {
        var issues: [RuntimeProofValidationIssue] = []

        if row.verdict == .proven {
            appendProvenClaimIssues(row, into: &issues)
        }

        if row.requirements.contains(.noParserMarkerLeak) {
            let leaks = detectedParserLeaks(in: row)
            if !leaks.isEmpty {
                issues.append(
                    .init(
                        severity: .blocker,
                        requirement: .noParserMarkerLeak,
                        message:
                            "visible/runtime output contains parser marker leaks: \(leaks.sorted().joined(separator: ", "))"
                    )
                )
            }
        }

        if row.verdict == .failed, row.artifactPaths.isEmpty {
            issues.append(
                .init(
                    severity: .warning,
                    requirement: nil,
                    message: "failed rows should keep an artifact path so the failure remains inspectable"
                )
            )
        }

        return RuntimeProofValidationResult(row: row, issues: issues)
    }

    private static func appendProvenClaimIssues(
        _ row: RuntimeProofRow,
        into issues: inout [RuntimeProofValidationIssue]
    ) {
        if row.artifactPaths.isEmpty {
            issues.append(
                .init(
                    severity: .blocker,
                    requirement: nil,
                    message: "proven runtime rows require at least one artifact path"
                )
            )
        }

        for requirement in row.requirements {
            switch requirement {
            case .visibleOutput:
                if row.visibleOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(
                        blocker(.visibleOutput, "proven visible-output rows require non-empty visible output")
                    )
                }
            case .tokensPerSecond:
                if row.generationTokenCount ?? 1 > 0 {
                    guard let tps = row.tokensPerSecond, tps > 0 else {
                        issues.append(
                            blocker(.tokensPerSecond, "proven generation rows require token/s greater than zero")
                        )
                        break
                    }
                } else if row.tokensPerSecond == nil {
                    issues.append(
                        blocker(
                            .tokensPerSecond,
                            "zero-token tool rows must still record token/s as unavailable/zero, not leave it missing"
                        )
                    )
                }
            case .noParserMarkerLeak:
                break
            case .multiTurnCoherency:
                if !row.multiTurnCoherent {
                    issues.append(
                        blocker(.multiTurnCoherency, "proven multi-turn rows require coherent follow-up behavior")
                    )
                }
            case .systemPromptInjection:
                if row.systemPromptEvidence?.provesSourceTrace != true {
                    issues.append(
                        blocker(
                            .systemPromptInjection,
                            "proven system-prompt rows require source trace into the composed static prompt"
                        )
                    )
                }
                if !row.systemPromptProbePassed {
                    issues.append(
                        blocker(
                            .systemPromptInjection,
                            "proven system-prompt rows require a positive prompt-injection probe"
                        )
                    )
                }
            case .ramFootprint:
                if !row.ramWithinLimit {
                    issues.append(
                        blocker(
                            .ramFootprint,
                            "proven RAM rows require physical-footprint evidence within the intended gate"
                        )
                    )
                }
            case .cancellation:
                if !row.cancellationCleanedUp {
                    issues.append(
                        blocker(.cancellation, "proven cancellation rows require cleanup/no-zombie-load evidence")
                    )
                }
            case .cacheHit:
                if row.cacheEvidence?.provesRequiredHit != true {
                    issues.append(blocker(.cacheHit, "proven cache rows require topology-specific hit evidence"))
                }
            case .mediaPayload:
                if row.mediaEvidence?.provesMediaPath != true {
                    issues.append(
                        blocker(
                            .mediaPayload,
                            "proven media rows require real payload, cache salt, media-path routing, and cache-hit validation"
                        )
                    )
                }
            }
        }
    }

    private static func detectedParserLeaks(in row: RuntimeProofRow) -> Set<String> {
        let explicit = Set(row.parserMarkerLeaks.filter { !$0.isEmpty })
        let combined = [row.visibleOutput, row.reasoningOutput]
            .compactMap { $0 }
            .joined(separator: "\n")
        guard !combined.isEmpty else { return explicit }
        let implicit = knownParserMarkers.filter { marker in
            combined.localizedCaseInsensitiveContains(marker)
        }
        return explicit.union(implicit)
    }

    private static func blocker(
        _ requirement: RuntimeProofRequirement,
        _ message: String
    ) -> RuntimeProofValidationIssue {
        RuntimeProofValidationIssue(
            severity: .blocker,
            requirement: requirement,
            message: message
        )
    }
}
