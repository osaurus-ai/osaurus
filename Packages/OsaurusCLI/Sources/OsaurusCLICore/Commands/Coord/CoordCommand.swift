import Foundation

public struct CoordCommand: Command {
    public static let name = "coord"

    public static func execute(args: [String]) async {
        fputs("osaurus coord is experimental and may change or be removed.\n", stderr)
        do {
            try run(args: args)
        } catch {
            fputs("coord: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func run(args: [String]) throws {
        let parsed = try parseRoot(args)
        guard let subcommand = parsed.args.first else {
            printUsage()
            return
        }
        let rest = Array(parsed.args.dropFirst())
        switch subcommand {
        case "help", "-h", "--help":
            printUsage()
        case "init":
            try runInit(paths: parsed.paths)
        case "status":
            try runStatus(paths: parsed.paths, args: rest)
        case "feature-flags":
            try runFeatureFlags(paths: parsed.paths, args: rest)
        case "lock":
            try runLock(paths: parsed.paths, args: rest)
        case "preflight", "gate-main", "heartbeat", "lane", "nudge", "promote", "agent-abort", "conflict-proof",
            "reviewer-summary", "tick-report", "pause", "resume", "stop", "clear-stop":
            fputs("coord \(subcommand) is not available in the coordinator foundation slice.\n\n", stderr)
            printUsage()
            exit(EXIT_FAILURE)
        default:
            fputs("Unknown coord subcommand: \(subcommand)\n\n", stderr)
            printUsage()
            exit(EXIT_FAILURE)
        }
    }

    static func parseRoot(_ args: [String]) throws -> (paths: CoordinatorPaths, args: [String]) {
        var remaining: [String] = []
        var cliRoot: String?
        var index = 0
        while index < args.count {
            if args[index] == "--root" {
                let valueIndex = index + 1
                guard valueIndex < args.count else { throw CoordCommandError.missingRootValue }
                cliRoot = args[valueIndex]
                index += 2
            } else {
                remaining.append(args[index])
                index += 1
            }
        }
        return (try CoordinatorPaths.resolve(cliRoot: cliRoot), remaining)
    }

    private static func runInit(paths: CoordinatorPaths) throws {
        let result = try CoordinatorBootstrap(paths: paths).initialize()
        print("Initialized coordinator root: \(result.root.path)")
        if !result.createdDirectories.isEmpty {
            print("Created directories: \(result.createdDirectories.count)")
        }
        if !result.seededFiles.isEmpty {
            print("Seeded files: \(result.seededFiles.count)")
        }
    }

    private static func runStatus(paths: CoordinatorPaths, args: [String]) throws {
        let snapshot = try CoordinatorStatusService(paths: paths).snapshot()
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(data: try encoder.encode(snapshot), encoding: .utf8) ?? "{}")
            return
        }
        print("Coordinator root: \(snapshot.root)")
        print("Initialized: \(snapshot.initialized ? "yes" : "no")")
        print("Active locks: \(snapshot.activeLocks.count)")
        print("Expired locks: \(snapshot.expiredLocks.count)")
        print("Paused: \(snapshot.paused ? "yes" : "no")")
        print("Stopped: \(snapshot.stopped ? "yes" : "no")")
    }

    private static func runFeatureFlags(paths: CoordinatorPaths, args: [String]) throws {
        let store = CoordinatorFeatureFlagsStore(paths: paths)
        let action = args.first ?? "list"
        switch action {
        case "list":
            let flags = try store.load().flags.sorted { $0.key < $1.key }
            for (name, enabled) in flags {
                print("\(name)=\(enabled)")
            }
        case "get":
            guard args.count == 2 else { throw CoordCommandError.invalidFeatureFlagsUsage }
            let flags = try store.load().flags
            print("\(args[1])=\(flags[args[1]] ?? false)")
        case "set":
            guard args.count == 3, let enabled = Bool(coordFlagValue: args[2]) else {
                throw CoordCommandError.invalidFeatureFlagsUsage
            }
            _ = try store.set(args[1], enabled: enabled)
            print("\(args[1])=\(enabled)")
        default:
            throw CoordCommandError.invalidFeatureFlagsUsage
        }
    }

