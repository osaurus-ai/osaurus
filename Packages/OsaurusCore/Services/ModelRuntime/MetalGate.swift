//
//  MetalGate.swift
//  osaurus
//
//  Process-wide mutual-exclusion gate across every MLX/Metal *GPU producer*
//  in the app — LLM generation (vmlx-swift's `BatchEngine`), the Model2Vec
//  embedder behind capability/memory search, the Rampart PII detector behind
//  the privacy filter, and model loading (weight
//  dequantization + kernel compilation). All submit work to the same Metal
//  device on different threads, and two distinct producers driving the Metal
//  command queue at once race on the command buffer and abort with crashes
//  like
//      -[_MTLCommandBuffer addCompletedHandler:]: Completed handler provided after commit call
//      -[IOGPUMetalCommandBuffer validate]: commit command buffer with uncommitted encoder
//  or an `EXC_BAD_ACCESS` deep inside `mlx::core::metal::*`. Observed live as a
//  model load (model switch) overlapping an in-flight generation's GPU tail.
//
//  ## Design — mutual exclusion keyed by producer identity
//
//  The gate admits work by an opaque *owner* key:
//    - Acquisitions for the SAME `shared` owner overlap. Generation passes the
//      model name (`gen:<model>`) as a shared owner, so one model's batched
//      decode slots — which the `BatchEngine` actor already evaluates on a
//      single loop thread — keep batching for throughput.
//    - Every OTHER owner is mutually exclusive: a different model's generation,
//      an embedder (`embedding`), and a model load (`load:<model>`) each wait
//      for the current producer to drain before taking the GPU, and block new
//      work from starting until they finish.
//    - A waiting foreign owner blocks new same-owner admissions, so a steady
//      stream of one producer can't starve another (generalizes the old
//      writer-preference that protected the embedder).
//
//  Generation holds the gate for the FULL stream consumption — vmlx does not
//  `finish()` the stream until after its end-of-turn cache-store eval, so the
//  caller releases on stream end (not on the `.info` event) to cover the
//  BatchEngine's async tail too.
//

import Foundation

