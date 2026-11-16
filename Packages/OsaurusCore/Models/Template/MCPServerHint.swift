//
//  MCPServerHint.swift
//  osaurus
//
//  How to set up an MCP server a template names, so the receiving Mac can
//  add it in one step. A template's steps reference servers by name only;
//  a hint carries the connection shape the author used: the endpoint or
//  command, the sign-in kind, and the NAMES of headers and environment
//  variables. Values never travel, so the shape cannot hold a secret.
//
//  Hints are optional and only annotate servers the payload already
//  requires; one naming any other server is dropped when sealed.
//

import Foundation

public struct MCPServerHint: Codable, Equatable, Sendable, Identifiable {
    /// The server name the template's steps use.
    public var name: String
    /// The Osaurus MCP Directory entry this server is, when it is one.
    public var directoryID: String?
    public var transport: MCPProviderTransport
    public var url: String?
    public var auth: MCPProviderAuthType?
    public var command: String?
    public var args: [String]
    /// Environment variable names the server reads. Values stay on the author's Mac.
    public var envKeys: [String]
    /// Header names the server expects. Values stay on the author's Mac.
    public var headerKeys: [String]
    public var workingDirectory: String?

    public var id: String { name.lowercased() }

    public init(
        name: String, directoryID: String? = nil, transport: MCPProviderTransport = .http, url: String? = nil,
        auth: MCPProviderAuthType? = nil, command: String? = nil, args: [String] = [], envKeys: [String] = [],
        headerKeys: [String] = [], workingDirectory: String? = nil
    ) {
        self.name = name
        self.directoryID = directoryID
        self.transport = transport
        self.url = url
        self.auth = auth
        self.command = command
        self.args = args
        self.envKeys = envKeys
        self.headerKeys = headerKeys
        self.workingDirectory = workingDirectory
    }

    enum CodingKeys: String, CodingKey {
        case name, transport, url, auth, command, args
        case directoryID = "directory_id"
        case envKeys = "env_keys"
        case headerKeys = "header_keys"
        case workingDirectory = "working_directory"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        directoryID = try c.decodeIfPresent(String.self, forKey: .directoryID)
        transport = try c.decodeIfPresent(MCPProviderTransport.self, forKey: .transport) ?? .http
        url = try c.decodeIfPresent(String.self, forKey: .url)
        auth = try c.decodeIfPresent(MCPProviderAuthType.self, forKey: .auth)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        envKeys = try c.decodeIfPresent([String].self, forKey: .envKeys) ?? []
        headerKeys = try c.decodeIfPresent([String].self, forKey: .headerKeys) ?? []
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(directoryID, forKey: .directoryID)
        try c.encode(transport, forKey: .transport)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(auth, forKey: .auth)
        try c.encodeIfPresent(command, forKey: .command)
        if !args.isEmpty { try c.encode(args, forKey: .args) }
        if !envKeys.isEmpty { try c.encode(envKeys, forKey: .envKeys) }
        if !headerKeys.isEmpty { try c.encode(headerKeys, forKey: .headerKeys) }
        try c.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
    }

    /// The hint for a configured server, under the name the template uses.
    /// Only names of secret and plain headers / env vars are kept.
    public static func from(_ provider: MCPProvider, as name: String, directoryID: String?) -> MCPServerHint {
        func names(_ plain: [String: String], _ secret: [String]) -> [String] {
            var seen = Set<String>()
            return (plain.keys.sorted() + secret).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        switch provider.transport {
        case .http:
            return MCPServerHint(
                name: name, directoryID: directoryID, transport: .http, url: provider.url, auth: provider.authType,
                headerKeys: names(provider.customHeaders, provider.secretHeaderKeys))
        case .stdio:
            return MCPServerHint(
                name: name, directoryID: directoryID, transport: .stdio, command: provider.command,
                args: provider.args, envKeys: names(provider.env, provider.secretEnvKeys),
                workingDirectory: provider.workingDirectory)
        }
    }
}
