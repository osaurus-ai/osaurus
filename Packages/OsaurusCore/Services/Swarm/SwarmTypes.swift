//
//  SwarmTypes.swift
//  osaurus
//
//  Value types the Osaurus Swarm master works with: paired nodes, their
//  model libraries, resource pools, leases, pairing offers and the
//  structured inference events a node streams back. They mirror the master
//  library's FFI surface (see docs/SWARM_MASTER.md) so the app never talks
//  to the library directly; `SwarmMasterBackend` is the only seam.
//

import Foundation

// MARK: - Nodes

/// A node's identity: its device key / endpoint id, as the library reports it.
typealias SwarmNodeID = String

/// A resource pool's identity, assigned by the library.
typealias SwarmPoolID = String

/// The engine backend a node runs models with.
enum SwarmEngineBackend: String, Codable, Sendable, Equatable {
    case metal
    case cuda
    /// A node without a GPU engine (e.g. a test node's echo engine).
    case none

    var displayName: String {
        switch self {
        case .metal: return "Metal"
        case .cuda: return "CUDA"
        case .none: return L("No GPU engine")
        }
    }
}

/// How the master reaches a node. Swarm never uses relayed paths.
enum SwarmConnectionPath: String, Codable, Sendable, Equatable {
    case lan
    case thunderbolt
    case internetDirect

    var displayName: String {
        switch self {
        case .lan: return L("Direct · LAN")
        case .thunderbolt: return L("Direct · Thunderbolt bridge")
        case .internetDirect: return L("Direct · internet")
        }
    }
}

/// Whether a node takes new leases, and why not.
enum SwarmNodeAvailability: Codable, Sendable, Equatable {
    case available
    case busy
    case paused(reason: String)
    case offline
    /// Only a relayed path exists. Swarm requires a direct one.
    case unreachableNoDirectPath
    /// The node's protocol is older (or newer) than this master supports.
    case updateRequired(side: String)

    /// True when the scheduler may hand this node a new lease.
    var acceptsLeases: Bool {
        switch self {
        case .available, .busy: return true
        case .paused, .offline, .unreachableNoDirectPath, .updateRequired: return false
        }
    }

    var label: String {
        switch self {
        case .available: return L("Available")
        case .busy: return L("Serving")
        case .paused: return L("Paused")
        case .offline: return L("Offline")
        case .unreachableNoDirectPath: return L("Unreachable")
        case .updateRequired: return L("Update required")
        }
    }

    /// The sentence shown under the status chip.
    var detail: String? {
        switch self {
        case .available, .busy, .offline: return nil
        case .paused(let reason): return reason
        case .unreachableNoDirectPath:
            return L("No direct path. Swarm only uses direct connections (LAN, Thunderbolt or a direct internet path).")
        case .updateRequired(let side):
            return side == "node"
                ? L("This node's Osaurus Swarm is too old for this Osaurus. Update the node.")
                : L("This node is newer than this Osaurus. Update Osaurus.")
        }
    }
}

/// Load state of one installed model on a node.
enum SwarmModelLoadState: String, Codable, Sendable, Equatable {
    case cold
    case loading
    case warm

    var label: String {
        switch self {
        case .cold: return L("Not loaded")
        case .loading: return L("Loading")
        case .warm: return L("Loaded")
        }
    }
}

/// One model in a node's library.
struct SwarmInstalledModel: Codable, Sendable, Equatable, Identifiable {
    /// The model's id as the node serves it (a Hugging Face repo id such as
    /// `OsaurusAI/Qwen3.6-27B-JANG_4M`).
    let modelId: String
    let sizeBytes: Int64
    let digest: String?
    var loadState: SwarmModelLoadState
    /// Keep loaded (preheat) instead of loading on demand.
    var preheat: Bool

    var id: String { modelId }
}

/// Hardware a node reported at pairing and on change.
struct SwarmNodeHardware: Codable, Sendable, Equatable {
    var os: String
    var cpu: String
    var gpu: String
    var backend: SwarmEngineBackend
    var trexVersion: String
    var protocolVersion: Int
    /// Unified memory (Mac) or VRAM (CUDA) in bytes.
    var memoryTotalBytes: Int64
    /// The owner's cap for loaded models plus their KV, in bytes.
    var memoryCapBytes: Int64
}

/// Live use a node reports with every heartbeat.
struct SwarmNodeTelemetry: Codable, Sendable, Equatable {
    var memoryInUseBytes: Int64
    var diskFreeBytes: Int64
    /// 0...1
    var gpuUtilization: Double
    var lastHeartbeat: Date
}

