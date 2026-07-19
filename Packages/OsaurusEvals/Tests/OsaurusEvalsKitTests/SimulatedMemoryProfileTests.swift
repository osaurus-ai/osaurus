import Foundation
import Testing

@preconcurrency import MLXLMCommon
import OsaurusCore

@testable import OsaurusEvalsKit

/// Locks the eval-only simulated target-RAM profile contract
/// (`OSAURUS_EVALS_SIM_RAM_GB`): the scaled load budget must come out of the
/// PRODUCTION memory-safety resolver (base mode fraction × sim/actual), the
/// profile must refuse to fake a larger machine, artifacts must carry the
/// simulated value alongside — never instead of — real host RAM, and the
/// summary must say SIMULATED so a policy-budget run can't be mistaken for
/// real constrained-hardware proof.
@Suite
struct SimulatedMemoryProfileTests {

    private let gib: UInt64 = 1 << 30

    @Test func scalesSafeAutoBudgetToSimulatedMachine() throws {
        // Default settings resolve to Safe Auto (load fraction 0.70). A
        // 16 GiB target on a 48 GiB host must produce the fraction whose
        // absolute budget equals the target machine's: 0.70 × 16/48.
        let resolution = EvalBootstrap.simulatedMemoryProfileSettings(
            base: VMLXServerRuntimeSettings(),
            simulatedBytes: 16 * gib,
            actualBytes: 48 * gib
        )
        guard case .applied(let settings, let notes) = resolution else {
            Issue.record("expected .applied, got \(resolution)")
            return
        }
        let fraction = try #require(settings.memorySafety.customPhysicalMemoryFraction)
        #expect(abs(fraction - 0.70 * 16.0 / 48.0) < 1e-9)

        // The scaled fraction must round-trip through the production
        // resolver to the target machine's absolute budget on this host.
        let plan = ServerRuntimeSettingsStore.resolvedMemorySafetyPlan(for: settings)
        let budget = plan.loadConfiguration.memoryLimit.resolve(physicalMemory: 48 * gib)
        #expect(budget == UInt64(0.70 * Double(16 * gib)))

        #expect(notes.contains { $0.contains("customPhysicalMemoryFraction") })
    }

    @Test func respectsExplicitCustomFractionAsBase() throws {
        // A user-chosen custom fraction is the base the target profile
        // scales, not something it silently replaces with the mode default.
        var base = VMLXServerRuntimeSettings()
        base.memorySafety.customPhysicalMemoryFraction = 0.5
        let resolution = EvalBootstrap.simulatedMemoryProfileSettings(
            base: base,
            simulatedBytes: 16 * gib,
            actualBytes: 32 * gib
        )
        guard case .applied(let settings, _) = resolution else {
            Issue.record("expected .applied, got \(resolution)")
            return
        }
        let fraction = try #require(settings.memorySafety.customPhysicalMemoryFraction)
        #expect(abs(fraction - 0.25) < 1e-9)
    }

    @Test func refusesToSimulateLargerMachine() {
        let resolution = EvalBootstrap.simulatedMemoryProfileSettings(
            base: VMLXServerRuntimeSettings(),
            simulatedBytes: 64 * gib,
            actualBytes: 48 * gib
        )
        guard case .rejected(let reason) = resolution else {
            Issue.record("expected .rejected, got \(resolution)")
            return
        }
        #expect(reason.contains("cannot simulate a larger machine"))
    }

    @Test func refusesEqualSizedMachine() {
        // sim == actual is a no-op simulation; refusing keeps the label
        // honest rather than recording a "simulated" run that changed nothing.
        let resolution = EvalBootstrap.simulatedMemoryProfileSettings(
            base: VMLXServerRuntimeSettings(),
            simulatedBytes: 48 * gib,
            actualBytes: 48 * gib
        )
        guard case .rejected = resolution else {
            Issue.record("expected .rejected, got \(resolution)")
            return
        }
    }

