import AppKit
import ShadCore
import Carbon.HIToolbox

package enum DrivesModule {
    package static let definition: FeatureModule = {
        let modifiers = controlKey | optionKey | cmdKey
        return FeatureModule(
            id: "drives",
            appName: "Shad Eject",
            category: "Easy Eject",
            group: "Drives",
            detail: "Safely eject external drives",
            symbol: "eject.fill",
            tileColor: NSColor(srgbRed: 0.96, green: 0.55, blue: 0.17, alpha: 1),
            launcher: KeyChord(2, modifiers, "D"),
            commandShortcuts: ["drives.eject-all": KeyChord(14, modifiers, "E")]
        ) {
            let tool = DrivesTool()
            return FeatureSession(commands: tool.commands)
        }
    }()
}
