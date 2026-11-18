import ShadCore
import AppKit
import SwiftUI

private final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let edition: Edition

    init(edition: Edition) { self.edition = edition }

    private var status: NSStatusItem!
    private var panel: NSPanel!
    private var model: PaletteModel!
    private var keyboard: Any?
    private var toast: NSPanel?
    private var hideToast: DispatchWorkItem?
    private var refresh: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TargetApplication.capture()
        model = PaletteModel(edition)
        model.applyAppearance = { [weak self] in NSApp.appearance = self?.model.appearance.appKitAppearance }
        model.applyAppearance?()
        model.open = { [weak self] in self?.toggle() }
        model.dismiss = { [weak self] in self?.hide() }
        model.shortcuts.fire = { [weak self] id in
            guard let self else { return }
            if panel?.isKeyWindow == true, model.recording != nil, let binding = model.shortcuts.binding(id) { model.save(binding) }
            else { model.hotkey(id) }
        }
        Commands.onChange = { [weak self] in
            guard let self, refresh == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.refresh = nil; self?.model.rebuild() }
            refresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
        }
        Feedback.present = { [weak self] in self?.message($0) }
        let size = NSSize(width: 824, height: 522)
        let p = CommandPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = edition.title
        p.setAccessibilityLabel(edition.title)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = NSHostingView(rootView: PaletteView(model: model))
        p.delegate = self
        panel = p
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button {
            button.image = NSImage(systemSymbolName: edition.symbol, accessibilityDescription: edition.title)
            button.image?.isTemplate = true
            button.toolTip = edition.title
            button.target = self
            button.action = #selector(statusClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        keyboard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return handled ? nil : event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TargetApplication.capture() }
        }
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = launchEvent?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !atLogin { openEdition() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shouldTerminate() ?? .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel != nil { openEdition() }
        return true
    }

    @objc private func statusClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            let openItem = menu.addItem(withTitle: "Open " + model.edition.title, action: #selector(menuOpen), keyEquivalent: "")
            openItem.target = self
            let settingsItem = menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: "")
            settingsItem.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit " + model.edition.title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
            status.menu = menu
            sender.performClick(nil)
            status.menu = nil
        } else { toggle() }
    }

    @objc private func menuOpen() { openEdition() }
    @objc private func menuSettings() { show(); model.showSettings() }
    private func openEdition() {
        if let open = model.standaloneWindow { open() }
        else { show() }
    }

    private func toggle() { panel.isVisible ? hide() : openEdition() }
    private func show() {
        TargetApplication.capture()
        model.reset()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            let size = NSSize(width: min(824, frame.width - 24), height: min(522, frame.height - 28))
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + (frame.height - size.height) * 0.62, width: size.width, height: size.height), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        model.refocus?()
        if model.shortcuts.conflicts.contains("app.open") {
            model.note = "The launcher shortcut is in use. Open Settings to assign a new one."
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.closed()
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { hide() }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow, event.window == panel else { return false }
        if model.recording != nil {
            if event.keyCode == 53 { model.back() }
            else if event.keyCode == 51 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { model.save(nil) }
            else if let chord = KeyChord(event: event) { model.save(chord) }
            else { model.note = "Include Control, Option or Command in the shortcut." }
            return true
        }
        if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 125, 126: model.nextSection(forward: event.keyCode == 125); return true
            case 36, 76: model.secondaryAction(); return true
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case ",": model.showSettings()
            case "k": model.toggleActions()
            case "q": NSApp.terminate(nil)
            case "v", "x", "c", "a":
                let selector = ["v": "paste:", "x": "cut:", "c": "copy:", "a": "selectAll:"][event.charactersIgnoringModifiers!.lowercased()]!
                NSApp.sendAction(NSSelectorFromString(selector), to: panel.firstResponder, from: self)
            default: return false
            }
            return true
        }
        if event.modifierFlags.contains(.control) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "n": model.move(1); return true
            case "p": model.move(-1); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 126: model.move(event.modifierFlags.contains(.option) ? -9 : -1)
        case 125: model.move(event.modifierFlags.contains(.option) ? 9 : 1)
        case 36, 76: model.confirmSelection()
        case 48 where model.tabScope != nil && model.actionTarget == nil && event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty:
            model.selectScope(model.tabScope)
        case 53: model.back()
        case 51 where model.actionTarget == nil && model.query.isEmpty && model.scope != nil && model.edition.isSuite: model.back()
        default: return false
        }
        return true
    }

    private func message(_ text: String) {
        hideToast?.cancel()
        toast?.orderOut(nil)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        let width = min(500, max(210, label.intrinsicContentSize.width + 32))
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
        label.preferredMaxLayoutWidth = width - 32
        let hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: max(44, label.intrinsicContentSize.height + 24)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .statusBar
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hidesOnDeactivate = false
        hud.ignoresMouseEvents = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = content
        if let frame = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame {
            hud.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.minY + 54))
        }
        hud.orderFrontRegardless()
        toast = hud
        NSAccessibility.post(element: label, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let work = DispatchWorkItem { [weak self] in self?.toast?.orderOut(nil); self?.toast = nil }
        hideToast = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (text.count > 100 ? 8 : 4), execute: work)
    }
}

package enum ShadApplication {
    @MainActor package static func run(_ edition: Edition) {
        if CommandLine.arguments.dropFirst().elementsEqual(["--describe-edition"]) {
            // No app, service, hardware, hotkey, or clipboard is initialized on this path.
            print(edition.id + "\t" + edition.modules.map(\.id).joined(separator: ","))
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(edition: edition)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
