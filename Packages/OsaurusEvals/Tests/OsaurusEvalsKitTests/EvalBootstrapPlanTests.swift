import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@Suite(.serialized)
struct EvalBootstrapPlanTests {
    @Test func pluginRequiredCapabilitySearchLoadsInstalledPluginsByDefault() {
        let suite = makeSuite(
            cases: [
                makeCase(
                    id: "capability_search.browser-prefix",
                    domain: "capability_search",
                    requirePlugins: ["osaurus.browser"]
                )
            ]
        )

        let plan = EvalBootstrapPlan.make(
            suite: suite,
            filter: "browser-prefix",
            preference: .automatic
        )

        // A selected case that requires an installed plugin auto-loads plugins
        // (which also brings up the search indices), so no extra index scope.
        #expect(plan == EvalBootstrapPlan(loadInstalledPlugins: true, initializeSearchIndices: false))
    }

    @Test func capabilitySearchInitializesIndicesWithoutPluginLoadingByDefault() {
        let suite = makeSuite(
            cases: [
                makeCase(
                    id: "capability_search.method-paraphrase",
                    domain: "capability_search",
                    expectedMethods: true
                )
            ]
        )

        let plan = EvalBootstrapPlan.make(
            suite: suite,
            filter: "method-paraphrase",
            preference: .automatic
        )

        #expect(
            plan
                == EvalBootstrapPlan(
                    loadInstalledPlugins: false,
                    searchIndexScope: EvalSearchIndexBootstrapScope(methods: true)
                )
        )
        #expect(plan.usesIsolatedSearchStorage)
    }

    @Test func capabilitySearchScopesIndexBootstrapToSelectedLanes() {
        let suite = makeSuite(
            cases: [
                makeCase(
                    id: "capability_search.skill-direct-name",
                    domain: "capability_search",
                    expectedSkills: true,
                    enableSkills: ["Research Analyst"]
                )
            ]
        )

        let plan = EvalBootstrapPlan.make(
            suite: suite,
            filter: "skill-direct-name",
            preference: .automatic
        )

        #expect(
            plan
                == EvalBootstrapPlan(
                    loadInstalledPlugins: false,
                    searchIndexScope: EvalSearchIndexBootstrapScope(skills: true)
                )
        )
    }

    @Test func pureDataSuitesSkipStartupBootstrap() {
        let suite = makeSuite(cases: [makeCase(id: "schema.minimum-bound", domain: "schema")])

        let plan = EvalBootstrapPlan.make(suite: suite, filter: nil, preference: .automatic)

        #expect(plan == EvalBootstrapPlan(loadInstalledPlugins: false, initializeSearchIndices: false))
        #expect(!plan.requiresWork)
    }

    @Test func filterControlsAutomaticBootstrapPlan() {
        let suite = makeSuite(
            cases: [
                makeCase(
                    id: "capability_search.browser-prefix",
                    domain: "capability_search",
                    requirePlugins: ["osaurus.browser"]
                ),
                makeCase(id: "schema.minimum-bound", domain: "schema"),
            ]
        )

        let plan = EvalBootstrapPlan.make(
            suite: suite,
            filter: "minimum-bound",
            preference: .automatic
        )

        #expect(plan == EvalBootstrapPlan(loadInstalledPlugins: false, initializeSearchIndices: false))
    }

    @Test func explicitPluginPreferencesOverrideDomainDefault() {
        let suite = makeSuite(cases: [makeCase(id: "capability_search.browser-prefix", domain: "capability_search")])

        let forced = EvalBootstrapPlan.make(suite: suite, filter: nil, preference: .force)
        let disabled = EvalBootstrapPlan.make(
            suite: makeSuite(
                cases: [
                    makeCase(
                        id: "capability_search.method-paraphrase",
                        domain: "capability_search",
                        expectedMethods: true
                    )
                ]
            ),
            filter: nil,
            preference: .disabled
        )

        #expect(forced == EvalBootstrapPlan(loadInstalledPlugins: true, initializeSearchIndices: false))
        #expect(
            disabled
                == EvalBootstrapPlan(
                    loadInstalledPlugins: false,
                    searchIndexScope: EvalSearchIndexBootstrapScope(methods: true)
                )
        )
    }

    @MainActor
    @Test func isolatedSearchStorageOverridesOsaurusRoot() {
        let previousRoot = OsaurusPaths.overrideRoot
        var isolatedRoot: URL?
        defer {
            OsaurusPaths.overrideRoot = previousRoot
            StorageKeyManager.shared.wipeCache()
            if let isolatedRoot {
                try? FileManager.default.removeItem(at: isolatedRoot)
            }
        }

        let root = EvalBootstrap.configureIsolatedSearchStorageIfNeeded(
            for: EvalBootstrapPlan(
                loadInstalledPlugins: false,
                searchIndexScope: EvalSearchIndexBootstrapScope(methods: true)
            )
        )
        isolatedRoot = root

        #expect(root != nil)
        #expect(OsaurusPaths.overrideRoot == root)
        #expect(root?.lastPathComponent.hasPrefix("osaurus-evals-") == true)

        if let root {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    @MainActor
    @Test func nonIsolatedBootstrapDoesNotReplaceExistingRootOverride() {
        let previousRoot = OsaurusPaths.overrideRoot
        let existingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-evals-existing-\(UUID().uuidString)", isDirectory: true)
        OsaurusPaths.overrideRoot = existingRoot
        defer {
            OsaurusPaths.overrideRoot = previousRoot
        }

        let root = EvalBootstrap.configureIsolatedSearchStorageIfNeeded(
            for: EvalBootstrapPlan(loadInstalledPlugins: true, initializeSearchIndices: false)
        )

        #expect(root == nil)
        #expect(OsaurusPaths.overrideRoot == existingRoot)
    }

    private func makeSuite(cases: [EvalCase]) -> EvalSuite {
        EvalSuite(
            directory: URL(fileURLWithPath: "/tmp/Evals", isDirectory: true),
            cases: cases,
            decodeFailures: []
        )
    }

    private func makeCase(
        id: String,
        domain: String,
        requirePlugins: [String]? = nil,
        expectedTools: Bool = false,
        expectedMethods: Bool = false,
        expectedSkills: Bool = false,
        seedMethods: [EvalCase.SeedMethod]? = nil,
        enableSkills: [String]? = nil
    ) -> EvalCase {
        let anyOf = EvalCase.CapabilitySearchExpectations.AnyOfMatcher(
            anyOf: [],
            minMatches: 0
        )
        let capabilitySearch =
            expectedTools || expectedMethods || expectedSkills
            ? EvalCase.CapabilitySearchExpectations(
                expectedTools: expectedTools ? anyOf : nil,
                expectedMethods: expectedMethods ? anyOf : nil,
                expectedSkills: expectedSkills ? anyOf : nil
            )
            : nil

        return EvalCase(
            id: id,
            domain: domain,
            query: "query",
            fixtures: .init(
                requirePlugins: requirePlugins,
                seedMethods: seedMethods,
                enableSkills: enableSkills
            ),
            expect: .init(capabilitySearch: capabilitySearch)
        )
    }
}
