import AppKit
import ShadColorValues
import ShadCore

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
                        group: "Color", keywords: "recent color colour history swatch",
                        swatch: NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                                        blue: CGFloat(color.blue) / 255, alpha: 1)) {
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
