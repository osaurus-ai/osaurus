//
//  WorkflowShareTests.swift
//  OsaurusCoreTests
//
//  The share sheet's two lists, checked against what an exported template
//  actually carries, and when the "This one is working well" card shows.
//

import Foundation
import Testing

@testable import OsaurusCore

private let secretValue = "sk-live-9f2c8a7b6e5d4c3b2a1900ab"
private let urlToken = "a8f3c9d2e1b7465f9a0c3d2e1f"

/// A workflow that uses a key and a folder, with the key's value typed into
/// an example, a dialog's secret default, and an MCP server address.
private func credentialedTemplate() -> Template {
    var def = WorkflowDefinition(
        inputSchema: WF.object(["client": WF.string]),
        outputSchema: WF.object([:]),
        nodes: [
            WorkflowNode(
                id: "fetch", name: "Fetch",
                kind: .code(CodeSpec(source: "async function run(input, ctx) { return {} }", secrets: ["CLIO_API_KEY"])),
                input: .object([:])),
            WorkflowNode(
                id: "ask", name: "Ask",
                kind: .dialog(
                    DialogSpec(
                        title: "Sign in",
                        fields: [DialogField(key: "token", label: "Token", type: .secret, defaultValue: .string(secretValue))])),
                input: .object([:])),
        ],
        edges: [WorkflowEdge(from: "fetch", to: "ask")],
        output: .object([:]))
    def.secrets = [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")]
    def.folders = [FolderRequirement(key: "invoices", label: "Invoices")]
    def.examples = [
        WorkflowExample(
            name: "Acme", input: .object(["client": .string("Acme"), "CLIO_API_KEY": .string(secretValue)]))
    ]
    var template = WF.template(def, name: "Billing")
    template.serverHints = [
        MCPServerHint(name: "Tracker", url: "https://mcp.example.com/s/\(urlToken)/mcp?api_key=\(secretValue)")
    ]
    return template
}

private func exported(_ template: Template) throws -> String {
    try TemplateExportSanitizer.sanitized(template).jsonString()
}

struct WorkflowShareSummaryTests {

    @Test func listsTheStepsAndWhatItNeedsByName() {
        let summary = WorkflowShareSummary.make(credentialedTemplate(), includesExampleRuns: false)
        #expect(summary.shared.first == "The 2 steps it follows")
        #expect(summary.shared.contains("What it needs access to: Clio, Invoices"))
        #expect(WorkflowShareSummary.make(WF.template(WF.intake()), includesExampleRuns: false).shared == ["The 4 steps it follows"])
    }

    @Test func manyAccessNamesEndWithACount() {
        var def = WF.intake()
        def.folders = (1 ... 6).map { FolderRequirement(key: "f\($0)", label: "Folder \($0)") }
        let line = WorkflowShareSummary.make(WF.template(def), includesExampleRuns: false).shared.last
        #expect(line == "What it needs access to: Folder 1, Folder 2, Folder 3, Folder 4, and 2 more")
    }

    @Test func runHistoryStaysOnlyWithoutExampleRuns() {
        let without = WorkflowShareSummary.make(credentialedTemplate(), includesExampleRuns: false)
        #expect(without.staysOnMac == ["Your results and run history", "Your accounts and sign-ins"])
        let with = WorkflowShareSummary.make(credentialedTemplate(), includesExampleRuns: true)
        #expect(with.staysOnMac == ["Your accounts and sign-ins"])
    }

    @Test func neverClaimsFilesAndFoldersStay() {
        let lines = WorkflowShareSummary.make(credentialedTemplate(), includesExampleRuns: false).staysOnMac
        #expect(!lines.contains { $0.localizedCaseInsensitiveContains("folder") || $0.localizedCaseInsensitiveContains("file") })
    }

    /// "Your accounts and sign-ins": no key value, from an example, a
    /// dialog default, or a server address, reaches the exported file.
    @Test func exportedTemplateCarriesNoCredentialValues() throws {
        let json = try exported(credentialedTemplate())
        #expect(!json.contains(secretValue))
        #expect(!json.contains(urlToken))
        #expect(json.contains("CLIO_API_KEY"))
    }

    /// "Your results and run history": a template has no field for runs,
    /// outputs or install bindings, so none can be written.
    @Test func exportedTemplateHasNoRunsOrBindings() throws {
        let json = try exported(credentialedTemplate())
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let known: Set<String> = [
            "format", "format_version", "id", "kind", "version", "changelog", "name", "summary", "author",
            "created_at", "available_to_orchestrator", "requirements", "agent", "actions", "workflows", "workflow",
            "bundled", "content_hash", "mcp_server_hints",
        ]
        #expect(Set(object.keys).isSubset(of: known))
        for key in ["runs", "history", "results", "bindings", "saved_answers"] {
            #expect(!json.contains("\"\(key)\""))
        }
    }

    /// Folder paths under home travel as `~/…`, which is why the sheet
    /// does not say files and folders stay on this Mac.
    @Test func homeFolderPathsTravelInExamples() throws {
        var def = WF.intake()
        def.examples = [WorkflowExample(name: "Mine", input: .object(["client": .string(NSHomeDirectory() + "/Clients/Acme")]))]
        #expect(try exported(WF.template(def)).contains("~/Clients/Acme"))
    }
}

/// The share card is gone; its saved flag still round-trips for old records.
struct ShareNudgeFlagTests {
    @Test func dismissFlagRoundTripsAndIsNotExported() throws {
        var w = InstalledWorkflow(template: WF.template(WF.intake()), bindings: InstallBindings())
        w.shareNudgeDismissed = true
        let data = try JSONEncoder().encode(w)
        #expect(try JSONDecoder().decode(InstalledWorkflow.self, from: data).shareNudgeDismissed)
        #expect(!(try w.template.jsonString()).contains("share_nudge"))

        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "share_nudge_dismissed")
        let old = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(InstalledWorkflow.self, from: old).shareNudgeDismissed == false)
    }
}
