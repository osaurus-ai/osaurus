//
//  PluginTests.swift
//  OsaurusCoreTests
//
//  Tests for the plugin system: manifest parsing, route matching, HTTP helpers,
//  rate limiting, MIME types, database operations, and config defaults.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Route Matching

struct PluginRouteMatchingTests {

    private func manifest(routes: [PluginManifest.RouteSpec]) -> PluginManifest {
        PluginManifest(
            plugin_id: "com.test.plugin",
            description: nil,
            capabilities: .init(tools: nil, routes: routes, config: nil, web: nil),
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

    @Test func exactPathMatch() {
        let m = manifest(routes: [
            .init(id: "callback", path: "/callback", methods: ["GET"])
        ])
        let result = m.matchRoute(method: "GET", subpath: "/callback")
        #expect(result?.id == "callback")
    }

    @Test func exactPathNoMatch_differentPath() {
        let m = manifest(routes: [
            .init(id: "callback", path: "/callback", methods: ["GET"])
        ])
        #expect(m.matchRoute(method: "GET", subpath: "/other") == nil)
    }

    @Test func exactPathNoMatch_differentMethod() {
        let m = manifest(routes: [
            .init(id: "callback", path: "/callback", methods: ["GET"])
        ])
        #expect(m.matchRoute(method: "POST", subpath: "/callback") == nil)
    }

    @Test func wildcardPathMatch_subpath() {
        let m = manifest(routes: [
            .init(id: "app", path: "/app/*", methods: ["GET"])
        ])
        #expect(m.matchRoute(method: "GET", subpath: "/app/index.html")?.id == "app")
        #expect(m.matchRoute(method: "GET", subpath: "/app/assets/style.css")?.id == "app")
    }

    @Test func wildcardPathMatch_exactPrefix() {
        let m = manifest(routes: [
            .init(id: "app", path: "/app/*", methods: ["GET"])
        ])
        #expect(m.matchRoute(method: "GET", subpath: "/app")?.id == "app")
    }

    @Test func wildcardNoMatch_differentPrefix() {
        let m = manifest(routes: [
            .init(id: "app", path: "/app/*", methods: ["GET"])
        ])
        #expect(m.matchRoute(method: "GET", subpath: "/api/data") == nil)
    }

    @Test func methodCaseInsensitive() {
        let m = manifest(routes: [
            .init(id: "events", path: "/events", methods: ["POST"])
        ])
        #expect(m.matchRoute(method: "post", subpath: "/events")?.id == "events")
        #expect(m.matchRoute(method: "Post", subpath: "/events")?.id == "events")
    }

    @Test func multipleMethodsOnRoute() {
        let m = manifest(routes: [
            .init(id: "api", path: "/api/*", methods: ["GET", "POST", "PUT"])
        ])
        #expect(m.matchRoute(method: "GET", subpath: "/api/items") != nil)
        #expect(m.matchRoute(method: "POST", subpath: "/api/items") != nil)
        #expect(m.matchRoute(method: "PUT", subpath: "/api/items") != nil)
        #expect(m.matchRoute(method: "DELETE", subpath: "/api/items") == nil)
    }

    @Test func multipleRoutes_firstMatchWins() {
        let m = manifest(routes: [
            .init(id: "exact", path: "/api/health", methods: ["GET"]),
            .init(id: "wildcard", path: "/api/*", methods: ["GET"]),
        ])
        #expect(m.matchRoute(method: "GET", subpath: "/api/health")?.id == "exact")
    }

    @Test func noRoutes_returnsNil() {
        let m = manifest(routes: [])
        #expect(m.matchRoute(method: "GET", subpath: "/anything") == nil)
    }

    @Test func pathNormalization_missingLeadingSlash() {
        let m = manifest(routes: [
            .init(id: "test", path: "callback", methods: ["GET"])
        ])
        #expect(m.matchRoute(method: "GET", subpath: "/callback")?.id == "test")
        #expect(m.matchRoute(method: "GET", subpath: "callback")?.id == "test")
    }

    @Test func authLevel_preserved() {
        let m = manifest(routes: [
            .init(id: "public", path: "/public", methods: ["GET"], auth: .none),
            .init(id: "protected", path: "/protected", methods: ["GET"], auth: .verify),
            .init(id: "private", path: "/private", methods: ["GET"], auth: .owner),
        ])
        #expect(m.matchRoute(method: "GET", subpath: "/public")?.auth == PluginManifest.RouteAuth.none)
        #expect(m.matchRoute(method: "GET", subpath: "/protected")?.auth == PluginManifest.RouteAuth.verify)
        #expect(m.matchRoute(method: "GET", subpath: "/private")?.auth == PluginManifest.RouteAuth.owner)
    }
}

// MARK: - Query Parameter Parsing

struct PluginQueryParamsTests {

    @Test func noQueryString() {
        let params = OsaurusHTTPRequest.parseQueryParams(from: "/path")
        #expect(params.isEmpty)
    }

    @Test func emptyQueryString() {
        let params = OsaurusHTTPRequest.parseQueryParams(from: "/path?")
        #expect(params.isEmpty)
    }

    @Test func singleParam() {
        let params = OsaurusHTTPRequest.parseQueryParams(from: "/path?key=value")
        #expect(params == ["key": "value"])
    }

    @Test func multipleParams() {
        let params = OsaurusHTTPRequest.parseQueryParams(from: "/path?a=1&b=2&c=3")
        #expect(params["a"] == "1")
        #expect(params["b"] == "2")
        #expect(params["c"] == "3")
    }

    @Test func percentEncoded() {
        let params = OsaurusHTTPRequest.parseQueryParams(from: "/path?name=hello%20world&code=abc%3D123")
        #expect(params["name"] == "hello world")
        #expect(params["code"] == "abc=123")
    }

    @Test func paramWithoutValue() {
        let params = OsaurusHTTPRequest.parseQueryParams(from: "/path?flag")
        #expect(params["flag"] == "")
    }

    @Test func paramWithEmptyValue() {
        let params = OsaurusHTTPRequest.parseQueryParams(from: "/path?key=")
        #expect(params["key"] == "")
    }

    @Test func valueWithEquals() {
        let params = OsaurusHTTPRequest.parseQueryParams(from: "/path?data=a=b=c")
        #expect(params["data"] == "a=b=c")
    }
}

// MARK: - MIME Type

struct MIMETypeTests {

    @Test func htmlType() {
        #expect(MIMEType.forExtension("html") == "text/html; charset=utf-8")
        #expect(MIMEType.forExtension("htm") == "text/html; charset=utf-8")
    }

    @Test func cssType() {
        #expect(MIMEType.forExtension("css") == "text/css; charset=utf-8")
    }

    @Test func jsType() {
        #expect(MIMEType.forExtension("js") == "application/javascript; charset=utf-8")
        #expect(MIMEType.forExtension("mjs") == "application/javascript; charset=utf-8")
    }

    @Test func jsonType() {
        #expect(MIMEType.forExtension("json") == "application/json; charset=utf-8")
    }

    @Test func imageTypes() {
        #expect(MIMEType.forExtension("png") == "image/png")
        #expect(MIMEType.forExtension("jpg") == "image/jpeg")
        #expect(MIMEType.forExtension("jpeg") == "image/jpeg")
        #expect(MIMEType.forExtension("gif") == "image/gif")
        #expect(MIMEType.forExtension("svg") == "image/svg+xml")
        #expect(MIMEType.forExtension("webp") == "image/webp")
        #expect(MIMEType.forExtension("ico") == "image/x-icon")
    }

    @Test func fontTypes() {
        #expect(MIMEType.forExtension("woff") == "font/woff")
        #expect(MIMEType.forExtension("woff2") == "font/woff2")
        #expect(MIMEType.forExtension("ttf") == "font/ttf")
        #expect(MIMEType.forExtension("otf") == "font/otf")
    }

    @Test func wasmType() {
        #expect(MIMEType.forExtension("wasm") == "application/wasm")
    }

    @Test func unknownType() {
        #expect(MIMEType.forExtension("xyz") == "application/octet-stream")
        #expect(MIMEType.forExtension("") == "application/octet-stream")
    }

    @Test func caseInsensitive() {
        #expect(MIMEType.forExtension("HTML") == "text/html; charset=utf-8")
        #expect(MIMEType.forExtension("CSS") == "text/css; charset=utf-8")
        #expect(MIMEType.forExtension("JS") == "application/javascript; charset=utf-8")
    }
}

// MARK: - Rate Limiter

struct PluginRateLimiterTests {

    @Test func allowsRequestsUnderLimit() {
        let limiter = PluginRateLimiter()
        for _ in 0 ..< 50 {
            #expect(limiter.allow(pluginId: "com.test.plugin"))
        }
    }

    @Test func separateBucketsPerPlugin() {
        let limiter = PluginRateLimiter()
        for _ in 0 ..< 99 {
            _ = limiter.allow(pluginId: "plugin.a")
        }
        #expect(limiter.allow(pluginId: "plugin.b"))
    }

    @Test func exhaustsBucketEventually() {
        let limiter = PluginRateLimiter()
        var denied = false
        for _ in 0 ..< 200 {
            if !limiter.allow(pluginId: "com.test.heavy") {
                denied = true
                break
            }
        }
        #expect(denied, "Rate limiter should deny after exceeding token budget")
    }
}

// MARK: - Config Default Decoding

struct ConfigDefaultTests {

    @Test func decodeBool() throws {
        let json = Data("true".utf8)
        let value = try JSONDecoder().decode(PluginManifest.ConfigDefault.self, from: json)
        if case .bool(let b) = value {
            #expect(b == true)
        } else {
            Issue.record("Expected .bool, got \(value)")
        }
    }

    @Test func decodeNumber() throws {
        let json = Data("42.5".utf8)
        let value = try JSONDecoder().decode(PluginManifest.ConfigDefault.self, from: json)
        if case .number(let n) = value {
            #expect(n == 42.5)
        } else {
            Issue.record("Expected .number, got \(value)")
        }
    }

    @Test func decodeString() throws {
        let json = Data("\"hello\"".utf8)
        let value = try JSONDecoder().decode(PluginManifest.ConfigDefault.self, from: json)
        if case .string(let s) = value {
            #expect(s == "hello")
        } else {
            Issue.record("Expected .string, got \(value)")
        }
    }

    @Test func decodeStringArray() throws {
        let json = Data("[\"a\",\"b\",\"c\"]".utf8)
        let value = try JSONDecoder().decode(PluginManifest.ConfigDefault.self, from: json)
        if case .stringArray(let arr) = value {
            #expect(arr == ["a", "b", "c"])
        } else {
            Issue.record("Expected .stringArray, got \(value)")
        }
    }

    @Test func stringValue_bool() throws {
        let json = Data("true".utf8)
        let value = try JSONDecoder().decode(PluginManifest.ConfigDefault.self, from: json)
        #expect(value.stringValue == "true")
    }

    @Test func stringValue_number() throws {
        let json = Data("3.14".utf8)
        let value = try JSONDecoder().decode(PluginManifest.ConfigDefault.self, from: json)
        #expect(value.stringValue == "3.14")
    }

    @Test func stringValue_string() throws {
        let json = Data("\"text\"".utf8)
        let value = try JSONDecoder().decode(PluginManifest.ConfigDefault.self, from: json)
        #expect(value.stringValue == "text")
    }

    @Test func stringValue_stringArray() throws {
        let json = Data("[\"x\",\"y\"]".utf8)
        let value = try JSONDecoder().decode(PluginManifest.ConfigDefault.self, from: json)
        let parsed = try JSONSerialization.jsonObject(with: Data(value.stringValue.utf8)) as? [String]
        #expect(parsed == ["x", "y"])
    }
}

// MARK: - Plugin Database

struct PluginDatabaseTests {

    private func makeInMemoryDB() throws -> PluginDatabase {
        let db = PluginDatabase(pluginId: "com.test.db.\(UUID().uuidString)")
        try db.openInMemory()
        return db
    }

    @Test func openAndClose() throws {
        let db = try makeInMemoryDB()
        db.close()
    }

    @Test func createTableAndInsert() throws {
        let db = try makeInMemoryDB()
        defer { db.close() }

        let createResult = db.exec(sql: "CREATE TABLE items (id TEXT PRIMARY KEY, name TEXT)", paramsJSON: nil)
        #expect(!createResult.contains("error"))

        let insertResult = db.exec(
            sql: "INSERT INTO items (id, name) VALUES (?1, ?2)",
            paramsJSON: "[\"item-1\", \"Test Item\"]"
        )
        #expect(insertResult.contains("\"changes\":1"))
    }

    @Test func queryRows() throws {
        let db = try makeInMemoryDB()
        defer { db.close() }

        _ = db.exec(sql: "CREATE TABLE kv (key TEXT, value TEXT)", paramsJSON: nil)
        _ = db.exec(sql: "INSERT INTO kv VALUES (?1, ?2)", paramsJSON: "[\"a\", \"1\"]")
        _ = db.exec(sql: "INSERT INTO kv VALUES (?1, ?2)", paramsJSON: "[\"b\", \"2\"]")

        let result = db.query(sql: "SELECT * FROM kv ORDER BY key", paramsJSON: nil)
        #expect(result.contains("\"columns\""))
        #expect(result.contains("\"rows\""))
        #expect(result.contains("\"a\""))
        #expect(result.contains("\"b\""))
    }

    @Test func parameterizedQuery() throws {
        let db = try makeInMemoryDB()
        defer { db.close() }

        _ = db.exec(sql: "CREATE TABLE items (id INTEGER, name TEXT)", paramsJSON: nil)
        _ = db.exec(sql: "INSERT INTO items VALUES (?1, ?2)", paramsJSON: "[1, \"alpha\"]")
        _ = db.exec(sql: "INSERT INTO items VALUES (?1, ?2)", paramsJSON: "[2, \"beta\"]")

        let result = db.query(sql: "SELECT name FROM items WHERE id = ?1", paramsJSON: "[2]")
        #expect(result.contains("\"beta\""))
        #expect(!result.contains("\"alpha\""))
    }

    @Test func forbiddenAttach() throws {
        let db = try makeInMemoryDB()
        defer { db.close() }

        let result = db.exec(sql: "ATTACH DATABASE '/tmp/evil.db' AS evil", paramsJSON: nil)
        #expect(result.contains("Forbidden"))
    }

    @Test func forbiddenDetach() throws {
        let db = try makeInMemoryDB()
        defer { db.close() }

        let result = db.exec(sql: "DETACH DATABASE main", paramsJSON: nil)
        #expect(result.contains("Forbidden"))
    }

    @Test func forbiddenLoadExtension() throws {
        let db = try makeInMemoryDB()
        defer { db.close() }

        let result = db.exec(sql: "SELECT LOAD_EXTENSION('/tmp/evil.so')", paramsJSON: nil)
        #expect(result.contains("Forbidden"))
    }

    @Test func invalidSQL_returnsError() throws {
        let db = try makeInMemoryDB()
        defer { db.close() }

        let result = db.exec(sql: "NOT VALID SQL AT ALL", paramsJSON: nil)
        #expect(result.contains("error"))
    }

    @Test func nullParameterBinding() throws {
        let db = try makeInMemoryDB()
        defer { db.close() }

        _ = db.exec(sql: "CREATE TABLE t (id INTEGER, val TEXT)", paramsJSON: nil)
        let result = db.exec(sql: "INSERT INTO t VALUES (?1, ?2)", paramsJSON: "[1, null]")
        #expect(result.contains("\"changes\":1"))

        let queryResult = db.query(sql: "SELECT val FROM t WHERE id = 1", paramsJSON: nil)
        #expect(queryResult.contains("null"))
    }

    @Test func boolParameterBinding() throws {
        let db = try makeInMemoryDB()
        defer { db.close() }

        _ = db.exec(sql: "CREATE TABLE t (id INTEGER, flag INTEGER)", paramsJSON: nil)
        _ = db.exec(sql: "INSERT INTO t VALUES (?1, ?2)", paramsJSON: "[1, true]")
        _ = db.exec(sql: "INSERT INTO t VALUES (?1, ?2)", paramsJSON: "[2, false]")

        let result = db.query(sql: "SELECT flag FROM t ORDER BY id", paramsJSON: nil)
        #expect(result.contains("1"))
        #expect(result.contains("0"))
    }

    @Test func lastInsertRowid() throws {
        let db = try makeInMemoryDB()
        defer { db.close() }

        _ = db.exec(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)", paramsJSON: nil)
        let r1 = db.exec(sql: "INSERT INTO t (name) VALUES (?1)", paramsJSON: "[\"first\"]")
        #expect(r1.contains("\"last_insert_rowid\":1"))

        let r2 = db.exec(sql: "INSERT INTO t (name) VALUES (?1)", paramsJSON: "[\"second\"]")
        #expect(r2.contains("\"last_insert_rowid\":2"))
    }
}

// MARK: - Manifest Decoding

struct PluginManifestDecodingTests {

    @Test func minimalManifest() throws {
        let json = """
            {
                "plugin_id": "com.test.minimal",
                "capabilities": {
                    "tools": []
                }
            }
            """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.plugin_id == "com.test.minimal")
        #expect(manifest.capabilities.tools?.isEmpty == true)
        #expect(manifest.capabilities.routes == nil)
        #expect(manifest.capabilities.config == nil)
        #expect(manifest.capabilities.web == nil)
    }

    @Test func manifestWithRoutes() throws {
        let json = """
            {
                "plugin_id": "com.test.routes",
                "capabilities": {
                    "routes": [
                        {
                            "id": "callback",
                            "path": "/callback",
                            "methods": ["GET"],
                            "description": "OAuth callback",
                            "auth": "none"
                        },
                        {
                            "id": "webhook",
                            "path": "/events",
                            "methods": ["POST"],
                            "auth": "verify"
                        }
                    ]
                }
            }
            """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.capabilities.routes?.count == 2)

        let callback = manifest.capabilities.routes?[0]
        #expect(callback?.id == "callback")
        #expect(callback?.path == "/callback")
        #expect(callback?.methods == ["GET"])
        #expect(callback?.auth == PluginManifest.RouteAuth.none)

        let webhook = manifest.capabilities.routes?[1]
        #expect(webhook?.auth == .verify)
    }

