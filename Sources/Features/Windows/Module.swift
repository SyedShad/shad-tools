import AppKit
import ShadCore
import Carbon.HIToolbox

package enum WindowsModule {
    package static let definition: FeatureModule = {
        let modifiers = controlKey | optionKey | cmdKey
        return FeatureModule(
            id: "windows",
            appName: "Shad Windows",
            category: "Window Layouts",
            group: "Windows",
            detail: "Tile windows and link their edges",
            symbol: "rectangle.split.2x1",
            tileColor: NSColor(srgbRed: 0.15, green: 0.67, blue: 0.76, alpha: 1),
            commandPrefix: "window",
            launcher: KeyChord(13, modifiers, "W"),
            commandShortcuts: [
                "window.left-half": KeyChord(123, modifiers, "←"),
                "window.right-half": KeyChord(124, modifiers, "→"),
                "window.bottom-half": KeyChord(125, modifiers, "↓"),
                "window.top-half": KeyChord(126, modifiers, "↑")
            ]
        ) {
            let tool = WindowTool()
            return FeatureSession(commands: tool.commands)
        }
    }()
}
