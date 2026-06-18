//
//  PerceptionTests.swift
//  OsaurusCoreTests — Computer Use
//
//  PR3 coverage for the local-first perception layer: the `CaptureRouter`
//  escalation ladder + cloud-route gating, the `CloudVisionConsent` gate, the
//  `FrameScrubber` type guarantee + masking superset invariant, the
//  `ComputerUseRunMetrics` buckets, and the ax-resolvable sweep.
//

import AppKit
import Foundation
import XCTest

@testable import OsaurusCore

private func availability(screenRecording: Bool) -> MacDriverAvailability {
    MacDriverAvailability(accessibility: true, screenRecording: screenRecording, skyLight: true)
}

// MARK: - Capture router

final class CaptureRouterTests: XCTestCase {
    func testLadderEscalatesOneRungWithScreenRecording() {
        let av = availability(screenRecording: true)
        XCTAssertEqual(CaptureRouter.nextTier(current: .ax, reason: .axEmpty, availability: av), .som)
        XCTAssertEqual(
            CaptureRouter.nextTier(current: .som, reason: .targetUnresolved, availability: av),
            .vision
        )
        XCTAssertEqual(
            CaptureRouter.nextTier(current: .vision, reason: .pixelsRequested, availability: av),
            .vision
        )
    }

    func testNoScreenRecordingPinsToAx() {
        let av = availability(screenRecording: false)
        XCTAssertEqual(CaptureRouter.nextTier(current: .ax, reason: .axEmpty, availability: av), .ax)
        XCTAssertFalse(CaptureRouter.canEscalate(from: .ax, availability: av))
        XCTAssertTrue(CaptureRouter.canEscalate(from: .ax, availability: availability(screenRecording: true)))
        XCTAssertFalse(
            CaptureRouter.canEscalate(from: .vision, availability: availability(screenRecording: true))
        )
    }

    func testEscalateForEmptyAXClimbsWhenPixelsAvailable() {
        let av = availability(screenRecording: true)
        // Empty view (0 items) escalates one rung up the ladder.
        XCTAssertEqual(CaptureRouter.escalateForEmptyAX(currentTier: .ax, itemCount: 0, availability: av), .som)
        XCTAssertEqual(
            CaptureRouter.escalateForEmptyAX(currentTier: .som, itemCount: 0, availability: av),
            .vision
        )
        // Already at the top → nothing to climb to.
        XCTAssertNil(CaptureRouter.escalateForEmptyAX(currentTier: .vision, itemCount: 0, availability: av))
    }

    func testEscalateForEmptyAXStaysOnPopulatedView() {
        let av = availability(screenRecording: true)
        XCTAssertNil(CaptureRouter.escalateForEmptyAX(currentTier: .ax, itemCount: 3, availability: av))
        // A custom threshold treats a near-empty view as escalatable.
        XCTAssertEqual(
            CaptureRouter.escalateForEmptyAX(currentTier: .ax, itemCount: 1, availability: av, threshold: 2),
            .som
        )
    }

    func testEscalateForEmptyAXPinsWithoutScreenRecording() {
        // No pixels available → no escalation even on an empty view.
        XCTAssertNil(
            CaptureRouter.escalateForEmptyAX(
                currentTier: .ax,
                itemCount: 0,
                availability: availability(screenRecording: false)
            )
        )
    }

    func testCloudRouteRequiresConsent() async {
        let frame = await makeScrubbedFrame()
        let av = availability(screenRecording: true)
        // No consent → no route, no matter that the frame is scrubbed.
        XCTAssertNil(CaptureRouter.cloudRoute(scrubbed: frame, consentGranted: false, availability: av))
        // No screen recording → not permitted even with consent.
        XCTAssertFalse(
            CaptureRouter.cloudVisionPermitted(
                consentGranted: true,
                availability: availability(screenRecording: false)
            )
        )
        // Consent + screen recording → the cloud route exists, carrying the frame.
        guard
            case .cloudVision(let carried)? = CaptureRouter.cloudRoute(
                scrubbed: frame,
                consentGranted: true,
                availability: av
            )
        else {
            return XCTFail("expected a cloudVision route")
        }
        XCTAssertEqual(carried, frame)
    }

