//
//  TemplateImportRouter.swift
//  osaurus
//
//  Brings a template file from outside the app to the import sheet that
//  owns its kind: a workflow to Workflows, an agent to Agents. Entry points
//  are a file opened from Finder (double-click, Open With, a drop on the
//  Dock icon), an `osaurus://templates-import?url=<registry URL>` link from
//  store.osaurus.ai, and a file dropped on the wrong tab's import
//  sheet. Nothing is imported here; the review sheet always shows first.
//
//  The link only fetches versioned template files from the workflows
//  registry (`WorkflowsRegistryAPIClient.isRegistryTemplateURL`), so it is
//  never a way to make Osaurus download an arbitrary URL. A workspace
//  listing answers 403 without a member's attestation; the fetch then tries
//  this Mac's workspaces, sending each attestation only as the
//  `X-Workspace-Attestation` header and never past a redirect to another
//  host.
//

import AppKit
import Foundation

/// The registry workflow a template link came from.
public struct RegistryImportSource: Equatable, Sendable {
    public let workflowID: UUID
    /// The version in the link's path; the install receipt signs it.
    public let version: Int
    /// The registry API origin that served the file.
    public let origin: URL
    /// The workspace whose listing it is, when one let the download in.
    public var workspaceID: String?

    public init(workflowID: UUID, version: Int, origin: URL, workspaceID: String? = nil) {
        self.workflowID = workflowID
        self.version = version
        self.origin = origin
        self.workspaceID = workspaceID
    }

    /// What the installed copy records about where it came from.
    public var installSource: InstalledWorkflow.Source {
        InstalledWorkflow.Source(registryID: workflowID.uuidString.lowercased(), workspaceID: workspaceID)
    }

    /// The source for a registry template URL, or nil when `url` is not one.
    public init?(templateURL url: URL, registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL) {
        guard let ref = WorkflowsRegistryAPIClient.registryTemplate(from: url, registry: registry),
            let origin = WorkflowsRegistryAPIClient.origin(of: url)
        else { return nil }
        self.init(workflowID: ref.id, version: ref.version, origin: origin)
    }
}

public struct PendingTemplateImport: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let kind: TemplateKind
    /// The host a deep link downloaded the file from; nil for a local
    /// file. A remote import is reviewed and set up, never added as is.
    public let sourceHost: String?
    /// Set only for a registry link, so a confirmed import can send its
    /// install receipt.
    public let registry: RegistryImportSource?

    public var registryWorkflowID: UUID? { registry?.workflowID }

    public init(
        text: String, kind: TemplateKind, sourceHost: String? = nil, registry: RegistryImportSource? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.kind = kind
        self.sourceHost = sourceHost
        self.registry = registry
    }

    public var isRemote: Bool { sourceHost != nil }
}

public enum TemplateImportRouter {
    public static let deepLinkHost = "templates-import"

    /// The kind a file's import sheet should open under. Text that does not
    /// parse opens under Workflows, where the sheet shows why.
    static func kind(of text: String) -> TemplateKind {
        (try? Template.parse(text))?.kind ?? .workflow
    }

