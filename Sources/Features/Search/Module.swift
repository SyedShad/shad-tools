import AppKit
import ShadCore
import Carbon.HIToolbox

package enum SearchModule {
    package static let definition: FeatureModule = {
        let modifiers = controlKey | optionKey | cmdKey
        return FeatureModule(
            id: "search",
            appName: "Shad Search",
            category: "Search Mac",
            group: "Search",
            detail: "Applications, files and folders",
            symbol: "magnifyingglass",
            tileColor: NSColor(srgbRed: 0.23, green: 0.56, blue: 0.98, alpha: 1),
            launcher: KeyChord(1, modifiers, "S")
        ) {
            let tool = SearchTool()
            return FeatureSession(commands: tool.commands, search: tool.results(for:))
        }
    }()
}
