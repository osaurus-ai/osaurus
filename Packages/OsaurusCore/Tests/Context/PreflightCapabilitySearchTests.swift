import Foundation
import Testing

@testable import OsaurusCore

struct PreflightCapabilitySearchTests {

    @Test func emptyQueryReturnsEmptyResult() async {
        let result = await PreflightCapabilitySearch.search(query: "")
        #expect(result.toolSpecs.isEmpty)
        #expect(result.contextSnippet.isEmpty)
    }

    @Test func whitespaceOnlyQueryReturnsEmptyResult() async {
        let result = await PreflightCapabilitySearch.search(query: "   \n  ")
        #expect(result.toolSpecs.isEmpty)
        #expect(result.contextSnippet.isEmpty)
    }

    @Test func nonsenseQueryReturnsGracefully() async {
        let result = await PreflightCapabilitySearch.search(
            query: "zzz_completely_nonexistent_capability_xyz_12345"
        )
        #expect(result.toolSpecs.isEmpty)
    }

    @Test func resultContainsNoDuplicateToolSpecs() async {
        let result = await PreflightCapabilitySearch.search(query: "deploy build test")
        let names = result.toolSpecs.map { $0.function.name }
        #expect(Set(names).count == names.count)
    }

    @Test func preflightToolSpecsHaveNoDuplicatesWithAlwaysLoaded() async {
        let alwaysLoaded = await MainActor.run {
            ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)
        }
        let alwaysNames = Set(alwaysLoaded.map { $0.function.name })

        let result = await PreflightCapabilitySearch.search(query: "search memory save method")
        let preflightNames = result.toolSpecs.map { $0.function.name }

        #expect(
            Set(preflightNames).count == preflightNames.count,
            "Pre-flight specs should not contain internal duplicates"
        )
    }

    // MARK: - PreflightSearchMode Tests

    @Test func offModeReturnsEmptyResult() async {
        let result = await PreflightCapabilitySearch.search(query: "deploy build test", mode: .off)
        #expect(result.toolSpecs.isEmpty)
        #expect(result.contextSnippet.isEmpty)
    }

    @Test func narrowModeReturnsNoDuplicates() async {
        let result = await PreflightCapabilitySearch.search(query: "deploy build test", mode: .narrow)
        let names = result.toolSpecs.map { $0.function.name }
        #expect(Set(names).count == names.count)
    }

    @Test func wideModeReturnsNoDuplicates() async {
        let result = await PreflightCapabilitySearch.search(query: "deploy build test", mode: .wide)
        let names = result.toolSpecs.map { $0.function.name }
        #expect(Set(names).count == names.count)
    }

    @Test func toolCapValuesAreCorrect() {
        #expect(PreflightSearchMode.off.toolCap == 0)
        #expect(PreflightSearchMode.narrow.toolCap == 3)
        #expect(PreflightSearchMode.balanced.toolCap == 8)
        #expect(PreflightSearchMode.wide.toolCap == 15)
    }
}
