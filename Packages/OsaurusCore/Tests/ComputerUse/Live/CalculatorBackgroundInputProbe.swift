import Foundation
import Testing

@testable import OsaurusCore

/// Live proof that the native driver's input lands in a backgrounded Calculator: open it behind the frontmost app,
/// clear it, press 7 through the element route (AXPress) and 3 through the coordinate route (a click posted to its
/// pid), then read the display back. The frontmost app must not change. Needs Accessibility for the test process and
/// a hands-off desktop, so it runs only with `OSAURUS_CU_LIVE_CALCULATOR=1`.
@Suite(
    "Live: background input lands in Calculator", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["OSAURUS_CU_LIVE_CALCULATOR"] == "1"))
struct CalculatorBackgroundInputProbe {
    private let driver = NativeMacDriver()

    private static func bareRole(_ element: CUElement) -> String {
        let role = element.role.lowercased()
        return role.hasPrefix("ax") ? String(role.dropFirst(2)) : role
    }

    private func snapshot(_ pid: Int32) async -> CUSnapshot {
        await driver.capture(
            pid: pid, tier: .ax, windowId: nil, maxElements: 400, focusedWindowOnly: true, interactiveOnly: false)
    }

    private func button(_ label: String, in snapshot: CUSnapshot) -> CUElement? {
        snapshot.elements.first { Self.bareRole($0) == "button" && $0.label == label }
    }

    /// Calculator's display: the text elements that are not button captions.
    private func display(_ snapshot: CUSnapshot) -> [String] {
        snapshot.elements
            .filter { ["statictext", "text", "scrollarea", "group"].contains(Self.bareRole($0)) }
            .compactMap { $0.value ?? $0.label }
            .filter { !$0.isEmpty }
    }

    @Test("element and point clicks change the display the loop sees; the frontmost app stays in front")
    func backgroundClicksLand() async throws {
        let availability = await driver.availability()
        try #require(availability.accessibility, "The test process needs Accessibility")
        let frontBefore = await driver.activeWindow()

        let app = try await driver.open(identifier: "com.apple.calculator", background: true).get()
        print("probe: opened \(app.name) pid=\(app.pid) ready=\(app.ready)")
        var view = await snapshot(app.pid)
        let buttons = view.elements.filter { Self.bareRole($0) == "button" }.compactMap(\.label)
        print("probe: \(view.elements.count) elements; buttons=\(buttons)")
        print("probe: display before=\(display(view))")

        if let clear = button("All Clear", in: view) ?? button("Clear", in: view) {
            let result = await driver.perform(.click(id: clear.id))
            print("probe: clear success=\(result.success) route=\(String(describing: result.routeUsed))")
            try await Task.sleep(for: .milliseconds(300))
            view = await snapshot(app.pid)
        }

        let seven = try #require(button("7", in: view), "no button labelled 7")
        let pressed = await driver.perform(.click(id: seven.id))
        print("probe: element 7 success=\(pressed.success) route=\(String(describing: pressed.routeUsed)) error=\(pressed.error ?? "-")")
        try await Task.sleep(for: .milliseconds(400))
        view = await snapshot(app.pid)
        let afterElement = display(view)
        print("probe: display after element 7=\(afterElement)")
        #expect(afterElement.contains { $0.contains("7") }, "AXPress on 7 did not reach the display")
        // The loop perceives and verifies through this capture: the display has to be in it, or a digit press
        // reads as "no visible change" and the done gate can never pass.
        let loopView = await driver.capture(pid: app.pid, tier: .ax)
        let loopDisplay = display(loopView)
        print("probe: loop capture \(loopView.elements.count) elements; display=\(loopDisplay)")
        #expect(loopDisplay.contains { $0.contains("7") }, "the loop's capture does not show Calculator's display")

        // A click posted to a background SwiftUI app's pid is dropped (recorded, not asserted: a platform limit).
        let three = try #require(button("3", in: view), "no button labelled 3")
        let center = CGPoint(x: three.x + three.w / 2, y: three.y + three.h / 2)
        let posted = await driver.coordinate(.click(x: Double(center.x), y: Double(center.y), pid: app.pid))
        try await Task.sleep(for: .milliseconds(400))
        print("probe: raw coordinate 3 route=\(String(describing: posted.routeUsed)) display=\(display(await snapshot(app.pid)))")

        // What the loop does with `target.point` on 3: hit-test its own capture, then press the control.
        let pointView = await driver.capture(pid: app.pid, tier: .ax)
        let pointed = try #require(ScreenshotPointing.hitTest(center, in: pointView), "the point on 3 hit nothing")
        #expect(pointed.label == "3")
        #expect(ComputerUseLoop.pressesAsElement(.click, pointed), "role=\(pointed.role) actions=\(pointed.actions)")
        let pressed3 = await driver.perform(.click(id: pointed.id))
        try await Task.sleep(for: .milliseconds(400))
        let afterPoint = display(await driver.capture(pid: app.pid, tier: .ax))
        print("probe: point 3 via element success=\(pressed3.success) loop display=\(afterPoint)")
        #expect(afterPoint.contains { $0.contains("73") }, "the point click on 3 did not reach the display")

        let frontAfter = await driver.activeWindow()
        print("probe: frontmost before=\(frontBefore?.app ?? "-") after=\(frontAfter?.app ?? "-")")
        #expect(frontAfter?.pid == frontBefore?.pid, "Calculator must stay behind the frontmost app")
    }
}
