import AppKit
import ShadCore
import Carbon.HIToolbox

package enum ClipboardModule {
    package static let definition: FeatureModule = {
        let modifiers = controlKey | optionKey | cmdKey
        return FeatureModule(
            id: "clipboard",
            appName: "Shad Clipboard",
            category: "Clipboard History",
            group: "Clipboard",
            detail: "Find and paste previously copied text and images",
            symbol: "list.clipboard",
            tileColor: NSColor(srgbRed: 0.18, green: 0.64, blue: 0.46, alpha: 1),
            commandShortcuts: ["clipboard.history": KeyChord(9, modifiers, "V")],
            homeCommand: "clipboard.history"
        ) {
            let tool = ClipboardTool()
            return FeatureSession(commands: tool.commands, openStandalone: tool.showHistory)
        }
    }()
}
