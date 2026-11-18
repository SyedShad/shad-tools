import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import ShadCore
@testable import ShadMouseFeature

@Suite("Mouse shortcut dispatch")
struct MouseToolTests {
    @Test @MainActor func outgoingShortcutsPreserveModifiersWithoutRetriggeringMouseInput() throws {
        let chord = KeyChord(15, optionKey | cmdKey | shiftKey | controlKey, "R")
        let events = MouseShortcutSender.events(for: chord)
        #expect(events.map(\.type) == [.keyDown, .keyUp])
        let input = MouseInput()
        let trigger = MouseTrigger(key: 15, modifiers: [.maskAlternate, .maskCommand, .maskShift, .maskControl])
        input.configure(dial: trigger, gesture: trigger, threshold: 30)
        for event in events {
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == 15)
            #expect(event.flags.rawValue == trigger.modifiers)
            #expect(!input.consume(event.type, event))
        }
    }

    @Test func onlyOneEditionConsumesPhysicalInputAndTheOtherCanTakeOver() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("capture.lock")
        let suite = FeatureLease(url: lock)
        let standalone = FeatureLease(url: lock)
        #expect(suite.acquire())
        #expect(suite.acquire())
        #expect(!standalone.acquire())
        suite.release()
        #expect(standalone.acquire())
        #expect(!suite.acquire())
    }
}
