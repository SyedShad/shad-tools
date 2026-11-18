import AppKit

struct MouseDialItem: Equatable {
    let title: String
    let symbol: String
}

/// Coordinates are in AppKit points, with the origin at the bottom left.
struct MouseDialGeometry {
    static let size: CGFloat = 408
    private static let angles: [CGFloat] = [112.5, 157.5, 202.5, 247.5, 67.5, 22.5, -22.5, -67.5]

    let frame: CGRect
    var scale: CGFloat { frame.width / Self.size }
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    var outer: CGFloat { 198 * scale }
    var inner: CGFloat { 80 * scale }

    init(at pointer: CGPoint, in screen: CGRect) {
        let margin = min(5, min(screen.width, screen.height) * 0.02)
        let usable = screen.insetBy(dx: margin, dy: margin)
        let size = min(Self.size, usable.width, usable.height)
        frame = CGRect(x: min(max(pointer.x - size / 2, usable.minX), usable.maxX - size),
                       y: min(max(pointer.y - size / 2, usable.minY), usable.maxY - size),
                       width: size, height: size)
    }

    init(frame: CGRect) { self.frame = frame }

    func actionCenter(_ slot: Int) -> CGPoint {
        point(radius: 142 * scale, degrees: Self.angles[slot])
    }

    func slot(at point: CGPoint) -> Int? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= inner, distance <= outer else { return nil }
        let angle = atan2(dy, dx) * 180 / .pi
        return Self.angles.firstIndex {
            let difference = abs((angle - $0).truncatingRemainder(dividingBy: 360))
            return min(difference, 360 - difference) <= 21.65
        }
    }

    func path(_ slot: Int) -> NSBezierPath {
        let middle = Self.angles[slot]
        let start = middle - 21.65, end = middle + 21.65
        let path = NSBezierPath()
        path.move(to: point(radius: outer, degrees: start))
        path.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end)
        path.line(to: point(radius: inner, degrees: end))
        path.appendArc(withCenter: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.close()
        return path
    }

    private func point(radius: CGFloat, degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
    }
}

private final class MouseDialPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class DialButton: NSButton {
    let slot: Int
    weak var dial: DialSurface?

    init(slot: Int) {
        self.slot = slot
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        target = self
        action = #selector(choose)
    }

    required init?(coder: NSCoder) { nil }

    // The parent draws the ring as one surface. These native buttons provide
    // accessibility actions and receive clicks over their complete annular sector.
    override func draw(_ dirtyRect: NSRect) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { dial?.highlight(slot) }
    override func mouseUp(with event: NSEvent) {
        guard let dial, dial.slot(for: event) == slot else { return }
        choose()
    }
    @objc private func choose() { dial?.onPick?(slot) }
}

@MainActor private final class DialSurface: NSView {
    var onPick: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private var items: [MouseDialItem] = []
    private var applicationName = ""
    private var buttons: [DialButton] = []
    private var tracking: NSTrackingArea?
    private var selected: Int?

