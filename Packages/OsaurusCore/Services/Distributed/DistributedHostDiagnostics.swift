//
//  DistributedHostDiagnostics.swift
//  osaurus
//
//  Read-only parsers for the OS reports the Distributed Inference panel shows.
//  Every parser is pure (text/JSON in, value out) so it can be tested against
//  captured fixtures from real Macs. None of these types start a rank worker,
//  change networking, or claim tensor-parallel readiness.
//

import Darwin
import Foundation

// MARK: - Thunderbolt topology

/// A Mac (or other host with its own Thunderbolt domain) directly cabled to one
/// of this Mac's Thunderbolt ports. The domain UUID is the physical-link
/// evidence: a peer that advertises the same UUID as its own domain is on the
/// other end of this exact cable.
struct ThunderboltPeerHost: Equatable, Sendable {
    let name: String
    let model: String?
    let domainUUID: String
    /// The peer offers Thunderbolt IP networking (`service_ip`).
    let offersIPService: Bool
}

/// One Thunderbolt/USB4 bus (physical receptacle group) on this Mac.
struct ThunderboltPort: Equatable, Sendable, Identifiable {
    var id: String { busName }
    let busName: String
    let ownDomainUUID: String?
    /// `receptacle_id_key`; maps to the "Thunderbolt N" hardware port.
    let receptacle: Int?
    /// OS-reported rate, e.g. "80 Gb/s" when linked or "Up to 120 Gb/s" idle.
    let speed: String?
    let connected: Bool
    /// Hosts cabled directly to this receptacle.
    let peers: [ThunderboltPeerHost]
    /// Directly attached non-host devices (docks, enclosures). Hosts reached
    /// through a dock are listed here too: they are not a direct cable.
    let devices: [String]

    var hardwarePortName: String? { receptacle.map { "Thunderbolt \($0)" } }

    /// Link rate in Gb/s when the OS reports a current (not "Up to") rate.
    var linkGbps: Int? {
        guard connected, let speed, !speed.lowercased().hasPrefix("up to") else { return nil }
        return Int(speed.prefix { $0.isNumber })
    }
}

enum ThunderboltTopology {
    /// Parses `system_profiler -json SPThunderboltDataType`. Returns nil when
    /// the payload is not the expected shape, so callers show "unreadable"
    /// rather than "no ports".
    static func parse(_ data: Data) -> [ThunderboltPort]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let buses = root["SPThunderboltDataType"] as? [[String: Any]]
        else { return nil }
        return buses.compactMap { bus -> ThunderboltPort? in
            guard let name = bus["_name"] as? String else { return nil }
            let receptacle = bus["receptacle_1_tag"] as? [String: Any]
            var peers: [ThunderboltPeerHost] = []
            var devices: [String] = []
            for item in bus["_items"] as? [[String: Any]] ?? [] {
                let itemName = (item["_name"] as? String) ?? (item["device_name_key"] as? String) ?? "Device"
                if let uuid = item["domain_uuid_key"] as? String, !uuid.isEmpty {
                    let services = item["services_title"] as? [[String: Any]] ?? []
                    peers.append(
                        ThunderboltPeerHost(
                            name: itemName,
                            model: item["device_name_key"] as? String,
                            domainUUID: uuid.uppercased(),
                            offersIPService: services.contains { ($0["_name"] as? String) == "service_ip" }
                        )
                    )
                } else {
                    devices.append(itemName)
                    devices.append(contentsOf: nestedHostNames(item).map { "\($0) (via \(itemName))" })
                }
            }
            return ThunderboltPort(
                busName: name,
                ownDomainUUID: (bus["domain_uuid_key"] as? String)?.uppercased(),
                receptacle: (receptacle?["receptacle_id_key"] as? String).flatMap { Int($0) },
                speed: receptacle?["current_speed_key"] as? String,
                connected: (receptacle?["receptacle_status_key"] as? String) == "receptacle_connected",
                peers: peers,
                devices: devices
            )
        }
        .sorted { ($0.receptacle ?? .max, $0.busName) < ($1.receptacle ?? .max, $1.busName) }
    }

    private static func nestedHostNames(_ item: [String: Any]) -> [String] {
        (item["_items"] as? [[String: Any]] ?? []).flatMap { child -> [String] in
            let here = child["domain_uuid_key"] == nil ? [] : [(child["_name"] as? String) ?? "Host"]
            return here + nestedHostNames(child)
        }
    }
}

// MARK: - Hardware ports, RDMA, addresses

enum HardwarePortMap {
    /// Parses `networksetup -listallhardwareports` into port name → BSD device.
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var port: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                port = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:"), let current = port {
                result[current] = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                port = nil
            }
        }
        return result
    }
}

