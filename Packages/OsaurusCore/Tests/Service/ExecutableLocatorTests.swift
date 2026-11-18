//
//  ExecutableLocatorTests.swift
//  osaurusTests
//
//  Home-directory caching for PATH resolution (APPLE-MACOS-3D9).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Executable locator")
struct ExecutableLocatorTests {

    @Test func homePathMatchesEnvironmentOrAccountHome() {
        let expected =
            ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ExecutableLocator.homePath == expected)
        #expect(!ExecutableLocator.homePath.isEmpty)
    }

    @Test func searchPathIncludesHomeFallbacks() {
        let home = ExecutableLocator.homePath
        let entries = ExecutableLocator.searchPath(env: ["PATH": "/usr/bin"], loginShellEntries: nil)
            .split(separator: ":").map(String.init)
        #expect(entries.first == "/usr/bin")
        #expect(entries.contains("\(home)/.local/bin"))
        #expect(entries.contains("\(home)/.volta/bin"))
    }

    @Test func expandUserPathUsesCachedHome() {
        let home = ExecutableLocator.homePath
        #expect(ExecutableLocator.expandUserPath("~") == home)
        #expect(ExecutableLocator.expandUserPath("~/bin/tool") == home + "/bin/tool")
        #expect(ExecutableLocator.expandUserPath("/abs/tool") == "/abs/tool")
    }
}
