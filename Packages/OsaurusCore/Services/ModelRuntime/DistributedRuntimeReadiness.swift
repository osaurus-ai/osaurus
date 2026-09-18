// Copyright © 2026 osaurus.

import Foundation

public enum DistributedTensorAddressClass: String, Codable, Sendable, Equatable, Hashable {
    case thunderboltLoopback
    case thunderboltDirect
    case tailscaleControl
    case localLoopback
    case privateOther
    case linkLocal
    case unknown

    public var isAllowedForTensorDataPlane: Bool {
        switch self {
        case .thunderboltLoopback, .thunderboltDirect:
            return true
        case .tailscaleControl, .localLoopback, .privateOther, .linkLocal, .unknown:
            return false
        }
    }
}

public struct DistributedTensorEndpoint: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String
    public let host: String
    public let port: UInt16?
    public let addressClass: DistributedTensorAddressClass

    public init(_ rawValue: String) {
        let parsed = Self.parse(rawValue)
        self.rawValue = rawValue
        self.host = parsed.host
        self.port = parsed.port
        self.addressClass = Self.classify(host: parsed.host)
    }

    public var isAllowedForTensorDataPlane: Bool {
        addressClass.isAllowedForTensorDataPlane
    }

    enum CodingKeys: String, CodingKey {
        case rawValue = "raw_value"
        case host
        case port
        case addressClass = "address_class"
    }

    private static func parse(_ rawValue: String) -> (host: String, port: UInt16?) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        if let components = URLComponents(string: trimmed),
           components.scheme != nil,
           let host = components.host {
            return (host, components.port.flatMap(UInt16.init))
        }

        if trimmed.hasPrefix("["),
           let closeIndex = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIndex])
            let rest = trimmed[trimmed.index(after: closeIndex)...]
            let port = rest.hasPrefix(":") ? UInt16(rest.dropFirst()) : nil
            return (host, port)
        }

        if trimmed.filter({ $0 == ":" }).count == 1,
           let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<colon])
            let port = UInt16(trimmed[trimmed.index(after: colon)...])
            if port != nil {
                return (host, port)
            }
        }

        return (trimmed, nil)
    }

    private static func classify(host: String) -> DistributedTensorAddressClass {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if lower == "localhost" || lower == "::1" {
            return .localLoopback
        }

        let parts = lower.split(separator: ".")
        guard parts.count == 4,
              let a = Int(parts[0]),
              let b = Int(parts[1]),
              let c = Int(parts[2]),
              let d = Int(parts[3]),
              (0...255).contains(a),
              (0...255).contains(b),
              (0...255).contains(c),
              (0...255).contains(d)
        else {
            return .unknown
        }

        switch (a, b, c) {
        case (10, 20, 0):
            return .thunderboltLoopback
        case (10, 10, _):
            return .thunderboltDirect
        case (100, _, _):
            return .tailscaleControl
        case (127, _, _):
            return .localLoopback
        case (169, 254, _):
            return .linkLocal
        default:
            if a == 10
                || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168) {
                return .privateOther
            }
            return .unknown
        }
    }
}

public enum DistributedRuntimeReadinessLevel: String, Codable, Sendable, Equatable, Hashable {
    case info
    case warning
    case error
}

public struct DistributedRuntimeFinding: Codable, Sendable, Equatable, Hashable {
    public let level: DistributedRuntimeReadinessLevel
    public let code: String
    public let message: String

    public init(level: DistributedRuntimeReadinessLevel, code: String, message: String) {
        self.level = level
        self.code = code
        self.message = message
    }
}

public struct DistributedIBVDeviceMatrix: Codable, Sendable, Equatable, Hashable {
    public let rows: [[String?]]

    public init(rows: [[String?]]) {
        self.rows = rows
    }

    public init(jsonData: Data) throws {
        self.rows = try JSONDecoder().decode([[String?]].self, from: jsonData)
    }

