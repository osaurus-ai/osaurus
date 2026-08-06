//
//  SandboxAlpinePackageTokensTests.swift
//  osaurusTests
//
//  Regression suite for the shared Alpine package-token contract used by
//  every root `apk add` path. These fixtures would fail open (accept
//  shell injection / option forms) before the hardening.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SandboxAlpinePackageTokensTests {

    // MARK: - Accepted Alpine atoms

    @Test func acceptsRealisticPackageNamesAndConstraints() {
        let accepted = [
            "curl",
            "ffmpeg",
            "python3",
            "py3-pip",
            "build-base",
            "g++",
            "libstdc++",
            "font-noto",
            "py3-numpy",
            "nodejs-current",
            // Subpackage-style names used in Alpine world files.
            "python3-dev",
            "openssl-dev",
            // Repository pins.
            "curl@edge",
            "ffmpeg@community",
            "python3@edge",
            // Version constraints apk accepts on `apk add`.
            "curl=8.5.0-r0",
            "ffmpeg>6.0",
            "python3>=3.11",
            "nodejs<21",
            "sqlite<=3.45",
            "curl~8.5",
            "curl@edge=8.5.0-r0",
            "python3@community>=3.12",
            // Epoch in version.
            "pkg=1:2.3.4-r0",
        ]
        for token in accepted {
            let result = SandboxAlpinePackageTokens.validate(token)
            guard case .success(let safe) = result else {
                Issue.record("expected accept for \(token), got \(result)")
                continue
            }
            #expect(safe == token)
        }
    }

    // MARK: - Rejected shell / option forms

    @Test func rejectsShellSyntaxAndOptionForms() {
        let rejected: [(String, SandboxAlpinePackageTokens.Rejection)] = [
            ("", .empty),
            ("   ", .whitespace),
            ("curl;id", .shellSyntax),
            ("curl|id", .shellSyntax),
            ("curl&id", .shellSyntax),
            ("curl`id`", .shellSyntax),
            ("curl$(id)", .shellSyntax),
            ("curl id", .whitespace),
            ("curl\tid", .whitespace),
            ("curl\nid", .whitespace),
            ("curl> /tmp/x", .whitespace),
            ("curl</etc/passwd", .shellSyntax),
            ("curl\"x", .shellSyntax),
            ("curl'x", .shellSyntax),
            ("curl\\x", .shellSyntax),
            ("--allow-untrusted", .leadingOption),
            ("-f", .leadingOption),
            ("-q", .leadingOption),
            ("!curl", .shellSyntax),
            ("curl; rm -rf /", .whitespace),
            ("$(reboot)", .shellSyntax),
            ("`reboot`", .shellSyntax),
            ("curl\0x", .whitespace),
            (String(repeating: "a", count: SandboxAlpinePackageTokens.maxTokenLength + 1), .tooLong),
            // Not a valid atom even without classic shell chars.
            ("@edge", .invalidGrammar),
            ("=1.0", .invalidGrammar),
            (".hidden", .invalidGrammar),
            ("curl==1", .invalidGrammar),
            ("curl=>1", .shellSyntax),
        ]

        for (token, expected) in rejected {
            let result = SandboxAlpinePackageTokens.validate(token)
            #expect(result == .failure(expected), "token=\(String(reflecting: token)) result=\(result)")
        }
    }

    @Test func validateAllFailsClosedOnFirstBadToken() {
        let result = SandboxAlpinePackageTokens.validateAll([
            "curl",
            "ffmpeg; id",
            "python3",
        ])
        #expect(result == .failure(.whitespace))
    }

    @Test func validateUniquePreservingOrderDedupes() throws {
        let unique = try SandboxAlpinePackageTokens.validateUniquePreservingOrder([
            "curl",
            "ffmpeg",
            "curl",
            "python3",
            "ffmpeg",
        ]).get()
        #expect(unique == ["curl", "ffmpeg", "python3"])
    }

    @Test func partitionForRepairSkipsUnsafeWithoutDroppingValid() {
        let (valid, rejected) = SandboxAlpinePackageTokens.partitionForRepair([
            "curl",
            "evil; id",
            "ffmpeg",
            "curl",  // dedupe
            "--force",
            "python3>=3.11",
        ])
        #expect(valid == ["curl", "ffmpeg", "python3>=3.11"])
        #expect(rejected.count == 2)
        #expect(rejected.map(\.token).contains("evil; id"))
        #expect(rejected.map(\.token).contains("--force"))
    }

    @Test func makeApkAddCommandReturnsNilWhenAllUnsafe() {
        let built = SandboxAlpinePackageTokens.makeApkAddCommand(
            fromUntrusted: ["curl; id", "--allow-untrusted", "x$(id)"]
        )
        #expect(built.command == nil)
        #expect(built.valid.isEmpty)
        #expect(built.rejected.count == 3)
    }

    @Test func makeApkAddCommandRendersSingleQuotedValidatedArgs() {
        let built = SandboxAlpinePackageTokens.makeApkAddCommand(
            fromUntrusted: ["ffmpeg", "curl", "ffmpeg", "python3>=3.11"]
        )
        // Deduped + sorted for repair batching.
        #expect(built.valid == ["curl", "ffmpeg", "python3>=3.11"])
        #expect(built.command == "apk add --no-cache 'curl' 'ffmpeg' 'python3>=3.11'")
        #expect(built.rejected.isEmpty)
    }

    @Test func renderShellArgumentsQuotesEachToken() {
        let rendered = SandboxAlpinePackageTokens.renderShellArguments([
            "curl",
            "ffmpeg@edge",
            "python3>=3.11",
        ])
        #expect(rendered == "'curl' 'ffmpeg@edge' 'python3>=3.11'")
    }

    // MARK: - Plugin dependency validation

    @Test func pluginValidateDependenciesRejectsInjection() {
        let plugin = SandboxPlugin(
            name: "Bad Deps",
            description: "legacy unsafe recipe",
            dependencies: ["curl", "ffmpeg; reboot", "python3"]
        )
        let errors = plugin.validateDependencies()
        #expect(errors.count == 1)
        #expect(errors[0].contains("ffmpeg; reboot"))
        #expect(errors[0].contains("shell"))
    }

    @Test func pluginValidateDependenciesAcceptsValidList() {
        let plugin = SandboxPlugin(
            name: "Good Deps",
            description: "normal recipe",
            dependencies: ["python3", "py3-pip", "curl@edge", "ffmpeg>=6"]
        )
        #expect(plugin.validateDependencies().isEmpty)
    }
}
