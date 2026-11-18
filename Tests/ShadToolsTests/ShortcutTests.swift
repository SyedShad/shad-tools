import Carbon.HIToolbox
import Testing
@testable import ShadTools

@Test func independentLaunchersCanRunTogether() {
    let keys = Edition.allCases.compactMap { KeyChord.defaults($0)["app.open"] }
    #expect(keys.count == 6)
    for (index, key) in keys.enumerated() {
        #expect(!keys.dropFirst(index + 1).contains(where: key.matches))
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
