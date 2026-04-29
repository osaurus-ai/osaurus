//
//  CoreModelServiceFallbackTests.swift
//  OsaurusCoreTests
//
//  Pins the chat-model fallback contract added in response to GitHub
//  issue #823 (https://github.com/osaurus-ai/osaurus/issues/823).
//
//  Before the fix, `CoreModelService.generate` short-circuited with
//  `modelUnavailable("none")` whenever the user had no working core
//  model — typically a fresh install on macOS < 26 where the default
//  `coreModelName = "foundation"` can never route. Preflight tool
//  selection silently returned zero LLM picks for that turn, plugin
//  tools never reached the model's schema, and the only signal was a
//  buried `Pre-flight tool selection skipped: …` log line.
//
//  These tests pin the new behaviour:
//
//    * No configured core model + no fallback supplied → still throws
//      `modelUnavailable("none")` (legacy behaviour preserved for
//      callers that intentionally don't pass a fallback).
//    * No configured core model + fallback supplied → routes via the
//      fallback (verified by the thrown identifier).
//    * Configured core model that the router can't satisfy + fallback
//      supplied → falls back to the supplied model.
//    * Whitespace-only / empty fallback strings are treated as nil so
//      callers can pass `request.model` straight through.
//
//  We rely on the routing contract that an unknown model identifier
//  surfaces as `CoreModelError.modelUnavailable("<that identifier>")`
//  to verify *which* model the service actually attempted, without
//  needing a live MLX or remote service in the test process.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct CoreModelServiceFallbackTests {

    // MARK: - Test scaffolding

    /// One-shot scaffold that:
    ///   1. Locks the storage paths so concurrent tests can't collide
    ///      on `OsaurusPaths.overrideRoot` or
    ///      `AppConfiguration.shared.chatConfig`.
    ///   2. Snapshots the singleton chat config so concurrent suites
    ///      that read `ChatConfigurationStore.load()` see the ambient
    ///      config restored after this test finishes (the singleton's
    ///      in-memory cache is global state).
    ///   3. Redirects OsaurusPaths to a per-test temporary directory so
    ///      the chat config writes don't clobber the user's real config.
    ///   4. Stubs `AppConfiguration.shared.chatConfig` to the supplied
    ///      configuration so `ChatConfigurationStore.load()` returns it.
    ///   5. Resets the CoreModelService circuit breaker (state survives
    ///      across the actor singleton's lifetime, so a previous test
    ///      throwing repeatedly could otherwise lock subsequent tests
    ///      out with `circuitBreakerOpen`).
    ///   6. Runs `body` and tears everything back down — including
    ///      restoring the original singleton chat config so other
    ///      suites running in parallel see their expected state.
    private func withChatConfig<T: Sendable>(
        _ overrideConfig: ChatConfiguration,
        _ body: @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-coremodel-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            // Snapshot the singleton's current config BEFORE we redirect
            // OsaurusPaths so the in-memory snapshot is authoritative —
            // restoring from disk after teardown could read a missing
            // file under the temp root.
            let originalConfig = await MainActor.run {
                AppConfiguration.shared.chatConfig
            }

            await MainActor.run {
                OsaurusPaths.overrideRoot = root
                OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
                AppConfiguration.shared.updateChatConfig(overrideConfig)
            }
            await CoreModelService.shared.resetBreaker()

            do {
                let value = try await body()
                await MainActor.run {
                    // Restore the original singleton config FIRST — this
                    // calls `saveToDisk`, which writes to the (still-
                    // overridden) temp root. Then clear the override so
                    // the next legitimate save lands at the real config
                    // path. Without this ordering, concurrent test suites
                    // that read `ChatConfigurationStore.load()` see the
                    // overrideConfig from this test until they reload.
                    AppConfiguration.shared.updateChatConfig(originalConfig)
                    OsaurusPaths.overrideRoot = nil
                }
                try? FileManager.default.removeItem(at: root)
                return value
            } catch {
                await MainActor.run {
                    AppConfiguration.shared.updateChatConfig(originalConfig)
                    OsaurusPaths.overrideRoot = nil
                }
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }
    }

    /// Build a `ChatConfiguration` with `coreModelName` / `coreModelProvider`
    /// pinned to the supplied values (everything else from `default`). Used to
    /// drive `ChatConfigurationStore.load().coreModelIdentifier` to the exact
    /// state each test needs.
    @MainActor
    private static func config(
        coreModelName: String?,
        coreModelProvider: String? = nil
    ) -> ChatConfiguration {
        var cfg = ChatConfiguration.default
        cfg.coreModelName = coreModelName
        cfg.coreModelProvider = coreModelProvider
        return cfg
    }

    /// Distinguish "modelUnavailable for identifier X" from the
    /// generic `modelUnavailable("none")` so the assertion can pin
    /// *which* model the service actually attempted. The error's
    /// associated value is the model identifier the service tried to
    /// route, so this is the cleanest verification that fallback
    /// routing happened (vs being silently swallowed).
    private static func assertUnavailableMatches(
        _ error: Error,
        expected: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case CoreModelError.modelUnavailable(let actual) = error else {
            Issue.record(
                "Expected CoreModelError.modelUnavailable, got \(error)",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(actual == expected, sourceLocation: sourceLocation)
    }

    // MARK: - Path 1: no configured core model

    @Test
    func generate_withoutCoreModelOrFallback_throwsUnavailableNone() async throws {
        let cfg = await Self.config(coreModelName: nil)
        try await withChatConfig(cfg) {
            do {
                _ = try await CoreModelService.shared.generate(
                    prompt: "ping",
                    timeout: 1
                )
                Issue.record("Expected throw, got success")
            } catch {
                Self.assertUnavailableMatches(error, expected: "none")
            }
        }
    }

    @Test
    func generate_withoutCoreModelButWithFallback_routesViaFallback() async throws {
        // The fallback identifier is intentionally unroutable so the
        // router throws `modelUnavailable("test-fallback/no-such-model")`
        // — that identifier in the error proves the fallback was the
        // model actually attempted (vs the legacy "none" sentinel).
        let cfg = await Self.config(coreModelName: nil)
        try await withChatConfig(cfg) {
            do {
                _ = try await CoreModelService.shared.generate(
                    prompt: "ping",
                    timeout: 1,
                    fallbackModel: "test-fallback/no-such-model"
                )
                Issue.record("Expected throw, got success")
            } catch {
                Self.assertUnavailableMatches(
                    error,
                    expected: "test-fallback/no-such-model"
                )
            }
        }
    }

    @Test
    func generate_treatsWhitespaceFallbackAsNoFallback() async throws {
        let cfg = await Self.config(coreModelName: nil)
        try await withChatConfig(cfg) {
            do {
                _ = try await CoreModelService.shared.generate(
                    prompt: "ping",
                    timeout: 1,
                    fallbackModel: "   "
                )
                Issue.record("Expected throw, got success")
            } catch {
                // Empty / whitespace-only fallback must short-circuit
                // back to the "no-fallback" path so callers don't
                // need to pre-validate `request.model`.
                Self.assertUnavailableMatches(error, expected: "none")
            }
        }
    }

    @Test
    func generate_treatsEmptyFallbackAsNoFallback() async throws {
        let cfg = await Self.config(coreModelName: nil)
        try await withChatConfig(cfg) {
            do {
                _ = try await CoreModelService.shared.generate(
                    prompt: "ping",
                    timeout: 1,
                    fallbackModel: ""
                )
                Issue.record("Expected throw, got success")
            } catch {
                Self.assertUnavailableMatches(error, expected: "none")
            }
        }
    }

    // MARK: - Path 2: configured core model, fallback retry

    @Test
    func generate_unroutableConfiguredModelWithoutFallback_propagatesConfigured() async throws {
        let cfg = await Self.config(coreModelName: "test-configured/no-such-model")
        try await withChatConfig(cfg) {
            do {
                _ = try await CoreModelService.shared.generate(
                    prompt: "ping",
                    timeout: 1
                )
                Issue.record("Expected throw, got success")
            } catch {
                // Without a fallback, the configured model's failure
                // must propagate verbatim so users see *their* setting
                // in the log message, not a generic "none".
                Self.assertUnavailableMatches(
                    error,
                    expected: "test-configured/no-such-model"
                )
            }
        }
    }

    @Test
    func generate_unroutableConfiguredModelWithFallback_retriesViaFallback() async throws {
        let cfg = await Self.config(coreModelName: "test-configured/no-such-model")
        try await withChatConfig(cfg) {
            do {
                _ = try await CoreModelService.shared.generate(
                    prompt: "ping",
                    timeout: 1,
                    fallbackModel: "test-fallback/no-such-model"
                )
                Issue.record("Expected throw, got success")
            } catch {
                // The configured model fails first, then the fallback
                // is attempted and also fails — the second attempt's
                // identifier surfaces in the thrown error, which pins
                // that the fallback path actually ran.
                Self.assertUnavailableMatches(
                    error,
                    expected: "test-fallback/no-such-model"
                )
            }
        }
    }

    @Test
    func generate_doesNotFallBackWhenFallbackEqualsConfigured() async throws {
        // A caller that names the same identifier for fallback as the
        // configured core model is degenerate — fallback would just
        // re-attempt the same broken model. Verify we short-circuit
        // back to the original failure rather than running a useless
        // second attempt.
        let cfg = await Self.config(coreModelName: "test-same/model")
        try await withChatConfig(cfg) {
            do {
                _ = try await CoreModelService.shared.generate(
                    prompt: "ping",
                    timeout: 1,
                    fallbackModel: "test-same/model"
                )
                Issue.record("Expected throw, got success")
            } catch {
                Self.assertUnavailableMatches(error, expected: "test-same/model")
            }
        }
    }
}
