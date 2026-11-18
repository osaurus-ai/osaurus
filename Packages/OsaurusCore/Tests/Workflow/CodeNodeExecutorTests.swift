//
//  CodeNodeExecutorTests.swift
//  OsaurusCoreTests
//
//  Code nodes against the real `osaurus-js-host` helper under its Seatbelt
//  profile: results and logs, script errors, declared secrets, the fetch
//  allowlist, workspace files, timeout and memory kills, cancellation,
//  and what the sandbox profile denies.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct CodeNodeExecutorTests {

    static func run(
        _ source: String, input: JSONValue = .object([:]), hosts: Set<String> = [], secrets: [String: String] = [:],
        workspace: URL? = nil, timeout: TimeInterval = 10, memoryMB: Int = CodeNodeExecutor.defaultMemoryLimitMB,
        fetcher: @escaping CodeNodeFetcher = { _ in throw URLError(.notConnectedToInternet) }
    ) async throws -> CodeNodeResult {
        try await CodeNodeExecutor.run(
            source: source, input: input,
            grants: CodeNodeGrants(allowedHosts: hosts, secrets: secrets, workspace: workspace),
            timeout: timeout, memoryLimitMB: memoryMB, fetcher: fetcher)
    }

    @Test
    func helperIsBuiltForTests() {
        #expect(JSHostLocator.executableURL() != nil)
    }

    @Test
    func returnsTheResultAndLogs() async throws {
        let result = try await Self.run(
            """
            async function run(input, ctx) {
              ctx.log("got", input.n);
              return { double: input.n * 2, name: input.name.toUpperCase() };
            }
            """,
            input: .object(["n": .number(21), "name": .string("acme")]))
        #expect(result.output == .object(["double": .number(42), "name": .string("ACME")]))
        #expect(result.logs == ["got 21"])
    }

    @Test
    func ctxCarriesTheRunAndCaller_frozen() async throws {
        let result = try await CodeNodeExecutor.run(
            source: """
                async function run(input, ctx) {
                  try { ctx.run.id = "changed"; } catch (e) {}
                  return { run: ctx.run.id, folder: ctx.run.workspace, who: ctx.caller.agent_name, kind: ctx.caller.kind };
                }
                """,
            input: .object([:]), grants: CodeNodeGrants(allowedHosts: [], secrets: [:], workspace: nil),
            timeout: 10, memoryLimitMB: CodeNodeExecutor.defaultMemoryLimitMB,
            run: .object(["id": .string("run-1"), "workspace": .string("/tmp/run-1")]),
            caller: .object(["kind": .string("agent"), "agent_id": .null, "agent_name": .string("Scout")]),
            fetcher: { _ in throw URLError(.notConnectedToInternet) })
        #expect(
            result.output
                == .object([
                    "run": .string("run-1"), "folder": .string("/tmp/run-1"), "who": .string("Scout"),
                    "kind": .string("agent"),
                ]))
    }

    @Test
    func thrownErrors_surfaceTheMessage() async {
        await #expect(throws: CodeNodeError.self) {
            _ = try await Self.run("async function run(input, ctx) { throw new Error('bad client id'); }")
        }
        do {
            _ = try await Self.run("async function run(input, ctx) { throw new Error('bad client id'); }")
        } catch let CodeNodeError.scriptError(message, _) {
            #expect(message.contains("bad client id"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test
    func onlyDeclaredSecretsAreReadable() async throws {
        let result = try await Self.run(
            """
            async function run(input, ctx) {
              const key = await ctx.secrets.get("CLIO_API_KEY");
              let other = "readable";
              try { await ctx.secrets.get("OTHER"); } catch (e) { other = "refused"; }
              return { key, other };
            }
            """,
            secrets: ["CLIO_API_KEY": "sk-123"])
        #expect(result.output == .object(["key": .string("sk-123"), "other": .string("refused")]))
    }

    @Test
    func fetch_reachesOnlyAllowlistedHTTPSHosts() async throws {
        let result = try await Self.run(
            """
            async function run(input, ctx) {
              const ok = await ctx.fetch("https://api.clio.com/v4/contacts?q=acme", { headers: { Authorization: "Bearer x" } });
              const out = { status: ok.status, body: await ok.text(), id: (await ok.json()).id };
              for (const url of ["https://evil.example.com/", "http://api.clio.com/"]) {
                try { await ctx.fetch(url); out[url] = "allowed"; } catch (e) { out[url] = "refused"; }
              }
              return out;
            }
            """,
            hosts: ["clio.com"],
            fetcher: { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer x")
                return CodeNodeFetchResponse(
                    status: 200, headers: ["content-type": "application/json"], body: #"{"id": 7}"#)
            })
        #expect(result.output.value(atPath: "status") == .number(200))
        #expect(result.output.value(atPath: "body") == .string(#"{"id": 7}"#))
        #expect(result.output.value(atPath: "id") == .number(7))
        #expect(result.output.objectValue?["https://evil.example.com/"] == .string("refused"))
        #expect(result.output.objectValue?["http://api.clio.com/"] == .string("refused"))
        #expect(result.fetches == ["GET api.clio.com/v4/contacts"])
    }

    @Test
    func files_stayInsideTheRunWorkspace() async throws {
        let workspace = WF.tempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let result = try await Self.run(
            """
            async function run(input, ctx) {
              await ctx.files.write("letter.txt", "Dear Acme");
              const text = await ctx.files.read("letter.txt");
              const names = await ctx.files.list();
              let escaped = "allowed";
              try { await ctx.files.write("../outside.txt", "x"); } catch (e) { escaped = "refused"; }
              return { text, names, escaped };
            }
            """,
            workspace: workspace)
        #expect(result.output.value(atPath: "text") == .string("Dear Acme"))
        #expect(result.output.value(atPath: "names") == .array([.string("letter.txt")]))
        #expect(result.output.value(atPath: "escaped") == .string("refused"))
        #expect(!FileManager.default.fileExists(atPath: workspace.deletingLastPathComponent().appendingPathComponent("outside.txt").path))
    }

    @Test
    func infiniteLoop_isKilledAtTheTimeout() async {
        let started = Date()
        do {
            _ = try await Self.run("async function run(input, ctx) { while (true) {} }", timeout: 1)
            Issue.record("should time out")
        } catch {
            #expect(error as? CodeNodeError == .timedOut(seconds: 1))
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test
    func runawayAllocation_isKilledAtTheMemoryLimit() async {
        do {
            _ = try await Self.run(
                """
                async function run(input, ctx) {
                  const hoard = [];
                  while (true) { hoard.push(new Array(1000000).fill(1.5)); }
                }
                """,
                timeout: 20, memoryMB: 64)
            Issue.record("should exceed the memory limit")
        } catch {
            #expect(error as? CodeNodeError == .memoryLimit(mb: 64))
        }
    }

    @Test
    func cancellation_killsTheHelper() async {
        let task = Task { try await Self.run("async function run(input, ctx) { while (true) {} }", timeout: 30) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let started = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test
    func missingRunFunction_isAScriptError() async {
        await #expect(throws: CodeNodeError.self) {
            _ = try await Self.run("const x = 1;")
        }
    }

    // MARK: - Sandbox profile

    static func sandboxed(_ executable: String, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", CodeNodeExecutor.profile(helperPath: executable), executable] + args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test
    func profile_deniesUserFilesWritesAndOtherExecutables() throws {
        let dir = WF.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: secret)

        #expect(try Self.sandboxed("/bin/cat", ["/System/Library/CoreServices/SystemVersion.plist"]) == 0)
        #expect(try Self.sandboxed("/bin/cat", [secret.path]) != 0)
        #expect(try Self.sandboxed("/usr/bin/touch", [dir.appendingPathComponent("new.txt").path]) != 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.txt").path))
        #expect(try Self.sandboxed("/bin/sh", ["-c", "/bin/ls /"]) != 0)
        #expect(CodeNodeExecutor.profile(helperPath: "/x").contains("(deny network*)"))
    }

    /// `/tmp` is a symlink to `/private/tmp`; a helper reached through it
    /// starts only by its real path.
    @Test
    func profile_startsAHelperReachedThroughASymlink() throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("osaurus-js-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let built = try #require(JSHostLocator.executableURL())
        let helper = dir.appendingPathComponent(JSHostLocator.executableName).path
        try FileManager.default.copyItem(atPath: built.path, toPath: helper)

        let execDenied: Int32 = 71
        #expect(try Self.sandboxed(helper, []) == execDenied)
        let real = CodeNodeExecutor.realPath(helper)
        #expect(real.hasPrefix("/private/tmp/"))
        #expect(try Self.sandboxed(real, []) != execDenied)
    }

    @Test
    func allowlistMatching() {
        let hosts: Set<String> = ["clio.com"]
        #expect(CodeNodeExecutor.isAllowed(URL(string: "https://clio.com/x")!, hosts: hosts))
        #expect(CodeNodeExecutor.isAllowed(URL(string: "https://app.CLIO.com/x")!, hosts: hosts))
        #expect(!CodeNodeExecutor.isAllowed(URL(string: "https://notclio.com/x")!, hosts: hosts))
        #expect(!CodeNodeExecutor.isAllowed(URL(string: "http://clio.com/x")!, hosts: hosts))
        #expect(CodeNodeExecutor.workspaceFile("../x", in: URL(fileURLWithPath: "/tmp")) == nil)
        #expect(CodeNodeExecutor.workspaceFile("a/b", in: URL(fileURLWithPath: "/tmp")) == nil)
    }

    // MARK: - Live fetcher

    @Test
    func redirectHops_areRecheckedAndStripHeadersAcrossHosts() {
        let hosts: Set<String> = ["clio.com"]
        let origin = URL(string: "https://api.clio.com/v4")!
        var sameHost = URLRequest(url: URL(string: "https://api.clio.com/v5")!)
        sameHost.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        if case .continue(let next) = CodeNodeExecutor.RedirectGuard.follow(sameHost, from: origin, hosts: hosts) {
            #expect(next.value(forHTTPHeaderField: "Authorization") == "Bearer x")
        } else {
            Issue.record("same-host hop should continue")
        }

        var sibling = URLRequest(url: URL(string: "https://files.clio.com/blob")!)
        sibling.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        sibling.setValue("1", forHTTPHeaderField: "X-Custom")
        if case .continue(let next) = CodeNodeExecutor.RedirectGuard.follow(sibling, from: origin, hosts: hosts) {
            #expect(next.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(next.value(forHTTPHeaderField: "X-Custom") == nil)
            #expect(next.url?.host == "files.clio.com")
        } else {
            Issue.record("allowed cross-host hop should continue without headers")
        }

        let offList = URLRequest(url: URL(string: "https://evil.example.com/")!)
        #expect(
            CodeNodeExecutor.RedirectGuard.follow(offList, from: origin, hosts: hosts)
                == .refuse(host: "evil.example.com"))
        let downgrade = URLRequest(url: URL(string: "http://api.clio.com/v4")!)
        #expect(
            CodeNodeExecutor.RedirectGuard.follow(downgrade, from: origin, hosts: hosts)
                == .refuse(host: "api.clio.com"))
    }

    static func stubbedFetcher(hosts: Set<String>) -> CodeNodeFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodeNodeFetchStubProtocol.self]
        return CodeNodeExecutor.makeFetcher(allowedHosts: hosts, configuration: config)
    }

    @Test
    func liveFetcher_followsAllowedRedirects_refusesOthers() async throws {
        CodeNodeFetchStubProtocol.reset()
        CodeNodeFetchStubProtocol.routes["https://api.clio.com/old"] = .redirect(to: "https://api.clio.com/new")
        CodeNodeFetchStubProtocol.routes["https://api.clio.com/new"] = .body("moved here", status: 200)
        CodeNodeFetchStubProtocol.routes["https://api.clio.com/leak"] = .redirect(to: "https://evil.example.com/")
        CodeNodeFetchStubProtocol.routes["https://evil.example.com/"] = .body("stolen", status: 200)

        let fetcher = Self.stubbedFetcher(hosts: ["clio.com"])
        var request = URLRequest(url: URL(string: "https://api.clio.com/old")!)
        request.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        let followed = try await fetcher(request)
        #expect(followed.status == 200)
        #expect(followed.body == "moved here")
        #expect(followed.truncated == false)

        do {
            _ = try await fetcher(URLRequest(url: URL(string: "https://api.clio.com/leak")!))
            Issue.record("off-list redirect should fail")
        } catch {
            #expect(error as? CodeNodeFetchError == .redirectRefused(host: "evil.example.com"))
        }
        #expect(!CodeNodeFetchStubProtocol.seen.contains { $0.url?.host == "evil.example.com" })
    }

    @Test
    func liveFetcher_sendsNoCookies_andCapsTheBody() async throws {
        CodeNodeFetchStubProtocol.reset()
        let big = String(repeating: "x", count: CodeNodeExecutor.maxResponseBytes + 4096)
        CodeNodeFetchStubProtocol.routes["https://api.clio.com/big"] = .body(big, status: 200)
        CodeNodeFetchStubProtocol.routes["https://api.clio.com/small"] = .body("ok", status: 200)

        // A cookie in the shared jar for this host must not travel.
        let cookie = HTTPCookie(properties: [
            .domain: "api.clio.com", .path: "/", .name: "session", .value: "abc", .secure: "TRUE",
        ])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }

        let fetcher = Self.stubbedFetcher(hosts: ["clio.com"])
        let small = try await fetcher(URLRequest(url: URL(string: "https://api.clio.com/small")!))
        #expect(small.body == "ok")
        #expect(CodeNodeFetchStubProtocol.seen.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })

        let capped = try await fetcher(URLRequest(url: URL(string: "https://api.clio.com/big")!))
        #expect(capped.truncated)
        #expect(capped.body.utf8.count == CodeNodeExecutor.maxResponseBytes)
    }
}

/// Serves canned responses so the live fetcher is exercised without a
/// network. Redirects are real 302s so `URLSession` runs its redirect path.
final class CodeNodeFetchStubProtocol: URLProtocol, @unchecked Sendable {
    enum Route {
        case body(String, status: Int)
        case redirect(to: String)
    }

    nonisolated(unsafe) static var routes: [String: Route] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            routes = [:]
            seen = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let route = Self.lock.withLock { () -> Route? in
            Self.seen.append(request)
            return Self.routes[url.absoluteString]
        }
        switch route {
        case .redirect(let target)?:
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .body(let text, let status)?:
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Chunked so the streamed cap has something to stop early on.
            let data = Data(text.utf8)
            var offset = 0
            while offset < data.count {
                let end = min(offset + 64 * 1024, data.count)
                client?.urlProtocol(self, didLoad: data[offset ..< end])
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
        }
    }

    override func stopLoading() {}
}
