import AppKit

/// CSS colors commonly placed on the pasteboard by design tools and browsers.
struct ClipboardColor: Equatable {
    let color: SampledColor
    let alpha: UInt8

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255, alpha: CGFloat(alpha) / 255)
    }
    var hex: String { color.hex + (alpha == 255 ? "" : String(format: "%02X", alpha)) }
    var rgb: String { formatted(.rgb, function: "rgba") }
    var hsl: String { formatted(.hsl, function: "hsla") }

    private func formatted(_ format: SampleFormat, function: String) -> String {
        let opaque = color.string(in: format)
        guard alpha != 255, let start = opaque.firstIndex(of: "(") else { return opaque }
        return function + opaque[start...].dropLast() + ", " + String(Double((Double(alpha) / 255 * 1000).rounded()) / 1000) + ")"
    }

    init?(css: String) {
        // Bail out before lowercasing or splitting entire documents.
        guard css.utf8.prefix(129).count <= 128 else { return nil }
        let text = css.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") {
            let digits = String(text.dropFirst())
            guard [3, 4, 6, 8].contains(digits.utf8.count),
                  digits.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            let expanded = digits.count < 5 ? digits.map { String(repeating: String($0), count: 2) }.joined() : digits
            guard let value = SampledColor(hex: String(expanded.prefix(6))) else { return nil }
            color = value
            alpha = expanded.count == 8 ? UInt8(expanded.suffix(2), radix: 16)! : 255
            return
        }
        guard let paren = text.firstIndex(of: "("), text.last == ")" else { return nil }
        let name = String(text[..<paren])
        let body = String(text[text.index(after: paren)..<text.index(before: text.endIndex)])
        let channels: [String]
        let opacity: String?
        if body.contains(",") {
            let parts = body.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard (3...4).contains(parts.count), !body.contains("/") else { return nil }
            channels = Array(parts.prefix(3))
            opacity = parts.count == 4 ? parts[3] : nil
        } else {
            let parts = body.components(separatedBy: "/")
            guard parts.count <= 2 else { return nil }
            channels = parts[0].split(whereSeparator: \.isWhitespace).map(String.init)
            opacity = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        guard channels.count == 3 else { return nil }
        if let opacity {
            guard let a = Self.component(opacity, max: 1) else { return nil }
            alpha = Self.byte(a)
        } else {
            alpha = 255
        }
        switch name {
        case "rgb", "rgba":
            let values = channels.compactMap { Self.component($0, max: 255) }
            guard values.count == 3 else { return nil }
            color = SampledColor(red: Self.byte(values[0]), green: Self.byte(values[1]), blue: Self.byte(values[2]))
        case "hsl", "hsla":
            guard let hue = Self.degrees(channels[0]), channels[1].hasSuffix("%"), channels[2].hasSuffix("%"),
                  let saturation = Self.component(channels[1], max: 1), let lightness = Self.component(channels[2], max: 1) else { return nil }
            let range = (1 - abs(2 * lightness - 1)) * saturation
            let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let x = range * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
            let options = [(range, x, 0.0), (x, range, 0), (0, range, x), (0, x, range), (x, 0, range), (range, 0, x)]
            let (r, g, b) = options[min(5, Int(h))]
            let offset = lightness - range / 2
            color = SampledColor(red: Self.byte(r + offset), green: Self.byte(g + offset), blue: Self.byte(b + offset))
        default: return nil
        }
    }

    private static func byte(_ value: Double) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }

    private static func component(_ token: String, max: Double) -> Double? {
        let percent = token.hasSuffix("%")
        guard let number = Double(percent ? String(token.dropLast()) : token), number.isFinite else { return nil }
        return min(1, Swift.max(0, number / (percent ? 100 : max)))
    }

    private static func degrees(_ token: String) -> Double? {
        let units = [("turn", 360.0), ("grad", 0.9), ("deg", 1.0), ("rad", 180 / Double.pi)]
        let unit = units.first { token.hasSuffix($0.0) } ?? ("", 1)
        guard let value = Double(token.dropLast(unit.0.count)) else { return nil }
        let result = value * unit.1
        return result.isFinite ? result : nil
    }
}
