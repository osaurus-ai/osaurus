//
//  ToolsList.swift
//  osaurus
//
//  Command to list all installed plugins with their IDs, names, and available tools.
//

import Foundation

public struct ToolsList {
    public static func execute(args: [String]) {
        let root = Configuration.toolsRootDirectory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            print("(no plugins installed)")
            exit(EXIT_SUCCESS)
        }
        do {
            let contents = try fm.contentsOfDirectory(atPath: root.path)
            if contents.isEmpty {
                print("(no plugins installed)")
            } else {
                for entry in contents.sorted() {
                    let dir = root.appendingPathComponent(entry, isDirectory: true)
                    let manifestURL = dir.appendingPathComponent("manifest.json")
                    if let data = try? Data(contentsOf: manifestURL),
                        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    {
                        let id = (obj["id"] as? String) ?? entry
                        let name = (obj["name"] as? String) ?? entry
                        let tools = ((obj["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                        let toolList = tools.isEmpty ? "" : " tools: \(tools.joined(separator: ", "))"
                        print("\(entry)  id=\(id)  name=\(name)\(toolList)")
                    } else {
                        print(entry)
                    }
                }
            }
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Failed to read tools directory: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
