import Foundation
import MLX
import Testing

@testable import OsaurusCore

/// Opt-in, model-free Metal proof. Run alone with a matching metallib beside
/// the test executable; ordinary CI must not allocate GPU buffers here.
@Suite("Live allocator recovery", .enabled(if: ProcessInfo.processInfo.environment["OSAURUS_ADMISSION_ALLOCATOR_PROOF"] == "1"))
struct SubagentAllocatorRecoveryLiveTests {
    @Test("real freed buffers return to MLX while a live array survives")
    func freedBuffersAreReclaimed() async {
        let runtime = ModelRuntime.shared
        await runtime.trimFreedBufferCacheUnderMemoryPressure()
        let originalLimit = Memory.cacheLimit
        Memory.cacheLimit = 128 << 20
        defer { Memory.cacheLimit = originalLimit }

        let retained = MLXArray([Int32(11), 22, 33])
        eval(retained)
        autoreleasepool {
            let scratch = MLXArray(Array(repeating: UInt8(7), count: 64 << 20))
            eval(scratch)
            #expect(scratch.nbytes == 64 << 20)
        }
        Stream.gpu.synchronize()
        let before = Memory.cacheMemory
        let active = Memory.activeMemory
        let availableBefore = ChatResidencyHandoff.availableMemoryBytes()
        #expect(before >= 64 << 20)
        await runtime.trimFreedBufferCacheUnderMemoryPressure()
        let after = Memory.cacheMemory
        let availableAfter = ChatResidencyHandoff.availableMemoryBytes()
        #expect(after < before)
        #expect(Memory.activeMemory == active)
        #expect(retained.asArray(Int32.self) == [11, 22, 33])
        print("ALLOCATOR_PROOF cached_before=\(before) cached_after=\(after) active_bytes=\(active) reclaimable_before=\(availableBefore) reclaimable_after=\(availableAfter)")
    }
}
