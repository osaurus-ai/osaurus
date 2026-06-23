//
//  RepositoryGlobalProxySettings.swift
//  OsaurusRepository
//

import Foundation
import OsaurusNetworking
import os

/// Disk-backed proxy resolver for plugin repository and artifact downloads.
///
/// `OsaurusRepository` cannot depend on `OsaurusCore`, but it can read the same
/// lightweight `server.json.globalProxyURL` setting through `ToolsPaths`. This
/// keeps CLI and app-driven plugin installs on the shared proxy policy without
/// introducing a package cycle.
enum RepositoryGlobalProxySettings {
    private struct SharedSessionState {
        let proxyKey: String
        let session: URLSession
    }

    private static let sharedSessionBox = OSAllocatedUnfairLock<SharedSessionState?>(initialState: nil)

    static func sharedSession() -> URLSession {
        let key = currentProxyCacheKey()
        return sharedSessionBox.withLock { state in
            if let state, state.proxyKey == key {
                return state.session
            }

            let session = makeSession()
            state = SharedSessionState(proxyKey: key, session: session)
            return session
        }
    }

    static func makeSession(
        base: URLSessionConfiguration = .default,
        delegate: URLSessionDelegate? = nil,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        GlobalProxyURLSessionFactory.makeSession(
            base: base,
            proxy: currentConfiguration(),
            delegate: delegate,
            delegateQueue: delegateQueue
        )
    }

    static func currentConfiguration() -> GlobalProxyConfiguration? {
        guard
            let rawURL = persistedProxyURL()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty
        else {
            return nil
        }
        return try? GlobalProxyConfiguration(urlString: rawURL)
    }

    static func currentProxyCacheKey() -> String {
        persistedProxyURL()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func persistedProxyURL() -> String? {
        guard
            let data = try? Data(contentsOf: serverConfigFile()),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["globalProxyURL"] as? String
    }

    private static func serverConfigFile() -> URL {
        let root = ToolsPaths.root()
        let newPath =
            root
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("server.json", isDirectory: false)
        let legacyPath = root.appendingPathComponent("ServerConfiguration.json", isDirectory: false)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacyPath.path) && !fm.fileExists(atPath: newPath.path) {
            return legacyPath
        }
        return newPath
    }
}
