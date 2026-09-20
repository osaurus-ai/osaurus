//
//  AppleAppCatalogTests.swift
//  OsaurusCoreTests — AppleApps
//
//  The `AppleApp` enum is the single gate list: the composer strips by it,
//  the registry excludes it from the Orchestrator, the migration maps into
//  it, and the declarative config validates against it. These tests pin
//  the invariants that keep those four consumers in sync, plus the schema
//  stability of every built-in Apple tool (byte-stable, template-renderable).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("AppleApp catalog")
struct AppleAppCatalogTests {

    @Test("every declared tool name has exactly one registered tool, and vice versa")
    func catalogMatchesDeclaredNames() {
        let tools = AppleAppToolCatalog.makeTools()
        let (undeclared, missing) = AppleAppToolCatalog.undeclaredOrMissingNames(in: tools)
        #expect(undeclared.isEmpty, "tools not declared on any AppleApp: \(undeclared.sorted())")
        #expect(missing.isEmpty, "declared names with no tool: \(missing.sorted())")
        let names = tools.map(\.name)
        #expect(Set(names).count == names.count, "duplicate Apple tool names")
    }

    @Test("tool names are app-prefixed and no app claims another app's tool")
    func namesArePrefixedAndDisjoint() {
        for app in AppleApp.allCases {
            for name in app.toolNames {
                #expect(AppleApp.app(forTool: name) == app, "\(name) resolves to the wrong app")
                let prefixes: [String]
                switch app {
                case .maps: prefixes = ["maps_", "location_"]
                default: prefixes = ["\(app.rawValue)_"]
                }
                #expect(prefixes.contains { name.hasPrefix($0) }, "\(name) lacks the \(app.rawValue) prefix")
            }
        }
        #expect(AppleApp.app(forTool: "web_search") == nil)
        #expect(AppleApp.allToolNames.count == AppleApp.allCases.reduce(0) { $0 + $1.toolNames.count })
    }

    @Test("toolNames(for:) and disabledToolNames(enabled:) partition the full set")
    func enabledDisabledPartition() {
        let enabled: Set<AppleApp> = [.calendar, .mail]
        let on = AppleApp.toolNames(for: enabled)
        let off = AppleApp.disabledToolNames(enabled: enabled)
        #expect(on.isDisjoint(with: off))
        #expect(on.union(off) == AppleApp.allToolNames)
        #expect(on.contains("calendar_events") && on.contains("mail_list"))
        #expect(off.contains("reminders_fetch") && off.contains("messages_send"))
        #expect(AppleApp.disabledToolNames(enabled: []) == AppleApp.allToolNames)
        #expect(AppleApp.disabledToolNames(enabled: Set(AppleApp.allCases)).isEmpty)
    }

    @Test("parse accepts raw names case-insensitively plus the common aliases")
    func parseAliases() {
        #expect(AppleApp.parse("calendar") == .calendar)
        #expect(AppleApp.parse(" Reminders ") == .reminders)
        #expect(AppleApp.parse("location") == .maps)
        #expect(AppleApp.parse("Maps & Location") == .maps)
        #expect(AppleApp.parse("iMessage") == .messages)
        #expect(AppleApp.parse("Apple Music") == .music)
        #expect(AppleApp.parse("safari") == nil)
        #expect(AppleApp.parse("") == nil)
    }

    @Test("sorted() follows allCases order")
    func sortedOrder() {
        #expect(AppleApp.sorted([.shortcuts, .calendar, .mail]) == [.calendar, .mail, .shortcuts])
    }

    @Test("legacy plugin tool names map onto real native tools of the owning app")
    func legacyMappingIsValid() {
        for (legacy, mapping) in AppleApp.legacyPluginToolNames {
            #expect(mapping.app.toolNames.contains(mapping.native), "\(legacy) → \(mapping.native) is not a \(mapping.app.rawValue) tool")
            #expect(!AppleApp.allToolNames.contains(legacy), "legacy name \(legacy) collides with a native name")
        }
        // The mail/messages `search_messages` collision resolves to mail.
        #expect(AppleApp.legacyPluginToolNames["search_messages"]?.app == .mail)
    }

