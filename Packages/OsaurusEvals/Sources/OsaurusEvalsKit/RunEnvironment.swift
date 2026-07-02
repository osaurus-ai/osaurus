//
//  RunEnvironment.swift
//  OsaurusEvalsKit
//
//  Provenance for a single eval run — the block that makes a CROWDSOURCED
//  result trustworthy and comparable. A pass-rate from a stranger's machine
//  only means something if you also know: which hardware (chip + RAM band),
//  which macOS / Osaurus build, which exact set of cases (catalogHash), which
//  judge graded the LLM-judged suites, and which KV regime was in force.
//
//  Everything is optional so a result that couldn't sample a field reads as
//  "unknown" rather than a fabricated value, and so older reports (written
//  before this block existed) still decode.
//

import Darwin
import Foundation
import IOKit.ps

public struct RunEnvironment: Codable, Sendable, Equatable {
    /// CPU brand string, e.g. "Apple M3 Max" (Apple Silicon) or the Intel
    /// brand; falls back to `hw.model` ("Mac15,6") when the brand is absent.
    public let chip: String?
    /// Total physical RAM in MB — the headline "does it fit?" axis for Mac.
    public let totalRamMb: Int?
    /// Logical CPU cores (informational).
    public let cpuCores: Int?
    /// macOS version "major.minor.patch", e.g. "26.2.0".
    public let osVersion: String?
    /// Osaurus/app `CFBundleShortVersionString` when running inside the app
    /// bundle; usually nil for the standalone CLI (use `commit` there).
    public let osaurusVersion: String?
    /// Short git commit the run was measured against, from
    /// `OSAURUS_EVALS_COMMIT` (the contribute flow exports it).
    public let commit: String?
    /// Run model id (mirrors the report's `modelId`, kept here so the env
    /// block is self-contained when copied into a leaderboard).
    public let runModel: String?
    /// Resolved judge for LLM-judged suites: a `provider/name` id, or
    /// "self-judge" when the run model graded itself (weaker signal).
    public let judge: String?
    /// KV-cache regime in force, self-declared via `OSAURUS_EVALS_KV_REGIME`
    /// (e.g. "memory-only", "disk-l2", "paged"). nil when not specified.
    public let kvRegime: String?
    /// Stable hash of the exact case ids evaluated — the comparability key.
    /// Two runs with the same `catalogHash` graded the same definitions.
    public let catalogHash: String?
    /// Number of cases that fed `catalogHash` (context for the hash).
    public let caseCount: Int?
    /// SoC thermal pressure at capture time (end of the run):
    /// "nominal" / "fair" / "serious" / "critical". Sequential suites heat
    /// the SoC, so a "serious" here says later columns may be
    /// thermally depressed — an order effect no per-case metric shows.
    public let thermalState: String?
    /// macOS Low Power Mode at capture time — caps CPU/GPU clocks, so
    /// perf rows from a low-power run aren't comparable to normal ones.
    public let lowPowerMode: Bool?
    /// Providing power source at capture time: "AC" / "battery" / "UPS".
    /// Apple Silicon throttles harder on battery under sustained load.
    public let powerSource: String?

    public init(
        chip: String? = nil,
        totalRamMb: Int? = nil,
        cpuCores: Int? = nil,
        osVersion: String? = nil,
        osaurusVersion: String? = nil,
        commit: String? = nil,
        runModel: String? = nil,
        judge: String? = nil,
        kvRegime: String? = nil,
        catalogHash: String? = nil,
        caseCount: Int? = nil,
        thermalState: String? = nil,
        lowPowerMode: Bool? = nil,
        powerSource: String? = nil
    ) {
        self.chip = chip
        self.totalRamMb = totalRamMb
        self.cpuCores = cpuCores
        self.osVersion = osVersion
        self.osaurusVersion = osaurusVersion
        self.commit = commit
        self.runModel = runModel
        self.judge = judge
        self.kvRegime = kvRegime
        self.catalogHash = catalogHash
        self.caseCount = caseCount
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.powerSource = powerSource
    }

    /// Capture the live environment for a run over `caseIDs` against
    /// `runModel`. Hardware/OS are probed from the host; `commit`/`kvRegime`
    /// are read from env vars the contribute flow sets; the judge is resolved
    /// exactly as the runners do so a self-judged contribution is flagged.
    public static func current(
        caseIDs: [String],
        runModel: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RunEnvironment {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let judgeResolution = EvalJudgeModel.resolve(runModelId: runModel, environment: environment)
        return RunEnvironment(
            chip: sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model"),
            totalRamMb: Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)),
            cpuCores: ProcessInfo.processInfo.activeProcessorCount,
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            osaurusVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            commit: nonEmpty(environment["OSAURUS_EVALS_COMMIT"]),
            runModel: runModel,
            judge: judgeResolution.isSelfJudge ? "self-judge" : judgeResolution.modelId,
            kvRegime: nonEmpty(environment["OSAURUS_EVALS_KV_REGIME"]),
            catalogHash: catalogHash(forCaseIDs: caseIDs),
            caseCount: caseIDs.isEmpty ? nil : Set(caseIDs).count,
            thermalState: thermalStateLabel(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            powerSource: providingPowerSource()
        )
    }

    /// Human label for `ProcessInfo.ThermalState` (stable strings — these
    /// land in committed snapshots/history).
    static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// "AC" / "battery" / "UPS" from IOKit's power-source registry, nil
    /// when the query fails (e.g. sandboxed test runners).
    static func providingPowerSource() -> String? {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String? else {
            return nil
        }
        switch type {
        case kIOPMACPowerKey: return "AC"
        case kIOPMBatteryPowerKey: return "battery"
        case kIOPMUPSPowerKey: return "UPS"
        default: return type.isEmpty ? nil : type
        }
    }

    /// FNV-1a hash of the sorted, de-duplicated case ids. Deterministic and
    /// dependency-free — same case set ⇒ same 16-hex-char key on any machine.
    public static func catalogHash(forCaseIDs ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        let joined = Set(ids).sorted().joined(separator: "\n")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// One-line human summary for markdown footers / console.
    public var summary: String {
        var parts: [String] = []
        if let chip { parts.append(chip) }
        if let totalRamMb { parts.append("\(totalRamMb / 1024)GB") }
        if let osVersion { parts.append("macOS \(osVersion)") }
        if let osaurusVersion { parts.append("osaurus \(osaurusVersion)") }
        if let commit { parts.append("@\(commit)") }
        if let kvRegime { parts.append("kv=\(kvRegime)") }
        if let judge { parts.append("judge=\(judge)") }
        if let catalogHash { parts.append("catalog=\(catalogHash)") }
        // Perf-comparability caveats: only shown when they'd actually skew
        // numbers (nominal/AC is the assumed baseline, so it stays quiet).
        if let thermalState, thermalState != "nominal" {
            parts.append("thermal=\(thermalState)")
        }
        if lowPowerMode == true { parts.append("low-power-mode") }
        if let powerSource, powerSource != "AC" { parts.append("power=\(powerSource)") }
        return parts.isEmpty ? "(no environment captured)" : parts.joined(separator: " · ")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Read a string sysctl by name (e.g. "machdep.cpu.brand_string").
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        if let nul = buffer.firstIndex(of: 0) { buffer.removeSubrange(nul...) }
        let value = String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
