//
//  CodexClientVersionStoreTests.swift
//  osaurusTests
//
//  The Codex client version Osaurus publishes at osaurus.ai/clients/codex.json. A bad value breaks every ChatGPT
//  chat, so a published value is only ever a raise over the built-in version.
//
//  How it can fail, and the test for each:
//   1. A valid document is not adopted ............................. adoptsAValidPublishedVersion
//   2. Another format version, or garbage, is adopted ............... refusesADocumentItCannotRead
//   3. A version that is not plain x.y.z is adopted .................. refusesAVersionThatIsNotPlainSemver
//   4. A version below the built-in one, or of another major, is
//      adopted ...................................................... refusesBelowTheBuiltInOrAnotherMajor
//   5. Nothing fetched yet is not the built-in version .............. startsOnTheBuiltInVersion
//   6. The adopted value is lost on relaunch ........................ aNewStoreReadsTheLastGoodCopy
//   7. A failed or rejected read drops the last good value .......... aFailedReadKeepsTheLastGoodCopy
//   8. A cached value below a newer build's version is still used ... aCachedCopyBelowANewerBuiltInFallsBack
//   9. "Off" still reaches the network ............................. offNeverFetches
//  10. The background check reads on every listing, or never again
//      after a failure ............................................. backgroundCheckRunsDailyAndBacksOffAnHour
//  11. A request names a version other than the one in use ......... requestsNameTheActiveVersion
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Codex client version store")
struct CodexClientVersionStoreTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private final class Site: @unchecked Sendable {
        var body: String
        var fails = false
        var reads = 0
        init(_ body: String) { self.body = body }
    }

    private static func doc(_ version: String, format: Int = 1) -> String {
        #"{"version":\#(format),"client_version":"\#(version)","checked":"2026-11-18","source":"x"}"#
    }

    /// A version above the built-in one with the same major, so the tests hold whatever it is bumped to.
    private static func above(_ step: Int = 1) -> String {
        let p = CodexClientVersionStore.builtIn.split(separator: ".").map { Int($0)! }
        return "\(p[0]).\(p[1] + step).0"
    }

    private static func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-version-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(CodexClientVersionStore.fileName)
    }

    private static func store(_ file: URL, _ site: Site?, clock: Clock = Clock()) -> CodexClientVersionStore {
        CodexClientVersionStore(
            fileURL: file,
            fetch: site.map { site in
                { @Sendable _ in
                    site.reads += 1
                    if site.fails { throw URLError(.cannotFindHost) }
                    return Data(site.body.utf8)
                }
            },
            now: { clock.now }
        )
    }

    @Test func startsOnTheBuiltInVersion() {
        let current = Self.store(Self.folder(), Site(Self.doc(Self.above()))).current
        #expect(current.version == OpenAICodexOAuthService.codexClientVersion)
        #expect(current.source == .builtIn)
    }

    @Test func adoptsAValidPublishedVersion() async {
        let store = Self.store(Self.folder(), Site(Self.doc(Self.above())))
        let result = await store.refresh()
        #expect(result.outcome == .updated)
        #expect(store.version == Self.above())
        #expect(store.current.source == .published)
        #expect(store.current.checked == "2026-11-18")
        #expect(await store.refresh().outcome == .unchanged)
    }

    @Test(arguments: [
        "not json", "[1,2,3]", #"{"client_version":"9.9.9"}"#, #"{"version":"1","client_version":"0.999.0"}"#,
        #"{"version":true,"client_version":"0.999.0"}"#, #"{"version":2,"client_version":"0.999.0"}"#,
        #"{"version":1,"client_version":170}"#,
    ])
    func refusesADocumentItCannotRead(_ body: String) async {
        let store = Self.store(Self.folder(), Site(body))
        #expect(await store.refresh().outcome == .rejected)
        #expect(store.version == CodexClientVersionStore.builtIn)
    }

    @Test(arguments: ["0.999.0-alpha.1", "v0.999.0", "0.999", "0.999.0.1", " 0.999.0", ""])
    func refusesAVersionThatIsNotPlainSemver(_ version: String) async {
        let store = Self.store(Self.folder(), Site(Self.doc(version)))
        #expect(await store.refresh().outcome == .rejected)
        #expect(store.version == CodexClientVersionStore.builtIn)
    }

    @Test func refusesBelowTheBuiltInOrAnotherMajor() async {
        let major = Int(CodexClientVersionStore.builtIn.split(separator: ".")[0])!
        for version in ["0.1.0", "\(major + 1).0.0"] {
            let store = Self.store(Self.folder(), Site(Self.doc(version)))
            #expect(await store.refresh().outcome == .rejected, "\(version)")
            #expect(store.version == CodexClientVersionStore.builtIn)
        }
    }

    @Test func aNewStoreReadsTheLastGoodCopy() async {
        let file = Self.folder()
        await Self.store(file, Site(Self.doc(Self.above()))).refresh()
        let relaunched = Self.store(file, nil)
        #expect(relaunched.version == Self.above())
        #expect(relaunched.current.source == .published)
    }

    @Test func aFailedReadKeepsTheLastGoodCopy() async {
        let file = Self.folder()
        let site = Site(Self.doc(Self.above()))
        let store = Self.store(file, site)
        await store.refresh()
        site.fails = true
        #expect(await store.refresh().outcome == .unreachable)
        #expect(store.version == Self.above())
        site.fails = false
        site.body = Self.doc("0.1.0")
        #expect(await store.refresh().outcome == .rejected)
        #expect(store.version == Self.above())
    }

    @Test func aCachedCopyBelowANewerBuiltInFallsBack() throws {
        let file = Self.folder()
        try Data(#"{"client_version":"0.100.0","fetched_at":"2026-01-01T00:00:00Z"}"#.utf8).write(to: file)
        #expect(Self.store(file, nil).version == CodexClientVersionStore.builtIn)
        try Data("{{{".utf8).write(to: file)
        #expect(Self.store(file, nil).version == CodexClientVersionStore.builtIn)
    }

    @Test func offNeverFetches() async {
        let file = Self.folder()
        let store = Self.store(file, nil)
        #expect(await store.refresh().outcome == .off)
        #expect(store.refreshInBackgroundIfStale() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func backgroundCheckRunsDailyAndBacksOffAnHour() async {
        let clock = Clock()
        let site = Site(Self.doc(Self.above()))
        let store = Self.store(Self.folder(), site, clock: clock)

        _ = await store.refreshInBackgroundIfStale()?.value
        #expect(site.reads == 1)

        clock.now += 23 * 3600
        #expect(store.refreshInBackgroundIfStale() == nil)

        clock.now += 2 * 3600
        site.fails = true
        _ = await store.refreshInBackgroundIfStale()?.value
        #expect(site.reads == 2)
        #expect(store.version == Self.above())

        clock.now += 30 * 60
        #expect(store.refreshInBackgroundIfStale() == nil)

        clock.now += 31 * 60
        site.fails = false
        _ = await store.refreshInBackgroundIfStale()?.value
        #expect(site.reads == 3)
    }

    @Test func checkSentenceSaysWhatChanged() {
        typealias S = CodexClientVersionStore
        #expect(
            S.checkSentence(listRead: true, before: ["a"], after: ["gpt-9-nova", "a"], outcome: .updated, version: "0.171.0")
                == "Added gpt-9-nova.")
        #expect(
            S.checkSentence(listRead: true, before: ["a"], after: ["a"], outcome: .unchanged, version: "0.170.0")
                == "Up to date. No new models from ChatGPT.")
        #expect(
            S.checkSentence(listRead: true, before: ["a", "b"], after: ["a"], outcome: .unreachable, version: "0.170.0")
                == "Up to date. No new models from ChatGPT. No longer offered: b. Couldn't check osaurus.ai for a newer Codex version, so 0.170.0 was used.")
        #expect(
            S.checkSentence(listRead: false, before: ["a"], after: [], outcome: .unchanged, version: "0.170.0")
                == "ChatGPT's model list couldn't be read just now. Try again in a moment.")
    }

    @Test func requestsNameTheActiveVersion() {
        let active = OpenAICodexOAuthService.activeClientVersion
        #expect(OpenAICodexOAuthService.codexUserAgent().contains("/\(active) "))
        #expect(RemoteProviderService.codexResponsesLiteHeaders(sessionId: "s")["version"] == active)
        let components = URLComponents(
            url: OpenAICodexOAuthService.modelsCatalogURL(), resolvingAgainstBaseURL: false)
        #expect(components?.queryItems?.first { $0.name == "client_version" }?.value == active)
    }
}