    private var geometry: MouseDialGeometry { MouseDialGeometry(frame: bounds) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mouse Dial")
        for slot in 0..<8 {
            let button = DialButton(slot: slot)
            button.dial = self
            addSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    func configure(items: [MouseDialItem], app: String) {
        self.items = items
        applicationName = app
        for (i, button) in buttons.enumerated() {
            let role = i < 4 ? "Universal" : app
            button.title = items[i].title
            button.setAccessibilityLabel(items[i].title)
            button.setAccessibilityHelp(role + " action " + String(i % 4 + 1))
            button.toolTip = items[i].title + " · " + role
        }
        selected = nil
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        for button in buttons {
            let center = geometry.actionCenter(button.slot)
            let factor = geometry.scale
            button.frame = NSRect(x: center.x - 47 * factor, y: center.y - 20 * factor,
                                  width: 94 * factor, height: 42 * factor)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func highlight(_ slot: Int?) {
        if selected != slot { selected = slot; needsDisplay = true }
    }

    func slot(for event: NSEvent) -> Int? {
        geometry.slot(at: convert(event.locationInWindow, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let slot = geometry.slot(at: local) { return buttons[slot] }
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) { highlight(slot(for: event)) }
    override func mouseExited(with event: NSEvent) { highlight(nil) }
    override func mouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let selected { onPick?(selected) }
            return
        }
        let current = selected ?? 0
        switch event.keyCode {
        case 48: highlight((current + (event.modifierFlags.contains(.shift) ? 7 : 1)) % 8)
        case 125: highlight(current / 4 * 4 + (current + 1) % 4)
        case 126: highlight(current / 4 * 4 + (current + 3) % 4)
        case 123: highlight(current % 4)
        case 124: highlight(4 + current % 4)
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard items.count == 8 else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let g = geometry
        let primary = ink(dark ? 0.97 : 0.13)
        let secondary = ink(dark ? 0.79 : 0.31)
        let surface = ink(dark ? 0.16 : 0.965)
        let border = ink(dark ? 0.33 : 0.80)
        let scale = g.scale
        let outerRect = CGRect(x: g.center.x - g.outer, y: g.center.y - g.outer, width: 2 * g.outer, height: 2 * g.outer)
        let circle = NSBezierPath(ovalIn: outerRect.insetBy(dx: -1.3 * scale, dy: -1.3 * scale))
        surface.setFill(); circle.fill()
        border.setStroke(); circle.lineWidth = 0.8 * scale; circle.stroke()

        for (slot, item) in items.enumerated() {
            let active = selected == slot
            let accent = slot < 4
                ? NSColor(srgbRed: dark ? 1.0 : 0.70, green: dark ? 0.57 : 0.20, blue: dark ? 0.61 : 0.23, alpha: 1)
                : NSColor(srgbRed: dark ? 0.73 : 0.41, green: dark ? 0.66 : 0.31, blue: dark ? 1.0 : 0.74, alpha: 1)
            let segment = g.path(slot)
            let base = ink(dark ? 0.224 : 0.998)
            (active ? (base.blended(withFraction: dark ? 0.25 : 0.14, of: accent) ?? base) : base).setFill()
            segment.fill()
            (active ? accent : border.withAlphaComponent(0.36)).setStroke()
            segment.lineWidth = (active ? 1.6 : 0.7) * scale
            segment.stroke()
            let location = g.actionCenter(slot)
            let iconSize = 22 * scale
            let glyphRect = NSRect(x: location.x - iconSize / 2, y: location.y - 1 * scale,
                                   width: iconSize, height: iconSize)
            symbol(item.symbol, in: glyphRect, color: accent)
            label(item.title, centeredAt: NSPoint(x: location.x, y: location.y - 14 * scale),
                  width: 98 * scale, size: 12.6 * scale, color: primary, weight: .medium)
        }

        let hubRadius = g.inner - 4 * scale
        let hub = NSBezierPath(ovalIn: CGRect(x: g.center.x - hubRadius, y: g.center.y - hubRadius,
                                              width: 2 * hubRadius, height: 2 * hubRadius))
        ink(dark ? 0.18 : 0.955).setFill(); hub.fill()
        border.withAlphaComponent(0.68).setStroke(); hub.lineWidth = scale * 0.8; hub.stroke()

        let c = g.center
        label("‹  Universal", centeredAt: CGPoint(x: c.x, y: c.y + 16 * scale),
              width: 118 * scale, size: 13 * scale, color: secondary, weight: .medium)
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: c.x - 32 * scale, y: c.y))
        separator.line(to: CGPoint(x: c.x + 32 * scale, y: c.y))
        separator.lineWidth = 0.7 * scale
        border.setStroke(); separator.stroke()
        label(applicationName + "  ›", centeredAt: CGPoint(x: c.x, y: c.y - 16 * scale),
              width: 119 * scale, size: 13 * scale, color: primary, weight: .semibold)
    }

    private func ink(_ gray: CGFloat) -> NSColor { NSColor(srgbRed: gray, green: gray, blue: gray + (gray < 0.98 ? 0.008 : 0), alpha: 1) }

    private func label(_ title: String, centeredAt p: CGPoint, width: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let height = ceil(font.ascender - font.descender) + 2
        let bounds = CGRect(x: p.x - width / 2, y: p.y - height / 2, width: width, height: height)
        (title as NSString).draw(in: bounds, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private func symbol(_ name: String, in box: CGRect, color: NSColor) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: box.height, weight: .medium)
            .applying(.init(paletteColors: [color]))
        guard let image = base.withSymbolConfiguration(config), image.size.width > 0, image.size.height > 0 else { return }
        let fit = min(box.width / image.size.width, box.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        image.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
    }
}

/// Shad keeps the target app captured by its caller. The borderless, nonactivating
/// panel takes keyboard focus for Escape without making Shad the foreground app.
@MainActor final class MouseDial: NSObject, NSWindowDelegate {
    private let panel: MouseDialPanel
    private let surface: DialSurface
    private var geometry: MouseDialGeometry?
    private var openedAt: CGPoint = .zero
    private var onSelect: ((Int) -> Void)?
    private var local: Any?
    private var global: Any?
    private var applicationObserver: NSObjectProtocol?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = MouseDialPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        surface = DialSurface(frame: .zero)
        super.init()
        panel.title = "Mouse Dial"
        panel.setAccessibilityLabel("Mouse Dial")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.contentView = surface
        surface.onPick = { [weak self] in self?.choose($0) }
        surface.onCancel = { [weak self] in self?.hide() }
    }

    func show(at point: CGPoint, application: String, universal: [MouseDialItem], contextual: [MouseDialItem],
              onSelect: @escaping (Int) -> Void) {
        hide()
        guard universal.count == 4, contextual.count == 4,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let layout = MouseDialGeometry(at: point, in: screen.visibleFrame)
        geometry = layout
        openedAt = point
        self.onSelect = onSelect
        panel.appearance = NSApp.effectiveAppearance
        surface.configure(items: universal + contextual, app: application)
        panel.setFrame(layout.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(surface)
        let masks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        local = NSEvent.addLocalMonitorForEvents(matching: masks) { [weak self] event in
            MainActor.assumeIsolated { if event.window !== self?.panel { self?.hide() } }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: masks) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let pid = app?.processIdentifier, pid != frontPID, pid != ProcessInfo.processInfo.processIdentifier {
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    func move(to point: CGPoint) { surface.highlight(geometry?.slot(at: point)) }

    @discardableResult func release(at point: CGPoint) -> Bool {
        // At screen edges the ring is clamped, so a stationary pointer can sit
        // on a sector. A quick click on the trigger should still open the dial.
        guard isVisible, hypot(point.x - openedAt.x, point.y - openedAt.y) >= 6,
              let index = geometry?.slot(at: point) else { return false }
        choose(index)
        return true
    }

    func hide() {
        if let local { NSEvent.removeMonitor(local); self.local = nil }
        if let global { NSEvent.removeMonitor(global); self.global = nil }
        if let applicationObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver); self.applicationObserver = nil }
        onSelect = nil
        geometry = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    func windowDidResignKey(_ notification: Notification) { if isVisible { hide() } }

    private func choose(_ index: Int) {
        guard let action = onSelect else { return }
        hide()
        action(index)
    }
}
