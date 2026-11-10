//
//  LegacyInboundDispatchCarryOver.swift
//  osaurus
//
//  Channel routing moved to events, so this build no longer models the
//  `inboundDispatch` block of the platform config files. Builds without
//  events still route inbound messages from it, and users can go back to one
//  on the same `~/.osaurus`, so every save carries the block over from the
//  file it replaces. Settings views build configurations from form state,
//  which is why this happens at save time rather than in the models.
//

import Foundation

enum LegacyInboundDispatchCarryOver {
    static let key = "inboundDispatch"

    /// `encoded` plus the top-level `inboundDispatch` of the file at `url`.
    static func platformFile(_ encoded: Data, replacing url: URL) -> Data {
        guard let previous = jsonObject(at: url)?[key],
            var object = jsonObject(encoded), object[key] == nil
        else { return encoded }
        object[key] = previous
        return serialized(object) ?? encoded
    }

    /// `encoded` plus each n8n connection's `inboundDispatch` from the file
    /// at `url`, matched by connection id.
    static func connectionsFile(_ encoded: Data, replacing url: URL) -> Data {
        guard let previousConnections = jsonObject(at: url)?["connections"] as? [[String: Any]] else {
            return encoded
        }
        var blocks: [String: Any] = [:]
        for connection in previousConnections {
            guard let id = connection["id"] as? String,
                let n8n = connection["n8n"] as? [String: Any],
                let block = n8n[key]
            else { continue }
            blocks[id] = block
        }
        guard !blocks.isEmpty, var object = jsonObject(encoded),
            var connections = object["connections"] as? [[String: Any]]
        else { return encoded }
        var changed = false
        for index in connections.indices {
            guard let id = connections[index]["id"] as? String, let block = blocks[id],
                var n8n = connections[index]["n8n"] as? [String: Any], n8n[key] == nil
            else { continue }
            n8n[key] = block
            connections[index]["n8n"] = n8n
            changed = true
        }
        guard changed else { return encoded }
        object["connections"] = connections
        return serialized(object) ?? encoded
    }

    private static func jsonObject(at url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap(jsonObject)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func serialized(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