    public func findings(worldSize: Int) -> [DistributedRuntimeFinding] {
        var out: [DistributedRuntimeFinding] = []

        if rows.count != worldSize {
            out.append(.init(
                level: .error,
                code: "ibv_matrix_world_size_mismatch",
                message: "MLX_IBV_DEVICES has \(rows.count) rows but world size is \(worldSize)."
            ))
        }

        for (rowIndex, row) in rows.enumerated() {
            if row.count != rows.count {
                out.append(.init(
                    level: .error,
                    code: "ibv_matrix_not_square",
                    message: "MLX_IBV_DEVICES row \(rowIndex) has \(row.count) entries, expected \(rows.count)."
                ))
            }
        }

        let limit = min(rows.count, worldSize)
        for sourceRank in 0 ..< limit {
            let row = rows[sourceRank]
            let peerLimit = min(row.count, worldSize)
            for targetRank in 0 ..< peerLimit {
                let device = row[targetRank]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if sourceRank == targetRank {
                    if !device.isEmpty {
                        out.append(.init(
                            level: .error,
                            code: "ibv_matrix_self_slot_not_empty",
                            message: "MLX_IBV_DEVICES[\(sourceRank)][\(targetRank)] must be null or empty for the self slot."
                        ))
                    }
                } else if device.isEmpty {
                    out.append(.init(
                        level: .error,
                        code: "ibv_matrix_peer_device_missing",
                        message: "MLX_IBV_DEVICES[\(sourceRank)][\(targetRank)] is missing the peer RDMA device name."
                    ))
                }
            }
        }

        if out.isEmpty {
            out.append(.init(
                level: .info,
                code: "ibv_matrix_valid",
                message: "MLX_IBV_DEVICES matrix matches the expected world size and self-slot convention."
            ))
        }

        return out
    }

    public func isValid(worldSize: Int) -> Bool {
        findings(worldSize: worldSize).allSatisfy { $0.level != .error }
    }
}

public struct DistributedRuntimeReadinessReport: Codable, Sendable, Equatable {
    public let endpoints: [DistributedTensorEndpoint]
    public let worldSize: Int
    public let librdmaLoadable: Bool?
    public let jacclAvailable: Bool?
    public let ibvDevicesConfigured: Bool?
    public let findings: [DistributedRuntimeFinding]

    public var readinessState: DistributedRuntimeState {
        if findings.contains(where: { $0.level == .error }) {
            return .blocked
        }
        if findings.contains(where: { $0.level == .warning }) {
            return .partial
        }
        return .ready
    }

    public var isRunnable: Bool {
        readinessState == .ready
    }

    enum CodingKeys: String, CodingKey {
        case endpoints
        case worldSize = "world_size"
        case librdmaLoadable = "librdma_loadable"
        case jacclAvailable = "jaccl_available"
        case ibvDevicesConfigured = "ibv_devices_configured"
        case findings
        case readinessState = "readiness_state"
        case isRunnable = "is_runnable"
    }

    public init(
        endpoints: [DistributedTensorEndpoint],
        worldSize: Int,
        librdmaLoadable: Bool?,
        jacclAvailable: Bool?,
        ibvDevicesConfigured: Bool?,
        findings: [DistributedRuntimeFinding]
    ) {
        self.endpoints = endpoints
        self.worldSize = worldSize
        self.librdmaLoadable = librdmaLoadable
        self.jacclAvailable = jacclAvailable
        self.ibvDevicesConfigured = ibvDevicesConfigured
        self.findings = findings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.endpoints = try container.decode([DistributedTensorEndpoint].self, forKey: .endpoints)
        self.worldSize = try container.decode(Int.self, forKey: .worldSize)
        self.librdmaLoadable = try container.decodeIfPresent(Bool.self, forKey: .librdmaLoadable)
        self.jacclAvailable = try container.decodeIfPresent(Bool.self, forKey: .jacclAvailable)
        self.ibvDevicesConfigured = try container.decodeIfPresent(Bool.self, forKey: .ibvDevicesConfigured)
        self.findings = try container.decode([DistributedRuntimeFinding].self, forKey: .findings)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoints, forKey: .endpoints)
        try container.encode(worldSize, forKey: .worldSize)
        try container.encodeIfPresent(librdmaLoadable, forKey: .librdmaLoadable)
        try container.encodeIfPresent(jacclAvailable, forKey: .jacclAvailable)
        try container.encodeIfPresent(ibvDevicesConfigured, forKey: .ibvDevicesConfigured)
        try container.encode(findings, forKey: .findings)
        try container.encode(readinessState, forKey: .readinessState)
        try container.encode(isRunnable, forKey: .isRunnable)
    }
}

public enum DistributedRuntimeState: String, Codable, Sendable, Equatable, Hashable {
    case off
    case discovering
    case candidate
    case partial
    case blocked
    case ready
    case running
}

public enum DistributedNodeRole: String, Codable, Sendable, Equatable, Hashable {
    case coordinator
    case rankWorker
    case localOnly
}

public struct DistributedNodeDiscoveryRecord: Codable, Sendable, Equatable {
    public let nodeID: String
    public let deviceName: String
    public let osaurusVersion: String?
    public let osaurusCommit: String?
    public let vmlxPin: String?
    public let distributedCapabilityVersion: Int
    public let roles: [DistributedNodeRole]
    public let controlEndpoints: [String]
    public let dataPlaneCandidates: [DistributedTensorEndpoint]
    public let readiness: DistributedRuntimeReadinessReport

