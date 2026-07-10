//
//  OnboardingModelsProxyTests.swift
//  OsaurusCoreTests
//
//  Signing message, request building, and response parsing for the
//  onboarding-only Osaurus model download proxy.
//

import Foundation
import Testing

@testable import OsaurusCore

struct OnboardingModelsProxyTests {
    private let base = URL(string: "https://models.example.com")!

    // MARK: - Auth message

    @Test func authMessage_bindsAddressMethodPathAndTimestamp() {
        let message = OnboardingModelsProxy.authMessage(
            address: "0xABCDef0123456789abcdef0123456789ABCDEF01",
            method: "get",
            pathAndQuery: "/v1/mlx-community/Qwen3-1.7B-4bit/resolve/main/model.safetensors?mode=json",
            timestamp: 1_717_171_717
        )
        #expect(
            message
                == "osaurus-models:0xabcdef0123456789abcdef0123456789abcdef01:GET:/v1/mlx-community/Qwen3-1.7B-4bit/resolve/main/model.safetensors?mode=json:1717171717"
        )
    }

    @Test func signHeaders_recoversToWalletAddress() throws {
        let pathAndQuery = "/v1/org/repo/resolve/main/config.json?mode=json"
        let timestamp = 1_717_171_717
        let headers = try OnboardingModelsProxy.signHeaders(
            method: "GET",
            pathAndQuery: pathAndQuery,
            timestamp: timestamp,
            privateKey: TestKeys.alicePrivateKey
        )
        #expect(headers.address == TestKeys.aliceAddress.lowercased())
        #expect(headers.nonce == nil)
        #expect(headers.values["x-wallet-nonce"] == nil)
        #expect(headers.values["x-wallet-address"] == TestKeys.aliceAddress.lowercased())
        #expect(headers.values["x-wallet-timestamp"] == String(timestamp))
        #expect(headers.values["x-wallet-signature"]?.hasPrefix("0x") == true)
    }

    // MARK: - Request URL

    @Test func resolveRequestURL_buildsV1ResolvePathWithJSONMode() {
        let url = OnboardingModelsProxy.resolveRequestURL(
            baseURL: base,
            repoId: "mlx-community/Qwen3-1.7B-4bit",
            revision: "main",
            path: "model.safetensors"
        )
        #expect(
            url?.absoluteString
                == "https://models.example.com/v1/mlx-community/Qwen3-1.7B-4bit/resolve/main/model.safetensors?mode=json"
        )
    }

    @Test func resolveRequestURL_acceptsNestedFilePaths() {
        let url = OnboardingModelsProxy.resolveRequestURL(
            baseURL: base,
            repoId: "org/repo",
            revision: "9217f5db79a29953eb74d5343926648285ec7e67",
            path: "sub/dir/tokenizer.json"
        )
        #expect(
            url?.absoluteString
                == "https://models.example.com/v1/org/repo/resolve/9217f5db79a29953eb74d5343926648285ec7e67/sub/dir/tokenizer.json?mode=json"
        )
    }

    @Test func resolveRequestURL_rejectsTraversalAndMalformedInputs() {
        #expect(
            OnboardingModelsProxy.resolveRequestURL(
                baseURL: base, repoId: "org/repo", revision: "main", path: "../secrets"
            ) == nil
        )
        #expect(
            OnboardingModelsProxy.resolveRequestURL(
                baseURL: base, repoId: "org/repo", revision: "", path: "config.json"
            ) == nil
        )
        #expect(
            OnboardingModelsProxy.resolveRequestURL(
                baseURL: base, repoId: "org/repo", revision: "main/extra", path: "config.json"
            ) == nil
        )
        #expect(
            OnboardingModelsProxy.resolveRequestURL(
                baseURL: base, repoId: "", revision: "main", path: "config.json"
            ) == nil
        )
    }

    // MARK: - Signed path

    @Test func pathAndQuery_isPercentEncodedWireForm() throws {
        let url = try #require(OnboardingModelsProxy.resolveRequestURL(
            baseURL: base,
            repoId: "org/repo",
            revision: "main",
            path: "model.gguf"
        ))
        #expect(
            OnboardingModelsProxy.pathAndQuery(for: url)
                == "/v1/org/repo/resolve/main/model.gguf?mode=json"
        )
    }

    // MARK: - Response parsing

    @Test func parseResolvePayload_readsPresignedURLPayload() {
        let json = Data(
            #"""
            {
              "url": "https://cdn-lfs.hf.co/repos/ab/model.gguf?X-Amz-Signature=abc",
              "etag": "\"74a4da8c9fdbcd15\"",
              "size": 491400032,
              "commit": "9217f5db79a29953eb74d5343926648285ec7e67"
            }
            """#.utf8
        )
        let resolved = OnboardingModelsProxy.parseResolvePayload(json)
        #expect(resolved?.url.host == "cdn-lfs.hf.co")
        #expect(resolved?.size == 491_400_032)
        #expect(resolved?.commit == "9217f5db79a29953eb74d5343926648285ec7e67")
    }

    @Test func parseResolvePayload_toleratesMissingOptionalFields() {
        let json = Data(#"{"url": "https://cdn-lfs.hf.co/x"}"#.utf8)
        let resolved = OnboardingModelsProxy.parseResolvePayload(json)
        #expect(resolved != nil)
        #expect(resolved?.etag == nil)
        #expect(resolved?.size == nil)
        #expect(resolved?.commit == nil)
    }

    @Test func parseResolvePayload_rejectsInlineFileBodies() {
        // Small non-LFS files come back as the file itself; a config.json has
        // no `url` key, so it must parse as nil and trigger the HF fallback.
        #expect(OnboardingModelsProxy.parseResolvePayload(Data(#"{"model_type": "qwen3"}"#.utf8)) == nil)
        #expect(OnboardingModelsProxy.parseResolvePayload(Data("not json".utf8)) == nil)
    }
}
