import AppKit
import ShadCore
import Carbon.HIToolbox

package enum MouseModule {
    package static let definition: FeatureModule = {
        let modifiers = controlKey | optionKey | cmdKey
        return FeatureModule(
            id: "mouse",
            appName: "Shad Mouse",
            category: "Mouse Tools",
            group: "Mouse",
            detail: "Open a shortcut dial or run a directional gesture",
            symbol: "computermouse.fill",
            tileColor: NSColor(srgbRed: 0.28, green: 0.50, blue: 0.85, alpha: 1),
            commandShortcuts: ["mouse.dial": KeyChord(46, modifiers, "M")]
        ) {
            let tool = MouseTool()
            return FeatureSession(commands: tool.commands, openStandalone: tool.showSettings)
        }
    }()
}
