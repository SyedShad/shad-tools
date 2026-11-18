import AppKit
import ApplicationServices

/// A reference to one application window. AX elements compare by identity across queries.
struct WindowReference: Equatable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }

    private static func value(_ key: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    private static func window(_ value: CFTypeRef?) -> WindowReference? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.12)
        return WindowReference(element: element)
    }
    private static func app(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        return app
    }

    static func focused(in pid: pid_t) -> Self? {
        let app = app(pid)
        return window(value(kAXFocusedWindowAttribute, of: app)) ?? window(value(kAXMainWindowAttribute, of: app))
    }
    static func at(_ point: CGPoint) -> Self? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.08)
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        if value(kAXRoleAttribute, of: hit) as? String == kAXWindowRole { return Self(element: hit) }
        return window(value(kAXWindowAttribute, of: hit))
    }

    var frame: CGRect? {
        guard let p = Self.value(kAXPositionAttribute, of: element),
              let s = Self.value(kAXSizeAttribute, of: element),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var isResizable: Bool {
        guard Self.value(kAXSubroleAttribute, of: element) as? String == kAXStandardWindowSubrole,
              Self.value("AXFullScreen", of: element) as? Bool != true,
              Self.value(kAXMinimizedAttribute, of: element) as? Bool != true else { return false }
        var movable = DarwinBoolean(false), sizable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &movable) == .success
            && AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizable) == .success
            && movable.boolValue && sizable.boolValue
    }

    /// Moving onto a different display can change the window's allowed size. Apply final size there.
    func apply(_ target: CGRect) -> CGRect? {
        guard let before = frame else { return nil }
        var origin = target.origin, size = target.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return nil }
        if target.width < before.width || target.height < before.height {
            _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        }
        if before.origin != origin {
            _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        }
        if before.size != size { _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
        if let actual = frame, actual.origin != origin {
            _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        }
        return frame
    }

    static func neighbors(of active: Self, within screen: CGRect) -> [(Self, CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var boundsByPID: [pid_t: [CGRect]] = [:], order: [pid_t] = []
        for row in rows {
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let pid = row[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let fields = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: fields as CFDictionary),
                  bounds.intersects(screen) else { continue }
            if boundsByPID[pid] == nil { order.append(pid) }
            boundsByPID[pid, default: []].append(bounds)
        }
        var peers: [(Self, CGRect)] = []
        for pid in order {
            guard let allowed = boundsByPID[pid], let windows = value(kAXWindowsAttribute, of: app(pid)) as? [AXUIElement] else { continue }
            for element in windows {
                let peer = Self(element: element)
                AXUIElementSetMessagingTimeout(element, 0.1)
                guard peer != active, let frame = peer.frame,
                      allowed.contains(where: { WindowGeometry.approximatelyEqual($0, frame, tolerance: 3) }), peer.isResizable else { continue }
                peers.append((peer, frame))
            }
        }
        return peers
    }
}
