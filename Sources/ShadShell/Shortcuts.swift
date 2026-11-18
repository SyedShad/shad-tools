import ShadCore
import AppKit
import Carbon.HIToolbox

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
    private var pendingRetry: Task<Void, Never>?
    var fire: ((String) -> Void)?

    init(_ edition: Edition, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        defaults = edition.shortcuts
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
        pendingRetry?.cancel()
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
        scheduleConflictRetry()
    }

    private func scheduleConflictRetry() {
        if conflicts.isEmpty {
            pendingRetry?.cancel()
            pendingRetry = nil
            return
        }
        guard pendingRetry == nil else { return }
        pendingRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            pendingRetry = nil
            let previous = conflicts
            for id in previous.sorted() {
                if let chord = binding(id), register(id, chord) { conflicts.remove(id) }
            }
            if previous != conflicts { Commands.changed() }
            scheduleConflictRetry()
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
        scheduleConflictRetry()
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
