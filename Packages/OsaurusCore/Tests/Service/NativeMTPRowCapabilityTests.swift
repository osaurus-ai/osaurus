import Foundation
import Testing

@testable import OsaurusCore

/// The depth row rendered on models with no MTP head because the capability
/// filter matched the bare "mtp:" prefix every status line carries.
@Suite("Speculative Depth row capability filter")
struct NativeMTPRowCapabilityTests {
    @Test("headless statuses are NOT capable")
    func headlessRejected() {
        #expect(
            !FloatingInputCard.statusIndicatesNativeMTPHead(
                "mtp: none, layers=0, tensors=0"))
        #expect(
            !FloatingInputCard.statusIndicatesNativeMTPHead(
                "mtp: unknown, layers=0, tensors=0"))
        #expect(
            !FloatingInputCard.statusIndicatesNativeMTPHead(
                "mtp: metadata_only_missing_weights, layers=1, tensors=0"))
        #expect(!FloatingInputCard.statusIndicatesNativeMTPHead(nil))
        #expect(!FloatingInputCard.statusIndicatesNativeMTPHead(""))
    }

    @Test("real heads ARE capable, with and without tuning suffixes")
    func realHeadsAccepted() {
        #expect(
            FloatingInputCard.statusIndicatesNativeMTPHead(
                "mtp: preserved_disabled, layers=1, tensors=13, tuning=d2, speculative=on"))
        #expect(
            FloatingInputCard.statusIndicatesNativeMTPHead(
                "mtp: enabled, layers=1, tensors=13, speculative=off (vmlx_mtp_tuning.json tuning required)"))
        #expect(
            FloatingInputCard.statusIndicatesNativeMTPHead(
                "mtp: speculative_verified, layers=1, tensors=13"))
    }

    @Test("a head-implying mode with zero tensors is rejected")
    func zeroTensorHeadRejected() {
        #expect(
            !FloatingInputCard.statusIndicatesNativeMTPHead(
                "mtp: enabled, layers=1, tensors=0"))
    }
}
