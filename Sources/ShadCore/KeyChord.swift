import AppKit
import Carbon.HIToolbox

package struct KeyChord: Codable, Equatable {
    package let code: UInt32
    package let modifiers: UInt32
    package let key: String

    package var label: String {
        var text = ""
        for (mask, glyph) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(mask) != 0 { text += glyph }
        }
        return text + key
    }

    package init(_ code: Int, _ modifiers: Int, _ key: String) {
        self.code = UInt32(code)
        self.modifiers = UInt32(modifiers)
        self.key = key
    }

    package init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        var mask = 0
        for (flag, value) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.command, cmdKey), (.shift, shiftKey)] where flags.contains(flag) {
            mask |= value
        }
        let names = [123: "←", 124: "→", 125: "↓", 126: "↑", 49: "Space", 48: "Tab", 36: "↩", 51: "⌫"]
        guard let label = names[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased(), !label.isEmpty else { return nil }
        self.init(Int(event.keyCode), mask, label)
    }

    package func matches(_ other: KeyChord) -> Bool {
        code == other.code && modifiers == other.modifiers
    }
}
