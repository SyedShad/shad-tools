import AppKit
import Testing
@testable import ShadTools

@Suite("Mouse triggers and gestures")
@MainActor
struct MouseInputTests {
    /// Exercise the production tap decoder with Quartz events; nothing is posted to the user's session.
    private func mouse(_ type: CGEventType, _ button: Int, x: CGFloat = 200, y: CGFloat = 150,
                       flags: CGEventFlags = [], dx: Int64 = 0, dy: Int64 = 0) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        event.flags = flags
        return event
    }

    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], repeating: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
        return event
    }

    private func flushEvents() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func gesturesChooseEachDirectionOnceAndIgnoreSubsequentDrift() async {
        let router = MouseInput()
        router.configure(dial: .middle, gesture: MouseTrigger(button: 7), threshold: 30)
        var issued: [MouseDirection] = []
        router.onEvent = { if case .gesture(let direction) = $0 { issued.append(direction) } }
        for (x, y) in [(202, 105), (202, 191), (154, 151), (243, 149)] {
            let down = mouse(.otherMouseDown, 7)
            #expect(router.consume(.otherMouseDown, down))
            #expect(router.consume(.otherMouseDragged, mouse(.otherMouseDragged, 7, x: CGFloat(x), y: CGFloat(y))))
            // After committing to a direction, a return towards the origin does not flip the action.
            #expect(router.consume(.otherMouseDragged, mouse(.otherMouseDragged, 7)))
            #expect(router.consume(.otherMouseUp, mouse(.otherMouseUp, 7)))
            #expect(!router.consume(.otherMouseUp, mouse(.otherMouseUp, 7)))
        }
        await flushEvents()
        #expect(issued == [.up, .down, .left, .right])
    }

    @Test func oneButtonSupportsBothTapAndDragAndWorksAtScreenEdges() async {
        let router = MouseInput()
        router.configure(dial: .middle, gesture: .middle, threshold: 25)
        var result: [MouseInputEvent] = []
        router.onEvent = { result.append($0) }
        #expect(router.consume(.otherMouseDown, mouse(.otherMouseDown, 2)))
        #expect(router.consume(.otherMouseDragged, mouse(.otherMouseDragged, 2, x: 201)))
        #expect(router.consume(.otherMouseUp, mouse(.otherMouseUp, 2, x: 201)))
        // The absolute pointer stays clamped at a screen edge while raw deltas continue.
        #expect(router.consume(.otherMouseDown, mouse(.otherMouseDown, 2)))
        for _ in 0..<4 {
            #expect(router.consume(.otherMouseDragged, mouse(.otherMouseDragged, 2, dy: -7)))
        }
        #expect(router.consume(.otherMouseUp, mouse(.otherMouseUp, 2)))
        await flushEvents()
        let tapped = result.filter { if case .toggleDial = $0 { return true }; return false }
        #expect(tapped.count == 1)
        #expect(result.filter { $0 == .gesture(.up) }.count == 1)
    }

    @Test func separateDialEmitsAppKitPointsOnDownMoveAndRelease() async {
        let router = MouseInput()
        router.configure(dial: MouseTrigger(button: 12), gesture: .middle, threshold: 25)
        var result: [MouseInputEvent] = []
        router.onEvent = { result.append($0) }
        let h = CGDisplayBounds(CGMainDisplayID()).height
        // Coordinates include a screen to the left and another above the menu bar display.
        #expect(router.consume(.otherMouseDown, mouse(.otherMouseDown, 12, x: -240, y: -65)))
        #expect(router.consume(.otherMouseDragged, mouse(.otherMouseDragged, 12, x: -275, y: -45)))
        #expect(router.consume(.otherMouseUp, mouse(.otherMouseUp, 12, x: -280, y: -45)))
        await flushEvents()
        #expect(result == [.dialBegan(CGPoint(x: -240, y: h + 65)),
                            .dialMoved(CGPoint(x: -275, y: h + 45)),
                            .dialEnded(CGPoint(x: -280, y: h + 45))])
    }

    @Test func exactMouseModifiersKeepOrdinaryClicksAndTypedKeysAvailable() async {
        let router = MouseInput()
        router.configure(dial: .optionClick, gesture: MouseTrigger(button: 1, modifiers: .maskControl), threshold: 30)
        var result: [MouseInputEvent] = []
        router.onEvent = { result.append($0) }
        #expect(!router.consume(.leftMouseDown, mouse(.leftMouseDown, 0)))
        #expect(!router.consume(.leftMouseUp, mouse(.leftMouseUp, 0)))
        #expect(!router.consume(.rightMouseDown, mouse(.rightMouseDown, 1)))
        #expect(!router.consume(.keyDown, key(0, down: true)))
        #expect(!router.consume(.keyUp, key(0, down: false)))
        #expect(!router.consume(.otherMouseDragged, mouse(.otherMouseDragged, 8)))
        #expect(router.consume(.leftMouseDown, mouse(.leftMouseDown, 0, flags: [.maskAlternate, .maskAlphaShift])))
        // Releasing Option before the click completes must not leak an orphan mouse-up.
        #expect(router.consume(.leftMouseUp, mouse(.leftMouseUp, 0)))
        await flushEvents()
        #expect(result.count == 2)
    }

    @Test func keyboardEmulatedMouseButtonsIgnoreRepeatAndSyntheticShortcutOutputs() async {
        let router = MouseInput()
        let f13 = MouseTrigger(key: 105, modifiers: [])
        router.configure(dial: f13, gesture: f13, threshold: 25)
        var result: [MouseInputEvent] = []
        router.onEvent = { result.append($0) }
        let synthetic = key(105, down: true)
        synthetic.setIntegerValueField(.eventSourceUserData, value: MouseInput.syntheticEventTag)
        #expect(!router.consume(.keyDown, synthetic))
        #expect(router.consume(.keyDown, key(105, down: true)))
        #expect(router.consume(.keyDown, key(105, down: true, repeating: true)))
        let origin = CGEvent(source: nil)!.location
        #expect(router.consume(.mouseMoved, mouse(.mouseMoved, 0, x: origin.x - 75, y: origin.y)))
        #expect(router.consume(.keyUp, key(105, down: false)))
        #expect(!router.consume(.keyUp, key(105, down: false)))
        await flushEvents()
        #expect(result.count == 2)
        #expect(result.last == .gesture(.left))
    }

    @Test func cancellationAndLostTapDiscardPendingGestures() async {
        let router = MouseInput()
        router.configure(dial: .middle, gesture: MouseTrigger(button: 4), threshold: 20)
        var result: [MouseInputEvent] = []
        router.onEvent = { result.append($0) }
        #expect(router.consume(.otherMouseDown, mouse(.otherMouseDown, 4)))
        #expect(router.consume(.otherMouseDragged, mouse(.otherMouseDragged, 4, y: 100)))
        #expect(router.consume(.keyDown, key(53, down: true)))
        #expect(router.consume(.keyUp, key(53, down: false)))
        #expect(router.consume(.otherMouseUp, mouse(.otherMouseUp, 4)))
        #expect(router.consume(.otherMouseDown, mouse(.otherMouseDown, 4)))
        #expect(!router.consume(.tapDisabledByTimeout, mouse(.otherMouseDown, 4)))
        #expect(!router.consume(.otherMouseUp, mouse(.otherMouseUp, 4)))
        #expect(!router.consume(.mouseMoved, mouse(.mouseMoved, 0)))
        await flushEvents()
        #expect(result.filter { $0 == .cancel }.count == 2)
        #expect(!result.contains { if case .gesture = $0 { return true }; return false })
    }

    @Test func triggerBindingsRoundTripAndRejectBareTypingOrBarePrimaryClick() throws {
        let shortcut = MouseTrigger(key: 9, modifiers: [.maskControl, .maskAlternate], keyName: "V")
        #expect(shortcut.isUsable && shortcut.label == "⌃⌥V")
        #expect(MouseTrigger(key: 9, modifiers: [.maskControl, .maskAlternate]) == shortcut)
        #expect(try JSONDecoder().decode(MouseTrigger.self, from: JSONEncoder().encode(shortcut)) == shortcut)
        #expect(MouseTrigger.optionClick.label == "⌥Left Click")
        #expect(!MouseTrigger(button: 0).isUsable)
        #expect(MouseTrigger(button: 18).label == "Button 19")
        #expect(MouseTrigger.middle.label == "Middle Click")
        #expect(MouseTrigger(key: 105, modifiers: []).label == "F13")
        #expect(!MouseTrigger(key: 18, modifiers: .maskShift).isUsable)
        #expect(!MouseTrigger(key: 53, modifiers: .maskCommand).isUsable)
    }
}