    @Test func manifestWithConfig() throws {
        let json = """
            {
                "plugin_id": "com.test.config",
                "capabilities": {
                    "config": {
                        "title": "Settings",
                        "sections": [
                            {
                                "title": "Auth",
                                "fields": [
                                    {
                                        "key": "api_key",
                                        "type": "secret",
                                        "label": "API Key",
                                        "placeholder": "sk-...",
                                        "validation": {
                                            "required": true,
                                            "pattern": "^sk-",
                                            "pattern_hint": "Must start with sk-"
                                        }
                                    },
                                    {
                                        "key": "enabled",
                                        "type": "toggle",
                                        "label": "Enabled",
                                        "default": true
                                    }
                                ]
                            }
                        ]
                    }
                }
            }
            """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let config = manifest.capabilities.config
        #expect(config?.title == "Settings")
        #expect(config?.sections.count == 1)

        let fields = config?.sections[0].fields
        #expect(fields?.count == 2)
        #expect(fields?[0].type == .secret)
        #expect(fields?[0].validation?.required == true)
        #expect(fields?[0].validation?.pattern == "^sk-")
        #expect(fields?[1].type == .toggle)

        if case .bool(true) = fields?[1].default {
            // correct
        } else {
            Issue.record("Expected .bool(true) default")
        }
    }

