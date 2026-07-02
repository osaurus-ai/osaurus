import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Locks the cross-model scoreboard's comparability caveats: mixed catalog
/// hashes, columns with no catalog hash, and self-judged columns must all
/// surface as warnings in the markdown and console renderings so a recorded
/// SNAPSHOT can't silently mix incomparable columns.
@Suite
struct EvalMatrixTests {

    private func column(
        model: String,
        passed: Int = 5,
        scored: Int = 10,
        env: RunEnvironment? = nil
    ) -> EvalMatrixModelColumn {
        EvalMatrixModelColumn(
            modelId: model,
            startedAt: "2026-06-19T00:00:00Z",
            perDomain: ["agent_loop": .init(passed: passed, scored: scored, skipped: 0, errored: 0)],
            totalPassed: passed,
            totalScored: scored,
            meanDecodeTokensPerSecond: nil,
            meanTtftMs: nil,
            peakPhysFootprintMb: nil,
            environment: env
        )
    }

    private func matrix(_ columns: [EvalMatrixModelColumn]) -> EvalMatrix {
        EvalMatrix(generatedAt: "2026-06-19T00:00:00Z", domains: ["agent_loop"], models: columns)
    }

    private func env(catalog: String?, judge: String = "xai/grok-4.3") -> RunEnvironment {
        RunEnvironment(
            chip: "Apple M4 Pro",
            totalRamMb: 49152,
            runModel: "m",
            judge: judge,
            catalogHash: catalog,
            caseCount: catalog == nil ? nil : 10
        )
    }

    @Test func sameCatalogSameJudgeYieldsNoWarnings() {
        let m = matrix([
            column(model: "a", env: env(catalog: "cafe")),
            column(model: "b", env: env(catalog: "cafe")),
        ])
        #expect(m.comparabilityWarnings.isEmpty)
        #expect(!m.formatMarkdown().contains("## Comparability"))
    }

    @Test func mixedCatalogHashesWarn() {
        let m = matrix([
            column(model: "a", env: env(catalog: "aaaa")),
            column(model: "prefix/b", env: env(catalog: "bbbb")),
        ])
        let warnings = m.comparabilityWarnings
        #expect(warnings.contains { $0.contains("DIFFERENT case catalogs") })
        #expect(warnings.contains { $0.contains("a=aaaa") && $0.contains("b=bbbb") })
        let md = m.formatMarkdown()
        #expect(md.contains("## Comparability"))
        #expect(md.contains("DIFFERENT case catalogs"))
        #expect(m.formatConsole().contains("DIFFERENT case catalogs"))
    }

    @Test func missingCatalogHashWarnsOnlyAgainstHashedColumns() {
        let m = matrix([
            column(model: "a", env: env(catalog: "cafe")),
            column(model: "b", env: env(catalog: nil)),
        ])
        #expect(m.comparabilityWarnings.contains { $0.contains("no catalog hash for: b") })

        // All-unhashed (legacy reports) stays silent — nothing to compare against.
        let legacy = matrix([
            column(model: "a", env: env(catalog: nil)),
            column(model: "b", env: env(catalog: nil)),
        ])
        #expect(legacy.comparabilityWarnings.isEmpty)
    }

    @Test func selfJudgedColumnWarns() {
        let m = matrix([
            column(model: "a", env: env(catalog: "cafe")),
            column(model: "b", env: env(catalog: "cafe", judge: "self-judge")),
        ])
        let warnings = m.comparabilityWarnings
        #expect(warnings.contains { $0.contains("self-judged column(s): b") })
    }
}
