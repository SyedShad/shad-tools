import AppKit
import ShadCore
import Carbon.HIToolbox

package enum AudioModule {
    package static let definition: FeatureModule = {
        let modifiers = controlKey | optionKey | cmdKey
        return FeatureModule(
            id: "audio",
            appName: "Shad Audio",
            category: "Audio Manager",
            group: "Audio",
            detail: "Rank input and output devices independently",
            symbol: "waveform",
            tileColor: NSColor(srgbRed: 0.56, green: 0.36, blue: 0.94, alpha: 1),
            launcher: KeyChord(0, modifiers, "A")
        ) {
            let tool = AudioTool()
            return FeatureSession(commands: tool.commands)
        }
    }()
}