    private static func runLock(paths: CoordinatorPaths, args: [String]) throws {
        guard let action = args.first else { throw CoordCommandError.invalidLockUsage }
        let service = CoordinatorLockService(paths: paths)
        let rest = Array(args.dropFirst())
        switch action {
        case "list":
            for lock in try service.list() {
                print("\(lock.resource) owner=\(lock.owner)")
            }
        case "acquire":
            guard let resource = rest.first else { throw CoordCommandError.invalidLockUsage }
            let options = parseLockOptions(Array(rest.dropFirst()))
            guard let owner = options.owner else { throw CoordCommandError.invalidLockUsage }
            switch try service.acquire(resource: resource, owner: owner, ttl: options.ttl) {
            case .acquired:
                print("acquired \(resource)")
            case .held(let current):
                print("held \(resource) owner=\(current.owner)")
                exit(EXIT_FAILURE)
            }
        case "release":
            guard let resource = rest.first else { throw CoordCommandError.invalidLockUsage }
            let options = parseLockOptions(Array(rest.dropFirst()))
            guard let owner = options.owner else { throw CoordCommandError.invalidLockUsage }
            switch try service.release(resource: resource, owner: owner, force: options.force) {
            case .released:
                print("released \(resource)")
            case .notFound:
                print("not-found \(resource)")
                exit(EXIT_FAILURE)
            case .ownerMismatch(let current):
                print("owner-mismatch \(resource) owner=\(current.owner)")
                exit(EXIT_FAILURE)
            }
        case "reap":
            let reaped = try service.reapExpired()
            print("reaped \(reaped.count)")
        default:
            throw CoordCommandError.invalidLockUsage
        }
    }

    private static func parseLockOptions(_ args: [String]) -> (owner: String?, ttl: TimeInterval?, force: Bool) {
        var owner: String?
        var ttl: TimeInterval?
        var force = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--owner":
                if index + 1 < args.count {
                    owner = args[index + 1]
                    index += 2
                } else {
                    index += 1
                }
            case "--ttl":
                if index + 1 < args.count {
                    ttl = TimeInterval(args[index + 1])
                    index += 2
                } else {
                    index += 1
                }
            case "--force":
                force = true
                index += 1
            default:
                index += 1
            }
        }
        return (owner, ttl, force)
    }

    private static func printUsage() {
        let usage = """
            osaurus coord <subcommand> [--root PATH]

            Foundation subcommands:
              init                         Create coordinator directories and seed state
              status [--json]              Show coordinator root, initialization, locks, and flags
              feature-flags list|get|set   Read or update JSON-backed feature flags
              lock list|acquire|release|reap
                                           Manage file-scoped coordinator locks

            Later orchestration subcommands are registered but unsupported in this slice.

            """
        print(usage)
    }
}

enum CoordCommandError: LocalizedError, Equatable {
    case missingRootValue
    case invalidFeatureFlagsUsage
    case invalidLockUsage

    var errorDescription: String? {
        switch self {
        case .missingRootValue:
            return "--root requires a path."
        case .invalidFeatureFlagsUsage:
            return "Usage: osaurus coord feature-flags [list|get <name>|set <name> <true|false>]"
        case .invalidLockUsage:
            return
                "Usage: osaurus coord lock [list|acquire <resource> --owner <owner> [--ttl seconds]|release <resource> --owner <owner> [--force]|reap]"
        }
    }
}

private extension Bool {
    init?(coordFlagValue value: String) {
        switch value.lowercased() {
        case "1", "true", "yes", "on", "enabled":
            self = true
        case "0", "false", "no", "off", "disabled":
            self = false
        default:
            return nil
        }
    }
}
