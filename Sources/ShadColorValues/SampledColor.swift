import AppKit

package enum SampleFormat: String, CaseIterable {
    case hex = "HEX"
    case rgb = "RGB"
    case hsl = "HSL"
}

package struct SampledColor: Equatable {
    package let red: UInt8
    package let green: UInt8
    package let blue: UInt8

    package init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    package init?(color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> UInt8 {
            UInt8((min(1, max(0, component)) * 255).rounded())
        }
        self.init(red: byte(rgb.redComponent), green: byte(rgb.greenComponent), blue: byte(rgb.blueComponent))
    }

    package init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : hex[...]
        guard digits.utf8.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8((value >> 16) & 255), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
    }

    package var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    package func string(in format: SampleFormat) -> String {
        switch format {
        case .hex: return hex
        case .rgb: return "rgb(\(red), \(green), \(blue))"
        case .hsl:
            let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
            let high = max(r, g, b), low = min(r, g, b)
            let range = high - low
            let lightness = (high + low) / 2
            let saturation = range == 0 ? 0 : range / (1 - abs(2 * lightness - 1))
            var hue: Double = 0
            if range > 0 {
                if high == r { hue = (g - b) / range }
                else if high == g { hue = (b - r) / range + 2 }
                else { hue = (r - g) / range + 4 }
                hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
            }
            func decimal(_ value: Double) -> String {
                let tenths = Int((value * 10).rounded())
                return tenths % 10 == 0 ? String(tenths / 10) : "\(tenths / 10).\(tenths % 10)"
            }
            return "hsl(\(decimal(hue)), \(decimal(saturation * 100))%, \(decimal(lightness * 100))%)"
        }
    }
}
