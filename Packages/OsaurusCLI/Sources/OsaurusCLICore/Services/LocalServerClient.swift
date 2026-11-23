//
//  LocalServerClient.swift
//  OsaurusCLI
//
//  Every CLI command that calls the local server goes through this client.
//  Credentials, in order: an access key from `--access-key` or the
//  environment, the token Osaurus gave this CLI when the owner clicked
//  Allow, or nothing (plain loopback trust). On a 401 from an interactive
//  terminal it asks Osaurus for approval once, saves the token, and retries.
//

import Darwin
import Foundation

/// The token Osaurus handed this CLI, in `~/.osaurus/cli/access-token`
/// (owner-only).
public struct CLITokenStore: Sendable {
    let fileURL: URL

    public static var live: CLITokenStore {
        CLITokenStore(
            fileURL: Configuration.root()
                .appendingPathComponent("cli", isDirectory: true)
                .appendingPathComponent("access-token")
        )
    }

    public func load() -> String? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.hasPrefix(LocalServerClient.tokenPrefix) ? token : nil
    }

    public func save(_ token: String) throws {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created owner-only before the token is written, so it is never
        // readable by anyone else even for a moment.
        let temporary = directory.appendingPathComponent(".access-token-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try Data(token.utf8).write(to: temporary)
            if fm.fileExists(atPath: fileURL.path) {
                _ = try fm.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: fileURL)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

public final class LocalServerClient: @unchecked Sendable {
    /// Kept in sync with `CLIAccessStore` in OsaurusCore (the CLI does not
    /// depend on Core).
    public static let tokenHeaderName = "X-Osaurus-CLI-Token"
    public static let tokenPrefix = "osc_"

    public let port: Int
    public let accessKey: AccessKeyCredential?
    /// Shown on the approval prompt so the owner knows what is asking.
    let commandLabel: String
    let tokenStore: CLITokenStore
    /// Whether a person can see and act on the approval prompt. Only then
    /// is it raised; scripts and MCP hosts fail fast with a hint instead.
    let interactive: Bool
    let session: URLSession
    /// How long `/cli/access` must stay open before "Click Allow" is shown.
    /// A cooldown or an already-open prompt is answered at once, and the
    /// instruction would contradict it.
    let approvalNoticeDelay: Duration
    /// Where approval progress and refusals are written (stderr).
    let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var token: String?
    private var refusalShown = false

    public init(
        port: Int,
        accessKey: AccessKeyCredential?,
        commandLabel: String,
        tokenStore: CLITokenStore = .live,
        interactive: Bool = isatty(STDERR_FILENO) != 0,
        session: URLSession = .shared,
        approvalNoticeDelay: Duration = .milliseconds(500),
        log: @escaping @Sendable (String) -> Void = { fputs($0 + "\n", stderr) }
    ) {
        self.port = port
        self.accessKey = accessKey
        self.commandLabel = commandLabel
        self.tokenStore = tokenStore
        self.interactive = interactive
        self.session = session
        self.approvalNoticeDelay = approvalNoticeDelay
        self.log = log
        self.token = tokenStore.load()
    }

    /// Makes sure the server is up, then builds a client for `command`.
    /// Access-key options are read from `args`.
    @MainActor
    public static func connect(
        command: String,
        args: [String],
        interactive: Bool = isatty(STDERR_FILENO) != 0
    ) async -> LocalServerClient {
        let port = await ServerControl.ensureServerReadyOrExit()
        return LocalServerClient(
            port: port,
            accessKey: AccessKeyResolver.resolve(args: args),
            commandLabel: command,
            interactive: interactive
        )
    }

    public var hasToken: Bool { lock.withLock { token != nil } }

    public func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path.hasPrefix("/") ? path : "/" + path)")!
    }

    public func request(_ path: String, method: String = "GET", timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        return request
    }

    /// `request` with `body` encoded as JSON.
    public func jsonRequest(
        _ path: String,
        method: String = "POST",
        body: Any,
        timeout: TimeInterval = 30
    ) -> URLRequest {
        var request = request(path, method: method, timeout: timeout)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Adds the credentials this client holds.
    public func authorize(_ request: inout URLRequest) {
        if let accessKey {
            request.setValue("Bearer \(accessKey.token)", forHTTPHeaderField: "Authorization")
        }
        if let token = lock.withLock({ token }) {
            request.setValue(token, forHTTPHeaderField: Self.tokenHeaderName)
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await send(request)
        guard response.statusCode == 401, await recoverFromUnauthorized() else { return (data, response) }
        return try await send(request)
    }

    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response) = try await stream(request)
        guard response.statusCode == 401, await recoverFromUnauthorized() else { return (bytes, response) }
        return try await stream(request)
    }

    /// `data(for:)` decoded as a JSON object, exiting with a readable
    /// message on transport errors and on a 401 that approval did not fix.
    public func jsonOrExit(_ request: URLRequest) async -> (status: Int, object: [String: Any]) {
        do {
            let (data, response) = try await data(for: request)
            if response.statusCode == 401 { exitUnauthorized() }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (response.statusCode, object)
        } catch {
            fputs("Could not reach the Osaurus server: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    /// Prints why the request was refused and what to do (unless the
    /// approval attempt already said why), then exits 1.
    public func exitUnauthorized() -> Never {
        if !lock.withLock({ refusalShown }) {
            fputs(unauthorizedHint + "\n", stderr)
        }
        exit(EXIT_FAILURE)
    }

    public var unauthorizedHint: String {
        if let accessKey {
            return "The access key from \(accessKey.source) was rejected."
        }
        return Self.approvalHint
    }

    public static let approvalHint =
        "Osaurus needs to approve this command-line tool. Run an osaurus command such as `osaurus list` in "
        + "Terminal once and click Allow in Osaurus, or pass --access-key KEY (also OSAURUS_API_KEY)."

    // MARK: - Approval

    enum ApprovalResult: Equatable {
        case approved
        case refused(String)
    }

    /// A stale or revoked token is dropped, then (interactive only) the
    /// owner is asked once. An explicit access key is never second-guessed.
    private func recoverFromUnauthorized() async -> Bool {
        guard accessKey == nil else { return false }
        dropToken()
        guard interactive else { return false }
        switch await requestApproval() {
        case .approved:
            return true
        case .refused(let message):
            log(message)
            lock.withLock { refusalShown = true }
            return false
        }
    }

    func requestApproval() async -> ApprovalResult {
        var request = jsonRequest("/cli/access", body: ["command": commandLabel], timeout: 150)
        request.setValue(nil, forHTTPHeaderField: Self.tokenHeaderName)
        let notice = Task { [log, approvalNoticeDelay] in
            try await Task.sleep(for: approvalNoticeDelay)
            log("Osaurus needs to approve this command-line tool. Click Allow in Osaurus on this Mac…")
        }
        let data: Data
        let status: Int
        do {
            let (body, response) = try await session.data(for: request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            notice.cancel()
            _ = await notice.result
            return .refused("Could not ask Osaurus for approval: \(error.localizedDescription)")
        }
        notice.cancel()
        _ = await notice.result
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let serverMessage = object["message"] as? String
        switch status {
        case 200:
            guard let token = object["token"] as? String, token.hasPrefix(Self.tokenPrefix) else {
                return .refused("Osaurus did not return an approval token.")
            }
            do {
                try tokenStore.save(token)
            } catch {
                log("Approved, but the token could not be saved: \(error.localizedDescription)")
            }
            lock.withLock { self.token = token }
            log("Approved.")
            return .approved
        case 404:
            return .refused(
                "This version of Osaurus cannot approve the command-line tool. Update Osaurus, "
                    + "or pass --access-key KEY.")
        default:
            return .refused(serverMessage ?? "Osaurus did not approve the command-line tool (status \(status)).")
        }
    }

    /// Makes sure this CLI holds a token, asking the owner when it does not
    /// and someone can answer. Routes only the app or an approved CLI may
    /// use (starting a workflow) need one even with loopback trust, and
    /// `osaurus mcp install` asks up front for the MCP host that cannot.
    public func requireToken() async -> Bool {
        if hasToken { return true }
        guard interactive else { return false }
        if case .refused(let message) = await requestApproval() {
            log(message)
            lock.withLock { refusalShown = true }
            return false
        }
        return true
    }

    /// Forgets a token the server no longer accepts.
    public func dropToken() {
        let hadToken = lock.withLock { () -> Bool in
            defer { token = nil }
            return token != nil
        }
        if hadToken { tokenStore.clear() }
    }

    // MARK: - Private

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private func stream(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var request = request
        authorize(&request)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (bytes, http)
    }
}