enum RDMAState: Equatable, Sendable {
    case enabled
    case disabled
    /// `rdma_ctl` is absent: this macOS release has no RDMA over Thunderbolt.
    case unsupported
    case unknown(String)

    static func parse(rdmaCtlStatus output: String?) -> RDMAState {
        guard let output else { return .unknown("rdma_ctl did not answer") }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "enabled": return .enabled
        case "disabled": return .disabled
        case let other: return .unknown(other.isEmpty ? "empty rdma_ctl status" : other)
        }
    }
}

struct RDMADevice: Equatable, Sendable {
    let name: String
    /// e.g. `PORT_ACTIVE`, `PORT_DOWN`; nil when `ibv_devinfo` did not report it.
    var portState: String?
    var linkLayer: String?

    /// `rdma_en6` → `en6`.
    var interface: String? { name.hasPrefix("rdma_") ? String(name.dropFirst(5)) : nil }
    var isActive: Bool { portState == "PORT_ACTIVE" }
}

enum RDMADeviceList {
    /// Parses `ibv_devices`: a two-line header then `name  guid` rows.
    static func parse(ibvDevices text: String) -> [RDMADevice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first.map(String.init), first != "device", !first.hasPrefix("-")
            else { return nil }
            return RDMADevice(name: first)
        }
    }

    /// Merges per-port state from `ibv_devinfo` into `devices`. Devices only
    /// present in `ibv_devinfo` are appended.
    static func merge(ibvDevinfo text: String, into devices: [RDMADevice]) -> [RDMADevice] {
        var result = devices
        var current: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "hca_id":
                if let index = result.firstIndex(where: { $0.name == parts[1] }) {
                    current = index
                } else {
                    result.append(RDMADevice(name: parts[1]))
                    current = result.count - 1
                }
            case "state":
                if let current { result[current].portState = parts[1].split(separator: " ").first.map(String.init) }
            case "link_layer":
                if let current { result[current].linkLayer = parts[1] }
            default: break
            }
        }
        return result
    }
}

enum InterfaceAddresses {
    /// Numeric IPv4/IPv6 addresses per BSD interface, via `getifaddrs`.
    static func read() -> [String: [String]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: [String]] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard let text = String(bytes: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
            else { continue }
            result[name, default: []].append(text)
        }
        return result
    }
}

// MARK: - Link summary

/// What this Mac can say about one Thunderbolt receptacle without asking a
/// peer. `cabledMac` is physical evidence of a cable to another Mac; it is not
/// RDMA readiness and not a rank.
struct ThunderboltLinkSummary: Equatable, Sendable, Identifiable {
    var id: String { port.busName }
    let port: ThunderboltPort
    let interface: String?
    let rdmaDevice: RDMADevice?
    let addresses: [String]

    var cabledMac: ThunderboltPeerHost? { port.peers.first }

    static func build(
        ports: [ThunderboltPort],
        hardwarePorts: [String: String],
        rdmaDevices: [RDMADevice],
        addresses: [String: [String]]
    ) -> [ThunderboltLinkSummary] {
        ports.map { port in
            let interface = port.hardwarePortName.flatMap { hardwarePorts[$0] }
            return ThunderboltLinkSummary(
                port: port,
                interface: interface,
                rdmaDevice: interface.flatMap { name in rdmaDevices.first { $0.interface == name } },
                addresses: interface.flatMap { addresses[$0] } ?? []
            )
        }
    }
}

// MARK: - Bounded read-only command runner

/// Runs one fixed, read-only system command with a deadline. Output goes to a
/// private temporary file rather than a pipe, so a full pipe cannot deadlock
/// the timeout; the file is removed before returning. Only the process this
/// runner started is ever signalled.
enum DiagnosticCommand {
    struct Result: Sendable {
        let output: Data?
        let exitStatus: Int32?
        let timedOut: Bool
        let missing: Bool
    }

    static let maximumOutputBytes = 1024 * 1024

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return Result(output: nil, exitStatus: nil, timedOut: false, missing: true)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-distributed-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
            let output = try? FileHandle(forWritingTo: url)
        else { return Result(output: nil, exitStatus: nil, timedOut: false, missing: false) }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: url)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            return Result(output: nil, exitStatus: nil, timedOut: false, missing: false)
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            return Result(output: nil, exitStatus: nil, timedOut: true, missing: false)
        }
        let data = try? Data(contentsOf: url)
        return Result(
            output: data.flatMap { $0.count <= maximumOutputBytes ? $0 : nil },
            exitStatus: process.terminationStatus,
            timedOut: false,
            missing: false
        )
    }

    /// Output only when the command exited 0.
    static func text(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let result = run(executable, arguments, timeout: timeout)
        guard result.exitStatus == 0, let data = result.output else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
