//
//  RouterSpendGateTests.swift
//  osaurusTests
//
//  Pins the Osaurus Router credit-spend gate for HTTP-origin requests:
//  key-less loopback callers must not be able to route master-key-signed,
//  credit-billed requests through the Router unless the user explicitly
//  opted in. Keyed callers and app-internal sources are unaffected.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct RouterSpendGateTests {

    // MARK: - Pure policy

    @Test func blocksUnkeyedHTTPCallerWithoutOptIn() {
        let error = ChatEngine.routerSpendAuthorizationError(
            serviceIsOsaurusRouter: true,
            source: .httpAPI,
            callerHasVerifiedAccessKey: false,
            allowsUnkeyedLoopbackSpend: false
        )
        #expect(error != nil)
        #expect(error?.httpStatus == 403)
    }

    @Test func allowsKeyedHTTPCaller() {
        let error = ChatEngine.routerSpendAuthorizationError(
            serviceIsOsaurusRouter: true,
            source: .httpAPI,
            callerHasVerifiedAccessKey: true,
            allowsUnkeyedLoopbackSpend: false
        )
        #expect(error == nil)
    }

    @Test func allowsUnkeyedCallerWithExplicitOptIn() {
        let error = ChatEngine.routerSpendAuthorizationError(
            serviceIsOsaurusRouter: true,
            source: .httpAPI,
            callerHasVerifiedAccessKey: false,
            allowsUnkeyedLoopbackSpend: true
        )
        #expect(error == nil)
    }

    @Test func neverBlocksAppInternalSources() {
        for source in [RequestSource.chatUI, .plugin, .p2p] {
            let error = ChatEngine.routerSpendAuthorizationError(
                serviceIsOsaurusRouter: true,
                source: source,
                callerHasVerifiedAccessKey: false,
                allowsUnkeyedLoopbackSpend: false
            )
            #expect(error == nil, "source \(source) must not be gated")
        }
    }

    @Test func neverBlocksNonRouterServices() {
        let error = ChatEngine.routerSpendAuthorizationError(
            serviceIsOsaurusRouter: false,
            source: .httpAPI,
            callerHasVerifiedAccessKey: false,
            allowsUnkeyedLoopbackSpend: false
        )
        #expect(error == nil)
    }

    // MARK: - Engine wiring

    private func makeRouterService() -> RemoteProviderService {
        let provider = RemoteProvider(
            name: "Osaurus",
            host: "127.0.0.1",
            providerProtocol: .http,
            port: 1,  // Unroutable port: reaching the network at all is a bug.
            basePath: "",
            authType: .none,
            providerType: .osaurusRouter
        )
        return RemoteProviderService(
            provider: provider,
            models: ["anthropic/claude-opus"],
            resolvedHeaders: [:]
        )
    }

    private func makeRequest() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "osaurus/anthropic/claude-opus",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: nil,
            max_tokens: 8,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
    }

    /// Without a caller context (or with an unkeyed one) an `.httpAPI` engine
    /// must refuse to dispatch a router-bound stream before any network I/O.
    @Test func streamChatFailsClosedForUnkeyedHTTPOrigin() async {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: OsaurusRouter.allowUnkeyedLoopbackSpendDefaultsKey)
        defaults.removeObject(forKey: OsaurusRouter.allowUnkeyedLoopbackSpendDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: OsaurusRouter.allowUnkeyedLoopbackSpendDefaultsKey)
            }
        }

        let router = makeRouterService()
        let engine = ChatEngine(
            services: [],
            installedModelsProvider: { [] },
            remoteServicesProvider: { [router] },
            source: .httpAPI
        )

        await #expect(throws: ChatEngine.EngineError.self) {
            _ = try await engine.streamChat(request: makeRequest())
        }
        do {
            _ = try await engine.streamChat(request: makeRequest())
            Issue.record("expected routerSpendNotAuthorized")
        } catch let error as ChatEngine.EngineError {
            #expect(error.httpStatus == 403)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// A bound caller context with a verified key must pass the gate. The
    /// request then reaches the (unroutable) transport layer, so any failure
    /// there must NOT be the 403 spend refusal.
    @Test func streamChatPassesGateForKeyedHTTPOrigin() async {
        let router = makeRouterService()
        let engine = ChatEngine(
            services: [],
            installedModelsProvider: { [] },
            remoteServicesProvider: { [router] },
            source: .httpAPI
        )

        await HTTPCallerContext.$current.withValue(
            HTTPCallerContext(hasVerifiedAccessKey: true)
        ) {
            do {
                let stream = try await engine.streamChat(request: makeRequest())
                for try await _ in stream {}
            } catch let error as ChatEngine.EngineError {
                #expect(
                    error.httpStatus != 403,
                    "keyed caller must not hit the spend gate"
                )
            } catch {
                // Transport-level failure (connection refused) is expected;
                // the gate itself passed.
            }
        }
    }
}
