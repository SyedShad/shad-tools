import AppKit
import ApplicationServices

@MainActor
final class WindowTool {
    private struct Link {
        let source: WindowReference
        let edge: WindowEdge
        let neighbor: WindowReference
    }
    private struct Drag {
        let window: WindowReference
        let original: CGRect
        var previousFrame: CGRect
        var screen: CGRect?
        var peers: [(WindowReference, CGRect)] = []
        var nextUpdate: TimeInterval = 0
        var didResize = false
    }

    private let enabledKey = "window.magnetic.enabled"
    private var magnetic: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private var monitor: Any?
    private var drag: Drag?
    private var links: [Link] = []
    private var history: [(WindowReference, CGRect)] = []
    private var preview: NSPanel?
    private var tracking = false
    private var linkRevision = 0

    init() { configureMonitor() }

    func commands() -> [ToolCommand] {
        let layouts = WindowLayout.allCases.map { layout in
            ToolCommand(id: "window." + layout.rawValue, title: layout.title, subtitle: "Arrange the focused window on its display", symbol: layout.symbol, group: "Windows", keywords: "tile resize snap move window " + layout.rawValue) { [weak self] in self?.arrange(layout) }
        }
        return layouts + [
            ToolCommand(id: "window.restore", title: "Restore Window Size and Position", subtitle: "Undo the last arrangement for this window", symbol: "arrow.uturn.backward", group: "Windows", keywords: "undo unsnap previous") { [weak self] in self?.restore() },
            ToolCommand(id: "window.magnetism", title: magnetic ? "Turn Off Magnetic Windows" : "Turn On Magnetic Windows", subtitle: "Snap adjacent windows and resize their shared edge together", symbol: "rectangle.split.2x1", group: "Windows", keywords: "magnet link adjacent snap drag toggle") { [weak self] in self?.toggleMagnetism() },
            ToolCommand(id: "window.accessibility", title: "Window Control Permission", subtitle: "Manage Accessibility access in System Settings", symbol: "accessibility", group: "Windows", keywords: "allow permissions authorize privacy") { [weak self] in self?.openAccess() }
        ]
    }

