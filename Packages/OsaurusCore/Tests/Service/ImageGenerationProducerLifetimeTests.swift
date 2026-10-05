import Foundation
import Testing
import vMLXFlux
@testable import OsaurusCore

// The service, ImageJobCancellation, MetalGate and both FluxEngine wrapper
// tasks are production code. Only the concrete, tensor-free model is a fake.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ImageGenerationProducerLifetimeTests {
    @Test func imagesStartSequentiallyAndPreserveSeedsAndOrder() async throws {
        let fixture = ImageProducerFixture(held: [0, 1], heldCheckpoints: [.willDrain(0)])
        defer { Task { await fixture.probe.releaseAll(); await fixture.checkpoints.releaseAll() } }
        let stream = await fixture.service.generate(.init(model: fixture.first,
            prompt: "two images", seed: 7, numImages: 2), jobID: "ordered")
        let consumer = Task { try await collectImageEvents(stream) }
        try await waitForImageProbe { await fixture.probe.startCount >= 1 }
        await fixture.checkpoints.waitUntilReached(.willDrain(0))
        // A positive checkpoint pauses the ACTUAL service immediately before
        // its first engine iterator. Count completed engine factory calls at
        // that checkpoint; legacy eager creation deterministically records
        // [0, 1] here. No absence-of-Task/scheduler-timeout assertion is needed.
        let created = await fixture.checkpoints.createdIndices
        #expect(created == [0])
        await fixture.checkpoints.release(.willDrain(0))
        await fixture.probe.release(0)
        try await waitForImageProbe { await fixture.probe.startCount == 2 }
        await fixture.probe.release(1)
        let events = try await consumer.value
        await fixture.service.waitForJobDrain(jobID: "ordered")
        let final = await fixture.probe.snapshot()
        #expect(final.maximumActive == 1)
        #expect(final.starts.map(\.seed) == [7, 8])
        #expect(final.starts.allSatisfy { $0.numImages == 1 })
        #expect(events.compactMap { event -> [UInt64]? in
            if case .completed(let images) = event { return images.map(\.seed) }
            return nil
        } == [[7, 8]])
        #expect(final.active == 0 && !final.loadWhileActive)
        await fixture.service.unload()
    }

    @Test func consumerTerminationDrainsBeforeUnloadAndNextLoad() async throws {
        let fixture = ImageProducerFixture(held: [0])
        defer { Task { await fixture.probe.releaseAll(); await fixture.checkpoints.releaseAll() } }
        let stream = await fixture.service.generate(.init(model: fixture.first,
            prompt: "cancel consumer", seed: 11, numImages: 2), jobID: "terminated")
        let consumer = Task { try await collectImageEvents(stream) }
        try await waitForImageProbe { await fixture.probe.startCount == 1 }
        consumer.cancel()
        let clientEvents = try await consumer.value
        let handoff = Task {
            await fixture.service.waitForJobDrain(jobID: "terminated")
            fixture.log.record("joined")
            await fixture.service.unload()
            fixture.log.record("unloaded")
            return try await collectImageEvents(await fixture.service.generate(
                .init(model: fixture.second, prompt: "after drain", seed: 21), jobID: "next"))
        }
        // All completion assertions below are event-order assertions after
        // controlled release, rather than timed absence checks.
        await fixture.probe.release(0)
        _ = try await handoff.value
        await fixture.service.waitForJobDrain(jobID: "next")
        let final = await fixture.probe.snapshot()
        #expect(final.starts.map(\.seed) == [11, 21]) // cancelled image two never starts
        #expect(final.loads == [fixture.first, fixture.second])
        #expect(final.maximumActive == 1 && !final.loadWhileActive)
        #expect(!clientEvents.contains { if case .completed = $0 { return true }; return false })
        let order = fixture.log.events
        let end = try #require(order.firstIndex(of: "end:0"))
        let join = try #require(order.firstIndex(of: "joined"))
        let unloaded = try #require(order.firstIndex(of: "unloaded"))
        let load = try #require(order.firstIndex(of: "load:\(fixture.second)"))
        #expect(end < join && join < unloaded && unloaded < load)
        // At least one production cleanup call is dispatched after the concrete
        // leaf ends and before the service join resolves. This is a fake barrier
        // callback ordering check, not a Metal completion proof.
        #expect(order[(end + 1)..<join].contains("cleanup"))
        await fixture.service.unload()
    }

    @Test func jobCancelDrainsActiveAndSuppressesRemainingImages() async throws {
        let fixture = ImageProducerFixture(held: [0])
        defer { Task { await fixture.probe.releaseAll(); await fixture.checkpoints.releaseAll() } }
        let stream = await fixture.service.generate(.init(model: fixture.first,
            prompt: "job cancel", seed: 31, numImages: 2), jobID: "cancel-by-id")
        let consumer = Task { try await collectImageEvents(stream) }
        try await waitForImageProbe { await fixture.probe.startCount == 1 }
        await fixture.service.cancel(jobID: "cancel-by-id")
        let drain = Task {
            await fixture.service.waitForJobDrain(jobID: "cancel-by-id")
            fixture.log.record("joined")
        }
        await fixture.probe.release(0)
        let events = try await consumer.value
        await drain.value
        let final = await fixture.probe.snapshot()
        #expect(final.starts.map(\.seed) == [31])
        #expect(final.active == 0 && final.maximumActive == 1)
        #expect(events.contains { if case .cancelled = $0 { return true }; return false })
        #expect(!events.contains { if case .completed = $0 { return true }; return false })
        await fixture.service.unload()
    }

    @Test func queuedCancelDoesNotLoad() async throws {
        let gate = MetalGate.makeForTesting()
        let fixture = ImageProducerFixture(held: [], gate: gate)
        try await gate.enterImageGeneration()
        defer { Task { await gate.exitImageGeneration() } }
        let stream = await fixture.service.generate(.init(model: fixture.first,
            prompt: "queued"), jobID: "queued")
        let consumer = Task { try await collectImageEvents(stream) }
        await fixture.service.cancel(jobID: "queued")
        let events = try await consumer.value
        await fixture.service.waitForJobDrain(jobID: "queued")
        let snapshot = await fixture.probe.snapshot()
        #expect(snapshot.loads.isEmpty && snapshot.starts.isEmpty)
        #expect(events.contains { if case .cancelled = $0 { return true }; return false })
        // Retention of a different owner's acquisition is covered by the
        // MetalGate suite; no scheduler-absence claim is made by this test.

    }
}

