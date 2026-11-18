import AppKit
import Carbon.HIToolbox
import Testing
@testable import ShadCore
@testable import ShadMouseFeature

@Suite("Mouse action profiles") @MainActor
struct MouseProfileTests {
    private func withProfiles(_ test: (URL, MouseProfiles) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shad-mouse-profiles-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory, MouseProfiles(directory: directory))
    }

    @Test func defaultsKeepFourGlobalAndFourAppActions() throws {
        try withProfiles { _, model in
            #expect(model.error == nil)
            #expect(!model.configuration.enabled)
            #expect(model.configuration.dialTrigger == .middle && model.configuration.gestureTrigger == .middle)
            let finder = model.actions(for: "com.apple.finder")
            let browser = model.actions(for: "com.apple.Safari")
            let fallback = model.actions(for: "example.unknown")
            #expect([finder, browser, fallback].allSatisfy { $0.count == 8 })
            #expect(Array(finder.prefix(4)) == Array(browser.prefix(4)))
            #expect(Array(finder.suffix(4)) != Array(browser.suffix(4)))
            #expect(finder[4].shortcut == KeyChord(49, 0, "Space"))
            #expect(browser[4].shortcut == KeyChord(17, cmdKey, "T"))
            #expect(fallback == model.actions(for: nil))
            #expect(Set(MouseDirection.allCases.map { model.gesture($0, for: nil).title }).count == 4)
        }
    }

    @Test func profilesSurviveRelaunchAndIndependentEdits() throws {
        try withProfiles { directory, suite in
            let standalone = MouseProfiles(directory: directory)
            let app = "com.example.draw"
            let zoom = MouseAction(title: "Zoom canvas", shortcut: KeyChord(6, 0, "Z"))
            let copyStyle = MouseAction(title: "Copy style", shortcut: KeyChord(8, cmdKey | optionKey, "C"))
            suite.setEnabled(true)
            suite.assign(zoom, to: .application(bundleID: app, name: "Draw", index: 0))
            standalone.assign(copyStyle, to: .universal(1))
            standalone.setThreshold(54)
            suite.setTrigger(.optionClick, forDial: true)
            suite.setTrigger(MouseTrigger(button: 5, modifiers: .maskShift), forDial: false)
            let fresh = MouseProfiles(directory: directory)
            #expect(fresh.configuration.enabled)
            #expect(fresh.configuration.gestureThreshold == 54)
            #expect(fresh.configuration.dialTrigger == .optionClick)
            #expect(fresh.configuration.gestureTrigger == MouseTrigger(button: 5, modifiers: .maskShift))
            #expect(fresh.actions(for: app)[4] == zoom)
            #expect(fresh.actions(for: app)[1] == copyStyle)
            #expect(fresh.actions(for: "com.apple.finder")[1] == copyStyle)
            #expect(fresh.actions(for: "com.apple.finder")[4] != zoom)
            #expect(fresh.actions(for: nil)[4] != zoom)
            #expect(fresh.configuration.apps[app]?.name == "Draw")
        }
    }

    @Test func gestureOverridesOnlyAffectTheSelectedApplication() throws {
        try withProfiles { directory, model in
            let id = "com.example.edit"
            let before = model.gesture(.left, for: id)
            let replacement = MouseAction(title: "Previous Track", shortcut: KeyChord(123, optionKey, "←"))
            model.setAppGestures(true, bundleID: id, name: "Edit")
            model.assign(replacement, to: .gesture(.left, bundleID: id, name: "Edit"))
            let again = MouseProfiles(directory: directory)
            #expect(again.gesture(.left, for: id) == replacement)
            #expect(again.gesture(.left, for: "com.example.other") == before)
            #expect(again.gesture(.right, for: id) == again.configuration.gestures[.right])
            again.setAppGestures(false, bundleID: id, name: "Edit")
            #expect(again.gesture(.left, for: id) == before)
            again.setAppGestures(true, bundleID: id, name: "Edit")
            #expect(again.gesture(.left, for: id) == replacement)
        }
    }
}