    static func isTemplateFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == TemplateFileExport.fileExtension
    }

    /// The registry template file a `templates-import` link points at, or
    /// nil when the link names anything else.
    static func remoteURL(from link: URL, registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL) -> URL? {
        guard link.scheme?.lowercased() == "osaurus", link.host?.lowercased() == deepLinkHost,
            let raw = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name.lowercased() == "url" })?.value,
            let url = URL(string: raw),
            WorkflowsRegistryAPIClient.isRegistryTemplateURL(url, registry: registry)
        else { return nil }
        return url
    }

    /// Opens the import sheet for `text` on the tab that owns its kind.
    @MainActor
    public static func present(text: String, sourceHost: String? = nil, registry: RegistryImportSource? = nil) {
        let kind = kind(of: text)
        let state = ManagementStateManager.shared
        AppDelegate.shared?.showManagementWindow(initialTab: kind == .agent ? .agents : .workflows)
        state.pendingTemplateImport = PendingTemplateImport(
            text: text, kind: kind, sourceHost: sourceHost, registry: registry)
    }

    @MainActor
    public static func open(fileURL url: URL) {
        do {
            present(text: try TemplateFileExport.readFile(url))
        } catch {
            ToastManager.shared.error(
                L("Import"), message: L("Could not read \(url.lastPathComponent): \(error.localizedDescription)"))
        }
    }

    @MainActor
    public static func handleDeepLink(_ link: URL) {
        guard let url = remoteURL(from: link) else {
            ToastManager.shared.error(
                L("Import"), message: L("Osaurus installs template links from store.osaurus.ai only."))
            return
        }
        importRegistryFile(url)
    }

    /// Downloads a registry template file and opens its import sheet.
    /// `workspaceID` is the workspace whose catalog listed it; without one,
    /// a workspace listing is tried against each of this Mac's workspaces.
    @MainActor
    public static func importRegistryFile(_ url: URL, workspaceID: String? = nil) {
        guard WorkflowsRegistryAPIClient.isRegistryTemplateURL(url) else {
            ToastManager.shared.error(
                L("Import"), message: L("Osaurus installs template links from store.osaurus.ai only."))
            return
        }
        var registry = RegistryImportSource(templateURL: url)
        let candidates = workspaceID.map { [$0] } ?? WorkspacesService.shared.workspaces.filter { !$0.isSuspended }.map(\.id)
        Task { @MainActor in
            do {
                let fetched = try await fetch(url, workspaceCandidates: candidates)
                registry?.workspaceID = fetched.workspaceID ?? workspaceID
                present(text: fetched.text, sourceHost: fetched.host, registry: registry)
            } catch {
                ToastManager.shared.error(
                    L("Import"), message: L("Could not download the template: \(error.localizedDescription)"))
            }
        }
    }

    /// The most workspaces one download tries before giving up.
    static let maxWorkspaceAttempts = 8

    /// `fetch`, then on 403 again with an attestation for each candidate
    /// workspace in turn until one is let in.
    static func fetch(
        _ url: URL, workspaceCandidates: [String],
        attestation: @Sendable (String) async throws -> String = {
            try await WorkspaceAttestationProvider.shared.attestation(for: $0)
        },
        configuration: URLSessionConfiguration? = nil
    ) async throws -> Fetched {
        do {
            return try await fetch(url, configuration: configuration)
        } catch FetchError.status(403) where !workspaceCandidates.isEmpty {
            for workspaceID in workspaceCandidates.prefix(maxWorkspaceAttempts) {
                guard let token = try? await attestation(workspaceID) else { continue }
                do {
                    var fetched = try await fetch(url, attestation: token, configuration: configuration)
                    fetched.workspaceID = workspaceID
                    return fetched
                } catch FetchError.status(403) {
                    continue
                }
            }
            throw FetchError.workspaceRequired
        }
    }

    enum FetchError: LocalizedError, Equatable {
        case status(Int)
        case notText
        /// A redirect left https or had no host.
        case insecureRedirect(String)
        case hashMismatch
        /// A workspace listing none of this Mac's workspaces can read.
        case workspaceRequired

        var errorDescription: String? {
            switch self {
            case .status(410): return L("This template is no longer shared.")
            case .status(404): return L("The registry has no such template.")
            case .status(let code): return L("The server answered \(code).")
            case .notText: return L("The file is not text.")
            case .insecureRedirect(let target):
                return L("The download was redirected to \(target), which is not an https address.")
            case .hashMismatch: return L("The file doesn't match what the registry says it serves.")
            case .workspaceRequired:
                return L("This template is shared with a workspace you're not a member of.")
            }
        }
    }

    struct Fetched: Equatable {
        var text: String
        /// The host that finally served the file (after redirects).
        var host: String
        /// The workspace whose attestation let the download in.
        var workspaceID: String? = nil
    }

    /// Every hop of a redirect chain must stay on https. Credentials and
    /// cookies never travel: the session is ephemeral with cookies off.
    final class HTTPSRedirectGuard: NSObject, URLSessionTaskDelegate {
        nonisolated(unsafe) private(set) var refused: String?
        nonisolated(unsafe) private(set) var finalURL: URL?
        /// The host the attestation was meant for; it never goes elsewhere.
        let originHost: String?

        init(originHost: String? = nil) {
            self.originHost = originHost?.lowercased()
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url, Self.isSecure(url) else {
                refused = request.url?.absoluteString ?? "?"
                completionHandler(nil)
                return
            }
            finalURL = url
            completionHandler(Self.forwarded(request, originHost: originHost))
        }

        /// The redirected request, without the attestation when it leaves
        /// the host it was minted for.
        static func forwarded(_ request: URLRequest, originHost: String?) -> URLRequest {
            guard request.url?.host?.lowercased() != originHost else { return request }
            var stripped = request
            stripped.setValue(nil, forHTTPHeaderField: WorkspaceAttestationProvider.header)
            return stripped
        }

        static func isSecure(_ url: URL) -> Bool {
            url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
        }
    }

    static func makeSession(delegate: URLSessionTaskDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    static func fetch(
        _ url: URL, attestation: String? = nil, configuration: URLSessionConfiguration? = nil
    ) async throws -> Fetched {
        guard HTTPSRedirectGuard.isSecure(url) else { throw FetchError.insecureRedirect(url.absoluteString) }
        let guardDelegate = HTTPSRedirectGuard(originHost: url.host)
        let session: URLSession
        if let configuration {
            session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
        } else {
            session = makeSession(delegate: guardDelegate)
        }
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let attestation { request.setValue(attestation, forHTTPHeaderField: WorkspaceAttestationProvider.header) }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if let refused = guardDelegate.refused { throw FetchError.insecureRedirect(refused) }
            throw error
        }
        if let refused = guardDelegate.refused { throw FetchError.insecureRedirect(refused) }
        guard let http = response as? HTTPURLResponse else { throw FetchError.status(0) }
        guard http.statusCode == 200 else { throw FetchError.status(http.statusCode) }
        if response.expectedContentLength > Int64(TemplateFileExport.maxImportBytes) {
            throw TemplateStore.StoreError.tooLarge
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > TemplateFileExport.maxImportBytes { throw TemplateStore.StoreError.tooLarge }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw FetchError.notText }
        // Text that doesn't parse goes to the review sheet, which says why.
        if let served = http.value(forHTTPHeaderField: "X-Content-Hash"), !served.isEmpty,
            let template = try? Template.parse(text), template.contentHash != served
        {
            throw FetchError.hashMismatch
        }
        let host = (response.url ?? guardDelegate.finalURL ?? url).host ?? url.host ?? ""
        return Fetched(text: text, host: host)
    }
}