    private func openAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        Feedback.show(AXIsProcessTrusted() ? "Window control has Accessibility access" : "Enable this app under Accessibility")
    }

    private func target() -> (WindowReference, CGRect)? {
        guard AXIsProcessTrusted() else {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            Feedback.show("Allow Accessibility access, then run the window command again")
            return nil
        }
        guard let app = TargetApplication.current ?? NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let window = WindowReference.focused(in: app.processIdentifier), let frame = window.frame else {
            Feedback.show("Focus an application window and try again")
            return nil
        }
        guard window.isResizable else {
            Feedback.show("This window is fixed-size or in full screen")
            return nil
        }
        return (window, frame)
    }

    private func workArea(for frame: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard let primary = screens.first,
              let index = WindowGeometry.screen(for: frame, among: screens.map({ WindowGeometry.flip($0.frame, primaryTop: primary.frame.maxY) })) else { return nil }
        return WindowGeometry.flip(screens[index].visibleFrame, primaryTop: primary.frame.maxY)
    }

    private func remember(_ window: WindowReference, _ frame: CGRect) {
        history.removeAll { $0.0 == window }
        history.append((window, frame))
        if history.count > 60 { history.removeFirst() }
    }

    private func arrange(_ layout: WindowLayout) {
        guard let (window, before) = target(), let screen = workArea(for: before) else { return }
        let intended = layout.frame(on: screen, current: before)
        guard let after = window.apply(intended) else { Feedback.show("The application could not move this window"); return }
        if !WindowGeometry.approximatelyEqual(before, after) {
            remember(window, before)
            if magnetic && hasLinks(window) {
                let visible = WindowReference.neighbors(of: window, within: screen).map(\.0)
                resizeNeighbors(of: window, from: before, to: after, visible: visible)
            }
        }
        if magnetic { relink(window, at: after, within: screen) }
        Feedback.show(WindowGeometry.approximatelyEqual(after, intended, tolerance: 3) ? layout.title : "The application limited the requested window frame")
    }

    private func restore() {
        guard let (window, _) = target() else { return }
        guard let index = history.lastIndex(where: { $0.0 == window }) else { Feedback.show("No saved arrangement for this window"); return }
        let saved = history[index].1
        guard let after = window.apply(saved) else { Feedback.show("The application could not restore this window"); return }
        history.remove(at: index)
        clearLinks(for: window)
        Feedback.show(WindowGeometry.approximatelyEqual(after, saved, tolerance: 3) ? "Window restored" : "The application limited the restored frame")
    }

    private func toggleMagnetism() {
        UserDefaults.standard.set(!magnetic, forKey: enabledKey)
        configureMonitor()
        Feedback.show(magnetic ? "Magnetic windows on" : "Magnetic windows off")
        Commands.changed()
    }

    private func configureMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        tracking = false
        drag = nil
        links.removeAll()
        preview?.orderOut(nil)
        guard magnetic else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func hasLinks(_ window: WindowReference) -> Bool {
        links.contains { $0.source == window || $0.neighbor == window }
    }

    private func clearLinks(for window: WindowReference) {
        linkRevision &+= 1
        links.removeAll { $0.source == window || $0.neighbor == window }
    }

    private func relink(_ window: WindowReference, at frame: CGRect, within screen: CGRect) {
        collectLinks(for: window, at: frame, within: screen)
        let revision = linkRevision
        // WindowServer's on-screen list can trail AX geometry briefly after tiling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.linkRevision == revision, self.magnetic, self.drag == nil,
                  let current = window.frame, WindowGeometry.approximatelyEqual(current, frame) else { return }
            self.collectLinks(for: window, at: current, within: screen)
        }
    }

    private func collectLinks(for window: WindowReference, at frame: CGRect, within screen: CGRect) {
        clearLinks(for: window)
        for (peer, peerFrame) in WindowReference.neighbors(of: window, within: screen) {
            for edge in WindowEdge.allCases {
                guard let offset = edge.distance(from: frame, to: peerFrame), abs(offset) <= 2 else { continue }
                links.append(Link(source: window, edge: edge, neighbor: peer))
            }
        }
        // Limit stale references after windows close or apps terminate.
        if links.count > 100 { links.removeFirst(links.count - 100) }
    }

    private func resizeNeighbors(of window: WindowReference, from old: CGRect, to new: CGRect, visible: [WindowReference]) {
        for link in links where link.source == window || link.neighbor == window {
            let forward = window == link.source
            let edge = forward ? link.edge : link.edge.opposite
            let peer = forward ? link.neighbor : link.source
            guard visible.contains(peer), let peerFrame = peer.frame,
                  let distance = edge.distance(from: old, to: peerFrame), abs(distance) <= 3,
                  let next = edge.resizedPeer(from: old, to: new, peer: peerFrame) else { continue }
            _ = peer.apply(next)
        }
    }

    private func handle(_ event: NSEvent) {
        // Only a drag triggers peer discovery. Capture its starting frame before the app moves it.
        switch event.type {
        case .leftMouseDown:
            tracking = false
            drag = nil
            preview?.orderOut(nil)
            if AXIsProcessTrusted(), let point = event.cgEvent?.location, let window = WindowReference.at(point), let frame = window.frame {
                drag = Drag(window: window, original: frame, previousFrame: frame)
            }
        case .leftMouseDragged:
            if !tracking {
                tracking = true
                if drag == nil, AXIsProcessTrusted(), let point = event.cgEvent?.location,
                   let window = WindowReference.at(point), let frame = window.frame {
                    drag = Drag(window: window, original: frame, previousFrame: frame)
                }
                if drag?.window.isResizable != true { drag = nil }
            }
            updateDrag(event, ending: false)
        case .leftMouseUp:
            if tracking, drag != nil { updateDrag(event, ending: true) }
            preview?.orderOut(nil)
            tracking = false
            drag = nil
        default: break
        }
    }

    private func updateDrag(_ event: NSEvent, ending: Bool) {
        guard var state = drag, ending || event.timestamp >= state.nextUpdate else { return }
        state.nextUpdate = event.timestamp + 1.0 / 30
        defer { drag = state }
        guard let current = state.window.frame else { return }
        if event.modifierFlags.contains(.shift) {
            preview?.orderOut(nil)
            if ending, !WindowGeometry.approximatelyEqual(current, state.original) { clearLinks(for: state.window) }
            state.previousFrame = current
            return
        }
        state.didResize = state.didResize || abs(state.original.width - current.width) > 1 || abs(state.original.height - current.height) > 1
        let moved = abs(state.original.minX - current.minX) > 2 || abs(state.original.minY - current.minY) > 2
        guard state.didResize || moved || state.screen != nil else { return }
        guard let screen = workArea(for: current) else { return }
        if state.screen != screen {
            state.screen = screen
            state.peers = WindowReference.neighbors(of: state.window, within: screen)
        }

        if state.didResize {
            preview?.orderOut(nil)
            resizeNeighbors(of: state.window, from: state.previousFrame, to: current, visible: state.peers.map(\.0))
            if ending { relink(state.window, at: current, within: screen) }
        } else {
            let candidate = WindowGeometry.magnet(current, peers: state.peers.map(\.1), within: screen)
            if ending {
                let final = candidate.flatMap { state.window.apply($0) } ?? current
                if let candidate, !WindowGeometry.approximatelyEqual(candidate, current) { remember(state.window, current) }
                relink(state.window, at: final, within: screen)
            } else if let candidate {
                showPreview(frame: candidate)
            } else {
                preview?.orderOut(nil)
            }
        }
        state.previousFrame = current
    }

    private func showPreview(frame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        if preview == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.animationBehavior = .none
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.09).cgColor
            view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            view.layer?.borderWidth = 2
            view.layer?.cornerRadius = 9
            panel.contentView = view
            preview = panel
        }
        preview?.setFrame(WindowGeometry.flip(frame, primaryTop: primary.frame.maxY), display: true)
        preview?.orderFrontRegardless()
    }
}
