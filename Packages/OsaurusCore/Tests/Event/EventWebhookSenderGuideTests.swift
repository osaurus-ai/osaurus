//
//  EventWebhookSenderGuideTests.swift
//  osaurusTests
//
//  The "Try it" curl command on a webhook automation's detail: it must
//  send what `EventWebhookIngress` verifies, for every verification method.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct EventWebhookSenderGuideTests {
    private let url = "http://127.0.0.1:1337/events/tok"

    @Test func hmacCommandSignsTheBodyTheWayIngressVerifies() throws {
        let webhook = WebhookSourceConfig(token: "tok", verification: .hmacSHA256)
        let command = EventDetailView.curlCommand(url: url, webhook: webhook, secret: "s3cret")
        #expect(command.contains("SECRET='s3cret'"))
        #expect(command.contains(#"-H "X-Osaurus-Signature: sha256=$SIG""#))
        #expect(command.contains("curl -X POST '\(url)'"))

        // Run the command's own signing lines and compare with CryptoKit.
        let signingLines = command.split(separator: "\n").prefix(3).joined(separator: "\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", signingLines + "\nprintf '%s' \"$SIG\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let produced = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        let body = Data(#"{"text":"Hello from curl"}"#.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data("s3cret".utf8)))
        let expected = mac.map { String(format: "%02x", $0) }.joined()
        #expect(produced == expected)
    }

    @Test func customHeaderAndPrefixFlowIntoTheCommand() {
        let webhook = WebhookSourceConfig(
            token: "tok", verification: .hmacSHA256, signatureHeader: "X-Hub-Signature-256", signaturePrefix: "v1=")
        let command = EventDetailView.curlCommand(url: url, webhook: webhook, secret: nil)
        #expect(command.contains("SECRET='<secret>'"))
        #expect(command.contains(#"-H "X-Hub-Signature-256: v1=$SIG""#))
        #expect(EventDetailView.verificationExplanation(webhook).contains("X-Hub-Signature-256"))
    }

    @Test func sharedSecretCommandSendsTheSecretHeader() {
        let webhook = WebhookSourceConfig(token: "tok", verification: .sharedSecretHeader)
        let command = EventDetailView.curlCommand(url: url, webhook: webhook, secret: "abc")
        #expect(command.contains(#"-H "X-Osaurus-Event-Secret: $SECRET""#))
        #expect(!command.contains("openssl"))
    }

    @Test func urlOnlyCommandHasNoSecret() {
        let webhook = WebhookSourceConfig(token: "tok", verification: .none)
        let command = EventDetailView.curlCommand(url: url, webhook: webhook, secret: nil)
        #expect(!command.contains("SECRET"))
        #expect(command.hasPrefix("curl -X POST '\(url)'"))
    }
}
