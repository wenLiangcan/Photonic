import AppKit
import Testing
@testable import Photonic

@MainActor
private final class Desktop {
    var time: TimeInterval = 100
    var pointer = CGPoint(x: 50, y: 50)
    var buttons = 0
    var window = ControlVisibilityController.WindowState(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    var hides = 0
    var unhides = 0

    func controller() -> ControlVisibilityController {
        ControlVisibilityController(environment: .init(
            now: { self.time }, pointerLocation: { self.pointer },
            pressedButtons: { self.buttons }, window: { self.window },
            hideCursor: { self.hides += 1 }, unhideCursor: { self.unhides += 1 },
            schedulesTimer: false
        ))
    }

    func advance(_ seconds: TimeInterval, _ controller: ControlVisibilityController) {
        time += seconds
        controller.checkInactivity()
    }
}

@Suite("Widget and cursor inactivity regressions")
@MainActor
struct ControlVisibilityTests {
    @Test func inactivityHidesOnlyAfterTheDeadlineAndBalancesCursorCalls() {
        let desktop = Desktop()
        let controller = desktop.controller()
        controller.scheduleHide()
        desktop.advance(1.79, controller)
        #expect(controller.isVisible)
        #expect(desktop.hides == 0)
        desktop.advance(0.02, controller)
        #expect(!controller.isVisible)
        #expect(desktop.hides == 1)
        desktop.advance(10, controller)
        #expect(desktop.hides == 1)
        controller.pointerActivity()
        #expect(controller.isVisible)
        #expect(desktop.unhides == 1)
        controller.pointerActivity()
        controller.cancel()
        #expect(desktop.unhides == 1)
    }

    @Test func continuousMovementKeepsControlsVisibleWithoutMouseMoveEvents() {
        let desktop = Desktop()
        let controller = desktop.controller()
        for _ in 0..<100 {
            desktop.pointer.x += 0.1
            desktop.advance(0.1, controller)
            #expect(controller.isVisible)
        }
        #expect(desktop.hides == 0)
        desktop.advance(1.79, controller)
        #expect(controller.isVisible)
        desktop.advance(0.02, controller)
        #expect(!controller.isVisible)
        desktop.pointer.y += 1
        desktop.advance(0.1, controller)
        #expect(controller.isVisible)
        #expect(desktop.unhides == 1)
    }

    @Test(arguments: [1, 2, 4])
    func holdingAnyMouseButtonPreventsHiding(button: Int) {
        let desktop = Desktop()
        let controller = desktop.controller()
        desktop.buttons = button
        desktop.advance(30, controller)
        #expect(controller.isVisible)
        desktop.buttons = 0
        controller.pointerActivity()
        desktop.advance(1.79, controller)
        #expect(controller.isVisible)
        desktop.advance(0.02, controller)
        #expect(!controller.isVisible)
    }

    @Test func clickNearDeadlineExtendsTheWholeVisibilityPeriod() {
        let desktop = Desktop()
        let controller = desktop.controller()
        desktop.advance(1.7, controller)
        controller.interactionBegan()
        desktop.advance(1.7, controller)
        #expect(controller.isVisible)
        controller.pointerActivity()
        desktop.advance(1.7, controller)
        #expect(controller.isVisible)
        desktop.advance(0.11, controller)
        #expect(!controller.isVisible)
    }

    @Test(arguments: [false, true])
    func hoverAndSliderTrackingPreventHiding(slider: Bool) {
        let desktop = Desktop()
        let controller = desktop.controller()
        if slider { controller.setWaterfallSizeAdjusting(true) }
        else { controller.setPointerOverControls(true) }
        desktop.advance(30, controller)
        #expect(controller.isVisible)
        if slider { controller.setWaterfallSizeAdjusting(false) }
        else { controller.setPointerOverControls(false) }
        desktop.advance(1.79, controller)
        #expect(controller.isVisible)
        desktop.advance(0.02, controller)
        #expect(!controller.isVisible)
    }

    @Test func filePickerRevealsCursorAndSuspendsHidingUntilDismissed() {
        let desktop = Desktop()
        let controller = desktop.controller()
        desktop.advance(2, controller)
        controller.suspend()
        #expect(controller.isVisible)
        #expect(desktop.unhides == 1)
        desktop.advance(120, controller)
        #expect(controller.isVisible)
        #expect(desktop.hides == 1)
        controller.resume()
        desktop.advance(1.79, controller)
        #expect(controller.isVisible)
        desktop.advance(0.02, controller)
        #expect(!controller.isVisible)
        #expect(desktop.hides == 2)
    }

    @Test(arguments: ["inactive", "notKey", "invisible", "sheet", "modal"])
    func unavailableViewerRevealsCursor(reason: String) {
        let desktop = Desktop()
        let controller = desktop.controller()
        desktop.advance(2, controller)
        switch reason {
        case "inactive": desktop.window.isActive = false
        case "notKey": desktop.window.isKey = false
        case "invisible": desktop.window.isVisible = false
        case "sheet": desktop.window.hasSheet = true
        default: desktop.window.hasModal = true
        }
        desktop.advance(30, controller)
        #expect(controller.isVisible)
        #expect(desktop.unhides == 1)
    }

    @Test func leavingWindowNeverLeavesTheDesktopCursorHidden() {
        let desktop = Desktop()
        let controller = desktop.controller()
        desktop.advance(2, controller)
        desktop.pointer = CGPoint(x: 200, y: 200)
        controller.pointerExited()
        desktop.advance(0.1, controller)
        desktop.advance(2, controller)
        #expect(!controller.isPointerInsideWindow)
        #expect(desktop.unhides == 1)
        #expect(desktop.hides == 1)
        controller.cancel()
        #expect(desktop.unhides == 1)
    }