    public init(
        nodeID: String,
        deviceName: String,
        osaurusVersion: String? = nil,
        osaurusCommit: String? = nil,
        vmlxPin: String? = nil,
        distributedCapabilityVersion: Int = 1,
        roles: [DistributedNodeRole],
        controlEndpoints: [String],
        dataPlaneCandidates: [String],
        readiness: DistributedRuntimeReadinessReport
    ) {
        self.nodeID = nodeID
        self.deviceName = deviceName
        self.osaurusVersion = osaurusVersion
        self.osaurusCommit = osaurusCommit
        self.vmlxPin = vmlxPin
        self.distributedCapabilityVersion = distributedCapabilityVersion
        self.roles = roles
        self.controlEndpoints = controlEndpoints
        self.dataPlaneCandidates = dataPlaneCandidates.map(DistributedTensorEndpoint.init)
        self.readiness = readiness
    }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case deviceName = "device_name"
        case osaurusVersion = "osaurus_version"
        case osaurusCommit = "osaurus_commit"
        case vmlxPin = "vmlx_pin"
        case distributedCapabilityVersion = "distributed_capability_version"
        case roles
        case controlEndpoints = "control_endpoints"
        case dataPlaneCandidates = "data_plane_candidates"
        case readiness
    }
}

public enum DistributedRuntimeReadiness {
    public static func evaluate(
        dataPlaneAddresses: [String],
        worldSize: Int,
        librdmaLoadable: Bool? = nil,
        jacclAvailable: Bool? = nil,
        ibvDevicesConfigured: Bool? = nil,
        ibvDeviceMatrix: DistributedIBVDeviceMatrix? = nil
    ) -> DistributedRuntimeReadinessReport {
        let endpoints = orderedUnique(dataPlaneAddresses).map(DistributedTensorEndpoint.init)
        var findings: [DistributedRuntimeFinding] = []

        if worldSize <= 1 {
            findings.append(.init(
                level: .error,
                code: "single_rank_not_tp",
                message: "Tensor-parallel readiness requires at least two ranks; size-1 fallback is not proof."
            ))
        }

        if endpoints.isEmpty {
            findings.append(.init(
                level: .warning,
                code: "missing_data_plane_addresses",
                message: "No tensor data-plane addresses were supplied."
            ))
        }

        for endpoint in endpoints {
            switch endpoint.addressClass {
            case .thunderboltLoopback, .thunderboltDirect:
                findings.append(.init(
                    level: .info,
                    code: "thunderbolt_data_plane_address",
                    message: "\(endpoint.host) is accepted as a Thunderbolt tensor data-plane address."
                ))
            case .tailscaleControl:
                findings.append(.init(
                    level: .error,
                    code: "tailscale_data_plane_forbidden",
                    message: "\(endpoint.host) is Tailscale/control-plane only and must not carry tensor-parallel data."
                ))
            case .localLoopback:
                findings.append(.init(
                    level: .warning,
                    code: "loopback_not_multirank_proof",
                    message: "\(endpoint.host) is local loopback and cannot prove multi-rank tensor parallelism."
                ))
            case .privateOther, .linkLocal, .unknown:
                findings.append(.init(
                    level: .warning,
                    code: "unproven_data_plane_address",
                    message: "\(endpoint.host) is \(endpoint.addressClass.rawValue), not a proven Thunderbolt tensor data-plane address."
                ))
            }
        }

        if librdmaLoadable == false {
            findings.append(.init(
                level: .error,
                code: "librdma_unavailable",
                message: "librdma is not loadable on this host."
            ))
        }

        if jacclAvailable == false {
            findings.append(.init(
                level: .error,
                code: "jaccl_unavailable",
                message: "JACCL is not available; distributed execution must stay disabled."
            ))
        }

        if ibvDevicesConfigured == false {
            findings.append(.init(
                level: .error,
                code: "ibv_devices_missing",
                message: "MLX_IBV_DEVICES is not configured for the tensor-parallel ranks."
            ))
        }

        if let ibvDeviceMatrix {
            findings.append(contentsOf: ibvDeviceMatrix.findings(worldSize: worldSize))
        }

        return DistributedRuntimeReadinessReport(
            endpoints: endpoints,
            worldSize: worldSize,
            librdmaLoadable: librdmaLoadable,
            jacclAvailable: jacclAvailable,
            ibvDevicesConfigured: ibvDevicesConfigured,
            findings: findings
        )
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}
