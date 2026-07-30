//
//  SharedEventLoopGroups.swift
//  osaurus
//
//  Process-wide shared NIO event-loop groups.
//
//  Every NIO server in the app previously allocated its own
//  `MultiThreadedEventLoopGroup` per start — the main HTTP server took one
//  thread per core, and each restart that outlived a graceful-shutdown budget
//  left the previous group's threads (and their kqueue/pipe descriptors)
//  alive while the next start allocated another. Production crash
//  APPLE-MACOS-19T captured nine concurrent 10-thread groups and death by
//  `kqueue(): Too many open files` (EMFILE, errno 24).
//
//  Sharing fixed groups removes the leak class entirely:
//    - restarts rebind channels on the same group — no thread/descriptor
//      churn, no half-drained group accumulation;
//    - the groups are static and never shut down, so NIO's "EventLoopGroup
//      is still running" deinit precondition (issue #860) can never fire —
//      statics are not deinitialized at process exit.
//
//  Server stop therefore means "close the listening channel and its child
//  channels" (see `OsaurusServer.stop`), never "tear down the loops".
//

import Foundation
import NIOCore
import NIOPosix

public enum SharedEventLoopGroups {
    /// Group for the main embedded HTTP server. Sized like the previous
    /// per-start group (one thread per core) since it carries all inference
    /// request I/O.
    public static let server = MultiThreadedEventLoopGroup(
        numberOfThreads: max(2, ProcessInfo.processInfo.activeProcessorCount)
    )

    /// Group for low-traffic auxiliary servers (sandbox host-API bridge,
    /// sandbox egress proxy). These previously allocated 2 threads each per
    /// start; sharing one small group bounds them for the process lifetime.
    public static let utility = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    /// Number of file descriptors currently open in this process — the gauge
    /// that would have caught the EMFILE build-up long before `kqueue()`
    /// failed fatally. Enumerates `/dev/fd` (cheap; one directory read).
    public static func openFileDescriptorCount() -> Int? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
            return nil
        }
        // The directory read itself briefly holds one descriptor.
        return max(0, entries.count - 1)
    }
}
