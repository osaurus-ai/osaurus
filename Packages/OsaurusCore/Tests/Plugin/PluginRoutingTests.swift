//
//  PluginRoutingTests.swift
//  OsaurusCoreTests
//
//  Integration-style tests for the v3 plugin routing surface.
//  Cover the changes from the Plugin Host API audit:
//
//  - Path-parameter extraction surfaces in `OsaurusHTTPRequest.path_params`
//  - `WebSpec.api_mount` flows through manifest decode unchanged
//  - Web mount overlap detection (manifest-load-time validation)
//  - Base64 / route shadowing helper behavior
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - OsaurusHTTPRequest path_params encoding

struct PluginHTTPRequestPathParamsTests {

    @Test func pathParamsEncodedToJSON() throws {
        let req = OsaurusHTTPRequest(
            route_id: "item",
            method: "GET",
            path: "/items/abc",
            query: [:],
            path_params: ["id": "abc"],
            headers: [:],
            body: "",
            body_encoding: "utf8",
            remote_addr: "",
            plugin_id: "com.test",
            osaurus: .init(
                base_url: "http://localhost",
                plugin_url: "http://localhost/plugins/com.test",
                agent_address: ""
            )
        )
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pathParams = dict?["path_params"] as? [String: String]
        #expect(pathParams?["id"] == "abc")
    }

    @Test func pathParamsEncodedAsEmptyMapForRoutesWithoutParams() throws {
        let req = OsaurusHTTPRequest(
            route_id: "callback",
            method: "GET",
            path: "/callback",
            query: [:],
            path_params: [:],
            headers: [:],
            body: "",
            body_encoding: "utf8",
            remote_addr: "",
            plugin_id: "com.test",
            osaurus: .init(
                base_url: "http://localhost",
                plugin_url: "http://localhost/plugins/com.test",
                agent_address: ""
            )
        )
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pathParams = dict?["path_params"] as? [String: String]
        #expect(pathParams != nil)
        #expect(pathParams?.isEmpty == true)
    }
}

// MARK: - WebSpec api_mount

struct PluginWebSpecAPIMountTests {

    @Test func decodesApiMountWhenPresent() throws {
        let json = """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "web": {
                  "static_dir": "web",
                  "entry": "index.html",
                  "mount": "/ui",
                  "auth": "owner",
                  "api_mount": "/v2"
                }
              }
            }
            """
        let data = json.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        #expect(manifest.capabilities.web?.api_mount == "/v2")
    }

    @Test func apiMountIsOptional() throws {
        let json = """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "web": {
                  "static_dir": "web",
                  "entry": "index.html",
                  "mount": "/ui",
                  "auth": "owner"
                }
              }
            }
            """
        let data = json.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        #expect(manifest.capabilities.web?.api_mount == nil)
    }
}

// MARK: - Plugin static file containment

struct PluginStaticFileContainmentTests {
    @Test func staticFileContainmentAllowsFilesInsideWebDirectory() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let webDir = root.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        let fileURL = webDir.appendingPathComponent("index.html")
        try "ok".write(to: fileURL, atomically: true, encoding: .utf8)

        let resolved = try #require(HTTPHandler.containedPluginStaticFileURL(for: fileURL, webDirectory: webDir))

        #expect(resolved.path == fileURL.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test func staticFileContainmentRejectsSiblingPrefixDirectories() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let webDir = root.appendingPathComponent("web", isDirectory: true)
        let sibling = root.appendingPathComponent("web-other", isDirectory: true)
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let secretURL = sibling.appendingPathComponent("secret.txt")
        try "secret".write(to: secretURL, atomically: true, encoding: .utf8)

        #expect(HTTPHandler.containedPluginStaticFileURL(for: secretURL, webDirectory: webDir) == nil)
    }

    @Test func staticFileContainmentRejectsTraversalOutsideWebDirectory() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let webDir = root.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        let secretURL = root.appendingPathComponent("secret.txt")
        try "secret".write(to: secretURL, atomically: true, encoding: .utf8)
        let traversalURL = webDir.appendingPathComponent("../secret.txt")

        #expect(HTTPHandler.containedPluginStaticFileURL(for: traversalURL, webDirectory: webDir) == nil)
    }

    @Test func staticFileContainmentRejectsSymlinksEscapingWebDirectory() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let webDir = root.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        let secretURL = root.appendingPathComponent("secret.txt")
        try "secret".write(to: secretURL, atomically: true, encoding: .utf8)
        let linkURL = webDir.appendingPathComponent("linked-secret.txt")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: secretURL)

        #expect(HTTPHandler.containedPluginStaticFileURL(for: linkURL, webDirectory: webDir) == nil)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-plugin-static-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

