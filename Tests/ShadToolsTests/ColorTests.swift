import AppKit
import Testing
@testable import ShadCore
@testable import ShadColorFeature
@testable import ShadColorValues

@Suite("Color sampling")
struct ColorTests {
    @Test
    func convertsToEightBitSRGBAndFormatsCSS() throws {
        let yellow = try #require(SampledColor(color: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)))
        #expect(yellow.hex == "#FF8000")
        #expect(yellow.string(in: .rgb) == "rgb(255, 128, 0)")
        #expect(yellow.string(in: .hsl) == "hsl(30.1, 100%, 50%)")
        #expect(SampledColor(hex: "ff0080")?.string(in: .hsl) == "hsl(329.9, 100%, 50%)")
        #expect(SampledColor(hex: "#80ff00")?.string(in: .hsl) == "hsl(89.9, 100%, 50%)")
        #expect(SampledColor(hex: "#0000ff")?.string(in: .hsl) == "hsl(240, 100%, 50%)")
        #expect(SampledColor(hex: "000000")?.string(in: .hsl) == "hsl(0, 0%, 0%)")
        #expect(SampledColor(hex: "FFFFFF")?.string(in: .hsl) == "hsl(0, 0%, 100%)")
    }

    @Test @MainActor
    func samplesCopiesRecallsAndCancelsThroughCommands() async throws {
        let domain = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let board = NSPasteboard.withUniqueName()
        defer { defaults.removePersistentDomain(forName: domain); board.releaseGlobally() }
        let recent = SampleHistory(defaults: defaults)
        var selection: NSColor? = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        var calls = 0
        let tool = ColorTool(history: recent, clipboard: board) {
            calls += 1
            return selection
        }
        let pick = try #require(tool.commands().first { $0.id == "color.pick.rgb" })
        pick.perform()
        for _ in 0..<150 where calls < 1 { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(calls == 1)
        #expect(board.string(forType: .string) == "rgb(255, 0, 0)")
        try #require(tool.commands().first { $0.id == "color.last.hsl" }).perform()
        #expect(board.string(forType: .string) == "hsl(0, 100%, 50%)")
        try #require(tool.commands().first { $0.id == "color.history.FF0000" }).perform()
        #expect(board.string(forType: .string) == "#FF0000")
        selection = nil
        let previous = board.changeCount
        pick.perform()
        for _ in 0..<150 where calls < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(calls == 2)
        #expect(board.changeCount == previous)
        #expect(recent.colors.count == 1)
    }

    @Test
    func rejectsMalformedHex() {
        for invalid in ["", "F0F", "transparent", "12-456", "#FA12345", "0xFFAA", "+00001", "FFFZZZ"] {
            #expect(SampledColor(hex: invalid) == nil)
        }
    }

    @Test
    func remembersRecentColorsAcrossLaunchesAndBoundsHistory() throws {
        let domain = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let history = SampleHistory(defaults: defaults)
        for byte in 0...24 {
            history.record(SampledColor(red: UInt8(byte), green: 0, blue: 0))
        }
        let again = SampleHistory(defaults: defaults)
        let picked = SampledColor(red: 23, green: 0, blue: 0)
        again.record(picked)
        #expect(history.colors.first == picked)
        #expect(history.colors.count == SampleHistory.limit)
        #expect(Set(history.colors.map(\.hex)).count == history.colors.count)
        again.clear()
        #expect(history.colors.isEmpty)
    }
}
