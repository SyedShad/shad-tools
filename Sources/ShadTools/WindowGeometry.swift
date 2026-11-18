import CoreGraphics
import Foundation

/// All frames use Accessibility coordinates, measured down from the primary display's top edge.
enum WindowLayout: String, CaseIterable {
    case leftHalf = "left-half", rightHalf = "right-half", topHalf = "top-half", bottomHalf = "bottom-half"
    case topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left", bottomRight = "bottom-right"
    case leftThird = "left-third", centerThird = "center-third", rightThird = "right-third"
    case leftTwoThirds = "left-two-thirds", rightTwoThirds = "right-two-thirds"
    case leftThreeQuarters = "left-three-quarters", rightThreeQuarters = "right-three-quarters"
    case maximize, center

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left Quarter"
        case .topRight: return "Top Right Quarter"
        case .bottomLeft: return "Bottom Left Quarter"
        case .bottomRight: return "Bottom Right Quarter"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two Thirds"
        case .rightTwoThirds: return "Right Two Thirds"
        case .leftThreeQuarters: return "Left Three Quarters"
        case .rightThreeQuarters: return "Right Three Quarters"
        case .maximize: return "Maximize Window"
        case .center: return "Center Window"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf, .leftThird, .leftTwoThirds, .leftThreeQuarters: return "rectangle.lefthalf.filled"
        case .rightHalf, .rightThird, .rightTwoThirds, .rightThreeQuarters: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return "rectangle.split.2x2"
        case .center, .centerThird: return "rectangle.center.inset.filled"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        }
    }

    func frame(on screen: CGRect, current: CGRect) -> CGRect {
        // Round each shared boundary once, including for odd-sized Retina work areas.
        func tile(_ left: Int, _ right: Int, of columns: Int, _ top: Int = 0, _ bottom: Int = 1, ofRows rows: Int = 1) -> CGRect {
            func x(_ i: Int) -> CGFloat { screen.minX + (screen.width * CGFloat(i) / CGFloat(columns)).rounded() }
            func y(_ i: Int) -> CGFloat { screen.minY + (screen.height * CGFloat(i) / CGFloat(rows)).rounded() }
            return CGRect(x: x(left), y: y(top), width: x(right) - x(left), height: y(bottom) - y(top))
        }
        switch self {
        case .leftHalf: return tile(0, 1, of: 2)
        case .rightHalf: return tile(1, 2, of: 2)
        case .topHalf: return tile(0, 1, of: 1, 0, 1, ofRows: 2)
        case .bottomHalf: return tile(0, 1, of: 1, 1, 2, ofRows: 2)
        case .topLeft: return tile(0, 1, of: 2, 0, 1, ofRows: 2)
        case .topRight: return tile(1, 2, of: 2, 0, 1, ofRows: 2)
        case .bottomLeft: return tile(0, 1, of: 2, 1, 2, ofRows: 2)
        case .bottomRight: return tile(1, 2, of: 2, 1, 2, ofRows: 2)
        case .leftThird: return tile(0, 1, of: 3)
        case .centerThird: return tile(1, 2, of: 3)
        case .rightThird: return tile(2, 3, of: 3)
        case .leftTwoThirds: return tile(0, 2, of: 3)
        case .rightTwoThirds: return tile(1, 3, of: 3)
        case .leftThreeQuarters: return tile(0, 3, of: 4)
        case .rightThreeQuarters: return tile(1, 4, of: 4)
        case .maximize: return screen
        case .center:
            let w = min(current.width, screen.width), h = min(current.height, screen.height)
            return CGRect(x: (screen.midX - w / 2).rounded(), y: (screen.midY - h / 2).rounded(), width: w, height: h)
        }
    }
}

enum WindowEdge: CaseIterable {
    case left, right, top, bottom
    var opposite: WindowEdge {
        switch self { case .left: return .right; case .right: return .left; case .top: return .bottom; case .bottom: return .top }
    }
    var vertical: Bool { self == .left || self == .right }

    func coordinate(in rect: CGRect) -> CGFloat {
        switch self { case .left: return rect.minX; case .right: return rect.maxX; case .top: return rect.minY; case .bottom: return rect.maxY }
    }

    func distance(from active: CGRect, to peer: CGRect) -> CGFloat? {
        let overlap: CGFloat, length: CGFloat
        if vertical {
            overlap = min(active.maxY, peer.maxY) - max(active.minY, peer.minY)
            length = min(active.height, peer.height)
        } else {
            overlap = min(active.maxX, peer.maxX) - max(active.minX, peer.minX)
            length = min(active.width, peer.width)
        }
        guard length > 0, overlap >= min(64, length * 0.4) else { return nil }
        return opposite.coordinate(in: peer) - coordinate(in: active)
    }

    /// Adjust only the neighbor's shared edge, preserving its outer boundary.
    func resizedPeer(from old: CGRect, to new: CGRect, peer: CGRect) -> CGRect? {
        let movement = coordinate(in: new) - coordinate(in: old)
        guard abs(movement) >= 1, abs(opposite.coordinate(in: old) - opposite.coordinate(in: new)) <= 2 else { return nil }
        let seam = coordinate(in: new)
        var result = peer
        switch self {
        case .right: result.size.width = peer.maxX - seam; result.origin.x = seam
        case .left: result.size.width = seam - peer.minX
        case .bottom: result.size.height = peer.maxY - seam; result.origin.y = seam
        case .top: result.size.height = seam - peer.minY
        }
        guard result.size.width >= 64, result.size.height >= 40 else { return nil }
        return result
    }
}

enum WindowGeometry {
    static func flip(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
    static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    static func screen(for window: CGRect, among screens: [CGRect]) -> Int? {
        screens.indices.max { area(window.intersection(screens[$0])) < area(window.intersection(screens[$1])) }
    }

    static func magnet(_ active: CGRect, peers: [CGRect], within screen: CGRect, threshold: CGFloat = 14) -> CGRect? {
        var dx: CGFloat?, dy: CGFloat?
        for peer in peers {
            for edge in WindowEdge.allCases {
                guard let offset = edge.distance(from: active, to: peer), abs(offset) <= threshold else { continue }
                if edge.vertical {
                    if dx == nil || abs(offset) < abs(dx!) { dx = offset }
                } else if dy == nil || abs(offset) < abs(dy!) { dy = offset }
            }
        }
        guard dx != nil || dy != nil else { return nil }
        let candidate = active.offsetBy(dx: dx ?? 0, dy: dy ?? 0)
        // Don't snap a window further off the display while preserving cross-display placements.
        guard area(candidate.intersection(screen)) >= area(active.intersection(screen)) - 1 else { return nil }
        return candidate
    }

    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
        WindowEdge.allCases.allSatisfy { abs($0.coordinate(in: lhs) - $0.coordinate(in: rhs)) <= tolerance }
    }
}
