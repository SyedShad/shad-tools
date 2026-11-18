import AppKit
import ShadCore
import Carbon.HIToolbox

package enum ColorModule {
    package static let definition: FeatureModule = {
        let modifiers = controlKey | optionKey | cmdKey
        return FeatureModule(
            id: "color",
            appName: "Shad Color",
            category: "Color Picker",
            group: "Color",
            detail: "Sample a pixel and copy its color",
            symbol: "eyedropper",
            tileColor: NSColor(srgbRed: 0.94, green: 0.29, blue: 0.54, alpha: 1),
            launcher: KeyChord(8, modifiers, "C")
        ) {
            let tool = ColorTool()
            return FeatureSession(commands: tool.commands)
        }
    }()
}