    @Test func rejectsUnlimitedBudgetMode() {
        // diagnosticDangerous with no custom fraction resolves to an
        // unlimited budget — there is no fraction to scale, so the profile
        // must refuse rather than fabricate a cap production would not apply.
        var base = VMLXServerRuntimeSettings()
        base.memorySafety.mode = .diagnosticDangerous
        let resolution = EvalBootstrap.simulatedMemoryProfileSettings(
            base: base,
            simulatedBytes: 16 * gib,
            actualBytes: 48 * gib
        )
        guard case .rejected(let reason) = resolution else {
            Issue.record("expected .rejected, got \(resolution)")
            return
        }
        #expect(reason.contains("not a physical-memory fraction"))
    }

    @Test func defaultsDiskL2CapOnlyWhenUnset() throws {
        let defaulted = EvalBootstrap.simulatedMemoryProfileSettings(
            base: VMLXServerRuntimeSettings(),
            simulatedBytes: 16 * gib,
            actualBytes: 48 * gib
        )
        guard case .applied(let settings, _) = defaulted else {
            Issue.record("expected .applied, got \(defaulted)")
            return
        }
        #expect(
            settings.cache.blockDisk.maxSizeGB
                == EvalBootstrap.simulatedProfileDefaultDiskL2CapGB
        )

        // An explicit user cap must survive the profile untouched.
        var withCap = VMLXServerRuntimeSettings()
        withCap.cache.blockDisk.maxSizeGB = 6
        let kept = EvalBootstrap.simulatedMemoryProfileSettings(
            base: withCap,
            simulatedBytes: 16 * gib,
            actualBytes: 48 * gib
        )
        guard case .applied(let keptSettings, _) = kept else {
            Issue.record("expected .applied, got \(kept)")
            return
        }
        #expect(keptSettings.cache.blockDisk.maxSizeGB == 6)
    }

    // MARK: - RunEnvironment provenance

    @Test func runEnvironmentParsesSimulatedRam() {
        #expect(
            RunEnvironment.simulatedRamMb(environment: ["OSAURUS_EVALS_SIM_RAM_GB": "16"])
                == 16 * 1024
        )
        #expect(
            RunEnvironment.simulatedRamMb(environment: ["OSAURUS_EVALS_SIM_RAM_GB": "16.5"])
                == 16896
        )
        #expect(RunEnvironment.simulatedRamMb(environment: [:]) == nil)
        #expect(
            RunEnvironment.simulatedRamMb(environment: ["OSAURUS_EVALS_SIM_RAM_GB": "0"]) == nil
        )
        #expect(
            RunEnvironment.simulatedRamMb(environment: ["OSAURUS_EVALS_SIM_RAM_GB": "-4"]) == nil
        )
        #expect(
            RunEnvironment.simulatedRamMb(environment: ["OSAURUS_EVALS_SIM_RAM_GB": "lots"]) == nil
        )
    }

    @Test func runEnvironmentCarriesBothRealAndSimulatedRam() {
        let env = RunEnvironment.current(
            caseIDs: ["x"],
            runModel: "OsaurusAI/Bonsai-27b-1bit-JANG",
            environment: ["OSAURUS_EVALS_SIM_RAM_GB": "16"]
        )
        // Real host RAM stays authoritative; the simulation rides alongside.
        #expect((env.totalRamMb ?? 0) > 0)
        #expect(env.simulatedRamMb == 16 * 1024)
        #expect(env.summary.contains("sim-ram=16GB(SIMULATED)"))
    }

    @Test func unsimulatedRunsOmitTheField() throws {
        let env = RunEnvironment.current(
            caseIDs: ["x"],
            runModel: nil,
            environment: [:]
        )
        #expect(env.simulatedRamMb == nil)
        #expect(!env.summary.contains("SIMULATED"))

        // Old reports (pre-schema) must keep decoding: the field is optional.
        let decoded = try JSONDecoder().decode(
            RunEnvironment.self,
            from: Data(#"{"chip":"Apple M1","totalRamMb":16384}"#.utf8)
        )
        #expect(decoded.simulatedRamMb == nil)
        #expect(decoded.totalRamMb == 16384)
    }
}
