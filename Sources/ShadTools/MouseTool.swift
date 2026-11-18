import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

enum MouseShortcutSender {
    static func events(for chord: KeyChord) -> [CGEvent] {
        guard chord.code < 128, let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(chord.code), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(chord.code), keyDown: false) else { return [] }
        var flags = CGEventFlags()
        for (mask, flag) in [(cmdKey, CGEventFlags.maskCommand), (controlKey, .maskControl),
                             (optionKey, .maskAlternate), (shiftKey, .maskShift)] where chord.modifiers & UInt32(mask) != 0 {
            flags.insert(flag)
        }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: MouseInput.syntheticEventTag)
        }
        return [down, up]
    }

    @MainActor static func send(_ action: MouseAction, to target: NSRunningApplication) {
        guard !target.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            Feedback.show("The active app changed. Open the dial or start the gesture again.")
            return
        }
        guard CGPreflightPostEventAccess() else {
            Feedback.show("Allow Accessibility access in Mouse Tools to run shortcuts.")
            return
        }
        let pair = events(for: action.shortcut)
        guard pair.count == 2 else { Feedback.show("This shortcut could not be sent."); return }
        // Posting to the session allows macOS to receive system shortcuts as well as
        // app shortcuts. The foreground check above keeps the original app in control.
        for event in pair { event.post(tap: .cghidEventTap) }
    }
}

// At most one edition should consume a physical button. The kernel releases the
// ownership automatically on exit, including when an app quits unexpectedly.
final class MouseCaptureLease {
    private let url: URL
    private var descriptor: Int32 = -1
    var held: Bool { descriptor >= 0 }

    init(url: URL) { self.url = url }

    func acquire() -> Bool {
        if held { return true }
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd
        return true
    }

