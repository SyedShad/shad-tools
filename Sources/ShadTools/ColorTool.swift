import AppKit

enum SampleFormat: String, CaseIterable {
    case hex = "HEX"
    case rgb = "RGB"
    case hsl = "HSL"
}

struct SampledColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> UInt8 {
            UInt8((min(1, max(0, component)) * 255).rounded())
        }
        self.init(red: byte(rgb.redComponent), green: byte(rgb.greenComponent), blue: byte(rgb.blueComponent))
    }

    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : hex[...]
        guard digits.utf8.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8((value >> 16) & 255), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    func string(in format: SampleFormat) -> String {
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

struct SampleHistory {
    static let limit = 12
    private let defaults: UserDefaults
    private let key = "color.recent.srgb"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var colors: [SampledColor] {
        Array((defaults.stringArray(forKey: key) ?? []).compactMap(SampledColor.init(hex:)).prefix(Self.limit))
    }

    func record(_ color: SampledColor) {
        let recent = [color] + colors.filter { $0 != color }
        defaults.set(recent.prefix(Self.limit).map(\.hex), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}

@MainActor
final class ColorTool {
    private let history: SampleHistory
    private let clipboard: NSPasteboard
    private let sample: @MainActor () async -> NSColor?
    private var picking = false

    init(history: SampleHistory = SampleHistory(), clipboard: NSPasteboard = .general,
         sample: @escaping @MainActor () async -> NSColor? = { await NSColorSampler().sample() }) {
        self.history = history
        self.clipboard = clipboard
        self.sample = sample
    }

    func commands() -> [ToolCommand] {
        var entries = SampleFormat.allCases.map { format in
            ToolCommand(id: "color.pick.\(format.rawValue.lowercased())",
                        title: "Pick Screen Color as \(format.rawValue)",
                        subtitle: "Sample a pixel and copy \(format.rawValue)",
                        symbol: "eyedropper", group: "Color", keywords: "colour picker sample pixel eyedropper clipboard") {
                self.pick(format)
            }
        }
        let colors = history.colors
        if let latest = colors.first {
            entries += SampleFormat.allCases.map { format in
                ToolCommand(id: "color.last.\(format.rawValue.lowercased())",
                            title: "Copy Last Color as \(format.rawValue)", subtitle: latest.string(in: format),
                            symbol: "doc.on.doc", group: "Color", keywords: "previous sample colour clipboard") {
                    self.copy(latest, as: format)
                }
            }
        }
        entries += colors.map { color in
            ToolCommand(id: "color.history.\(color.hex.dropFirst())", title: color.hex,
                        subtitle: "Copy HEX · \(color.string(in: .rgb))", symbol: "circle.fill",
                        group: "Color", keywords: "recent color colour history swatch") {
                self.copy(color, as: .hex)
            }
        }
        if !colors.isEmpty {
            entries.append(ToolCommand(id: "color.history.clear", title: "Clear Color History",
                                       subtitle: "Remove the saved swatches", symbol: "trash",
                                       group: "Color", keywords: "forget recent colours") {
                self.history.clear()
                Commands.changed()
                Feedback.show("Color history cleared")
            })
        }
        return entries
    }

    private func pick(_ format: SampleFormat) {
        guard !picking else { return }
        picking = true
        Task { @MainActor in
            defer { picking = false }
            guard let selection = await sample() else { return }
            guard let color = SampledColor(color: selection) else {
                Feedback.show("Couldn’t convert that pixel to sRGB.")
                return
            }
            history.record(color)
            Commands.changed()
            copy(color, as: format)
        }
    }

    private func copy(_ color: SampledColor, as format: SampleFormat) {
        let value = color.string(in: format)
        clipboard.clearContents()
        Feedback.show(clipboard.setString(value, forType: .string) ? "Copied \(value)" : "Couldn’t write to the clipboard.")
    }
}