// Internal test support is also used by Q21 request-forwarding tests. Each
// registry key is unique, and the persistent registry closure captures the
// probe weakly so the global registry does not retain test state or models.
struct ImageProducerFixture: Sendable {
    let service: ImageGenerationService
    let probe: ImageProducerProbe
    let log: ImageProducerLog
    let checkpoints: ImageProducerCheckpoints
    let error: ImageProducerErrorSignal
    let first: String
    let second: String

    init(held: Set<Int>, gate: MetalGate = .makeForTesting(),
         canonical: String? = nil, kind: ModelKind = .imageGen,
         capabilities: ImageModelCapabilities? = nil, identityStem: String? = nil,
         heldCheckpoints: Set<ImageGenerationService.StreamCheckpoint> = []) {
        let newLog = ImageProducerLog()
        let newProbe = ImageProducerProbe(held: held, log: newLog)
        let newCheckpoints = ImageProducerCheckpoints(held: heldCheckpoints)
        let newError = ImageProducerErrorSignal()
        let stem = (identityStem ?? canonical ?? "image-service") + "-fixture-" + UUID().uuidString.lowercased()
        let nameA = stem + "-a", nameB = stem + "-b"
        var targets: [String: ImageGenerationService.LoadTarget] = [:]
        for name in [nameA, nameB] {
            ModelRegistry.register(ModelEntry(name: name, displayName: name,
                kind: kind, defaultSteps: 40, defaultGuidance: 1,
                loader: { [weak newProbe] _, _ in
                    guard let newProbe else { throw CancellationError() }
                    await newProbe.loaded(name)
                    return ControlledImageProducer(probe: newProbe)
                }))
            let info = ImageModelInfo(id: name, canonicalName: canonical ?? name,
                displayName: name, kind: kind.rawValue, ready: true,
                quantizationBits: nil, defaultSteps: 40, defaultGuidance: 1,
                capabilities: capabilities ?? .init(textToImage: kind == .imageGen,
                    imageEdit: kind == .imageEdit), blockedReasons: [], totalBytes: 0)
            targets[name] = .init(info: info, directory: URL(fileURLWithPath: "/fixture/\(name)"),
                engineName: name, kind: kind)
        }
        let resolved = targets
        service = ImageGenerationService(testingEngine: FluxEngine(), gate: gate,
            cleanup: { newLog.record("cleanup") }, resolve: { name in
                newLog.record("resolve:\(name)")
                guard let target = resolved[name] else { throw ImageGenerationError.modelNotFound(name) }
                return target
            }, streamCheckpoint: { await newCheckpoints.reached($0) },
            errorSince: { _ in newError.message })
        log = newLog; probe = newProbe; checkpoints = newCheckpoints; error = newError
        first = nameA; second = nameB
    }
}

