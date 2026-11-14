import Foundation

/// Single-variable environment lookup for hot paths.
///
/// `ProcessInfo.processInfo.environment` rebuilds a `[String: String]` from the
/// whole `environ` block on every access. Reading one key through it from
/// SwiftUI getters (model directory, data root) that run several times per
/// body pass kept the main thread busy long enough to register as a hang.
/// `getenv` reads the one entry in place and still sees `setenv` changes made
/// at runtime, so test overrides keep working without a cache to invalidate.
enum ProcessEnvironment {
    static func value(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        return String(cString: raw)
    }
}
