//
//  SandboxAgentPathScope.swift
//  osaurus
//
//  One agent's reach into the `/workspace` share, as seen from the host.
//  An agent owns its home (`/workspace/agents/<name>`) and shares
//  `/workspace/shared` with every agent; other agents' homes and files at
//  the share root are out of reach.
//
//  VirtioFS reports every file as owned by whichever guest user touches
//  it, so guest Unix permissions cannot separate agents. Host code that
//  serves, copies, reads, or writes sandbox files on an agent's behalf
//  therefore resolves through this scope: a relative symlink
//  (`../other-agent/…`), an absolute link to a host path, or a
//  sibling-prefix path (`/workspace/agents/<name>x`) cannot cross into
//  another home or out of the share.
//

import Darwin
import Foundation

struct SandboxAgentPathScope: Sendable, Equatable {
    static let sharedMountPath = "/workspace/shared"

    /// In-guest home, e.g. `/workspace/agents/<name>`.
    let agentHome: String
    /// Host directory backing `agentHome`.
    let hostHome: URL

    init(agentName: String) {
        agentHome = OsaurusPaths.inContainerAgentHome(agentName)
        hostHome = OsaurusPaths.containerAgentDir(agentName)
    }

    /// Scope for an in-guest home path. `nil` unless `agentHome` is exactly
    /// `/workspace/agents/<name>` with a single, non-dot component.
    init?(agentHome: String) {
        let prefix = OsaurusPaths.inContainerAgentHome("")
        guard agentHome.hasPrefix(prefix) else { return nil }
        let name = String(agentHome.dropFirst(prefix.count))
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        self.init(agentName: name)
    }

    var hostShared: URL { OsaurusPaths.containerSharedDir() }

    /// Host roots the agent may reach.
    var hostRoots: [URL] { [hostHome, hostShared] }

    /// Create the in-scope roots so containment checks resolve symmetrically
    /// before the VM has ever populated them.
    func ensureRootsExist() {
        for root in hostRoots {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    /// The in-scope host root and the path relative to it for an absolute
    /// guest path. `nil` when the path is outside the agent home and
    /// `/workspace/shared`, or contains a `..` component.
    func split(sandboxPath path: String) -> (root: URL, relative: String)? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { return nil }
        let normalized = "/" + components.filter { $0 != "." }.joined(separator: "/")
        for (guestRoot, hostRoot) in [(agentHome, hostHome), (Self.sharedMountPath, hostShared)] {
            if normalized == guestRoot { return (hostRoot, "") }
            if normalized.hasPrefix(guestRoot + "/") {
                return (hostRoot, String(normalized.dropFirst(guestRoot.count + 1)))
            }
        }
        return nil
    }

    /// Host URL for an absolute guest path, with symlink-safe containment in
    /// the agent home or the shared directory (never the whole share).
    func hostURL(forSandboxPath path: String) throws -> URL {
        guard let (root, relative) = split(sandboxPath: path) else {
            throw FolderToolError.invalidArguments(
                "'\(path)' is outside your sandbox home (`\(agentHome)`) and `\(Self.sharedMountPath)`; "
                    + "only those are reachable from the host."
            )
        }
        guard Self.isUsableRoot(root) else {
            throw FolderToolError.invalidArguments("'\(path)' is not reachable: its sandbox root is not a directory.")
        }
        // Containment resolves against the root's real path, so it must exist.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try FolderToolHelpers.resolvePath(relative.isEmpty ? "." : relative, rootPath: root)
    }

    /// Whether an already-resolved host URL lives in scope after symlink
    /// resolution.
    func contains(hostURL url: URL) -> Bool {
        guard let real = Self.realPath(url) else { return false }
        return hostRoots.contains { root in
            guard Self.isRealDirectory(root), let realRoot = Self.realPath(root) else { return false }
            return real == realRoot || real.hasPrefix(realRoot + "/")
        }
    }

    // MARK: - Symlink-refusing file access

    /// The guest can rename entries in the share, so a root such as an
    /// agent home could itself be swapped for a link to a host directory;
    /// resolving it first would then make that host directory the
    /// containment boundary. A root must be a directory, not a link to one.
    static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.standardizedFileURL.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// A root that is missing (created later) or a real directory.
    static func isUsableRoot(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.standardizedFileURL.path, &info) == 0 else { return errno == ENOENT }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Whether `url`'s parent resolves inside `root` (a real directory).
    /// Use before deleting or enumerating guest-writable paths: removing
    /// `root/plugins/x` through a linked `plugins` would delete host files.
    static func parentIsContained(_ url: URL, within root: URL) -> Bool {
        guard isRealDirectory(root),
            let realRoot = realPath(root),
            let realParent = realPath(url.deletingLastPathComponent())
        else { return false }
        return realParent == realRoot || realParent.hasPrefix(realRoot + "/")
    }

    /// `realpath(3)`, keeping `/private/var` and `/private/tmp` spellings
    /// (Foundation's `resolvingSymlinksInPath` rewrites them back to the
    /// alias, which would then trip `O_NOFOLLOW_ANY`).
    static func realPath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Open `url` only when its parent's real path is inside `root` and no
    /// component of the opened path is a symlink. `O_NOFOLLOW_ANY` refuses a
    /// link swapped in between the check and the open, so a guest-planted
    /// link cannot point a host read or write at a file outside the share.
    /// Regular files only.
    static func openContained(
        _ url: URL,
        within root: URL,
        flags: Int32,
        mode: mode_t = 0o644
    ) -> Int32? {
        guard parentIsContained(url, within: root),
            let realParent = realPath(url.deletingLastPathComponent())
        else { return nil }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let fd = Darwin.open(realParent + "/" + name, flags | O_NOFOLLOW_ANY | O_CLOEXEC, mode)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// Read up to `maxBytes` of a regular file contained in `root`. `nil`
    /// when missing, not a regular file, reached through a symlink, or
    /// outside `root`.
    static func readContained(_ url: URL, within root: URL, maxBytes: Int = .max) -> Data? {
        guard let fd = openContained(url, within: root, flags: O_RDONLY) else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return try? handle.read(upToCount: maxBytes) ?? Data()
    }

    /// Write `data` to a file contained in `root`, creating missing parent
    /// directories one component at a time and refusing any symlink on the
    /// way. Not atomic: a symlink-safe write matters more here than a
    /// crash-safe one, and callers rewrite whole files.
    static func writeContained(_ data: Data, to url: URL, within root: URL) throws {
        guard isRealDirectory(root), let realRoot = realPath(root) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let rootPath = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(rootPath + "/") else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        let parts = target.dropFirst(rootPath.count + 1).split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: url.path])
        }
        var directory = realRoot
        for component in parts.dropLast() {
            directory += "/" + component
            if Darwin.mkdir(directory, 0o755) != 0, errno != EEXIST {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directory])
            }
            var info = stat()
            guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: directory])
            }
        }
        let fileURL = URL(fileURLWithPath: directory).appendingPathComponent(parts[parts.count - 1])
        guard
            let fd = openContained(
                fileURL,
                within: URL(fileURLWithPath: realRoot),
                flags: O_WRONLY | O_CREAT | O_TRUNC
            )
        else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
    }
}
