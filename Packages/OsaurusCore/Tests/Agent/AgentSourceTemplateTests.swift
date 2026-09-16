//
//  AgentSourceTemplateTests.swift
//  OsaurusCoreTests
//
//  `sourceTemplateName` is display provenance for agents made from a
//  template. It must survive the agent JSON round trip, load as nil for
//  agents written before the field existed, travel through the declarative
//  document as `source_template`, and follow the agent through Duplicate.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentSourceTemplateTests {

    @Test
    func roundTripsThroughAgentJSON_andDefaultsToNil() throws {
        var agent = AgentManager.newCustomAgentRecord(name: "Invoice Bot")
        agent.sourceTemplateName = "Cloud Agent"
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)
        #expect(decoded.sourceTemplateName == "Cloud Agent")

        // An agent persisted before the field existed decodes with nil.
        var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        json?["sourceTemplateName"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: json ?? [:])
        #expect(try JSONDecoder().decode(Agent.self, from: legacy).sourceTemplateName == nil)
    }

    @Test
    func duplicateCarriesTheOrigin() {
        var agent = AgentManager.newCustomAgentRecord(name: "Invoice Bot")
        agent.sourceTemplateName = "Cloud Agent"
        let copy = AgentManager.duplicateRecord(from: agent, name: "Invoice Bot Copy")
        #expect(copy.sourceTemplateName == "Cloud Agent")
        #expect(copy.id != agent.id)
    }

    @Test
    func declarativeDocument_carriesSourceTemplate() throws {
        let yaml = """
            version: 1
            agents:
              - name: Invoice Bot
                source_template: Cloud Agent
            """
        let document = try ConfigYAML.decode(yaml)
        #expect(document.agents?.first?.sourceTemplate == "Cloud Agent")
        let encoded = try ConfigYAML.encode(document)
        #expect(encoded.contains("source_template: Cloud Agent"))
    }
}
