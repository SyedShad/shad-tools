import AppKit
import Testing
@testable import ShadCore
@testable import ShadMouseFeature

@Suite("Mouse dial")
struct MouseDialTests {
    @Test func fourActionsOnEachSideUseTheSameDrawingAndHitOrder() {
        let g = MouseDialGeometry(frame: CGRect(x: -840, y: 180, width: 408, height: 408))
        for slot in 0..<8 {
            let point = g.actionCenter(slot)
            #expect(g.slot(at: point) == slot)
            #expect(g.path(slot).contains(point))
            #expect((point.x < g.center.x) == (slot < 4))
            if slot % 4 > 0 { #expect(point.y < g.actionCenter(slot - 1).y) }
        }
        #expect(g.slot(at: g.center) == nil)
        #expect(g.slot(at: CGPoint(x: g.center.x, y: g.center.y + g.outer * 0.85)) == nil)
        #expect(g.slot(at: CGPoint(x: g.frame.minX, y: g.frame.minY)) == nil)
    }

    @Test func keepsTheWholeDialOnTheInvokingDisplay() {
        let screens = [CGRect(x: 0, y: 70, width: 1440, height: 820),
                       CGRect(x: -1366, y: -510, width: 1366, height: 740),
                       CGRect(x: 340, y: 896, width: 326, height: 260)]
        for screen in screens {
            for x in [screen.minX, screen.midX, screen.maxX - 1] {
                for y in [screen.minY, screen.midY, screen.maxY - 1] {
                    let layout = MouseDialGeometry(at: CGPoint(x: x, y: y), in: screen)
                    #expect(screen.contains(layout.frame))
                    #expect(layout.frame.width == layout.frame.height)
                    for slot in 0..<8 { #expect(layout.slot(at: layout.actionCenter(slot)) == slot) }
                }
            }
            let center = CGPoint(x: screen.midX, y: screen.midY)
            #expect(MouseDialGeometry(at: center, in: screen).center == center)
        }
    }
}
