// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

private actor ModelDeletionTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor ModelDeletionTestSignal {
    private var signalled = false

    func signal() {
        signalled = true
    }

    func value() -> Bool {
        signalled
    }
}

private struct ExpectedModelDeletionFailure: Error {}

@Suite("Model deletion lease", .serialized)
struct ModelDeletionLeaseTests {
    private static func packageRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Service/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func functionBody(_ signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: signature))
        let peers = [
            "\n    private func ",
            "\n    private static func ",
            "\n    private nonisolated static func ",
            "\n    @Test",
        ]
        let end =
            peers.compactMap {
                source.range(of: $0, range: start.upperBound ..< source.endIndex)?.lowerBound
            }
            .min() ?? source.endIndex
        return String(source[start.lowerBound ..< end])
    }

    private func eventually(
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<20_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    @Test("deletion drains prior setup and quarantines later model use")
    func deletionOrdersModelAccess() async throws {
        let runtime = ModelRuntime.shared
        let suffix = UUID().uuidString
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix

        let firstAccess = try await runtime.beginModelDeletionProtectedAccess(
            modelID: modelID,
            modelName: modelName
        )
        let deletionEntered = ModelDeletionTestSignal()
        let allowDeletionToFinish = ModelDeletionTestGate()
        let deletionTask = Task {
            try await runtime.withModelDeletionLease(
                modelID: modelID,
                modelName: modelName
            ) { _ in
                await deletionEntered.signal()
                await allowDeletionToFinish.wait()
            }
        }

        let quarantineInstalled = await eventually {
            await runtime.modelDeletionProtectionSnapshot(
                modelID: modelID,
                modelName: modelName
            ).isDeleting
        }
        #expect(quarantineInstalled)

        let laterAccessEntered = ModelDeletionTestSignal()
        let laterAccessTask = Task {
            let lease = try await runtime.beginModelDeletionProtectedAccess(
                modelID: modelID.uppercased(),
                modelName: modelName.uppercased()
            )
            await laterAccessEntered.signal()
            await runtime.finishModelDeletionProtectedAccess(lease)
        }
        let laterAccessBlocked = await eventually {
            await runtime.modelDeletionProtectionSnapshot(
                modelID: modelID,
                modelName: modelName
            ).blockedModelUses == 1
        }
        #expect(laterAccessBlocked)
        #expect(!(await deletionEntered.value()))

        await runtime.finishModelDeletionProtectedAccess(firstAccess)
        #expect(await eventually { await deletionEntered.value() })
        #expect(!(await laterAccessEntered.value()))

        await allowDeletionToFinish.open()
        try await deletionTask.value
        try await laterAccessTask.value

        #expect(await laterAccessEntered.value())
        let finalSnapshot = await runtime.modelDeletionProtectionSnapshot(
            modelID: modelID,
            modelName: modelName
        )
        #expect(
            finalSnapshot
                == ModelRuntime.ModelDeletionProtectionSnapshot(
                    isDeleting: false,
                    activeModelUses: 0,
                    blockedModelUses: 0
                )
        )
    }

    @Test("ordinary unload admission blocks later model use until teardown releases")
    func ordinaryUnloadAdmissionBlocksLaterModelUse() async {
        let runtime = ModelRuntime.shared
        let suffix = UUID().uuidString
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix
        let admissionEntered = ModelDeletionTestSignal()
        let allowAdmissionToFinish = ModelDeletionTestGate()

        let admissionTask = Task { () -> Bool in
            do {
                try await runtime.withModelUnloadAdmissionForTesting(
                    modelID: modelID,
                    modelName: modelName
                ) {
                    await admissionEntered.signal()
                    await allowAdmissionToFinish.wait()
                }
                return true
            } catch {
                Issue.record("Unexpected ordinary unload-admission error: \(error)")
                return false
            }
        }

        let enteredWithinBound = await eventually {
            await admissionEntered.value()
        }
        #expect(enteredWithinBound)
        guard enteredWithinBound else {
            admissionTask.cancel()
            _ = await admissionTask.value
            return
        }

        let laterAccessEntered = ModelDeletionTestSignal()
        let laterAccessTask = Task { () -> Bool in
            do {
                let lease = try await runtime.beginModelDeletionProtectedAccess(
                    modelID: modelID.uppercased(),
                    modelName: modelName.uppercased()
                )
                await laterAccessEntered.signal()
                await runtime.finishModelDeletionProtectedAccess(lease)
                return true
            } catch {
                Issue.record("Unexpected later model-use error: \(error)")
                return false
            }
        }

        let laterAccessBlocked = await eventually {
            await runtime.modelDeletionProtectionSnapshot(
                modelID: modelID,
                modelName: modelName
            ).blockedModelUses == 1
        }
        #expect(laterAccessBlocked)
        #expect(!(await laterAccessEntered.value()))

        await allowAdmissionToFinish.open()
        #expect(await admissionTask.value)
        #expect(await laterAccessTask.value)
        #expect(await laterAccessEntered.value())
    }

    @Test("delete owner can enter unload admission without self-waiting")
    func deleteOwnerCanEnterUnloadAdmissionWithoutSelfWaiting() async {
        let runtime = ModelRuntime.shared
        let suffix = UUID().uuidString
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix
        let admissionEntered = ModelDeletionTestSignal()
        let operationCompleted = ModelDeletionTestSignal()
        let allowUnloadAdmissionToFinish = ModelDeletionTestGate()
        let allowDeletionToFinish = ModelDeletionTestGate()

        let deleteTask = Task { () -> Bool in
            do {
                try await runtime.withModelDeletionLease(
                    modelID: modelID,
                    modelName: modelName
                ) { authorization in
                    try await runtime.withModelUnloadAdmissionForTesting(
                        modelID: modelID.uppercased(),
                        modelName: modelName.uppercased(),
                        deletionAuthorization: authorization
                    ) {
                        await admissionEntered.signal()
                        await allowUnloadAdmissionToFinish.wait()
                    }
                    await allowDeletionToFinish.wait()
                }
                await operationCompleted.signal()
                return true
            } catch {
                Issue.record("Unexpected nested unload-admission error: \(error)")
                return false
            }
        }

        let enteredWithinBound = await eventually {
            await admissionEntered.value()
        }
        #expect(enteredWithinBound)
        guard enteredWithinBound else {
            deleteTask.cancel()
            _ = await deleteTask.value
            return
        }

        let laterAccessEntered = ModelDeletionTestSignal()
        let laterAccessTask = Task { () -> Bool in
            do {
                let lease = try await runtime.beginModelDeletionProtectedAccess(
                    modelID: modelID,
                    modelName: modelName
                )
                await laterAccessEntered.signal()
                await runtime.finishModelDeletionProtectedAccess(lease)
                return true
            } catch {
                Issue.record("Unexpected delete-racing model-use error: \(error)")
                return false
            }
        }
        #expect(
            await eventually {
                await runtime.modelDeletionProtectionSnapshot(
                    modelID: modelID,
                    modelName: modelName
                ).blockedModelUses == 1
            }
        )
        #expect(!(await laterAccessEntered.value()))

        await allowUnloadAdmissionToFinish.open()
        #expect(!(await operationCompleted.value()))
        #expect(
            (await runtime.modelDeletionProtectionSnapshot(
                modelID: modelID,
                modelName: modelName
            )).isDeleting
        )

        await allowDeletionToFinish.open()
        #expect(await deleteTask.value)
        #expect(await operationCompleted.value())
        #expect(await laterAccessTask.value)
        #expect(await laterAccessEntered.value())
    }

    @Test("delete owner bypasses an ordinary unload admission queued behind its lease")
    func deleteOwnerBypassesQueuedOrdinaryUnloadAdmission() async {
        let runtime = ModelRuntime.shared
        let suffix = UUID().uuidString
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix
        let deletionEntered = ModelDeletionTestSignal()
        let allowOwnerAdmission = ModelDeletionTestGate()
        let ownerAdmissionEntered = ModelDeletionTestSignal()
        let allowDeletionToFinish = ModelDeletionTestGate()

        let deleteTask = Task { () -> Bool in
            do {
                try await runtime.withModelDeletionLease(
                    modelID: modelID,
                    modelName: modelName
                ) { authorization in
                    await deletionEntered.signal()
                    await allowOwnerAdmission.wait()
                    try await runtime.withModelUnloadAdmissionForTesting(
                        modelID: modelID.uppercased(),
                        modelName: modelName.uppercased(),
                        deletionAuthorization: authorization
                    ) {
                        await ownerAdmissionEntered.signal()
                    }
                    await allowDeletionToFinish.wait()
                }
                return true
            } catch {
                Issue.record("Unexpected owner deletion error: \(error)")
                return false
            }
        }

        let deletionStarted = await eventually {
            await deletionEntered.value()
        }
        #expect(deletionStarted)
        guard deletionStarted else {
            deleteTask.cancel()
            await allowOwnerAdmission.open()
            await allowDeletionToFinish.open()
            _ = await deleteTask.value
            return
        }

        let ordinaryAdmissionEntered = ModelDeletionTestSignal()
        let ordinaryAdmissionTask = Task { () -> Bool in
            do {
                try await runtime.withModelUnloadAdmissionForTesting(
                    modelID: modelID,
                    modelName: modelName
                ) {
                    await ordinaryAdmissionEntered.signal()
                }
                return true
            } catch {
                Issue.record("Unexpected ordinary unload-admission error: \(error)")
                return false
            }
        }

        let ordinaryAdmissionQueued = await eventually {
            await runtime.modelDeletionProtectionSnapshot(
                modelID: modelID,
                modelName: modelName
            ).blockedDeletionRequests == 1
        }
        #expect(ordinaryAdmissionQueued)
        guard ordinaryAdmissionQueued else {
            ordinaryAdmissionTask.cancel()
            deleteTask.cancel()
            await allowOwnerAdmission.open()
            await allowDeletionToFinish.open()
            _ = await ordinaryAdmissionTask.value
            _ = await deleteTask.value
            return
        }

        await allowOwnerAdmission.open()
        let ownerBypassedWaiter = await eventually {
            await ownerAdmissionEntered.value()
        }
        #expect(ownerBypassedWaiter)
        #expect(!(await ordinaryAdmissionEntered.value()))
        #expect(
            (await runtime.modelDeletionProtectionSnapshot(
                modelID: modelID,
                modelName: modelName
            )).blockedDeletionRequests == 1
        )

        guard ownerBypassedWaiter else {
            ordinaryAdmissionTask.cancel()
            deleteTask.cancel()
            await allowDeletionToFinish.open()
            _ = await ordinaryAdmissionTask.value
            _ = await deleteTask.value
            return
        }

        await allowDeletionToFinish.open()
        #expect(await deleteTask.value)
        #expect(await ordinaryAdmissionTask.value)
        #expect(await ordinaryAdmissionEntered.value())
    }

    @Test("deletion authorization cannot borrow another canonical identity")
    func deletionAuthorizationCannotBorrowAnotherIdentity() async {
        let runtime = ModelRuntime.shared
        let ownerSuffix = UUID().uuidString
        let otherSuffix = UUID().uuidString
        let ownerID = "lease-tests/\(ownerSuffix)"
        let otherID = "lease-tests/\(otherSuffix)"

        let rejected: Bool
        do {
            rejected = try await runtime.withModelDeletionLease(
                modelID: ownerID,
                modelName: ownerSuffix
            ) { authorization in
                do {
                    _ = try await runtime.withModelUnloadAdmissionForTesting(
                        modelID: otherID,
                        modelName: otherSuffix,
                        deletionAuthorization: authorization
                    ) {}
                    return false
                } catch {
                    return true
                }
            }
        } catch {
            Issue.record("Unexpected owner deletion error: \(error)")
            return
        }

        #expect(rejected)
        #expect(
            !(await runtime.modelDeletionProtectionSnapshot(
                modelID: otherID,
                modelName: otherSuffix
            )).isDeleting
        )
    }

    @Test("cancelled teardown admission rejects only the cancelled context")
    func cancelledTeardownAdmissionRejectsOnlyCancelledContext() async {
        let runtime = ModelRuntime.shared
        let suffix = UUID().uuidString
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix
        let cancelledEntered = ModelDeletionTestSignal()

        let cancelledTask = Task { () -> String in
            do {
                try await runtime.withModelUnloadAdmissionForTesting(
                    modelID: modelID,
                    modelName: modelName
                ) {
                    await cancelledEntered.signal()
                }
                return "entered"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                Issue.record("Unexpected cancelled-admission error: \(error)")
                return "error"
            }
        }
        cancelledTask.cancel()

        #expect(await cancelledTask.value == "cancelled")
        #expect(!(await cancelledEntered.value()))

        // Non-cancelled control: the exact same admission seam must enter and
        // release normally, so the observed rejection is tied to cancellation.
        let controlEntered = ModelDeletionTestSignal()
        let controlResult: Bool
        do {
            try await runtime.withModelUnloadAdmissionForTesting(
                modelID: modelID,
                modelName: modelName
            ) {
                await controlEntered.signal()
            }
            controlResult = true
        } catch {
            Issue.record("Unexpected non-cancelled admission error: \(error)")
            controlResult = false
        }
        #expect(controlResult)
        #expect(await controlEntered.value())

        // Detached intervention: cleanup launched outside the cancelled
        // caller's task context still reaches the same admission seam.
        let detachedEntered = ModelDeletionTestSignal()
        let detachedResult = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                try await runtime.withModelUnloadAdmissionForTesting(
                    modelID: modelID,
                    modelName: modelName
                ) {
                    await detachedEntered.signal()
                }
                return true
            } catch {
                return false
            }
        }.value
        #expect(detachedResult)
        #expect(await detachedEntered.value())
    }

    @Test("normalized resident key binds deletion authorization to stable ID")
    func sameRepoTailDeletionAuthorizationIsolated() async throws {
        let runtime = ModelRuntime.shared
        let ownerID = "org-a/shared"
        let otherID = "org-b/shared"

        let result = try await runtime.withModelDeletionLease(
            modelID: ownerID,
            modelName: "shared"
        ) { authorization in
            let ownerAliasAccepted: Bool
            do {
                try await runtime.withModelUnloadAdmissionForTesting(
                    modelID: ownerID,
                    modelName: "shared",
                    residentModelID: ownerID,
                    deletionAuthorization: authorization
                ) {}
                ownerAliasAccepted = true
            } catch {
                ownerAliasAccepted = false
            }

            let otherOrganizationRejected: Bool
            do {
                try await runtime.withModelUnloadAdmissionForTesting(
                    modelID: ownerID,
                    modelName: "shared",
                    residentModelID: otherID,
                    deletionAuthorization: authorization
                ) {}
                otherOrganizationRejected = false
            } catch {
                otherOrganizationRejected = true
            }

            return (ownerAliasAccepted, otherOrganizationRejected)
        }

        #expect(result.0)
        #expect(result.1)
        #expect(
            !(await runtime.modelDeletionProtectionSnapshot(
                modelID: otherID,
                modelName: "shared"
            )).isDeleting
        )
    }

    @Test("stable holder identity reaches normalized unload authorization")
    func stableHolderIdentityWiringPrecedesTeardown() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let service = try Self.source("Services/ModelDownloadService.swift")

        let holder = try Self.functionBody(
            "private final class SessionHolder: NSObject",
            in: runtime
        )
        #expect(holder.contains("let modelID: String"))
        #expect(holder.contains("modelID: String,"))
        #expect(holder.contains("self.modelID = modelID"))

        let testSeam = try Self.functionBody(
            "func withModelUnloadAdmissionForTesting<T: Sendable>(",
            in: runtime
        )
        #expect(testSeam.contains("beginModelUnloadAdmission("))
        #expect(testSeam.contains("residentModelID: residentModelID ?? modelID"))

        let load = try #require(runtime.range(of: "let holder = SessionHolder("))
        let loadID = try #require(
            runtime.range(
                of: "modelID: id,",
                range: load.upperBound ..< runtime.endIndex
            )
        )
        #expect(load.lowerBound < loadID.lowerBound)

        let finish = try Self.functionBody(
            "private func finishLoadedContainer(",
            in: runtime
        )
        #expect(finish.contains("residentMetadata[name] = ResidentMetadata("))
        #expect(finish.contains("modelID: holder.modelID"))
        #expect(runtime.contains("private struct ResidentMetadata: Sendable, Equatable"))
        #expect(runtime.contains("private struct ResidentMetadata: Sendable, Equatable {\n        let modelID: String"))

        let delete = try Self.functionBody(
            "func delete(_ model: MLXModel) async",
            in: service
        )
        #expect(delete.contains("let modelID = model.id"))
        #expect(delete.contains("name: modelID,"))
        #expect(delete.contains("deletionAuthorization: deletionAuthorization"))

        let unload = try Self.functionBody("func unload(", in: runtime)
        let normalizedKey = try #require(
            unload.range(of: "guard let key = residentKey(matching: name)")
        )
        let forwardedID = try #require(
            unload.range(
                of: "requestedModelID: name,",
                range: normalizedKey.upperBound ..< unload.endIndex
            )
        )
        #expect(normalizedKey.lowerBound < forwardedID.lowerBound)

        let unloadClaimed = try Self.functionBody(
            "private func unloadClaimed(",
            in: runtime
        )
        #expect(unloadClaimed.contains("requestedModelID: String"))
        let admission = try #require(
            unloadClaimed.range(of: "try await beginModelUnloadAdmission(")
        )
        let admissionID = try #require(
            unloadClaimed.range(
                of: "modelID: requestedModelID,",
                range: admission.upperBound ..< unloadClaimed.endIndex
            )
        )
        let residentID = try #require(
            unloadClaimed.range(
                of: "residentModelID: residentMetadata[name]?.modelID,",
                range: admissionID.upperBound ..< unloadClaimed.endIndex
            )
        )
        let teardown = try #require(
            unloadClaimed.range(
                of: "await MLXBatchAdapter.Registry.shared.shutdownEngine(for: name)",
                range: residentID.upperBound ..< unloadClaimed.endIndex
            )
        )
        #expect(admission.lowerBound < admissionID.lowerBound)
        #expect(admissionID.lowerBound < residentID.lowerBound)
        #expect(residentID.lowerBound < teardown.lowerBound)

        let validation = try Self.functionBody(
            "private func isValidModelDeletionAuthorization(",
            in: runtime
        )
        let equality = try #require(
            validation.range(of: "requestedStableID == residentStableID")
        )
        let targetKeys = try #require(
            validation.range(of: "let targetKeys = Set(")
        )
        #expect(equality.lowerBound < targetKeys.lowerBound)
        #expect(validation.contains("guard !requestedStableID.isEmpty"))

        let admissionHelper = try Self.functionBody(
            "private func beginModelUnloadAdmission(",
            in: runtime
        )
        #expect(admissionHelper.contains("isValidModelDeletionAuthorization("))
        #expect(admissionHelper.contains("residentModelID: residentModelID"))
    }

    @Test("cancelled protected access returns while deletion remains active")
    func cancelledProtectedAccessDoesNotWaitForDeletionRelease() async {
        let runtime = ModelRuntime.shared
        let suffix = UUID().uuidString
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix
        let deletionEntered = ModelDeletionTestSignal()
        let deletionCompleted = ModelDeletionTestSignal()
        let allowDeletionToFinish = ModelDeletionTestGate()

        let deletionTask = Task {
            do {
                try await runtime.withModelDeletionLease(
                    modelID: modelID,
                    modelName: modelName
                ) { _ in
                    await deletionEntered.signal()
                    await allowDeletionToFinish.wait()
                }
                await deletionCompleted.signal()
            } catch {
                Issue.record("Unexpected owner deletion error: \(error)")
            }
        }
        #expect(await eventually { await deletionEntered.value() })

        let blockedAccessTask = Task { () -> Bool in
            do {
                let lease = try await runtime.beginModelDeletionProtectedAccess(
                    modelID: modelID,
                    modelName: modelName
                )
                await runtime.finishModelDeletionProtectedAccess(lease)
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record("Unexpected protected-access error: \(error)")
                return false
            }
        }
        #expect(
            await eventually {
                await runtime.modelDeletionProtectionSnapshot(
                    modelID: modelID,
                    modelName: modelName
                ).blockedModelUses == 1
            }
        )

        blockedAccessTask.cancel()
        #expect(await blockedAccessTask.value)
        #expect(!(await deletionCompleted.value()))

        let stillDeleting = await runtime.modelDeletionProtectionSnapshot(
            modelID: modelID,
            modelName: modelName
        )
        #expect(stillDeleting.isDeleting)
        #expect(stillDeleting.blockedModelUses == 0)

        await allowDeletionToFinish.open()
        await deletionTask.value
        #expect(await deletionCompleted.value())
    }

    @Test("cancelled competing deletion never enters after owner release")
    func cancelledCompetingDeletionDoesNotRun() async {
        let runtime = ModelRuntime.shared
        let suffix = UUID().uuidString
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix
        let ownerEntered = ModelDeletionTestSignal()
        let ownerCompleted = ModelDeletionTestSignal()
        let competitorEntered = ModelDeletionTestSignal()
        let allowOwnerToFinish = ModelDeletionTestGate()

        let ownerTask = Task {
            do {
                try await runtime.withModelDeletionLease(
                    modelID: modelID,
                    modelName: modelName
                ) { _ in
                    await ownerEntered.signal()
                    await allowOwnerToFinish.wait()
                }
                await ownerCompleted.signal()
            } catch {
                Issue.record("Unexpected owner deletion error: \(error)")
            }
        }
        #expect(await eventually { await ownerEntered.value() })

        let competitorTask = Task { () -> Bool in
            do {
                try await runtime.withModelDeletionLease(
                    modelID: modelID.uppercased(),
                    modelName: modelName.uppercased()
                ) { _ in
                    await competitorEntered.signal()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record("Unexpected competing deletion error: \(error)")
                return false
            }
        }
        #expect(
            await eventually {
                await runtime.modelDeletionProtectionSnapshot(
                    modelID: modelID,
                    modelName: modelName
                ).blockedDeletionRequests == 1
            }
        )

        competitorTask.cancel()
        #expect(await competitorTask.value)
        #expect(!(await competitorEntered.value()))
        #expect(!(await ownerCompleted.value()))

        let stillOwned = await runtime.modelDeletionProtectionSnapshot(
            modelID: modelID,
            modelName: modelName
        )
        #expect(stillOwned.isDeleting)
        #expect(stillOwned.blockedDeletionRequests == 0)

        await allowOwnerToFinish.open()
        await ownerTask.value
        #expect(await ownerCompleted.value())
        #expect(!(await competitorEntered.value()))
    }

    @Test("cancelled draining deletion clears quarantine before access release")
    func cancelledDrainingDeletionClearsQuarantine() async throws {
        let runtime = ModelRuntime.shared
        let suffix = UUID().uuidString
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix
        let deletionEntered = ModelDeletionTestSignal()
        let activeAccess = try await runtime.beginModelDeletionProtectedAccess(
            modelID: modelID,
            modelName: modelName
        )

        let deletionTask = Task { () -> Bool in
            do {
                try await runtime.withModelDeletionLease(
                    modelID: modelID,
                    modelName: modelName
                ) { _ in
                    await deletionEntered.signal()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record("Unexpected draining deletion error: \(error)")
                return false
            }
        }
        #expect(
            await eventually {
                let snapshot = await runtime.modelDeletionProtectionSnapshot(
                    modelID: modelID,
                    modelName: modelName
                )
                return snapshot.isDeleting
                    && snapshot.activeModelUses == 1
                    && snapshot.drainingDeletionRequests == 1
            }
        )

        deletionTask.cancel()
        #expect(await deletionTask.value)
        #expect(!(await deletionEntered.value()))

        let afterCancellation = await runtime.modelDeletionProtectionSnapshot(
            modelID: modelID,
            modelName: modelName
        )
        #expect(!afterCancellation.isDeleting)
        #expect(afterCancellation.activeModelUses == 1)
        #expect(afterCancellation.drainingDeletionRequests == 0)

        // The original access is deliberately still held: cancellation must
        // clear quarantine independently instead of waiting for this release.
        let laterAccess = try await runtime.beginModelDeletionProtectedAccess(
            modelID: modelID,
            modelName: modelName
        )
        await runtime.finishModelDeletionProtectedAccess(laterAccess)
        await runtime.finishModelDeletionProtectedAccess(activeAccess)
    }

    @Test("cancellation and release races resolve every deletion waiter once")
    func cancellationReleaseRaceDoesNotLeakWaiters() async throws {
        let runtime = ModelRuntime.shared

        for iteration in 0..<32 {
            let suffix = UUID().uuidString
            let modelID = "lease-tests/\(suffix)"
            let modelName = suffix
            let activeAccess = try await runtime.beginModelDeletionProtectedAccess(
                modelID: modelID,
                modelName: modelName
            )

            let deletionTask = Task { () -> Bool in
                do {
                    try await runtime.withModelDeletionLease(
                        modelID: modelID,
                        modelName: modelName
                    ) { _ in }
                    return true
                } catch is CancellationError {
                    return true
                } catch {
                    Issue.record("Unexpected deletion race error: \(error)")
                    return false
                }
            }
            #expect(
                await eventually {
                    await runtime.modelDeletionProtectionSnapshot(
                        modelID: modelID,
                        modelName: modelName
                    ).drainingDeletionRequests == 1
                }
            )

            let blockedAccessTask = Task { () -> Bool in
                do {
                    let lease = try await runtime.beginModelDeletionProtectedAccess(
                        modelID: modelID,
                        modelName: modelName
                    )
                    await runtime.finishModelDeletionProtectedAccess(lease)
                    return true
                } catch is CancellationError {
                    return true
                } catch {
                    Issue.record("Unexpected protected-access race error: \(error)")
                    return false
                }
            }
            #expect(
                await eventually {
                    await runtime.modelDeletionProtectionSnapshot(
                        modelID: modelID,
                        modelName: modelName
                    ).blockedModelUses == 1
                }
            )

            // Vary scheduling order while keeping all three events concurrent.
            let releaseTask = Task {
                if iteration.isMultiple(of: 2) { await Task.yield() }
                await runtime.finishModelDeletionProtectedAccess(activeAccess)
            }
            let cancelDeletionTask = Task {
                if !iteration.isMultiple(of: 2) { await Task.yield() }
                deletionTask.cancel()
            }
            let cancelAccessTask = Task {
                blockedAccessTask.cancel()
            }
            await releaseTask.value
            await cancelDeletionTask.value
            await cancelAccessTask.value
            #expect(await deletionTask.value)
            #expect(await blockedAccessTask.value)

            #expect(
                await eventually {
                    await runtime.modelDeletionProtectionSnapshot(
                        modelID: modelID,
                        modelName: modelName
                    ) == ModelRuntime.ModelDeletionProtectionSnapshot(
                        isDeleting: false,
                        activeModelUses: 0,
                        blockedModelUses: 0,
                        blockedDeletionRequests: 0,
                        drainingDeletionRequests: 0
                    )
                }
            )
        }
    }

    @Test("owned operation abort drains blocked access before deletion release")
    func ownedOperationAbortReturnsBeforeDeletionRelease() async {
        let runtime = ModelRuntime.shared
        let suffix = UUID().uuidString
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix
        let deletionEntered = ModelDeletionTestSignal()
        let deletionCompleted = ModelDeletionTestSignal()
        let allowDeletionToFinish = ModelDeletionTestGate()

        let deletionTask = Task {
            do {
                try await runtime.withModelDeletionLease(
                    modelID: modelID,
                    modelName: modelName
                ) { _ in
                    await deletionEntered.signal()
                    await allowDeletionToFinish.wait()
                }
                await deletionCompleted.signal()
            } catch {
                Issue.record("Unexpected owner deletion error: \(error)")
            }
        }
        #expect(await eventually { await deletionEntered.value() })

        let operation = OwnedSubagentOperation {
            let access = try await runtime.beginModelDeletionProtectedAccess(
                modelID: modelID,
                modelName: modelName
            )
            await runtime.finishModelDeletionProtectedAccess(access)
        }
        #expect(
            await eventually {
                await runtime.modelDeletionProtectionSnapshot(
                    modelID: modelID,
                    modelName: modelName
                ).blockedModelUses == 1
            }
        )

        await operation.abortAndWait()
        #expect(!(await deletionCompleted.value()))

        let stillDeleting = await runtime.modelDeletionProtectionSnapshot(
            modelID: modelID,
            modelName: modelName
        )
        #expect(stillDeleting.isDeleting)
        #expect(stillDeleting.blockedModelUses == 0)

        await allowDeletionToFinish.open()
        await deletionTask.value
        #expect(await deletionCompleted.value())
    }

    @Test("thrown deletion operation releases quarantine")
    func deletionFailureReleasesLease() async throws {
        let runtime = ModelRuntime.shared
        let suffix = UUID().uuidString
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix

        do {
            try await runtime.withModelDeletionLease(
                modelID: modelID,
                modelName: modelName
            ) { _ in
                throw ExpectedModelDeletionFailure()
            }
            Issue.record("expected deletion operation to throw")
        } catch is ExpectedModelDeletionFailure {
            // Expected.
        }

        let snapshot = await runtime.modelDeletionProtectionSnapshot(
            modelID: modelID,
            modelName: modelName
        )
        #expect(!snapshot.isDeleting)

        let access = try await runtime.beginModelDeletionProtectedAccess(
            modelID: modelID,
            modelName: modelName
        )
        await runtime.finishModelDeletionProtectedAccess(access)
    }

    @Test @MainActor
    func downloadServiceDeleteUsesRuntimeQuarantine() async throws {
        let suffix = UUID().uuidString.lowercased()
        let modelID = "lease-tests/\(suffix)"
        let modelName = suffix
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-model-delete-\(suffix)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MLXModel(
            id: modelID,
            name: modelName,
            description: "Deletion lease test",
            downloadURL: "",
            rootDirectory: root
        )
        try FileManager.default.createDirectory(
            at: model.localDirectory,
            withIntermediateDirectories: true
        )
        let sentinel = model.localDirectory.appendingPathComponent("weights.safetensors")
        try Data("sentinel".utf8).write(to: sentinel)

        let runtime = ModelRuntime.shared
        let activeAccess = try await runtime.beginModelDeletionProtectedAccess(
            modelID: modelID,
            modelName: modelName
        )
        let service = ModelDownloadService.shared
        service.downloadStates[modelID] = .completed
        let deleteTask = Task { @MainActor in
            await service.delete(model)
        }

        #expect(
            await eventually {
                await runtime.modelDeletionProtectionSnapshot(
                    modelID: modelID,
                    modelName: modelName
                ).isDeleting
            }
        )
        #expect(FileManager.default.fileExists(atPath: sentinel.path))

        await runtime.finishModelDeletionProtectedAccess(activeAccess)
        await deleteTask.value

        #expect(!FileManager.default.fileExists(atPath: model.localDirectory.path))
        #expect(service.downloadStates[modelID] == .notStarted)
        #expect(
            !(await runtime.modelDeletionProtectionSnapshot(
                modelID: modelID,
                modelName: modelName
            ).isDeleting)
        )
    }
}