public actor MetalGate {
    public static let shared = MetalGate()

    /// The producer currently holding the GPU, or `nil` when idle.
    private var currentOwner: String?
    /// Whether the current holder permits same-owner overlap.
    private var currentShared = false
    /// Active acquisitions under `currentOwner`. Greater than 1 only for
    /// same-owner shared overlap (a model's batched generation slots).
    private var activeHolders = 0
    /// Suspended acquirers grouped by owner, so a foreign waiter can block new
    /// same-owner admissions and avoid starvation.
    private var waitingByOwner: [String: Int] = [:]

    /// A parked acquirer. Woken on every release (each re-checks its own
    /// predicate — standard actor condition pattern) or, for cancellable
    /// acquisitions, when its task is cancelled.
    private struct GateWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [GateWaiter] = []
    private var nextWaiterID: UInt64 = 0
    /// IDs whose cancellation fired before the continuation was registered
    /// (the `onCancel` hop can beat the suspension into the actor).
    private var preCancelledWaiterIDs: Set<UInt64> = []

    private init() {}

    /// Isolated instance for unit tests. Admission-ordering and
    /// cancellation tests must not use `shared`: production paths in other
    /// suites (embedder, PII scans, ChatSession sends, image jobs) acquire
    /// the singleton concurrently, and this gate's anti-starvation rule — a
    /// parked foreign waiter blocks new same-owner admissions — lets any
    /// foreign traffic deadlock a test that holds the gate while awaiting
    /// an admission it expects to proceed.
    static func makeForTesting() -> MetalGate {
        MetalGate()
    }

    /// Park until the next wake. When `cancellable`, the caller's task
    /// cancellation also resumes this specific waiter (the acquire loop then
    /// observes `Task.isCancelled` and gives up).
    private func suspend(cancellable: Bool) async {
        let id = nextWaiterID
        nextWaiterID &+= 1
        if !cancellable {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(GateWaiter(id: id, continuation: c))
            }
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if preCancelledWaiterIDs.remove(id) != nil {
                    c.resume()
                } else {
                    waiters.append(GateWaiter(id: id, continuation: c))
                }
            }
        } onCancel: {
            Task { await self.wakeWaiter(id: id) }
        }
    }

    /// Resume one specific (cancelled) waiter without waking the others.
    private func wakeWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            // Cancellation raced ahead of the suspension; mark it so the
            // registration path resumes immediately instead of parking a
            // continuation nothing will ever wake.
            preCancelledWaiterIDs.insert(id)
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume()
    }

    private func wakeAll() {
        guard !waiters.isEmpty else { return }
        let woken = waiters
        waiters.removeAll()
        for w in woken { w.continuation.resume() }
    }

    private func hasForeignWaiter(_ owner: String) -> Bool {
        for (key, count) in waitingByOwner where key != owner && count > 0 { return true }
        return false
    }

    private func canAdmit(_ owner: String, shared: Bool) -> Bool {
        if currentOwner == nil { return true }
        if shared, currentShared, currentOwner == owner { return !hasForeignWaiter(owner) }
        return false
    }

    private func removeWaiting(_ owner: String) {
        let remaining = (waitingByOwner[owner] ?? 1) - 1
        waitingByOwner[owner] = remaining > 0 ? remaining : nil
    }

    // MARK: - Core acquire / release

    /// Acquire the GPU gate for `owner`. When `shared` is true, acquisitions for
    /// the same owner overlap; otherwise the owner is exclusive even against
    /// itself. Every distinct owner is mutually exclusive.
    ///
    /// NOT cancellation-aware: a cancelled caller keeps waiting and still
    /// acquires. Reserved for teardown/load sequences that must run to
    /// completion once started (skipping them would leak weights or free
    /// buffers without the gate). User-cancellable producers go through
    /// `acquireCancellable` so Stop doesn't leave tasks parked behind a
    /// wedged GPU holder.
    public func acquire(_ owner: String, shared: Bool) async {
        if !canAdmit(owner, shared: shared) {
            waitingByOwner[owner, default: 0] += 1
            repeat {
                await suspend(cancellable: false)
            } while !canAdmit(owner, shared: shared)
            removeWaiting(owner)
        }
        admit(owner, shared: shared)
    }

    /// Cancellation-aware variant of `acquire`. Throws `CancellationError`
    /// when the caller's task is cancelled while waiting (or already
    /// cancelled on entry) — the caller MUST NOT submit GPU work and MUST NOT
    /// call the paired release when this throws.
    public func acquireCancellable(_ owner: String, shared: Bool) async throws {
        try Task.checkCancellation()
        if !canAdmit(owner, shared: shared) {
            waitingByOwner[owner, default: 0] += 1
            while true {
                await suspend(cancellable: true)
                if Task.isCancelled {
                    removeWaiting(owner)
                    // This waiter may have been the foreign waiter blocking
                    // same-owner admissions for the current holder; re-wake
                    // the others so they re-check admissibility.
                    wakeAll()
                    throw CancellationError()
                }
                if canAdmit(owner, shared: shared) { break }
            }
            removeWaiting(owner)
        }
        admit(owner, shared: shared)
    }

    private func admit(_ owner: String, shared: Bool) {
        if currentOwner == nil {
            currentOwner = owner
            currentShared = shared
        }
        activeHolders += 1
    }

    /// Release one acquisition. When the last holder leaves, the gate goes idle
    /// and all waiters are woken to re-contend.
    public func release(_ owner: String) {
        activeHolders = max(0, activeHolders - 1)
        if activeHolders == 0 {
            currentOwner = nil
            currentShared = false
            wakeAll()
        }
    }

    // MARK: - Generation (LLM via BatchEngine) — shared per model

    /// Cancellation-aware: a Stop during the wait throws `CancellationError`
    /// instead of leaving the generation task parked behind a wedged holder.
    /// Do NOT call `exitGeneration` when this throws.
    public func enterGeneration(model: String) async throws {
        try await acquireCancellable("gen:\(model)", shared: true)
    }

    public func exitGeneration(model: String) {
        release("gen:\(model)")
    }

    // MARK: - Embedding (Model2Vec / capability + memory search) — exclusive

    /// Cancellation-aware; do NOT call `exitEmbedding` when this throws.
    public func enterEmbedding() async throws {
        try await acquireCancellable("embedding", shared: false)
    }

    public func exitEmbedding() {
        release("embedding")
    }

    // MARK: - Media prep (audio/image/video encode before generation) — exclusive

    /// Preparing a media-bearing request runs GPU evals on the SUBMITTING
    /// task's thread — the Nemotron-Omni audio pre-encode and any VLM media
    /// encoder that materializes during `UserInputProcessor.prepare` — i.e.
    /// outside the `BatchEngine` actor loop that makes same-model generation
    /// overlap safe. Under the shared `gen:` owner those prep evals could
    /// encode concurrently with an in-flight decode (or another request's
    /// prep) on the shared Metal command queue. Media prep therefore takes
    /// its own exclusive owner; text-only prep does no GPU encode and keeps
    /// the shared generation owner so batching is preserved.
    /// Cancellation-aware; do NOT call `exitMediaPrep` when this throws.
    public func enterMediaPrep(model: String) async throws {
        try await acquireCancellable("prep:\(model)", shared: false)
    }

    public func exitMediaPrep(model: String) {
        release("prep:\(model)")
    }

    // MARK: - PII detection (Rampart NER behind the privacy filter) — exclusive

    /// The Rampart PII model (an MLX BERT token classifier) is another MLX
    /// graph on the shared Metal device: its load materializes the weights
    /// with an `eval`, and every `detect` runs a forward pass (including a
    /// cold-start kernel JIT compile). Observed live as the outbound privacy
    /// scan of a remote-provider request racing an in-flight local
    /// generation's decode on the shared command queue
    /// (`tryCoalescingPreviousComputeCommandEncoder` abort). Exclusive, like
    /// the embedder.
    ///
    /// Cancellation-aware; do NOT call `exitPIIDetection` when this throws.
    public func enterPIIDetection() async throws {
        try await acquireCancellable("pii", shared: false)
    }

    public func exitPIIDetection() {
        release("pii")
    }

    // MARK: - Model load (weight dequant + kernel compile) — exclusive

    public func enterModelLoad(model: String) async {
        await acquire("load:\(model)", shared: false)
    }

    public func exitModelLoad(model: String) {
        release("load:\(model)")
    }

    // MARK: - Model teardown (weight free + GPU drain) — exclusive

    /// Unloading a model is a GPU producer too: freeing the weight arrays
    /// enqueues allocator frees + fences and the `Stream.gpu.synchronize` /
    /// `Memory.clearCache` drains submit/settle device work. Like a load it must
    /// not overlap any other producer — otherwise the next producer (a model
    /// load, image job, or embedder) admitted the instant `unload` returns races
    /// this model's still-in-flight teardown buffers on the shared Metal command
    /// queue (observed as the chat→image handoff `Gather::eval_gpu` /
    /// `computeCommandEncoderWithDispatchType:` abort). A distinct owner from
    /// `load:` keeps teardown vs load distinguishable in telemetry; both are
    /// mutually exclusive against every other owner.
    public func enterModelTeardown(model: String) async {
        await acquire("unload:\(model)", shared: false)
    }

    public func exitModelTeardown(model: String) {
        release("unload:\(model)")
    }

    // MARK: - Image generation (vMLXFlux engine) — exclusive

    /// The native image engine (vMLXFlux) is a second MLX graph on the same Metal
    /// device. Like embedding and model load it must not overlap any other GPU
    /// producer, so it acquires the gate as its own exclusive owner, held across
    /// the entire vMLXFlux event-stream drain (including the terminal VAE decode).
    ///
    /// Cancellation-aware; do NOT call `exitImageGeneration` when this throws.
    /// Image-model TEARDOWN must not use this — it goes through the
    /// non-cancellable `enterModelTeardown` instead, because a teardown that
    /// gives up mid-wait would free weights without the gate.
    public func enterImageGeneration() async throws {
        try await acquireCancellable("image", shared: false)
    }

    public func exitImageGeneration() {
        release("image")
    }
}
