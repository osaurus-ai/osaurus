import Foundation

/// Model-free eval bridge for the production memory planner, recovery sampler
/// and reservation actor. Host facts are explicit inputs, not claimed hardware
/// measurements. Live agent-loop cases separately exercise inference/cleanup.
public enum SubagentAdmissionEvaluator {
    public struct Facts: Sendable, Codable {
        public let model: String
        public let resident: Bool
        public let loadBytes: UInt64
        public let childCapBytes: UInt64
        public let childBytes: UInt64?
        public let availableBytes: UInt64?
        public let parentCreditBytes: UInt64
        public let loadBudgetBytes: UInt64?
        public let reserveBytes: UInt64

        fileprivate var memory: SubagentBatchMemoryFacts {
            .init(canonicalModelKey: model, targetAlreadyResident: resident,
                  targetLoadFootprintBytes: loadBytes,
                  perActiveChildHeadroomBytes: childCapBytes,
                  requestBoundedChildHeadroomBytes: childBytes,
                  reclaimableBytes: availableBytes,
                  releasableParentBytes: parentCreditBytes,
                  resolvedLoadBudgetBytes: loadBudgetBytes,
                  osHeadroomBytes: reserveBytes)
        }
    }

    public struct Step: Sendable, Codable {
        public let before: Facts?
        public let after: Facts?
        public let reclaimSucceeds: Bool
    }

    public struct Scenario: Sendable, Codable {
        public let localJobs: Int
        public let remoteJobs: Int
        public let agentLimit: Int
        public let engineLimit: Int
        public let engineSubmissionLimit: Int?
        public let batching: Bool
        public let ramSafety: Bool
        public let steps: [Step]
    }

    public struct Observation: Sendable, Codable, Equatable {
        public let capacity: Int
        public let width: Int
        public let weightCharge: UInt64?
        public let limitingFactors: [String]
        public let samples: Int
        public let reclaims: Int
        public let subwaves: [Int]
        public let remainingReservations: Int
        public let reservationError: Bool
    }

    public static func run(_ scenario: Scenario) async -> [Observation] {
        // One actor for the entire scenario: a hidden reset between steps
        // would mask the exact sequential/repeated-chat regression.
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        var observations: [Observation] = []
        for step in scenario.steps {
            var samples = 0
            var reclaims = 0
            let facts = await SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded(
                ramSafetyEnabled: scenario.ramSafety,
                sample: {
                    samples += 1
                    return samples == 1 ? step.before?.memory : step.after?.memory
                },
                reclaim: { reclaims += 1; return step.reclaimSucceeds }
            )
            let plan = SubagentBatchAdmissionPlanner.plan(.init(
                localJobCount: scenario.localJobs, remoteJobCount: scenario.remoteJobs,
                agentParallelLimit: scenario.agentLimit,
                engineParallelLimit: scenario.engineLimit,
                engineSubmissionLimit: scenario.engineSubmissionLimit,
                continuousBatchingEnabled: scenario.batching,
                ramSafetyEnabled: scenario.ramSafety,
                failClosedWhenEstimateUnknown: true, memory: facts
            ))
            var subwaves: [Int] = []
            var reservationError = false
            if case .admitted = plan.verdict, scenario.localJobs > 0 {
                var remaining = scenario.localJobs
                while remaining > 0, plan.localCapacity > 0, plan.localParallelism > 0 {
                    let result = await admission.reserveLocalInPlace(
                        modelKey: facts?.canonicalModelKey,
                        requestedSlots: min(remaining, plan.localParallelism),
                        slotCapacity: plan.localCapacity, timeoutSeconds: 0.1
                    )
                    guard case .admitted(let slots) = result else {
                        reservationError = true
                        break
                    }
                    subwaves.append(slots)
                    remaining -= slots
                    await admission.releaseLocalInPlace(modelKey: facts?.canonicalModelKey, slots: slots)
                }
                if remaining > 0 { reservationError = true }
            }
            let snapshot = await admission.snapshot()
            observations.append(.init(
                capacity: plan.localCapacity, width: plan.localParallelism,
                weightCharge: plan.incrementalWeightChargeBytes,
                limitingFactors: plan.limitingFactors.map(\.rawValue).sorted(),
                samples: samples, reclaims: reclaims, subwaves: subwaves,
                remainingReservations: snapshot.inPlace + snapshot.exclusive + snapshot.remote,
                reservationError: reservationError
            ))
        }
        return observations
    }
}
