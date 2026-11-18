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
    var fileURL: URL? {
        for prefix in ["search.app.", "search.file."] where id.hasPrefix(prefix) {
            return URL(fileURLWithPath: String(id.dropFirst(prefix.count)))
        }
        return nil
    }
    var kind: String {
        if id.hasPrefix("group.") || id == "clipboard.history" { return "Tool" }
        if id.hasPrefix("search.app.") { return "Application" }
        if id.hasPrefix("search.file.") { return symbol == "folder" ? "Folder" : "File" }
        return "Command"
    }
    var primaryActionTitle: String {
        kind == "Command" ? "Run Command" : "Open " + kind
    }
}

enum PaletteAction: String, Identifiable {
    case run, shortcut, favorite, reveal, copyPath, settings
    var id: Self { self }

    func title(for command: ToolCommand, editing: Bool, favorite: Bool) -> String {
        switch self {
        case .run: return editing ? "Set Keyboard Shortcut" : command.primaryActionTitle
        case .shortcut: return "Set Keyboard Shortcut"
        case .favorite: return favorite ? "Remove from Favorites" : "Add to Favorites"
        case .reveal: return "Show in Finder"
        case .copyPath: return "Copy Path"
        case .settings: return "Open Settings"
        }
    }
    var symbol: String {
        switch self {
        case .run: return "return"
        case .shortcut: return "keyboard"
        case .favorite: return "star"
        case .reveal: return "folder"
        case .copyPath: return "doc.on.doc"
        case .settings: return "gearshape"
        }
    }
}
