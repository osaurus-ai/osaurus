//
//  FileDescriptorLimit.swift
//  osaurus
//
//  macOS gives GUI apps a soft file-descriptor limit of 256 by default.
//  Osaurus routinely holds far more: SwiftNIO event loops (one kqueue +
//  wakeup pipe per loop across three groups), per-plugin SQLite databases,
//  chat/memory/knowledge stores, model bundle files, sockets for local and
//  remote providers, and Bonjour browsing. Under load the default limit is
//  reachable, and SwiftNIO treats `kqueue(): Too many open files` as fatal
//  (production crash APPLE-MACOS-19T).
//
//  Raising the *soft* limit to the allowed maximum at launch is the
//  standard, zero-risk mitigation: it changes nothing for processes that
//  never approach the old ceiling and removes the artificial cap for the
//  ones that do.
//

import Darwin
import Foundation

enum FileDescriptorLimit {
    /// Raises the soft `RLIMIT_NOFILE` to the highest value the kernel
    /// allows for this process. Call once, as early as possible at launch —
    /// before the NIO server, plugin host, or storage layer can start
    /// accumulating descriptors.
    @discardableResult
    static func raiseToMaximum() -> rlim_t? {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return nil }

        // For RLIMIT_NOFILE, macOS rejects a soft limit above OPEN_MAX
        // unless the hard limit is RLIM_INFINITY — clamp to the smaller of
        // the two so the setrlimit below cannot fail with EINVAL.
        let ceiling = min(rlim_t(OPEN_MAX), limits.rlim_max)
        guard limits.rlim_cur < ceiling else { return limits.rlim_cur }

        limits.rlim_cur = ceiling
        guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else { return nil }
        return ceiling
    }
}
