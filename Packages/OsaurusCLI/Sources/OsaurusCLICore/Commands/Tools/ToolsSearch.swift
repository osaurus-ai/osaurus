//
//  ToolsSearch.swift
//  osaurus
//
//  Command to search for tools in the central repository by ID or name.
//

import Foundation
import OsaurusRepository

public struct ToolsSearch {
    public static func execute(args: [String]) {
        let query = args.first?.lowercased() ?? ""
        let specs = CentralRepositoryManager.shared.listAllSpecs()
        let filtered = specs.filter { spec in
            if query.isEmpty { return true }
            if spec.plugin_id.lowercased().contains(query) { return true }
            if let name = spec.name?.lowercased(), name.contains(query) { return true }
            return false
        }
        if filtered.isEmpty {
            print("(no matches)")
        } else {
            for spec in filtered.sorted(by: { $0.plugin_id < $1.plugin_id }) {
                let latest = spec.versions.map(\.version).sorted(by: >).first?.description ?? "-"
                print("\(spec.plugin_id)\tlatest: \(latest)\t\(spec.name ?? "")")
            }
        }
        exit(EXIT_SUCCESS)
    }
}