    @Test func manifestWithWebSpec() throws {
        let json = """
            {
                "plugin_id": "com.test.web",
                "capabilities": {
                    "web": {
                        "static_dir": "web",
                        "entry": "index.html",
                        "mount": "/app",
                        "auth": "owner"
                    }
                }
            }
            """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let web = manifest.capabilities.web
        #expect(web?.static_dir == "web")
        #expect(web?.entry == "index.html")
        #expect(web?.mount == "/app")
        #expect(web?.auth == .owner)
    }

    @Test func manifestWithDocs() throws {
        let json = """
            {
                "plugin_id": "com.test.docs",
                "capabilities": {},
                "docs": {
                    "readme": "README.md",
                    "changelog": "CHANGELOG.md",
                    "links": [
                        {"label": "Docs", "url": "https://example.com/docs"},
                        {"label": "Issues", "url": "https://github.com/test/issues"}
                    ]
                }
            }
            """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.docs?.readme == "README.md")
        #expect(manifest.docs?.changelog == "CHANGELOG.md")
        #expect(manifest.docs?.links?.count == 2)
        #expect(manifest.docs?.links?[0].label == "Docs")
        #expect(manifest.docs?.links?[1].url == "https://github.com/test/issues")
    }

    @Test func routeAuthDefaultsToOwner() throws {
        let route = PluginManifest.RouteSpec(id: "test", path: "/test", methods: ["GET"])
        #expect(route.auth == .owner)
    }
}

// MARK: - Route Auth Decoding

struct RouteAuthDecodingTests {

    @Test func decodeNone() throws {
        let json = Data("\"none\"".utf8)
        let auth = try JSONDecoder().decode(PluginManifest.RouteAuth.self, from: json)
        #expect(auth == .none)
    }

    @Test func decodeVerify() throws {
        let json = Data("\"verify\"".utf8)
        let auth = try JSONDecoder().decode(PluginManifest.RouteAuth.self, from: json)
        #expect(auth == .verify)
    }

    @Test func decodeOwner() throws {
        let json = Data("\"owner\"".utf8)
        let auth = try JSONDecoder().decode(PluginManifest.RouteAuth.self, from: json)
        #expect(auth == .owner)
    }

    @Test func decodeInvalid_throws() {
        let json = Data("\"admin\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PluginManifest.RouteAuth.self, from: json)
        }
    }
}
