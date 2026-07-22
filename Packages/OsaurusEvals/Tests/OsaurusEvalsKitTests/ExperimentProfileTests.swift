import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Locks the experiment-profile contract for the optimization harness:
/// decode + validation refusals (protected sections/tools, unknown ids,
/// bad names), composition-identity hashing, the resolved feature
/// vector, and the RunEnvironment/matrix provenance that keeps profiled
/// runs from silently reading as production results.
@Suite
struct ExperimentProfileTests {

    // MARK: - Decode + validation

    @Test func decodesFromJSONAndValidates() throws {
        let json = """
            {
              "name": "drop-code-style",
              "description": "price the codeStyle section",
              "dropSections": ["codeStyle"],
              "deferTools": ["file_search"]
            }
            """
        let profile = try JSONDecoder().decode(
            ExperimentProfile.self, from: Data(json.utf8)
        )
        #expect(profile.validationErrors().isEmpty)
        #expect(profile.experiment.dropSectionIds == ["codeStyle"])
        #expect(profile.experiment.deferToolNames == ["file_search"])
        #expect(!profile.isBaseline)
    }

    @Test func refusesProtectedSectionsAndTools() {
        let profile = ExperimentProfile(
            name: "bad",
            dropSections: ["grounding", "platform"],
            deferTools: ["capabilities_load"]
        )
        let errors = profile.validationErrors()
        #expect(errors.contains { $0.contains("protected section") && $0.contains("grounding") })
        #expect(errors.contains { $0.contains("protected section") && $0.contains("platform") })
        #expect(errors.contains { $0.contains("protected tool") && $0.contains("capabilities_load") })
    }

    @Test func refusesUnknownSectionIdsAndBadNames() {
        #expect(
            ExperimentProfile(name: "x", dropSections: ["notASection"])
                .validationErrors()
                .contains { $0.contains("unknown section id") }
        )
        #expect(
            ExperimentProfile(name: "  ").validationErrors()
                .contains { $0.contains("non-empty") }
        )
        #expect(
            ExperimentProfile(name: "two words").validationErrors()
                .contains { $0.contains("whitespace") }
        )
    }

    @Test func loadThrowsOnInvalidProfileFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-\(UUID().uuidString).json")
        try Data(#"{"name":"bad","dropSections":["grounding"]}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) {
            _ = try ExperimentProfile.load(from: url)
        }
    }

    // MARK: - Identity + feature vector

    @Test func hashTracksCompositionNotMetadata() {
        let a = ExperimentProfile(name: "a", description: "one", dropSections: ["codeStyle"])
        let b = ExperimentProfile(name: "b", description: "two", dropSections: ["codeStyle"])
        let c = ExperimentProfile(name: "c", dropSections: ["riskAware"])
        #expect(a.profileHash == b.profileHash)
        #expect(a.profileHash != c.profileHash)
        #expect(ExperimentProfile.baseline.isBaseline)
    }

    @Test func featureVectorIsCanonicalAndSorted() {
        let profile = ExperimentProfile(
            name: "combo",
            forceCompactPrompt: true,
            dropSections: ["riskAware", "codeStyle"],
            deferTools: ["file_search"]
        )
        #expect(
            profile.resolvedFeatureVector == [
                "compactPrompt=forced-on",
                "dropSection=codeStyle",
                "dropSection=riskAware",
                "deferTool=file_search",
            ]
        )
    }

    @Test func compactLoadedResultsAxisTracksInVectorHashAndExperiment() {
        let on = ExperimentProfile(name: "compact-loads", compactLoadedResults: true)
        let off = ExperimentProfile(name: "compact-loads")
        #expect(on.resolvedFeatureVector == ["compactLoadedResults=on"])
        #expect(on.profileHash != off.profileHash)
        #expect(on.experiment.compactLoadedResults == true)
        #expect(!on.isBaseline)
        #expect(off.isBaseline)
    }

    @Test func manifestReplacementProfileIsNowValid() {
        // The exact paginated capabilities_discover list mode replaced the
        // manifest-protection rule: dropping enabledManifest must validate
        // (the QUALITY gates decide promotability, not the validator).
        let profile = ExperimentProfile(
            name: "arch-manifest-replacement",
            dropSections: ["enabledManifest"]
        )
        #expect(profile.validationErrors().isEmpty)
    }

    // MARK: - Provenance

    @Test func environmentStampsProfileAndSummary() {
        let profile = ExperimentProfile(name: "drop-code-style", dropSections: ["codeStyle"])
        let env = RunEnvironment(runModel: "m").withExperiment(profile)
        #expect(env.experimentProfile == "drop-code-style")
        #expect(env.experimentProfileHash == profile.profileHash)
        #expect(env.experimentFeatures == ["dropSection=codeStyle"])
        #expect(env.summary.contains("profile=drop-code-style@\(profile.profileHash)"))
    }

    @Test func matrixWarnsOnMixedProfileColumns() {
        func column(_ model: String, env: RunEnvironment?) -> EvalMatrixModelColumn {
            EvalMatrixModelColumn(
                modelId: model,
                startedAt: "2026-07-20T00:00:00Z",
                perDomain: [:],
                totalPassed: 1,
                totalScored: 1,
                meanDecodeTokensPerSecond: nil,
                meanTtftMs: nil,
                peakPhysFootprintMb: nil,
                environment: env
            )
        }
        let profile = ExperimentProfile(name: "drop-code-style", dropSections: ["codeStyle"])
        let mixed = EvalMatrix(
            generatedAt: "2026-07-20T00:00:00Z",
            domains: [],
            models: [
                column("a", env: RunEnvironment(runModel: "a")),
                column("b", env: RunEnvironment(runModel: "b").withExperiment(profile)),
            ]
        )
        #expect(
            mixed.comparabilityWarnings.contains {
                $0.contains("experiment-profile column(s) mixed with production")
            }
        )

        // Same profile on every column → no profile warning.
        let uniform = EvalMatrix(
            generatedAt: "2026-07-20T00:00:00Z",
            domains: [],
            models: [
                column("a", env: RunEnvironment(runModel: "a").withExperiment(profile)),
                column("b", env: RunEnvironment(runModel: "b").withExperiment(profile)),
            ]
        )
        #expect(
            !uniform.comparabilityWarnings.contains { $0.contains("profile") }
        )
    }
}
