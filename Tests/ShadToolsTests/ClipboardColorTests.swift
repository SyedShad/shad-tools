import Testing
@testable import ShadCore
@testable import ShadClipboardFeature

@Suite("Clipboard color representations")
struct ClipboardColorTests {
    @Test func cssColorsPreserveAlphaAcrossRepresentations() {
        for value in ["#f008", "#FF000088", "rgb(100% 0% 0% / 53.33333%)", "hsla(1turn, 100%, 50%, 0.53333)"] {
            let color = ClipboardColor(css: value)
            #expect(color?.hex == "#FF000088")
            #expect(color?.rgb == "rgba(255, 0, 0, 0.533)")
            #expect(color?.hsl == "hsla(0, 100%, 50%, 0.533)")
        }
        #expect(ClipboardColor(css: "hsl(-120deg 100% 50%)")?.hex == "#0000FF")
        #expect(ClipboardColor(css: "RGB(100% 0% 100%)")?.hex == "#FF00FF")
    }

    @Test func ordinaryClipboardTextRemainsText() {
        for invalid in ["abc", "face", "ff0000", "#12345", "rgb(nan,0,0)", "hsl(1e300turn,1,1)", "rgb(1,,,3)", "rgba(1 2 / 3)"] {
            #expect(ClipboardColor(css: invalid) == nil)
        }
    }
}
