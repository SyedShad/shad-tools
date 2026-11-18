import Carbon.HIToolbox
import Testing
@testable import ShadTools

@Test func independentLaunchersCanRunTogether() {
    let keys = Edition.allCases.compactMap { edition in
        let primary = [Edition.clipboard: "clipboard.history", .mouse: "mouse.dial"][edition] ?? "app.open"
        return KeyChord.defaults(edition)[primary]
    }
    #expect(keys.count == Edition.allCases.count)
    #expect(KeyChord.defaults(.capture)["app.open"]?.label == "⌃⌥⌘P")
    for (index, key) in keys.enumerated() {
        #expect(!keys.dropFirst(index + 1).contains(where: key.matches))
    }
}

@Test func mouseDialShortcutIsSharedBySuiteAndMouseEdition() {
    for edition in Edition.allCases {
        let chord = KeyChord.defaults(edition)["mouse.dial"]
        #expect((chord != nil) == (edition == .suite || edition == .mouse))
        if let chord { #expect(chord.label == "⌃⌥⌘M") }
    }
}

@Test func clipboardShortcutOpensHistoryInBothClipboardEditions() {
    for edition in Edition.allCases {
        let keys = KeyChord.defaults(edition)
        let history = keys["clipboard.history"]
        #expect((history != nil) == (edition == .suite || edition == .clipboard))
        if let history {
            #expect(history.label == "⌃⌥⌘V")
            #expect(keys.filter { $0.key != "clipboard.history" }.values.allSatisfy { !history.matches($0) })
        }
    }
}

@Test func ejectShortcutIsLimitedToEditionsThatCanEject() {
    for edition in Edition.allCases {
        let chord = KeyChord.defaults(edition)["drives.eject-all"]
        #expect((chord != nil) == (edition == .suite || edition == .drives))
        if let chord { #expect(chord.label == "⌃⌥⌘E") }
    }
}

@Test func keyIdentitySurvivesDifferentDisplayLabels() {
    #expect(KeyChord(6, cmdKey, "Z").matches(KeyChord(6, cmdKey, "Y")))
    #expect(!KeyChord(6, cmdKey, "Z").matches(KeyChord(6, controlKey, "Z")))
}
