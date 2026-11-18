import ShadCore
import AppKit

enum PaletteAppearance: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension ToolCommand {
    var kind: String {
        if id.hasPrefix("group.") || id == "clipboard.history" { return "Tool" }
        if fileURL != nil { return symbol == "app" ? "Application" : symbol == "folder" ? "Folder" : "File" }
        return "Command"
    }
    var primaryActionTitle: String {
        kind == "Command" ? "Run Command" : "Open " + kind
    }
}

enum PaletteAction: Hashable, Identifiable {
    case run, shortcut, favorite, settings
    case feature(ToolAction)
    var id: Self { self }

    func title(for command: ToolCommand, editing: Bool, favorite: Bool) -> String {
        switch self {
        case .run: return editing ? "Set Keyboard Shortcut" : command.primaryActionTitle
        case .shortcut: return "Set Keyboard Shortcut"
        case .favorite: return favorite ? "Remove from Favorites" : "Add to Favorites"
        case .feature(let action): return action.title
        case .settings: return "Open Settings"
        }
    }
    var symbol: String {
        switch self {
        case .run: return "return"
        case .shortcut: return "keyboard"
        case .favorite: return "star"
        case .feature(let action): return action.symbol
        case .settings: return "gearshape"
        }
    }
}