    /// A scrubbed frame can only come from `FrameScrubber` — build one from a
    /// trivial solid image (no text ⇒ nothing masked, but still a `ScrubbedFrame`).
    private func makeScrubbedFrame() async -> ScrubbedFrame {
        let cu = renderCUImage(text: "")
        let frame = await FrameScrubber.scrub(cu, mode: .pii)
        return frame
            ?? {
                // Should never happen for a decodable image; fail loudly if it does.
                XCTFail("FrameScrubber returned nil for a valid image")
                fatalError("unreachable")
            }()
    }
}

// MARK: - Cloud vision consent

final class CloudVisionConsentTests: XCTestCase {
    @MainActor
    func testDefaultOffAndScopes() {
        let suite = "cu-consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let consent = CloudVisionConsent(defaults: defaults)
        XCTAssertFalse(consent.isGranted)

        consent.grantForSession()
        XCTAssertTrue(consent.isGranted)
        XCTAssertFalse(consent.isPersistentlyGranted)

        consent.revoke()
        XCTAssertFalse(consent.isGranted)

        consent.grantPersistently()
        XCTAssertTrue(consent.isGranted)
        // A fresh instance over the same defaults sees the persisted grant.
        XCTAssertTrue(CloudVisionConsent(defaults: defaults).isPersistentlyGranted)

        consent.setPersistent(false)
        XCTAssertFalse(consent.isGranted)
    }
}

// MARK: - Frame scrubber

final class FrameScrubberTests: XCTestCase {
    func testReturnsScrubbedFrameForValidImage() async {
        let cu = renderCUImage(text: "hello world")
        let frame = await FrameScrubber.scrub(cu, mode: .pii)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.image.mimeType, "image/jpeg")
    }

    func testAllTextMasksAtLeastAsMuchAsPII() async {
        // Independent of exact OCR output: masking every text region is a
        // superset of masking only the PII regions.
        let image = renderCGImage(text: "Reach me: jane.doe@example.com or 415-555-0142")
        guard let pii = await FrameScrubber.scrub(cgImage: image, mode: .pii),
            let all = await FrameScrubber.scrub(cgImage: image, mode: .allText)
        else { return XCTFail("scrub returned nil") }
        XCTAssertGreaterThanOrEqual(all.1.maskedRegions, pii.1.maskedRegions)
        // If OCR ran at all, allText masks exactly the recognized regions.
        if all.1.textRegions > 0 {
            XCTAssertEqual(all.1.maskedRegions, all.1.textRegions)
        }
    }
}

// MARK: - Metrics

final class ComputerUseRunMetricsTests: XCTestCase {
    func testCountAndRateBuckets() {
        XCTAssertEqual(ComputerUseRunMetrics.countBucket(0), "0")
        XCTAssertEqual(ComputerUseRunMetrics.countBucket(2), "1-3")
        XCTAssertEqual(ComputerUseRunMetrics.countBucket(5), "4-9")
        XCTAssertEqual(ComputerUseRunMetrics.countBucket(99), "10+")

        XCTAssertEqual(ComputerUseRunMetrics.rateBucket(nil), "na")
        XCTAssertEqual(ComputerUseRunMetrics.rateBucket(0.1), "low")
        XCTAssertEqual(ComputerUseRunMetrics.rateBucket(0.5), "med")
        XCTAssertEqual(ComputerUseRunMetrics.rateBucket(0.95), "high")
    }

    func testTierAndRateAccumulation() {
        var m = ComputerUseRunMetrics()
        XCTAssertNil(m.axResolvableRate)
        m.recordResolveAttempt(success: true)
        m.recordResolveAttempt(success: false)
        XCTAssertEqual(m.axResolvableRate, 0.5)

        XCTAssertEqual(m.maxTier, .ax)
        m.raiseTier(to: .som)
        XCTAssertEqual(m.maxTier, .som)
        m.raiseTier(to: .ax)  // never lowers
        XCTAssertEqual(m.maxTier, .som)
        m.raiseTier(to: .vision)
        XCTAssertEqual(m.maxTier, .vision)
    }
}

