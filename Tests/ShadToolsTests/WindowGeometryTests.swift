import CoreGraphics
import Testing
@testable import ShadCore
@testable import ShadWindowsFeature

struct WindowGeometryTests {
    let display = CGRect(x: -1919, y: -109, width: 1919, height: 1033)
    let sample = CGRect(x: -1800, y: 0, width: 900, height: 600)

    @Test func tilesMeetOnOddSizedSecondaryDisplay() {
        func tile(_ layout: WindowLayout) -> CGRect { layout.frame(on: display, current: sample) }
        #expect(tile(.leftHalf).maxX == tile(.rightHalf).minX)
        #expect(tile(.leftThird).maxX == tile(.centerThird).minX)
        #expect(tile(.rightThird).minX == tile(.centerThird).maxX)
        #expect(tile(.rightTwoThirds).minX == tile(.leftThird).maxX)
        #expect(tile(.leftTwoThirds).maxX == tile(.rightThird).minX)
        #expect(tile(.topLeft).maxY == tile(.bottomLeft).minY)
        #expect(tile(.topRight).minX == tile(.topLeft).maxX)
        #expect(tile(.leftThreeQuarters).width == 1439)
        #expect(tile(.rightThreeQuarters).maxX == display.maxX)
        for layout in WindowLayout.allCases { #expect(display.contains(tile(layout))) }
    }

    @Test func layoutsRespectWorkAreaAndChooseDisplayByIntersection() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let other = CGRect(x: -1919, y: -130, width: 1919, height: 1080)
        #expect(WindowGeometry.screen(for: CGRect(x: -300, y: 10, width: 500, height: 200), among: [primary, other]) == 1)
        let cocoa = CGRect(x: -1919, y: -50, width: 1919, height: 1033)
        let ax = WindowGeometry.flip(cocoa, primaryTop: 900)
        #expect(ax.minY == -83)
        #expect(WindowGeometry.flip(ax, primaryTop: 900) == cocoa)
        #expect(WindowLayout.maximize.frame(on: display, current: primary) == display)
        #expect(WindowLayout.center.frame(on: display, current: sample).size == sample.size)
    }

    @Test func movingBetweenDisplaysPreservesAnchorsAndFitsSmallerScreens() {
        let source = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let destination = CGRect(x: -1000, y: -100, width: 1000, height: 700)
        let bottomRight = CGRect(x: 1040, y: 600, width: 400, height: 300)
        #expect(WindowGeometry.move(bottomRight, from: source, to: destination) ==
                CGRect(x: -400, y: 300, width: 400, height: 300))
        #expect(WindowGeometry.move(source, from: source, to: destination) == destination)
        let centered = CGRect(x: 520, y: 300, width: 400, height: 300)
        let moved = WindowGeometry.move(centered, from: source, to: destination)
        #expect(moved.midX == destination.midX && moved.midY == destination.midY)
        #expect(moved.size == centered.size)
    }

    @Test func snapsAcrossOverlappingEdgesInBothDirections() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let active = CGRect(x: 100, y: 100, width: 500, height: 400)
        let beside = CGRect(x: 608, y: 200, width: 400, height: 400)
        let below = CGRect(x: 0, y: 507, width: 500, height: 200)
        #expect(WindowGeometry.magnet(active, peers: [beside, below], within: screen) == active.offsetBy(dx: 8, dy: 7))
        #expect(WindowGeometry.magnet(beside, peers: [active], within: screen) == beside.offsetBy(dx: -8, dy: 0))
        #expect(WindowGeometry.magnet(active, peers: [beside.offsetBy(dx: 15, dy: 0)], within: screen) == nil)
        #expect(WindowGeometry.magnet(active, peers: [beside.offsetBy(dx: 0, dy: 295)], within: screen) == nil)
    }

    @Test func shiftsSharedBoundaryWithoutChangingOuterEdges() {
        let first = CGRect(x: 0, y: 0, width: 600, height: 800)
        let second = first.offsetBy(dx: 600, dy: 0)
        let wider = CGRect(x: 0, y: 0, width: 750, height: 800)
        let narrower = CGRect(x: 750, y: 0, width: 450, height: 800)
        #expect(WindowEdge.right.resizedPeer(from: first, to: wider, peer: second) == narrower)
        #expect(WindowEdge.left.resizedPeer(from: second, to: narrower, peer: first) == wider)
        #expect(WindowEdge.right.resizedPeer(from: first, to: first.offsetBy(dx: 40, dy: 0), peer: second) == nil)
        #expect(WindowEdge.right.resizedPeer(from: first, to: CGRect(x: 0, y: 0, width: 1199, height: 800), peer: second) == nil)
        let top = CGRect(x: -600, y: -900, width: 500, height: 400)
        let bottom = top.offsetBy(dx: 0, dy: 400)
        let taller = CGRect(x: -600, y: -900, width: 500, height: 470)
        let shorter = CGRect(x: -600, y: -430, width: 500, height: 330)
        #expect(WindowEdge.bottom.resizedPeer(from: top, to: taller, peer: bottom) == shorter)
        #expect(WindowEdge.top.resizedPeer(from: bottom, to: shorter, peer: top) == taller)
    }
}