/// Everything the master knows about one paired node.
struct SwarmNodeSnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: SwarmNodeID
    /// The master-assigned display name (the node's own name is only a
    /// suggestion at pairing). Still rendered verbatim, never as Markdown.
    var name: String
    var hardware: SwarmNodeHardware
    var telemetry: SwarmNodeTelemetry
    var availability: SwarmNodeAvailability
    var path: SwarmConnectionPath?
    var rttMs: Double?
    var models: [SwarmInstalledModel]

    func model(_ modelId: String) -> SwarmInstalledModel? {
        models.first { $0.modelId == modelId }
    }
}

// MARK: - Pairing

/// A pairing offer: the 12-character code the node owner types, and the same
/// offer as a QR payload. Offers expire (5 minutes) and close after five
/// wrong attempts; the library enforces both.
struct SwarmPairingOffer: Sendable, Equatable {
    let code: String
    let qrPayload: String
    let expiresAt: Date

    /// `ABCD-EFGH-JKLM`: the code in groups of four, as the node app shows
    /// its input boxes.
    var groupedCode: String {
        if code.contains("-") { return code }
        return stride(from: 0, to: code.count, by: 4).map { start -> String in
            let lower = code.index(code.startIndex, offsetBy: start)
            let upper = code.index(lower, offsetBy: min(4, code.count - start))
            return String(code[lower ..< upper])
        }.joined(separator: "-")
    }
}

// MARK: - Library management

/// Where a node gets a model from.
enum SwarmInstallSource: Sendable, Equatable {
    /// A Hugging Face link (`https://huggingface.co/org/repo`, optionally
    /// with `/tree/<revision>`) or a bare `org/repo`.
    case huggingFace(repoOrURL: String, revision: String?)
    /// Copy from another swarm member that already has the model. A nil
    /// `fromNode` lets the master pick the source.
    case peer(modelId: String, fromNode: SwarmNodeID?)

    /// The model id the install will produce on the node.
    var modelId: String? {
        switch self {
        case .huggingFace(let repoOrURL, _): return Self.huggingFaceRepoId(from: repoOrURL)
        case .peer(let modelId, _): return modelId
        }
    }

    /// `org/repo` from a Hugging Face link or a bare repo id; nil when the
    /// text is neither. Plain string parsing (no `URL`): the accepted forms
    /// are `https://huggingface.co/org/repo[/tree/rev][?…][#…]` (also
    /// `www.huggingface.co`, `hf.co`, `http://`, a leading `models/`) and
    /// `org/repo`; any other host or scheme is rejected.
    static func huggingFaceRepoId(from text: String) -> String? {
        guard let segments = huggingFacePathSegments(text), segments.count >= 2 else { return nil }
        return "\(segments[0])/\(segments[1])"
    }

    /// The `tree/<revision>` segment of a Hugging Face link, when present.
    static func huggingFaceRevision(from text: String) -> String? {
        guard let segments = huggingFacePathSegments(text), segments.count >= 4, segments[2] == "tree" else {
            return nil
        }
        return segments[3]
    }

    private static func huggingFacePathSegments(_ text: String) -> [String]? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !rest.isEmpty else { return nil }
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<cut] }
        if let scheme = rest.range(of: "://") {
            let name = rest[..<scheme.lowerBound].lowercased()
            guard name == "https" || name == "http" else { return nil }
            rest = rest[scheme.upperBound...]
            let hostEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            let host = rest[..<hostEnd].lowercased()
            guard ["huggingface.co", "www.huggingface.co", "hf.co"].contains(host) else { return nil }
            rest = rest[hostEnd...]
        } else if rest.contains(":") {
            return nil
        }
        var segments = rest.split(separator: "/").map(String.init)
        if segments.first == "models" { segments.removeFirst() }
        guard segments.count >= 2, isRepoName(segments[0]), isRepoName(segments[1]) else { return nil }
        return segments
    }

    /// Hugging Face org and repo names: ASCII letters, digits, `-`, `_`, `.`.
    private static func isRepoName(_ name: String) -> Bool {
        !name.isEmpty
            && name.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A: return true
                case 0x2D, 0x2E, 0x5F: return true
                default: return false
                }
            }
    }
}

enum SwarmInstallState: Sendable, Equatable {
    case queued
    case downloading
    case verifying
    case installed
    case failed(String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .installed, .failed, .cancelled: return true
        case .queued, .downloading, .verifying: return false
        }
    }
}

/// Progress of one install on one node.
struct SwarmInstallProgress: Sendable, Equatable, Identifiable {
    let nodeId: SwarmNodeID
    let modelId: String
    var bytesDone: Int64
    var bytesTotal: Int64?
    var state: SwarmInstallState

