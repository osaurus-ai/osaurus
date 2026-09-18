//
//  SandboxStartupMetrics.swift
//  osaurus
//
//  Structured startup timing for the sandbox runtime: cold-start,
//  warm-start, VM-ready, and first-agent-ready phase samples persisted
//  locally (full fidelity, `~/.osaurus/container/startup-metrics.json`)
//  so optimization work is evidence-based. Only coarse latency buckets
//  ever leave the machine, and only through the consent-gated
//  `TelemetryService` — never raw durations, paths, or agent identity.
//

import Foundation

#if os(macOS)

    /// One boot's phase timings, in seconds. `nil` phases were skipped
    /// (e.g. `containerCreate` on a warm restart).
    public struct SandboxBootSample: Codable, Sendable, Equatable {
            public enum BootKind: String, Codable, Sendable {
                /// Full image unpack (first run or invalidated cache).
                case cold
                /// Persisted rootfs reused, no unpack.
                case warm
                /// Warm attempt failed and fell back to a cold rebuild.
                case warmFallback
                /// Rootfs cloned (copy-on-write) from the immutable base
                /// template — no unpack, no reuse of a booted filesystem.
                case template
            }

        public let kind: BootKind
        public let startedAt: Date
        /// Kernel + initfs + image resolution (concurrent futures).
        public let assetResolution: Double?
        /// `manager.create` — rootfs unpack (cold paths only).
        public let containerCreate: Double?
        /// `container.create()` + `container.start()` — the VM boot.
        public let vmBoot: Double?
        /// Post-boot in-guest setup (`configureSandbox`).
        public let configure: Double?
        /// Provision entry → status `.running`.
        public let totalToRunning: Double
        /// Boot completion → first agent fully provisioned (user, token,
        /// SOUL seed). Stamped after the fact by
        /// `SandboxStartupMetricsStore.recordFirstAgentReady`.
        public var firstAgentReady: Double?

        public init(
            kind: BootKind,
            startedAt: Date,
            assetResolution: Double?,
            containerCreate: Double?,
            vmBoot: Double?,
            configure: Double?,
            totalToRunning: Double,
            firstAgentReady: Double? = nil
        ) {
            self.kind = kind
            self.startedAt = startedAt
            self.assetResolution = assetResolution
            self.containerCreate = containerCreate
            self.vmBoot = vmBoot
            self.configure = configure
            self.totalToRunning = totalToRunning
            self.firstAgentReady = firstAgentReady
        }
    }

    /// Sanitized startup/provisioning failure record. These closed enum-like
    /// tokens deliberately exclude error messages, paths, domains,
    /// environment values, and agent identity.
    public struct SandboxStartupFailureSample: Codable, Sendable, Equatable {
        public let recordedAt: Date
        public let category: String
        public let backend: String
        public let phase: String
        /// Closed error-class token (`SandboxToolRegistrar.failureErrorClass`).
        /// Optional so samples persisted before the field existed still
        /// decode.
        public let errorClass: String?
        /// Closed `SandboxToolRegistrar.RegistrationTrigger` raw value.
        public let trigger: String?
        /// `true` when the attempt was a first-run cold provision
        /// (`setupComplete == false`), `false` for a warm restart.
        public let coldStart: Bool?

        public init(
            recordedAt: Date = Date(),
            category: String,
            backend: String,
            phase: String,
            errorClass: String? = nil,
            trigger: String? = nil,
            coldStart: Bool? = nil
        ) {
            self.recordedAt = recordedAt
            self.category = category
            self.backend = backend
            self.phase = phase
            self.errorClass = errorClass
            self.trigger = trigger
            self.coldStart = coldStart
        }
    }

    /// Ring-buffer persistence for boot samples. Local-only diagnostics;
    /// surfaced in the Sandbox settings panel and used by the opt-in
    /// integration benchmark to compare cold vs warm boots.
    public enum SandboxStartupMetricsStore {
        static let maxSamples = 20

        static func fileURL() -> URL {
            OsaurusPaths.container().appendingPathComponent("startup-metrics.json")
        }

        static func failureFileURL() -> URL {
            OsaurusPaths.container().appendingPathComponent("startup-failures.json")
        }

        public static func load() -> [SandboxBootSample] {
            guard let data = try? Data(contentsOf: fileURL()) else { return [] }
            return (try? JSONDecoder().decode([SandboxBootSample].self, from: data)) ?? []
        }

        public static func record(_ sample: SandboxBootSample) {
            var samples = load()
            samples.append(sample)
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
            persist(samples)
        }

        /// Attach the first-agent-ready duration to the most recent boot
        /// sample. Called once per boot by `SandboxAgentProvisioner` for
        /// the first agent that completes provisioning.
        public static func recordFirstAgentReady(seconds: Double) {
            var samples = load()
            guard let last = samples.indices.last,
                samples[last].firstAgentReady == nil
            else { return }
            samples[last].firstAgentReady = seconds
            persist(samples)
        }

        public static func loadFailures() -> [SandboxStartupFailureSample] {
            guard let data = try? Data(contentsOf: failureFileURL()) else { return [] }
            return (try? JSONDecoder().decode([SandboxStartupFailureSample].self, from: data)) ?? []
        }

        public static func recordFailure(_ sample: SandboxStartupFailureSample) {
            var samples = loadFailures()
            samples.append(sample)
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
            persistFailures(samples)
        }

        private static func persist(_ samples: [SandboxBootSample]) {
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.container())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(samples) else { return }
            try? data.write(to: fileURL(), options: .atomic)
        }

        private static func persistFailures(_ samples: [SandboxStartupFailureSample]) {
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.container())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(samples) else { return }
            try? data.write(to: failureFileURL(), options: .atomic)
        }

        /// One-line, copy-pasteable digest of a failure sample for the
        /// Sandbox settings panel so a user can self-report exactly what
        /// the telemetry would have said. Tokens only — no message.
        public static func failureSummary(
            _ sample: SandboxStartupFailureSample,
            now: Date = Date()
        ) -> String {
            var parts: [String] = [sample.category, sample.phase]
            if let errorClass = sample.errorClass { parts.append(errorClass) }
            if let trigger = sample.trigger { parts.append(trigger) }
            if let coldStart = sample.coldStart { parts.append(coldStart ? "cold" : "warm") }
            parts.append(sample.backend)
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let when = formatter.localizedString(for: sample.recordedAt, relativeTo: now)
            return "Last failure: " + parts.joined(separator: " · ") + " · \(when)"
        }

        /// Coarse, low-cardinality latency bucket for consent-gated
        /// telemetry. Raw durations never leave the machine.
        public static func latencyBucket(_ seconds: Double) -> String {
            switch seconds {
            case ..<1: return "lt_1s"
            case ..<5: return "1_5s"
            case ..<15: return "5_15s"
            case ..<60: return "15_60s"
            case ..<300: return "1_5m"
            default: return "gte_5m"
            }
        }
    }

#endif
