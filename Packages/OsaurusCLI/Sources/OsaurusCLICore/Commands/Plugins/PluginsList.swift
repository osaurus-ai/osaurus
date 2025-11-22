//
//  PluginsList.swift
//  osaurus
//
//  Command to list all installed plugins with their versions from the receipts index.
//

import Foundation
import OsaurusRepository

public struct PluginsList {
    public static func execute(args: [String]) {
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        let url =
            supportDir
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent("receipts.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            print("(no plugins installed)")
            exit(EXIT_SUCCESS)
        }
        struct IndexDump: Decodable { let receipts: [String: [String: PluginReceipt]] }
        if let index = try? JSONDecoder().decode(IndexDump.self, from: data) {
            if index.receipts.isEmpty {
                print("(no plugins installed)")
            } else {
                for pluginId in index.receipts.keys.sorted() {
                    let versions =
                        index.receipts[pluginId]?.keys.sorted(by: { (a, b) in
                            guard let va = SemanticVersion.parse(a), let vb = SemanticVersion.parse(b) else {
                                return a > b
                            }
                            return va > vb
                        }) ?? []
                    let latest = versions.first ?? "-"
                    print("\(pluginId)  versions: \(versions.joined(separator: ", "))  latest: \(latest)")
                }
            }
            exit(EXIT_SUCCESS)
        } else {
            print("(no plugins installed)")
            exit(EXIT_SUCCESS)
        }
    }
}