    var id: String { "\(nodeId)|\(modelId)" }

    var fraction: Double? {
        guard let total = bytesTotal, total > 0 else { return nil }
        return min(1, max(0, Double(bytesDone) / Double(total)))
    }
}

// MARK: - Pools

/// A named group of nodes that serve the same model(s). Callers ask the
/// pool, never a node.
struct SwarmPool: Codable, Sendable, Equatable, Identifiable {
    let id: SwarmPoolID
    var name: String
    var modelIds: [String]
    var nodeIds: [SwarmNodeID]
    /// Default lease duration in seconds.
    var leaseSeconds: Int
    /// How long a caller waits for a free node before `swarm_pool_busy`.
    var maxQueueWaitSeconds: Int
    /// Optional context length the pool's models run with (fit checks and
    /// the picker's context window). Nil leaves it to the model bundle.
    var contextLength: Int?

    static let defaultLeaseSeconds = 300
    static let defaultMaxQueueWaitSeconds = 60
    /// Stepper ranges for the pool editor (the spec's 30 s to 60 min).
    static let leaseSecondsRange: ClosedRange<Int> = 30 ... 3_600
    static let maxQueueWaitSecondsRange: ClosedRange<Int> = 0 ... 3_600
}

/// What the app sends to create or edit a pool.
struct SwarmPoolDraft: Sendable, Equatable {
    var name: String
    var modelIds: [String]
    var nodeIds: [SwarmNodeID]
    var leaseSeconds: Int
    var maxQueueWaitSeconds: Int
    var contextLength: Int?

    init(
        name: String = "",
        modelIds: [String] = [],
        nodeIds: [SwarmNodeID] = [],
        leaseSeconds: Int = SwarmPool.defaultLeaseSeconds,
        maxQueueWaitSeconds: Int = SwarmPool.defaultMaxQueueWaitSeconds,
        contextLength: Int? = nil
    ) {
        self.name = name
        self.modelIds = modelIds
        self.nodeIds = nodeIds
        self.leaseSeconds = leaseSeconds
        self.maxQueueWaitSeconds = maxQueueWaitSeconds
        self.contextLength = contextLength
    }

    init(_ pool: SwarmPool) {
        self.init(
            name: pool.name,
            modelIds: pool.modelIds,
            nodeIds: pool.nodeIds,
            leaseSeconds: pool.leaseSeconds,
            maxQueueWaitSeconds: pool.maxQueueWaitSeconds,
            contextLength: pool.contextLength
        )
    }
}

// MARK: - Leases

/// A time-limited hold on one node's slot for a model, granted by the
/// master's scheduler.
struct SwarmLease: Sendable, Equatable {
    let id: String
    let poolId: SwarmPoolID
    let nodeId: SwarmNodeID
    let modelId: String
    var expiresAt: Date
    /// The model was already loaded on the node when the lease was granted.
    let warm: Bool
}

struct SwarmLeaseRequest: Sendable, Equatable {
    let poolId: SwarmPoolID
    /// Empty: every member of the pool is a candidate.
    let nodeIds: [SwarmNodeID]
    let modelId: String
    let leaseSeconds: Int
    let maxWaitSeconds: Int
    /// Stable per caller (chat session, agent run) so consecutive requests
    /// renew the same lease and keep the node's prefix cache warm.
    let callerKey: String
}

// MARK: - Inference

/// One model request sent to a node. The body is the OpenAI Chat
/// Completions JSON the node's engine already serves.
struct SwarmInferenceRequest: Sendable, Equatable {
    let requestId: String
    let leaseId: String
    let idempotencyKey: String
    let modelId: String
    let chatBodyJSON: Data
    /// The conversation, so the node's prefix cache evicts per chat; nil
    /// uses the lease.
    var cacheChainId: String? = nil
    /// `warmup` or `auxiliary` (titles, summaries: keep nothing); nil for a
    /// normal generation.
    var cacheIntent: String? = nil
}

struct SwarmCompletionInfo: Sendable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var cachedPromptTokens: Int?
    var tokensPerSecond: Double
    var prefillTokensPerSecond: Double?
    /// `stop`, `length`, `tool_calls`, …
    var finishReason: String?
}

/// Structured events a node streams back for one request. Reasoning and
/// tool-call parsing happen on the node; the master only maps these.
enum SwarmInferenceEvent: Sendable, Equatable {
    case content(String)
    case reasoning(String)
    case toolCall(index: Int, id: String, name: String, argumentsJSON: String)
    /// A tool call still being generated. The engine may never send these.
    case toolCallProgress(String)
    /// Prompt processing before the first token. The engine may never send these.
    case prefillProgress(processed: Int, total: Int)
    case completion(SwarmCompletionInfo)
}

