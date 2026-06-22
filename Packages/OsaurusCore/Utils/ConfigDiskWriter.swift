//
//  ConfigDiskWriter.swift
//  osaurus
//
//  Off-main persistence for the small JSON configuration files.
//

import Foundation

/// Serializes configuration-file writes onto a background queue so the
/// `@MainActor` configuration stores never pay disk I/O on the main thread.
/// Frequent writes — e.g. the settings auto-save firing as the user types —
/// would otherwise stall the UI and surface as app-hang reports.
///
/// Writes are atomic and ordered (a single serial queue). In tests, detected
/// via a path override, the write runs synchronously on the calling thread so
/// existing write-then-read-from-disk assertions keep passing.
enum ConfigDiskWriter {
    private static let queue = DispatchQueue(label: "ai.osaurus.config-disk-write", qos: .utility)

    /// Atomically persist `data` to `url`.
    ///
    /// - Parameters:
    ///   - data: Encoded file contents (build this on the caller's thread —
    ///     encoding is cheap CPU; only the disk write is deferred).
    ///   - url: Destination file. Its directory must already exist.
    ///   - synchronous: When true, write on the calling thread (tests read the
    ///     file back immediately). Production passes false so the write lands
    ///     off the main thread.
    ///   - onError: Invoked on the writing thread if the write throws, so the
    ///     caller can log with its own context.
    static func write(
        _ data: Data,
        to url: URL,
        synchronous: Bool,
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
        if synchronous {
            do { try data.write(to: url, options: .atomic) } catch { onError?(error) }
        } else {
            queue.async {
                do { try data.write(to: url, options: .atomic) } catch { onError?(error) }
            }
        }
    }
}
