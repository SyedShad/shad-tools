import AppKit
import CoreGraphics

enum MouseDirection: String, CaseIterable, Codable {
    case up, down, left, right
}

/// Quartz numbers buttons from zero. A shortcut can also come from a mouse driver that sends
/// a real key-down/key-up pair. Plain typing and an unmodified primary click stay available.
struct MouseTrigger: Codable, Equatable {
    enum Kind: String, Codable { case button, key }
    let kind: Kind
    let code: Int
    let modifiers: UInt64
    let keyName: String?

    private static let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    private static let functionKeys = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                       103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    init(button: Int, modifiers: CGEventFlags = []) {
        kind = .button
        code = button
        self.modifiers = modifiers.intersection(Self.modifierMask).rawValue
        keyName = nil
    }

    init(key: Int, modifiers: CGEventFlags, keyName: String? = nil) {
        kind = .key
        code = key
        self.modifiers = modifiers.intersection(Self.modifierMask).rawValue
        self.keyName = keyName
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.code == rhs.code && lhs.modifiers == rhs.modifiers
    }

    static let middle = MouseTrigger(button: 2)
    static let optionClick = MouseTrigger(button: 0, modifiers: .maskAlternate)

    var isUsable: Bool {
        let flags = CGEventFlags(rawValue: modifiers)
        guard flags.subtracting(Self.modifierMask).isEmpty else { return false }
        switch kind {
        case .button: return (0...65535).contains(code) && (code != 0 || !flags.isEmpty)
        case .key: return (0...127).contains(code) && code != 53 &&
            (Self.functionKeys.contains(code) || !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty)
        }
    }

    var label: String {
        let flags = CGEventFlags(rawValue: modifiers)
        var name = ""
        for (flag, symbol): (CGEventFlags, String) in [(.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")] {
            if flags.contains(flag) { name += symbol }
        }
        switch kind {
        case .button:
            switch code {
            case 0: return name + "Left Click"
            case 1: return name + "Right Click"
            case 2: return name + "Middle Click"
            default: return name + "Button " + String(code + 1)
            }
        case .key:
            if let index = Self.functionKeys.firstIndex(of: code) { return name + "F" + String(index + 1) }
            return name + (keyName ?? "Key " + String(code))
        }
    }
}

enum MouseInputEvent: Equatable {
    // Points handed to AppKit UI are in global screen coordinates, with Y increasing upwards.
    case began(CGPoint)
    case dialBegan(CGPoint), dialMoved(CGPoint), dialEnded(CGPoint)
    case toggleDial(CGPoint)
    case gesture(MouseDirection)
    case cancel
}

@MainActor
final class MouseInput {
    nonisolated static let syntheticEventTag: Int64 = 0x536861644d6f7573
    var onEvent: (MouseInputEvent) -> Void = { _ in }
    var running: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var isLearning: Bool { learning != nil }

    private enum Mode { case dial, gesture, shared }
    private struct Physical: Hashable {
        let isKey: Bool
        let code: Int
    }
    private struct Hold {
        let input: Physical
        let mode: Mode
        var lastPoint: CGPoint
        var travel: CGPoint = .zero
        var direction: MouseDirection?

        mutating func move(to point: CGPoint, delta: CGPoint, threshold: CGFloat) {
            // At a screen edge the absolute cursor can stop while the mouse still sends deltas.
            let dx = point.x - lastPoint.x
            let dy = point.y - lastPoint.y
            travel.x += dx == 0 ? delta.x : dx
            travel.y += dy == 0 ? delta.y : dy
            lastPoint = point
            guard direction == nil, max(abs(travel.x), abs(travel.y)) >= threshold else { return }
            if abs(travel.x) >= abs(travel.y) { direction = travel.x < 0 ? .left : .right }
            else { direction = travel.y < 0 ? .up : .down }
        }
    }

    private var dial: MouseTrigger = .middle
    private var gesture: MouseTrigger = .middle
    private var threshold: CGFloat = 36
    private var hold: Hold?
    private var suppressed = Set<Physical>()
    private var learning: ((MouseTrigger?) -> Void)?
    private var pendingLearn: (Physical, MouseTrigger)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func configure(dial: MouseTrigger, gesture: MouseTrigger, threshold: CGFloat) {
        if self.dial != dial || self.gesture != gesture { cancelInteraction() }
        self.dial = dial
        self.gesture = gesture
        self.threshold = threshold.isFinite ? min(240, max(4, threshold)) : 36
    }