// MARK: - Backend events

/// Why a node's tool call was refused.
enum InvalidToolCallReason: Sendable, Equatable {
    case noToolsOffered
    case notOffered
    case argumentsNotObject
}

/// What the library pushes to the app.
enum SwarmBackendEvent: Sendable, Equatable {
    case nodeUpdated(SwarmNodeSnapshot)
    case nodeRemoved(SwarmNodeID)
    case pairingCompleted(SwarmNodeSnapshot)
    case pairingFailed(String)
    case installProgress(SwarmInstallProgress)
    case leaseRevoked(leaseId: String, reason: String)
    case poolsChanged
}

// MARK: - Errors

/// Typed Swarm failures. `code` is the stable wire id the HTTP API returns.
enum SwarmError: Error, Sendable, Equatable, LocalizedError {
    /// The Swarm library isn't running (not included in this build, or not started).
    case unavailable
    case notPaired
    case nodeNotFound(SwarmNodeID)
    case nodeOffline(String)
    case noDirectPath(String)
    case nodePaused(node: String, reason: String)
    case fitRefused(String)
    case capExceeded(cap: String, neededBytes: Int64, limitBytes: Int64)
    case modelNotInstalled(model: String, node: String)
    case updateRequired(side: String)
    case poolNotFound(String)
    /// No node in the pool became free within its max queue wait.
    case poolBusy(pool: String, waitedSeconds: Int)
    /// The node holding the lease went away (paused, offline, over a cap).
    case leaseLost(reason: String)
    /// The node's engine refused the request; status and message are TREX's, verbatim.
    case engine(status: Int, message: String)
    case invalidHuggingFaceLink(String)
    /// The node called a tool the request did not offer, or sent arguments
    /// that are not a JSON object. Nothing is run.
    case invalidToolCall(name: String, reason: InvalidToolCallReason)
    /// The library refused a request as malformed.
    case rejected(String)
    /// The library doesn't know the node, pool, model or request named.
    case notFound(String)
    /// The library failed internally (key store, runtime).
    case internalError(String)
    case cancelled
    case transport(String)

    var code: String {
        switch self {
        case .unavailable: return "swarm_unavailable"
        case .notPaired: return "swarm_not_paired"
        case .nodeNotFound: return "swarm_node_not_found"
        case .nodeOffline: return "swarm_node_offline"
        case .noDirectPath: return "swarm_no_direct_path"
        case .nodePaused: return "swarm_node_paused"
        case .fitRefused: return "swarm_fit_refused"
        case .capExceeded: return "swarm_cap_exceeded"
        case .modelNotInstalled: return "swarm_model_not_installed"
        case .updateRequired: return "swarm_update_required"
        case .poolNotFound: return "swarm_pool_not_found"
        case .poolBusy: return "swarm_pool_busy"
        case .leaseLost: return "swarm_lease_lost"
        case .engine: return "swarm_engine_error"
        case .invalidHuggingFaceLink: return "swarm_invalid_model_link"
        case .invalidToolCall: return "swarm_invalid_tool_call"
        case .rejected: return "swarm_invalid_request"
        case .notFound: return "swarm_not_found"
        case .internalError: return "swarm_internal_error"
        case .cancelled: return "request_cancelled"
        case .transport: return "swarm_transport_error"
        }
    }

    /// HTTP status the API returns for this failure.
    var httpStatus: Int {
        switch self {
        case .poolBusy, .unavailable, .nodeOffline, .noDirectPath, .nodePaused, .leaseLost, .updateRequired:
            return 503
        case .poolNotFound, .nodeNotFound, .modelNotInstalled: return 404
        case .fitRefused, .capExceeded, .invalidHuggingFaceLink, .notPaired: return 400
        case .engine(let status, _): return (400 ... 599).contains(status) ? status : 502
        case .cancelled: return 499
        case .transport, .invalidToolCall: return 502
        case .rejected: return 400
        case .notFound: return 404
        case .internalError: return 500
        }
    }