// MARK: - Tunnel exposure flag

struct PluginTunnelExposureTests {

    @Test func routeTunnelExposedDecodesTrue() throws {
        let json = """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "routes": [
                  {
                    "id": "callback",
                    "path": "/oauth/callback",
                    "methods": ["GET"],
                    "auth": "none",
                    "tunnel_exposed": true
                  }
                ]
              }
            }
            """
        let data = json.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        let route = try #require(manifest.capabilities.routes?.first)
        #expect(route.tunnel_exposed == true)
        #expect(route.isTunnelExposed == true)
    }

    @Test func routeTunnelExposedDefaultsToFalse() throws {
        let json = """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "routes": [
                  {
                    "id": "internal",
                    "path": "/items",
                    "methods": ["GET"],
                    "auth": "owner"
                  }
                ]
              }
            }
            """
        let data = json.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        let route = try #require(manifest.capabilities.routes?.first)
        #expect(route.tunnel_exposed == nil)
        #expect(route.isTunnelExposed == false)
    }

    @Test func webTunnelExposedDecodesTrue() throws {
        let json = """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "web": {
                  "static_dir": "web",
                  "entry": "index.html",
                  "mount": "/ui",
                  "auth": "owner",
                  "tunnel_exposed": true
                }
              }
            }
            """
        let data = json.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        let web = try #require(manifest.capabilities.web)
        #expect(web.tunnel_exposed == true)
        #expect(web.isTunnelExposed == true)
    }

    @Test func webTunnelExposedDefaultsToFalse() throws {
        let json = """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "web": {
                  "static_dir": "web",
                  "entry": "index.html",
                  "mount": "/ui",
                  "auth": "owner"
                }
              }
            }
            """
        let data = json.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        let web = try #require(manifest.capabilities.web)
        #expect(web.tunnel_exposed == nil)
        #expect(web.isTunnelExposed == false)
    }

    @Test func routeSpecInitDefaultsTunnelExposedToNil() {
        let route = PluginManifest.RouteSpec(
            id: "x",
            path: "/x",
            methods: ["GET"]
        )
        #expect(route.tunnel_exposed == nil)
        #expect(route.isTunnelExposed == false)
    }

    @Test func routeSpecInitAcceptsTunnelExposed() {
        let route = PluginManifest.RouteSpec(
            id: "x",
            path: "/x",
            methods: ["GET"],
            tunnel_exposed: true
        )
        #expect(route.tunnel_exposed == true)
        #expect(route.isTunnelExposed == true)
    }
}

// MARK: - Path parameter wildcard interaction

struct PluginRouteMatchPrecedenceTests {

    private func manifest(routes: [PluginManifest.RouteSpec], web: PluginManifest.WebSpec? = nil) -> PluginManifest {
        PluginManifest(
            plugin_id: "com.test.plugin",
            description: nil,
            capabilities: .init(tools: nil, routes: routes, config: nil, web: web, artifact_handler: nil),
            instructions: nil,
            name: nil,
            version: nil,
            license: nil,
            authors: nil,
            min_macos: nil,
            min_osaurus: nil,
            secrets: nil,
            docs: nil
        )
    }

    @Test func wildcardStillWinsWhenNoExactOrParam() {
        let m = manifest(routes: [
            .init(id: "wildcard", path: "/api/*", methods: ["GET"])
        ])
        let match = m.matchRouteWithParams(method: "GET", subpath: "/api/foo/bar")
        #expect(match?.route.id == "wildcard")
        #expect(match?.pathParams.isEmpty == true)
    }

    @Test func paramAndExactCanCoexist() {
        let m = manifest(routes: [
            .init(id: "list", path: "/items", methods: ["GET"]),
            .init(id: "get", path: "/items/:id", methods: ["GET"]),
        ])
        #expect(m.matchRouteWithParams(method: "GET", subpath: "/items")?.route.id == "list")
        let getMatch = m.matchRouteWithParams(method: "GET", subpath: "/items/42")
        #expect(getMatch?.route.id == "get")
        #expect(getMatch?.pathParams["id"] == "42")
    }
}
