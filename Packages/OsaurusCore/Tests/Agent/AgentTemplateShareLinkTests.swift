//
//  AgentTemplateShareLinkTests.swift
//  OsaurusCoreTests
//
//  A share link must round-trip a template byte-for-byte, stay within a
//  length chat clients keep intact, and fail loudly on anything else.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentTemplateShareLinkTests {

    private func sample() -> AgentTemplate {
        var entry = AgentEntry(name: "Invoice Bot")
        entry.systemPrompt = String(repeating: "You are a careful invoice assistant. ", count: 40)
        entry.model = .value("sonnet-5")
        var tools = AgentToolsEntry()
        tools.mode = "manual"
        tools.enabled = ["fetch", "time"]
        entry.tools = tools
        entry.workingFolder = .value("~/Documents/Invoices")
        return AgentTemplate(
            name: "Invoice Bot", agent: entry, summary: "Reads and files invoices",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            requires: [TemplateRequirement(kind: .workingFolder, value: "~/Documents/Invoices")])
    }

    @Test
    func roundTrip_preservesTheTemplate() throws {
        let template = sample()
        let url = try AgentTemplateShareLink.url(for: template)
        #expect(url.scheme == "osaurus")
        #expect(url.host == "templates-import")
        #expect(AgentTemplateShareLink.claims(url))
        #expect(url.absoluteString.count <= AgentTemplateShareLink.maxURLLength)
        let decoded = try AgentTemplateShareLink.template(from: url)
        #expect(decoded == template)
    }

    @Test
    func compressionKeepsLongPromptsWithinTheLimit() throws {
        // ~1.5 KB of prose; raw base64 JSON would be well over 2 KB.
        let url = try AgentTemplateShareLink.url(for: sample())
        #expect(url.absoluteString.count < 2000)
    }

    @Test
    func oversizeTemplate_isRefusedWithGuidance() {
        var entry = AgentEntry(name: "Huge")
        // Incompressible payload defeats zlib.
        entry.systemPrompt = (0..<12_000).map { _ in String(UInt32.random(in: 0x21...0x7E), radix: 36) }.joined()
        let template = AgentTemplate(name: "Huge", agent: entry)
        do {
            _ = try AgentTemplateShareLink.url(for: template)
            Issue.record("expected tooLarge")
        } catch let AgentTemplateShareLink.LinkError.tooLarge(length) {
            #expect(length > AgentTemplateShareLink.maxURLLength)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func foreignAndMalformedLinks_areRejected() {
        #expect(!AgentTemplateShareLink.claims(URL(string: "osaurus://settings?tab=agents")!))
        #expect(throws: AgentTemplateShareLink.LinkError.notAShareLink) {
            _ = try AgentTemplateShareLink.templateJSON(from: URL(string: "https://osaurus.ai/templates-import?t=abc")!)
        }
        #expect(throws: AgentTemplateShareLink.LinkError.malformedPayload) {
            _ = try AgentTemplateShareLink.templateJSON(from: URL(string: "osaurus://templates-import?t=not-zlib")!)
        }
        #expect(throws: AgentTemplateShareLink.LinkError.malformedPayload) {
            _ = try AgentTemplateShareLink.templateJSON(from: URL(string: "osaurus://templates-import")!)
        }
    }

    @Test
    func validLinkWithInvalidTemplate_reportsTheTemplateError() throws {
        let json = #"{"format": "osaurus.agent-template", "name": "X", "agent": {"name": "X", "bogus": 1}}"#
        let compressed = try (Data(json.utf8) as NSData).compressed(using: .zlib) as Data
        let url = URL(string: "osaurus://templates-import?t=\(PKCE.base64URLEncoded(compressed))")!
        do {
            _ = try AgentTemplateShareLink.template(from: url)
            Issue.record("expected invalidTemplate")
        } catch AgentTemplateShareLink.LinkError.invalidTemplate(let detail) {
            #expect(detail.contains("bogus"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