final class ImageProducerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ value: String) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

actor ImageProducerProbe {
    struct Snapshot: Sendable {
        let starts: [ImageGenRequest]
        let edits: [ImageEditRequest]
        let loads: [String]
        let maximumActive: Int
        let active: Int
        let loadWhileActive: Bool
    }
    private let held: Set<Int>
    private let log: ImageProducerLog
    private var released: Set<Int> = []
    private var releaseEverything = false
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var starts: [ImageGenRequest] = []
    private var edits: [ImageEditRequest] = []
    private var loads: [String] = []
    private var active = 0
    private var maximumActive = 0
    private var loadWhileActive = false
    init(held: Set<Int>, log: ImageProducerLog) { self.held = held; self.log = log }
    var startCount: Int { starts.count }
    func loaded(_ name: String) {
        loads.append(name); loadWhileActive = loadWhileActive || active != 0
        log.record("load:\(name)")
    }
    func start(_ request: ImageGenRequest) -> Int {
        let index = starts.count; starts.append(request)
        active += 1; maximumActive = max(maximumActive, active)
        log.record("start:\(index)"); return index
    }
    func edited(_ request: ImageEditRequest) { edits.append(request) }
    func wait(_ index: Int) async {
        guard held.contains(index), !released.contains(index), !releaseEverything else { return }
        await withCheckedContinuation { waiters[index] = $0 }
    }
    func release(_ index: Int) { released.insert(index); waiters.removeValue(forKey: index)?.resume() }
    func releaseAll() {
        releaseEverything = true
        let pending = Array(waiters.values); waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func ended(_ index: Int) { active -= 1; log.record("end:\(index)") }
    func snapshot() -> Snapshot { .init(starts: starts, edits: edits, loads: loads,
        maximumActive: maximumActive, active: active, loadWhileActive: loadWhileActive) }
}

struct ControlledImageProducer: ImageGenerator, ImageEditor {
    let probe: ImageProducerProbe
    func generate(_ request: ImageGenRequest) -> AsyncThrowingStream<ImageGenEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let index = await probe.start(request)
                continuation.yield(.step(step: 1, total: request.steps, etaSeconds: nil))
                await probe.wait(index)
                await probe.ended(index)
                continuation.yield(.completed(url: request.outputDir.appendingPathComponent("fixture-\(index).png"),
                    seed: request.seed ?? 0))
                continuation.finish()
            }
        }
    }
    func edit(_ request: ImageEditRequest) -> AsyncThrowingStream<ImageGenEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await probe.edited(request)
                continuation.yield(.completed(url: request.outputDir.appendingPathComponent("fixture-edit.png"),
                    seed: request.seed ?? 0))
                continuation.finish()
            }
        }
    }
}

func collectImageEvents(_ stream: AsyncThrowingStream<ImageGenerationEvent, Error>) async throws -> [ImageGenerationEvent] {
    var events: [ImageGenerationEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private enum ImageProbeTimeout: Error { case notReached }
private func waitForImageProbe(_ predicate: @Sendable () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ImageProbeTimeout.notReached
}

actor ImageProducerCheckpoints {
    typealias Point = ImageGenerationService.StreamCheckpoint
    private let held: Set<Point>
    private var seen: Set<Point> = []
    private var created: [Int] = []
    private var released: Set<Point> = []
    private var allReleased = false
    private var observers: [Point: [CheckedContinuation<Void, Never>]] = [:]
    private var parked: [Point: CheckedContinuation<Void, Never>] = [:]
    init(held: Set<Point>) { self.held = held }
    var createdIndices: [Int] { created }
    func reached(_ point: Point) async {
        if case .created(let index) = point { created.append(index) }
        seen.insert(point)
        for observer in observers.removeValue(forKey: point) ?? [] { observer.resume() }
        if held.contains(point), !released.contains(point), !allReleased {
            await withCheckedContinuation { parked[point] = $0 }
        }
    }
    func waitUntilReached(_ point: Point) async {
        guard !seen.contains(point) else { return }
        await withCheckedContinuation { observers[point, default: []].append($0) }
    }
    func release(_ point: Point) { released.insert(point); parked.removeValue(forKey: point)?.resume() }
    func releaseAll() {
        allReleased = true
        let pending = Array(parked.values); parked.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

final class ImageProducerErrorSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var message: String? { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ message: String) { lock.lock(); defer { lock.unlock() }; stored = message }
}