    @discardableResult func start() -> Bool {
        if let tap {
            if CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                if running { return true }
            }
            stop()
        }
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                     .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                     .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                     .mouseMoved, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, reference in
            guard let reference else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<MouseInput>.fromOpaque(reference).takeUnretainedValue()
            let consumed = MainActor.assumeIsolated { owner.consume(type, event) }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        tap = port
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return running
    }

    func stop() {
        cancelLearning()
        cancelInteraction()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        suppressed.removeAll()
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    func learn(_ completion: @escaping (MouseTrigger?) -> Void) {
        cancelLearning()
        cancelInteraction()
        guard running || start() else { completion(nil); return }
        learning = completion
    }

    func cancelLearning() { finishLearning(nil) }

    private func finishLearning(_ value: MouseTrigger?) {
        guard let completion = learning else { return }
        learning = nil
        pendingLearn = nil
        DispatchQueue.main.async { completion(value) }
    }

    func cancelInteraction() {
        if hold != nil { hold = nil; emit(.cancel) }
    }

    private func emit(_ event: MouseInputEvent) {
        // Native window and action code runs after the event tap has returned to WindowServer.
        DispatchQueue.main.async { [weak self] in self?.onEvent(event) }
    }

    private func appPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    }

    private func motion(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if let pendingLearn, type != .mouseMoved,
           pendingLearn.0 == Physical(isKey: false, code: Int(event.getIntegerValueField(.mouseEventButtonNumber))) {
            return true
        }
        guard var active = hold else { return false }
        if type != .mouseMoved {
            let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard !active.input.isKey, number == active.input.code else { return false }
        }
        let point = event.location
        if active.mode == .dial {
            active.lastPoint = point
            emit(.dialMoved(appPoint(point)))
        } else {
            active.move(to: point, delta: CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX),
                                                  y: event.getDoubleValueField(.mouseEventDeltaY)), threshold: threshold)
        }
        hold = active
        return true
    }

    /// Synchronous decision used directly by the Quartz tap. Only a configured trigger or its
    /// paired drag/release is consumed. Normal clicks, typing, and Shad-generated actions pass.
    func consume(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelInteraction()
            cancelLearning()
            suppressed.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventTag else { return false }
        switch type {
        case .mouseMoved, .otherMouseDragged, .leftMouseDragged, .rightMouseDragged: return motion(type, event)
        case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: break
        default: return false
        }
        let key = type == .keyDown || type == .keyUp
        let code = Int(event.getIntegerValueField(key ? .keyboardEventKeycode : .mouseEventButtonNumber))
        let input = Physical(isKey: key, code: code)
        let up = type == .keyUp || type == .otherMouseUp || type == .leftMouseUp || type == .rightMouseUp
        if up {
            guard suppressed.remove(input) != nil else { return false }
            if let pendingLearn, pendingLearn.0 == input {
                finishLearning(pendingLearn.1)
                return true
            }
            guard var active = hold, active.input == input else { return true }
            hold = nil
            // A keyboard event's stored pointer location can be stale on driver-generated key-ups.
            let point = key ? active.lastPoint : event.location
            switch active.mode {
            case .dial: emit(.dialEnded(appPoint(point)))
            case .gesture, .shared:
                active.move(to: point, delta: .zero, threshold: threshold)
                if let direction = active.direction { emit(.gesture(direction)) }
                else if active.mode == .shared { emit(.toggleDial(appPoint(point))) }
                else { emit(.cancel) }
            }
            return true
        }
        if key && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return suppressed.contains(input) }
        if key && code == 53 && (isLearning || hold != nil) {
            cancelLearning()
            cancelInteraction()
            suppressed.insert(input)
            return true
        }
        let trigger = key ? MouseTrigger(key: code, modifiers: event.flags) : MouseTrigger(button: code, modifiers: event.flags)
        if isLearning {
            if let pendingLearn { return pendingLearn.0 == input }
            guard trigger.isUsable else { return false }
            var learned = trigger
            if key, let text = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.uppercased(),
               !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                learned = MouseTrigger(key: code, modifiers: event.flags, keyName: text)
            }
            suppressed.insert(input)
            pendingLearn = (input, learned)
            return true
        }
        if hold != nil { cancelInteraction() }
        guard trigger.isUsable, trigger == dial || trigger == gesture else { return false }
        let mode: Mode = trigger == dial ? (trigger == gesture ? .shared : .dial) : .gesture
        let point = key ? (CGEvent(source: nil)?.location ?? event.location) : event.location
        hold = Hold(input: input, mode: mode, lastPoint: point)
        suppressed.insert(input)
        emit(mode == .dial ? .dialBegan(appPoint(point)) : .began(appPoint(point)))
        return true
    }
}