    /// Whether a request that failed with this error may be retried on
    /// another node of the same pool (before any output reached the caller).
    var isRetryableOnAnotherNode: Bool {
        switch self {
        case .leaseLost, .nodeOffline, .noDirectPath, .nodePaused, .transport, .updateRequired:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L("Osaurus Swarm isn't running.")
        case .notPaired:
            return L("That device isn't paired with this Osaurus.")
        case .nodeNotFound(let id):
            return String(format: L("Swarm node %@ is not paired with this Osaurus."), SwarmText.inert(id))
        case .nodeOffline(let node):
            return String(format: L("Swarm node %@ is offline."), SwarmText.inert(node))
        case .noDirectPath(let node):
            return String(
                format: L("Swarm node %@ has no direct network path. Swarm only uses direct connections."),
                SwarmText.inert(node)
            )
        case .nodePaused(let node, let reason):
            return String(format: L("Swarm node %@ is paused: %@"), SwarmText.inert(node), SwarmText.inert(reason))
        case .fitRefused(let reason):
            return SwarmText.inert(reason)
        case .capExceeded(let cap, let needed, let limit):
            let fmt = ByteCountFormatter()
            fmt.countStyle = .memory
            return String(
                format: L("Needs %@, the node's %@ cap is %@."),
                fmt.string(fromByteCount: needed),
                SwarmText.inert(cap),
                fmt.string(fromByteCount: limit)
            )
        case .modelNotInstalled(let model, let node):
            if node.isEmpty {
                return String(format: L("Model not installed: %@"), SwarmText.inert(model))
            }
            return String(
                format: L("%@ isn't installed on Swarm node %@."),
                SwarmText.inert(model),
                SwarmText.inert(node)
            )
        case .updateRequired(let side):
            return side == "node"
                ? L("The Swarm node needs an update to work with this Osaurus.")
                : L("Osaurus needs an update to work with this Swarm node.")
        case .poolNotFound(let pool):
            return String(format: L("Swarm pool %@ doesn't exist."), SwarmText.inert(pool))
        case .poolBusy(let pool, let waited):
            return String(
                format: L(
                    "No Swarm node in %@ became free within %d seconds (swarm_pool_busy). Try again, add nodes to the pool, or raise its max queue wait."
                ),
                pool,
                waited
            )
        case .leaseLost(let reason):
            return String(
                format: L("The Swarm node stopped serving this request (lease lost): %@"),
                SwarmText.inert(reason)
            )
        case .engine(let status, let message):
            return String(
                format: L("The Swarm node's engine refused the request (%d): %@"),
                status,
                SwarmText.inert(message)
            )
        case .rejected(let detail):
            return String(format: L("The Swarm library refused the request: %@"), SwarmText.inert(detail))
        case .notFound(let detail):
            return String(format: L("Not found in the swarm: %@"), SwarmText.inert(detail))
        case .internalError(let detail):
            return String(format: L("Osaurus Swarm failed: %@"), SwarmText.inert(detail))
        case .invalidToolCall(let name, let reason):
            switch reason {
            case .noToolsOffered:
                return String(
                    format: L("The Swarm node called %@ but this request offered no tools. Nothing was run."),
                    SwarmText.inert(name)
                )
            case .notOffered:
                return String(
                    format: L("The Swarm node called %@, which this request did not offer. Nothing was run."),
                    SwarmText.inert(name)
                )
            case .argumentsNotObject:
                return String(
                    format: L("The Swarm node's arguments for %@ are not a JSON object. Nothing was run."),
                    SwarmText.inert(name)
                )
            }
        case .invalidHuggingFaceLink(let text):
            return String(format: L("%@ isn't a Hugging Face model link or org/repo id."), SwarmText.inert(text))
        case .cancelled:
            return L("The Swarm request was cancelled.")
        case .transport(let message):
            return String(format: L("Swarm connection error: %@"), SwarmText.inert(message))
        }
    }
}

// MARK: - Peer text

/// Text a node supplies (its suggested name, model ids, pause reasons, engine
/// and transport messages) is untrusted. Settings renders it verbatim, never
/// as a catalog key. Error text can also reach surfaces that render
/// Markdown (a chat error turn), where a blacklist cannot catch every
/// autolink (bare domains, emails, `tel:` and custom schemes), so peer text
/// is quoted as an inline code span instead: renderers never linkify or
/// format inside one. Backticks (which would close the span), control
/// characters and line breaks are removed.
enum SwarmText {
    static let maximumLength = 300

    static func inert(_ text: String) -> String {
        var body = ""
        body.reserveCapacity(min(text.count, maximumLength))
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace || character.isNewline {
                if !lastWasSpace, !body.isEmpty { body.append(" ") }
                lastWasSpace = true
                continue
            }
            if character == "`" { continue }
            if character.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || $0.value == 0xFFFE || $0.value == 0xFFFF
            }) {
                continue
            }
            body.append(character)
            lastWasSpace = false
            if body.count >= maximumLength { break }
        }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "" : "`\(trimmed)`"
    }
}