// MARK: - Ax-resolvable sweep

final class AxResolvableSweepTests: XCTestCase {
    func testSweepTalliesResolutionOutcomes() async {
        let driver = MockMacDriver.demo()  // pid 4242: Search textfield + Go button
        let probe = AxProbe(
            pid: 4242,
            targets: [
                AgentTarget(describe: "Go"),  // exact label → resolved
                AgentTarget(describe: "Search"),  // exact label → resolved
                AgentTarget(describe: "zzzzz"),  // no match → reobserve
            ]
        )
        let result = await AxResolvableSweep.run(driver: driver, probes: [probe])
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.resolved, 2)
        XCTAssertEqual(result.reobserve, 1)
        XCTAssertEqual(result.deadEnd, 0)
        XCTAssertEqual(result.resolvableRate, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testEmptySweepHasZeroRate() async {
        let result = await AxResolvableSweep.run(driver: MockMacDriver(), probes: [])
        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(result.resolvableRate, 0)
    }
}

// MARK: - Vision attachment decision

final class VisionAttachmentTests: XCTestCase {
    private let frame = renderCUImage(text: "")
    private let av = availability(screenRecording: true)

    func testNoImageOrNonVisionModelAttachesNothing() {
        let visionLocal = VisionContext(
            modelAcceptsImages: true,
            modelIsLocal: true,
            cloudConsent: false
        )
        XCTAssertEqual(VisionAttachment.decide(image: nil, context: visionLocal, availability: av), .none)

        let nonVision = VisionContext(
            modelAcceptsImages: false,
            modelIsLocal: true,
            cloudConsent: true
        )
        XCTAssertEqual(
            VisionAttachment.decide(image: frame, context: nonVision, availability: av),
            .none
        )
    }

    func testLocalVisionModelAttachesDirectly() {
        let ctx = VisionContext(modelAcceptsImages: true, modelIsLocal: true, cloudConsent: false)
        XCTAssertEqual(
            VisionAttachment.decide(image: frame, context: ctx, availability: av),
            .localFrame(frame)
        )
    }

    func testRemoteVisionModelNeedsConsent() {
        let consented = VisionContext(
            modelAcceptsImages: true,
            modelIsLocal: false,
            cloudConsent: true
        )
        XCTAssertEqual(
            VisionAttachment.decide(image: frame, context: consented, availability: av),
            .needsScrubForCloud(frame)
        )

        let noConsent = VisionContext(
            modelAcceptsImages: true,
            modelIsLocal: false,
            cloudConsent: false
        )
        XCTAssertEqual(
            VisionAttachment.decide(image: frame, context: noConsent, availability: av),
            .none
        )
    }

    func testRemoteVisionModelNeedsScreenRecordingForCloud() {
        // Consent without Screen Recording can't reach the cloud route.
        let ctx = VisionContext(modelAcceptsImages: true, modelIsLocal: false, cloudConsent: true)
        XCTAssertEqual(
            VisionAttachment.decide(
                image: frame,
                context: ctx,
                availability: availability(screenRecording: false)
            ),
            .none
        )
    }
}

// MARK: - Image helpers

/// Render text onto a white background and return the CGImage.
private func renderCGImage(text: String, size: CGSize = CGSize(width: 640, height: 140)) -> CGImage {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    if !text.isEmpty {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: CGPoint(x: 20, y: 50), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

private func renderCUImage(text: String) -> CUImage {
    let cg = renderCGImage(text: text)
    let rep = NSBitmapImageRep(cgImage: cg)
    let data = rep.representation(using: .png, properties: [:])!
    return CUImage(
        base64: data.base64EncodedString(),
        mimeType: "image/png",
        width: cg.width,
        height: cg.height
    )
}
