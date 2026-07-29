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
            ) {
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
                ) {
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
                ) {
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
                ) {
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
                ) {
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
                    ) {}
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
                ) {
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
            ) {
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
