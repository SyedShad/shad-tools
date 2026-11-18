import Carbon.HIToolbox
import Foundation
import Testing
@testable import ShadCore
@testable import ShadShell
@testable import ShadSearchFeature
@testable import ShadAudioFeature
@testable import ShadDrivesFeature
@testable import ShadColorFeature
@testable import ShadWindowsFeature
@testable import ShadCaptureFeature
@testable import ShadClipboardFeature
@testable import ShadMouseFeature

private let featureModules = [
    SearchModule.definition, AudioModule.definition, DrivesModule.definition, ColorModule.definition,
    WindowsModule.definition, CaptureModule.definition, ClipboardModule.definition, MouseModule.definition,
]
private let editions: [Edition] = [.suite(featureModules)] + featureModules.map(Edition.standalone)

@Test func suiteModulesReserveDisjointIDsAndShortcutNamespaces() {
    #expect(Set(featureModules.map(\.id)).count == featureModules.count)
    #expect(Set(featureModules.map(\.commandPrefix)).count == featureModules.count)
    let suiteBindings = Edition.suite(featureModules).shortcuts
    for module in featureModules {
        for (id, chord) in module.commandShortcuts {
            #expect(id.hasPrefix(module.commandPrefix))
            #expect(suiteBindings[id] == chord)
        }
    }
}

@Test func independentLaunchersCanRunTogether() {
    let keys = editions.compactMap { edition in
        let primary = ["clipboard": "clipboard.history", "mouse": "mouse.dial"][edition.id] ?? "app.open"
        return edition.shortcuts[primary]
    }
    #expect(keys.count == editions.count)
    #expect(Edition.standalone(CaptureModule.definition).shortcuts["app.open"]?.label == "⌃⌥⌘P")
    for (index, key) in keys.enumerated() {
        #expect(!keys.dropFirst(index + 1).contains(where: key.matches))
    }
}

@Test func mouseDialShortcutIsSharedBySuiteAndMouseEdition() {
    for edition in editions {
        let chord = edition.shortcuts["mouse.dial"]
        #expect((chord != nil) == (edition.isSuite || edition.id == "mouse"))
        if let chord { #expect(chord.label == "⌃⌥⌘M") }
    }
}

@Test func clipboardShortcutOpensHistoryInBothClipboardEditions() {
    for edition in editions {
        let keys = edition.shortcuts
        let history = keys["clipboard.history"]
        #expect((history != nil) == (edition.isSuite || edition.id == "clipboard"))
        if let history {
            #expect(history.label == "⌃⌥⌘V")
            #expect(keys.filter { $0.key != "clipboard.history" }.values.allSatisfy { !history.matches($0) })
        }
    }
}

@Test func ejectShortcutIsLimitedToEditionsThatCanEject() {
    for edition in editions {
        let chord = edition.shortcuts["drives.eject-all"]
        #expect((chord != nil) == (edition.isSuite || edition.id == "drives"))
        if let chord { #expect(chord.label == "⌃⌥⌘E") }
    }
}

@Test func keyIdentitySurvivesDifferentDisplayLabels() {
    #expect(KeyChord(6, cmdKey, "Z").matches(KeyChord(6, cmdKey, "Y")))
    #expect(!KeyChord(6, cmdKey, "Z").matches(KeyChord(6, controlKey, "Z")))
}


@Test @MainActor func waitingEditionRecoversAReleasedShortcutWithoutReopeningThePalette() async throws {
    let domain = "ShadShortcutTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    // F18 with four modifiers avoids existing launcher and system shortcuts.
    let chord = KeyChord(79, cmdKey | controlKey | optionKey | shiftKey, "F18")
    defaults.set(try JSONEncoder().encode(["app.open": chord]), forKey: "shortcuts.v1")
    var reserved: EventHotKeyRef?
    let identity = EventHotKeyID(signature: 0x53485451, id: 1)
    let status = RegisterEventHotKey(chord.code, chord.modifiers, identity, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reserved)
    let reservation = try #require(reserved, "Carbon returned \(status)")
    var released = false
    defer { if !released { UnregisterEventHotKey(reservation) } }
    let shortcuts = Shortcuts(.standalone(SearchModule.definition), preferences: defaults)
    shortcuts.reconcile(["app.open"])
    #expect(shortcuts.conflicts == ["app.open"])
    released = UnregisterEventHotKey(reservation) == noErr
    let deadline = Date().addingTimeInterval(6)
    while !shortcuts.conflicts.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(shortcuts.conflicts.isEmpty)
}