    func release() {
        guard held else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

@MainActor final class MouseTool {
    private let profiles: MouseProfiles
    private let input = MouseInput()
    private let dial = MouseDial()
    private let lease: MouseCaptureLease
    private var subscription: AnyCancellable?
    private var check: Timer?
    private var target: NSRunningApplication?
    private var suppressCapture = false
    private var configuringTrigger = false
    private lazy var editor: MouseSettingsWindow = {
        let window = MouseSettingsWindow(profiles: profiles)
        window.permissionStatus = { [weak self] in self?.permissionStatus ?? "" }
        window.requestPermission = { [weak self] in self?.requestAccess() }
        window.learn = { [weak self] completion in self?.learn(completion) }
        window.cancelLearn = { [weak self] in self?.input.cancelLearning() }
        window.recordingShortcut = { [weak self] recording in
            guard let self else { return }
            suppressCapture = recording
            reconcile(profiles.configuration)
        }
        return window
    }()

    convenience init() {
        let lock = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/io.github.syedshad.shadtools.mouse.capture.lock")
        self.init(profiles: MouseProfiles(), lease: MouseCaptureLease(url: lock))
    }

    init(profiles: MouseProfiles, lease: MouseCaptureLease) {
        self.profiles = profiles
        self.lease = lease
        input.onEvent = { [weak self] event in self?.handle(event) }
        subscription = profiles.$configuration.sink { [weak self] config in
            guard let self else { return }
            input.configure(dial: config.dialTrigger, gesture: config.gestureTrigger, threshold: CGFloat(config.gestureThreshold))
            reconcile(config)
        }
    }

    deinit { check?.invalidate() }

    private func reconcile(_ config: MouseConfiguration) {
        guard !configuringTrigger else { return }
        if !config.enabled || suppressCapture {
            if input.running { input.stop() }
            // Keep ownership while recording a shortcut so the other edition
            // cannot intercept the keystroke being assigned in this window.
            if !config.enabled { lease.release() }
            dial.hide()
            check?.invalidate()
            check = nil
            return
        }
        // Recheck after a grant, or when the other edition quits and frees its lease.
        if check == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.configuringTrigger else { return }
                    self.maintainCapture()
                }
            }
            timer.tolerance = 0.35
            RunLoop.main.add(timer, forMode: .common)
            check = timer
        }
        maintainCapture()
    }

    private func maintainCapture() {
        guard AXIsProcessTrusted() else {
            if input.running { input.stop(); dial.hide() }
            lease.release()
            return
        }
        if !input.running, lease.acquire(), !input.start() { lease.release() }
    }

    private var permissionStatus: String {
        if !AXIsProcessTrusted() { return "Allow Accessibility access to use mouse buttons and run shortcuts." }
        if !CGPreflightPostEventAccess() { return "Allow Accessibility access to send your assigned shortcuts." }
        if profiles.configuration.enabled && !input.running && !CGPreflightListenEventAccess() {
            return "Allow Input Monitoring for this app to recognize mouse buttons and gestures."
        }
        return ""
    }

    private func requestAccess() {
        if !AXIsProcessTrusted() {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        } else if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        else if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        reconcile(profiles.configuration)
    }

    private func learn(_ completion: @escaping (MouseTrigger?) -> Void) {
        guard AXIsProcessTrusted() else { requestAccess(); completion(nil); return }
        dial.hide()
        if !input.running && !input.start() { requestAccess(); completion(nil); return }
        configuringTrigger = true
        input.learn { [weak self] trigger in
            guard let self else { return }
            configuringTrigger = false
            if !lease.held { input.stop() }
            completion(trigger)
            reconcile(profiles.configuration)
        }
    }

    private func captureTarget() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    func showSettings() {
        dial.hide()
        editor.show(app: TargetApplication.current)
    }

    func showDial() {
        if dial.isVisible { dial.hide(); return }
        presentDial(at: NSEvent.mouseLocation, for: captureTarget() ?? TargetApplication.current)
    }

    private func presentDial(at point: CGPoint, for app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { Feedback.show("Switch to an app, then open the mouse dial."); return }
        let actions = profiles.actions(for: app.bundleIdentifier)
        guard actions.count == 8 else { return }
        let items = actions.map { MouseDialItem(title: $0.title, symbol: $0.symbol) }
        dial.show(at: point, application: app.localizedName ?? "Current App", universal: Array(items.prefix(4)),
                  contextual: Array(items.suffix(4))) { index in
            guard actions.indices.contains(index) else { return }
            MouseShortcutSender.send(actions[index], to: app)
        }
    }

    private func handle(_ event: MouseInputEvent) {
        guard profiles.configuration.enabled, !suppressCapture, !configuringTrigger else { return }
        switch event {
        case .began:
            target = captureTarget()
        case .dialBegan(let point):
            target = captureTarget()
            if dial.isVisible { dial.hide() }
            else { presentDial(at: point, for: target) }
        case .dialMoved(let point):
            dial.move(to: point)
        case .dialEnded(let point):
            _ = dial.release(at: point)
        case .toggleDial(let point):
            if dial.isVisible { dial.hide() }
            else { presentDial(at: point, for: target) }
        case .gesture(let direction):
            dial.hide()
            if let target { MouseShortcutSender.send(profiles.gesture(direction, for: target.bundleIdentifier), to: target) }
            target = nil
        case .cancel:
            dial.hide()
            target = nil
        }
    }

    func commands() -> [ToolCommand] {
        [
            ToolCommand(id: "mouse.dial", title: "Show Mouse Dial", subtitle: "Four universal shortcuts and four for the active app",
                        symbol: "circle.grid.3x3", group: "Mouse", keywords: "ring wheel radial actions mouse shortcuts") { [weak self] in self?.showDial() },
            ToolCommand(id: "mouse.settings", title: "Configure Mouse Tools", subtitle: "Assign buttons, gestures and app-specific dial actions",
                        symbol: "computermouse", group: "Mouse", keywords: "setup enable learn button profile directions mapping gesture") { [weak self] in self?.showSettings() }
        ]
    }
}
