import AppKit
import Carbon.HIToolbox

struct KeyChord: Codable, Equatable {
    let code: UInt32
    let modifiers: UInt32
    let key: String

    var label: String {
        var text = ""
        for (mask, glyph) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(mask) != 0 { text += glyph }
        }
        return text + key
    }

    init(_ code: Int, _ modifiers: Int, _ key: String) {
        self.code = UInt32(code)
        self.modifiers = UInt32(modifiers)
        self.key = key
    }

    init?(event: NSEvent) {
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

    func matches(_ other: KeyChord) -> Bool {
        code == other.code && modifiers == other.modifiers
    }

    static func defaults(_ edition: Edition) -> [String: KeyChord] {
        let tri = controlKey | optionKey | cmdKey
        let launcher: KeyChord
        switch edition {
        case .suite: launcher = KeyChord(49, controlKey | optionKey, "Space")
        case .search: launcher = KeyChord(1, tri, "S")
        case .audio: launcher = KeyChord(0, tri, "A")
        case .drives: launcher = KeyChord(2, tri, "D")
        case .color: launcher = KeyChord(8, tri, "C")
        case .windows: launcher = KeyChord(13, tri, "W")
        case .capture: launcher = KeyChord(35, tri, "P")
        }
        var bindings = ["app.open": launcher]
        if edition == .suite || edition == .drives { bindings["drives.eject-all"] = KeyChord(14, tri, "E") }
        if edition == .suite || edition == .windows {
            for (id, code, key) in [("left", 123, "←"), ("right", 124, "→"), ("bottom", 125, "↓"), ("top", 126, "↑")] {
                bindings["window." + id + "-half"] = KeyChord(code, tri, key)
            }
        }
        return bindings
    }
}

private let hotkeySignature: OSType = 0x53686454
@MainActor final class Shortcuts {
    private struct Registered {
        let ref: EventHotKeyRef
        let index: UInt32
        let chord: KeyChord
    }
    private var registered = [String: Registered]()
    private var byIndex = [UInt32: String]()
    private var counter: UInt32 = 0
    private var handler: EventHandlerRef?
    private var custom: [String: KeyChord]
    private var bindingNames: [String: String]
    private var disabled: Set<String>
    var savedNames: [String: String] {
        Dictionary(uniqueKeysWithValues: custom.keys.map { ($0, bindingNames[$0] ?? $0) })
    }
    private let defaults: [String: KeyChord]
    private let preferences: UserDefaults
    private(set) var conflicts = Set<String>()
    var fire: ((String) -> Void)?

    init(_ edition: Edition, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        defaults = KeyChord.defaults(edition)
        custom = (preferences.data(forKey: "shortcuts.v1")).flatMap { try? JSONDecoder().decode([String: KeyChord].self, from: $0) } ?? [:]
        bindingNames = preferences.dictionary(forKey: "shortcutNames") as? [String: String] ?? [:]
        disabled = Set(preferences.stringArray(forKey: "disabledShortcuts") ?? [])
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout.size(ofValue: id), nil, &id)
            guard status == noErr, id.signature == hotkeySignature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<Shortcuts>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let key = owner.byIndex[id.id] { owner.fire?(key) }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit {
        registered.values.forEach { UnregisterEventHotKey($0.ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    func binding(_ id: String) -> KeyChord? { disabled.contains(id) ? nil : custom[id] ?? defaults[id] }

    func reconcile(_ available: Set<String>) {
        let needed = Set(defaults.keys).union(custom.keys).intersection(available).subtracting(disabled)
        conflicts.formIntersection(needed)
        for id in Array(registered.keys) where !needed.contains(id) || registered[id]?.chord != binding(id) {
            remove(id)
        }
        for id in needed.sorted() where registered[id] == nil {
            if let chord = binding(id), register(id, chord) { conflicts.remove(id) }
            else { conflicts.insert(id) }
        }
    }

    func change(_ id: String, title: String, to chord: KeyChord?) -> String? {
        if let chord {
            for other in Set(defaults.keys).union(custom.keys) where other != id && binding(other)?.matches(chord) == true {
                return "This shortcut is already assigned to another command."
            }
            if registered[id]?.chord.matches(chord) == true { return nil }
            let old = registered[id]?.chord
            remove(id)
            guard register(id, chord) else {
                if let old { _ = register(id, old) }
                return "macOS or another app is using that shortcut. Try another combination."
            }
            disabled.remove(id)
            custom[id] = chord
            bindingNames[id] = title
        } else {
            remove(id)
            disabled.insert(id)
            custom.removeValue(forKey: id)
            bindingNames.removeValue(forKey: id)
        }
        conflicts.remove(id)
        preferences.set(bindingNames, forKey: "shortcutNames")
        preferences.set(try? JSONEncoder().encode(custom), forKey: "shortcuts.v1")
        preferences.set(Array(disabled), forKey: "disabledShortcuts")
        return nil
    }

    private func register(_ id: String, _ chord: KeyChord) -> Bool {
        counter &+= 1
        var ref: EventHotKeyRef?
        let hotKey = EventHotKeyID(signature: hotkeySignature, id: counter)
        guard RegisterEventHotKey(chord.code, chord.modifiers, hotKey, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref) == noErr, let ref else { return false }
        registered[id] = Registered(ref: ref, index: counter, chord: chord)
        byIndex[counter] = id
        return true
    }

    private func remove(_ id: String) {
        guard let old = registered.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(old.ref)
        byIndex.removeValue(forKey: old.index)
    }
}