    @Test func teardownUnhidesCursorExactlyOnce() {
        let desktop = Desktop()
        let controller = desktop.controller()
        desktop.advance(2, controller)
        controller.cancel()
        controller.cancel()
        #expect(desktop.hides == 1)
        #expect(desktop.unhides == 1)
    }
}

@Suite("AppKit input dispatch regressions")
@MainActor
struct InputDispatchTests {
    @Test func testsDoNotInitializeTheApplication() {
        #expect(NSApp == nil, "Regression tests must not launch Photonic's application entry point")
    }

    private func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
    }

    @Test func liveActivitySchedulerWaitsUntilMouseUpReturns() async throws {
        @MainActor final class DispatchState {
            var finished = false
        }
        let state = DispatchState()
        let event = try mouse(.leftMouseUp)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let returned = ViewerInputRouter.route(
                event, interactionBegan: {},
                pointerActivity: {
                    #expect(state.finished, "The live scheduler must let AppKit finish click dispatch first")
                    continuation.resume()
                },
                leftMouseDown: { $0 }, scrollWheel: { $0 }, keyDown: { $0 }
            )
            #expect(returned === event)
            state.finished = true
        }
    }

    @Test func wheelHandlingStillReceivesEventsAndDefersActivity() throws {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 10, wheel2: 0, wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        var pending: [@MainActor () -> Void] = []
        var scrolls = 0
        var activity = 0
        let returned = ViewerInputRouter.route(
            event, interactionBegan: { Issue.record("Wheel began button tracking") },
            pointerActivity: { activity += 1 }, deferActivity: { pending.append($0) },
            leftMouseDown: { $0 },
            scrollWheel: { received in
                #expect(received === event)
                scrolls += 1
                return nil
            },
            keyDown: { event in Issue.record("Wheel entered keyboard handling"); return event }
        )
        #expect(returned == nil)
        #expect(scrolls == 1)
        #expect(activity == 0)
        #expect(pending.count == 1)
        pending.forEach { $0() }
        #expect(activity == 1)
    }

    @Test func explicitlyHandledHeaderClickCanStillBeConsumed() throws {
        let event = try mouse(.leftMouseDown)
        var headerActions = 0
        let returned = ViewerInputRouter.route(
            event, interactionBegan: {}, pointerActivity: {}, deferActivity: { $0() },
            leftMouseDown: { _ in headerActions += 1; return nil },
            scrollWheel: { $0 }, keyDown: { $0 }
        )
        #expect(returned == nil)
        #expect(headerActions == 1)
    }

    @Test(arguments: [
        NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved
    ])
    func pointerEventsKeepTheirIdentityAndNeverEnterKeyboardHandling(type: NSEvent.EventType) throws {
        let event = try mouse(type)
        var began = 0
        var activity = 0
        var pending: [@MainActor () -> Void] = []
        let returned = ViewerInputRouter.route(
            event, interactionBegan: { began += 1 }, pointerActivity: { activity += 1 },
            deferActivity: { pending.append($0) },
            leftMouseDown: { $0 },
            scrollWheel: { event in Issue.record("Mouse event entered wheel handling"); return event },
            keyDown: { event in Issue.record("Mouse event entered keyboard handling"); return event }
        )
        #expect(returned === event)
        #expect(activity == 0, "Visibility must not change during mouse-up dispatch")
        let deferred = [.leftMouseUp, .rightMouseUp, .otherMouseUp, .mouseMoved].contains(type)
        #expect(began == (deferred ? 0 : 1))
        #expect(pending.count == (deferred ? 1 : 0))
        pending.forEach { $0() }
        #expect(activity == pending.count)
    }

    @Test(arguments: ["j", "k", "←", "→"])
    func keyboardNavigationPreservesHiddenControlsAndCursor(key: String) throws {
        let desktop = Desktop()
        let controller = desktop.controller()
        desktop.advance(2, controller)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
        ))
        var navigations = 0
        let returned = ViewerInputRouter.route(
            event, interactionBegan: { controller.interactionBegan() },
            pointerActivity: { controller.pointerActivity() },
            deferActivity: { $0() }, leftMouseDown: { $0 }, scrollWheel: { $0 },
            keyDown: { _ in navigations += 1; return nil }
        )
        #expect(returned == nil)
        #expect(navigations == 1)
        #expect(!controller.isVisible)
        #expect(desktop.unhides == 0)
    }

    @Test func buttonDownUpSequenceCompletesBeforeVisibilityUpdates() throws {
        let desktop = Desktop()
        let controller = desktop.controller()
        desktop.advance(1.7, controller)
        var pending: [@MainActor () -> Void] = []
        var delivered: [NSEvent.EventType] = []
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try mouse(type)
            let returned = ViewerInputRouter.route(
                event, interactionBegan: { controller.interactionBegan() },
                pointerActivity: { controller.pointerActivity() },
                deferActivity: { pending.append($0) }, leftMouseDown: { $0 }, scrollWheel: { $0 },
                keyDown: { event in Issue.record("Button click reached keyboard code"); return event }
            )
            if let returned { delivered.append(returned.type) }
            desktop.advance(0.1, controller)
            #expect(controller.isVisible)
        }
        #expect(delivered == [.leftMouseDown, .leftMouseUp])
        #expect(pending.count == 1)
        pending.forEach { $0() }
        desktop.advance(1.79, controller)
        #expect(controller.isVisible)
    }
}