    @Test("superseded plugin ids cover the eight shipped Apple plugins only")
    func supersededIds() {
        let ids = Set(AppleApp.allCases.compactMap(\.supersededPluginId))
        #expect(
            ids == [
                "osaurus.calendar", "osaurus.reminders", "osaurus.contacts", "osaurus.notes",
                "osaurus.mail", "osaurus.messages", "osaurus.maps", "osaurus.music",
            ])
        #expect(AppleApp.weather.supersededPluginId == nil)
        #expect(AppleApp.shortcuts.supersededPluginId == nil)
    }

    @Test("every Apple tool is a PermissionedTool whose requirements are the app's permissions")
    func permissionedContract() {
        for tool in AppleAppToolCatalog.makeTools() {
            guard let apple = tool as? AppleToolBase else {
                Issue.record("\(tool.name) is not an AppleToolBase")
                continue
            }
            let appPerms = Set(apple.app.systemPermissions.map(\.rawValue))
            #expect(Set(apple.requirements).isSubset(of: appPerms), "\(tool.name) requires permissions outside its app")
            let expectedPolicy: ToolPermissionPolicy = apple.isWrite ? .ask : .auto
            #expect(apple.defaultPermissionPolicy == expectedPolicy, "\(tool.name) policy")
        }
        // Deletes are per-call approvals.
        let deletes = AppleAppToolCatalog.makeTools().filter { $0.name.hasSuffix("_delete") || $0.name.hasSuffix("_delete_event") }
        #expect(!deletes.isEmpty)
        for tool in deletes {
            #expect(tool is PerCallApprovalTool, "\(tool.name) must require per-call approval")
        }
    }

    @Test("Apple tool schemas are byte-stable and template-renderable")
    func schemaStability() throws {
        func payload() throws -> Data {
            var joined = Data()
            for tool in AppleAppToolCatalog.makeTools() {
                let spec = Tool(type: "function", function: ToolFunction(name: tool.name, description: tool.description, parameters: tool.parameters))
                joined.append(try JSONSerialization.data(withJSONObject: spec.toTokenizerToolSpec(), options: [.sortedKeys]))
                joined.append(0x1F)
            }
            return joined
        }
        #expect(try payload() == payload())

        // Every `type` in schema positions is a plain string; every property
        // has a description (the model relies on them for date contracts).
        var failures: [String] = []
        func walk(_ value: Any, path: String) {
            if let dict = value as? [String: Any] {
                if !path.hasSuffix(".properties"), let type = dict["type"], !(type is String) {
                    failures.append("\(path).type=\(type)")
                }
                if path.contains(".properties."), !path.hasSuffix(".items"), dict["description"] == nil, dict["type"] != nil {
                    failures.append("\(path) has no description")
                }
                for (key, child) in dict { walk(child, path: path + "." + key) }
            } else if let array = value as? [Any] {
                for (i, child) in array.enumerated() { walk(child, path: "\(path)[\(i)]") }
            }
        }
        for tool in AppleAppToolCatalog.makeTools() {
            guard let params = tool.parameters else {
                failures.append("\(tool.name) has no parameters object")
                continue
            }
            let data = try JSONEncoder().encode(params)
            let obj = try JSONSerialization.jsonObject(with: data)
            walk(obj, path: tool.name)
            #expect(!tool.description.isEmpty, "\(tool.name) has an empty description")
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    @Test("date parameters repeat the date contract in their description")
    func dateParametersCarryContract() throws {
        var checked = 0
        for tool in AppleAppToolCatalog.makeTools() {
            guard let params = tool.parameters else { continue }
            let data = try JSONEncoder().encode(params)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let props = obj?["properties"] as? [String: Any] ?? [:]
            for (key, raw) in props {
                guard let prop = raw as? [String: Any], let description = prop["description"] as? String else { continue }
                let looksLikeDate = ["start", "end", "since", "due", "due_date", "occurrence_start", "end_date", "before", "after", "departure", "arrival"].contains(key)
                    || key.hasSuffix("_date") || key.hasSuffix("_at")
                if looksLikeDate, prop["type"] as? String == "string" {
                    checked += 1
                    #expect(description.contains("ISO 8601") || description.contains("yyyy-MM-dd"), "\(tool.name).\(key) lacks the date contract")
                }
            }
        }
        #expect(checked > 0)
    }
}

@Suite("AppleApp registry gating")
@MainActor
struct AppleAppRegistryGatingTests {

    @Test("the Orchestrator never carries Apple tools; the registry does")
    func orchestratorExclusion() {
        for name in AppleApp.allToolNames {
            #expect(ToolRegistry.orchestratorExcludedToolNames.contains(name), "\(name) is missing from orchestratorExcludedToolNames")
            #expect(!ToolRegistry.orchestratorAllowedToolNames.contains(name), "\(name) leaked onto the orchestrator allowlist")
        }
        let registered = Set(ToolRegistry.shared.listTools().map(\.name))
        #expect(AppleApp.allToolNames.isSubset(of: registered), "unregistered: \(AppleApp.allToolNames.subtracting(registered).sorted())")
    }
}
